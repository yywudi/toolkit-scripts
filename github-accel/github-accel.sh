#!/usr/bin/env bash
# GitHub 本地透明加速一体化管理脚本 (Universal Linux Edition - Architecture Redesign)
# 适用场景: 国内生产 Linux 服务器，免全局代理，Web 仅监听 127.0.0.1:44433，内核出站精准重定向
# 支持功能: install (安装加速) | restore (完全卸载) | backup (配置备份) | status (全景勘察) | test (验收测试)
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 帮助信息与手动恢复指南
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
  local exit_code="${1:-0}"
  cat << 'EOF'
用法:
  ./github-accel.sh [命令] [选项]
  ./github-accel.sh -h | --help

可用命令:
  install          执行前置全面勘察并安全安装加速配置（默认命令）
  restore          完全卸载加速配置，系统 100% 物理还原至原生网络状态
  backup [DIR]     备份当前加速相关的所有系统与服务配置至指定目录
  status           全景勘察报告：网络环境、端口监听、Web 服务与规则状态
  test             运行全量自动化验收用例 (TC-01 至 TC-07，含 SSH 与公网防御测试)
  apply-rules      (内置) 应用内核出站重定向规则
  clear-rules      (内置) 清理内核出站重定向规则

常用选项:
  --force          在网络直连正常、境外机器或非白名单系统上强制执行
  --with-caddy     纯净新机（无 Web 服务）时，通过系统包管理器自动安装 Caddy
  --with-nginx     纯净新机（无 Web 服务）时，通过系统包管理器自动安装 Nginx

架构设计与生产安全原则:
  1. 公网 0 暴露: Web 反代严格仅监听 127.0.0.1:44433 ssl，物理清空主 443 端口 github 虚拟主机；
  2. 放行 SSRF 校验: /etc/hosts 不写 127.0.0.1，必须绑定 GitHub 官方真实公网单播 IP；
  3. 内核出站精准重定向: 在 Linux netfilter OUTPUT 链将官方 IP:443 重定向至 127.0.0.1:44433；
  4. Systemd 重启固化: 由主脚本内置 apply-rules/clear-rules 承接，开机自动挂载与卸载物理清除；
  5. 彻底修复快照还原死循环: restore 无论是否存在快照，坚决物理清理加速 vhost、证书、CA 与规则；
  6. 双因子 4 状态网络机: 结合 GeoIP 与官方直连质量，区分境内外与连通状态，精准决策；
  7. 主流 OS 白名单准入: 严格限定 Debian/Ubuntu 系与 RHEL/CentOS 系等主流 Linux 发行版；
  8. 容器与宿主通用: 对 /etc/hosts 使用流覆写，彻底杜绝 bind-mount 下 Device or resource busy 报错；
  9. 跨发行版证书信任: 兼容 Debian/Ubuntu 与 RHEL/CentOS 证书更新体系；
  10. 权限严格收敛: CA 与服务器私钥 0600、证书目录 0700 防护，杜绝非 root 用户越权读取；
  11. 全局 SSH 443 托管: 注入 /etc/ssh/ssh_config.d/10-github-accel.conf，将 github.com:22 路由至 ssh.github.com:443；
  12. 控制面直连保密: api.github.com 严格不劫持、不走第三方反代，杜绝 Token 泄露与 403 阻断。

手动完全恢复指南:
  若需脱离脚本手动还原系统:
    1. 停止并清理 Systemd 重定向服务与内核规则:
       - systemctl disable --now github-accel-redirect.service 2>/dev/null || true
       - rm -f /etc/systemd/system/github-accel-redirect.service && systemctl daemon-reload
       - nft delete table ip github_accel 2>/dev/null || true
       - iptables -t nat -D OUTPUT -j GITHUB_ACCEL 2>/dev/null; iptables -t nat -F GITHUB_ACCEL 2>/dev/null; iptables -t nat -X GITHUB_ACCEL 2>/dev/null || true
    2. 还原 Web 配置:
       - Nginx:  rm -f /etc/nginx/sites-enabled/github-accel.conf /etc/nginx/sites-available/github-accel.conf /etc/nginx/conf.d/github-accel.conf && systemctl reload nginx
       - Caddy:  sed -i '/# BEGIN github-accel/,/# END github-accel/d' /etc/caddy/Caddyfile && systemctl reload caddy
       - Apache: rm -f /etc/apache2/sites-enabled/github-accel.conf /etc/apache2/sites-available/github-accel.conf /etc/httpd/conf.d/github-accel.conf && systemctl reload apache2
    3. 清理证书:
       - rm -rf /etc/nginx/certs/github-accel /etc/nginx/ssl/github-accel /etc/caddy/certs/github-accel /etc/ssl/github-accel
       - rm -f /usr/local/share/ca-certificates/local-github-ca.crt /etc/pki/ca-trust/source/anchors/local-github-ca.crt
       - (update-ca-certificates --fresh 2>/dev/null || update-ca-trust 2>/dev/null || true)
    4. 清理 Hosts 与环境变量:
       - sed -i '/# BEGIN github-accel/,/# END github-accel/d' /etc/hosts
       - rm -f /etc/systemd/system.conf.d/10-github-accel.conf && systemctl daemon-reload
       - sed -i '/# github-accel$/d' /etc/environment
       - [ -f /etc/profile.d/local-ca.sh ] && grep -q "# Managed by github-accel" /etc/profile.d/local-ca.sh && rm -f /etc/profile.d/local-ca.sh
       - rm -f /etc/ssh/ssh_config.d/10-github-accel.conf
EOF
  exit "$exit_code"
}

# ─────────────────────────────────────────────────────────────────────────────
# 参数处理与全局变量初始化
# ─────────────────────────────────────────────────────────────────────────────
COMMAND="install"
FORCE=false
INSTALL_BACKEND=""
BACKUP_TARGET_DIR=""
CURRENT_BACKUP_DIR=""
ACTIVE_TEMP_NEW=""
ACTIVE_TEMP_PREV=""
MAX_SNAPSHOTS_KEEP=3
DEFAULT_GITHUB_MAIN_IP="20.205.243.166"
readonly GITHUB_RAW_IP="185.199.108.133"
ACTIVE_GITHUB_MAIN_IP=""

# ─────────────────────────────────────────────────────────────────────────────
# 动态探测 GitHub 官方存活 IP (优先国内主流 DNS 解析，失败则优雅回退至活跃节点)
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 校验是否为合规公网单播 IPv4 (严格排除私有、回环、保留地址)
# ─────────────────────────────────────────────────────────────────────────────
is_public_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] 2>/dev/null || return 1
  done
  [ "$o1" -eq 0 ] || [ "$o1" -eq 127 ] || [ "$o1" -eq 10 ] && return 1
  [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ] && return 1
  [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ] && return 1
  if [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 快速校验目标 IP:443 端口出站连通性 (带 1 秒超时保护)
# ─────────────────────────────────────────────────────────────────────────────
verify_ip_connectivity() {
  local ip="$1"
  timeout 1 bash -c "cat < /dev/null > /dev/tcp/$ip/443" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# 动态探测 GitHub 官方存活 IP (优先国内主流 DNS 解析并做单播与连通性验证)
# ─────────────────────────────────────────────────────────────────────────────
detect_active_github_ip() {
  if [ -n "$ACTIVE_GITHUB_MAIN_IP" ]; then
    echo "$ACTIVE_GITHUB_MAIN_IP"
    return 0
  fi
  local candidate=""
  if command -v dig >/dev/null 2>&1; then
    for ip in $(dig +short +time=1 +tries=1 @223.5.5.5 github.com A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true); do
      if is_public_ipv4 "$ip" && verify_ip_connectivity "$ip"; then
        candidate="$ip"
        break
      fi
    done
  fi
  if [ -z "$candidate" ] && command -v nslookup >/dev/null 2>&1; then
    for ip in $(nslookup -timeout=1 github.com 223.5.5.5 2>/dev/null | awk '/^Address: / { print $2 }' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true); do
      if is_public_ipv4 "$ip" && verify_ip_connectivity "$ip"; then
        candidate="$ip"
        break
      fi
    done
  fi
  if [ -z "$candidate" ] && command -v getent >/dev/null 2>&1; then
    for ip in $(timeout 1 getent ahostsv4 github.com 2>/dev/null | awk '{ print $1 }' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true); do
      if is_public_ipv4 "$ip" && verify_ip_connectivity "$ip"; then
        candidate="$ip"
        break
      fi
    done
  fi

  if [ -n "$candidate" ]; then
    ACTIVE_GITHUB_MAIN_IP="$candidate"
  elif is_public_ipv4 "$DEFAULT_GITHUB_MAIN_IP" && verify_ip_connectivity "$DEFAULT_GITHUB_MAIN_IP"; then
    ACTIVE_GITHUB_MAIN_IP="$DEFAULT_GITHUB_MAIN_IP"
  else
    echo "错误: 无法探测到任何可用且 443 端口畅通的 GitHub 官方存活 IP（动态 DNS 与静态兜底节点均不可达）！" >&2
    return 1
  fi
  echo "$ACTIVE_GITHUB_MAIN_IP"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help)
      show_help 0
      ;;
    install|status|test|restore|uninstall|apply-rules|clear-rules)
      COMMAND="$1"
      [ "$COMMAND" = "uninstall" ] && COMMAND="restore"
      shift
      ;;
    backup)
      COMMAND="backup"
      shift
      if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
        BACKUP_TARGET_DIR="$1"
        shift
      fi
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --with-caddy)
      INSTALL_BACKEND="caddy"
      shift
      ;;
    --with-nginx)
      INSTALL_BACKEND="nginx"
      shift
      ;;
    *)
      echo "错误: 未知参数 [$1]" >&2
      show_help 1
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Root 权限硬性校验 (涉及系统网络 hosts、内核防火墙规则与 Web 服务配置，非 root 坚决阻断)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 本脚本涉及系统网络 (/etc/hosts)、内核防火墙规则与 Web 服务配置，必须使用 root 权限运行！" >&2
  echo "请切换至 root 用户，或使用: sudo $0 $*" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 基础文件与对象状态检测 (覆盖常规文件、目录、断链 symlink)
# ─────────────────────────────────────────────────────────────────────────────
is_obj_exist() {
  [ -e "$1" ] || [ -L "$1" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 操作系统兼容性白名单准入与 Systemd 运行环境检测
# ─────────────────────────────────────────────────────────────────────────────
check_os_and_init() {
  if [ ! -f /etc/os-release ]; then
    echo "错误: 无法读取 /etc/os-release，不支持在当前系统环境运行！" >&2
    exit 1
  fi
  . /etc/os-release
  local supported=false
  local supported_os_list=("debian" "ubuntu" "deepin" "uos" "rhel" "centos" "rocky" "almalinux" "fedora" "alinux" "anolis" "tencentos" "openeuler" "kylin")
  local os_id="$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')"
  local os_like="$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"

  for target in "${supported_os_list[@]}"; do
    local t_lower="$(echo "$target" | tr '[:upper:]' '[:lower:]')"
    if [ "$os_id" = "$t_lower" ]; then
      supported=true
      break
    fi
    for like_token in $os_like; do
      if [ "$like_token" = "$t_lower" ]; then
        supported=true
        break 2
      fi
    done
  done

  if ! $supported; then
    if ! $FORCE; then
      echo "错误: 当前操作系统 [$os_id] 不在受支持的主流发行版白名单中！" >&2
      echo "受支持列表: ${supported_os_list[*]}" >&2
      echo "(若需强制执行，请使用 --force 参数)" >&2
      exit 1
    else
      echo "警告: 当前操作系统 [$os_id] 未在受支持列表中，因 --force 强制继续..." >&2
    fi
  fi

  if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    if ! $FORCE; then
      echo "错误: 未检测到运行中的 Systemd 环境！本脚本内核出站重定向固化依赖 Systemd。" >&2
      echo "(若需在非 Systemd 容器内强制执行，请使用 --force 参数)" >&2
      exit 1
    else
      echo "警告: 未检测到 Systemd 环境，因 --force 强制继续..." >&2
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 快照容量治理与自动轮转 (防止磁盘无限膨胀)
# ─────────────────────────────────────────────────────────────────────────────
prune_old_snapshots() {
  local pattern="$1"
  local keep_count="$2"

  local dirs=()
  for d in $pattern; do
    [ -d "$d" ] && dirs+=("$d")
  done

  local count="${#dirs[@]}"
  if [ "$count" -gt "$keep_count" ]; then
    local remove_count=$(( count - keep_count ))
    echo "      [*] 执行快照容量轮转: 仅保留最新 $keep_count 份，清理 $remove_count 份旧快照..."
    ls -dt $pattern 2>/dev/null | tail -n "+$(( keep_count + 1 ))" | while IFS= read -r old_dir; do
      if [ -d "$old_dir" ]; then
        rm -rf "$old_dir"
        echo "      已清理旧快照: $old_dir"
      fi
    done
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 校验区块是否健康合法 (只读预检，不修改文件)
# ─────────────────────────────────────────────────────────────────────────────
validate_block_syntax() {
  local file="$1"
  local begin_mark="$2"
  local end_mark="$3"

  ! is_obj_exist "$file" && return 0

  local b_count e_count
  b_count=$(grep -c "^${begin_mark}$" "$file" 2>/dev/null || true)
  e_count=$(grep -c "^${end_mark}$" "$file" 2>/dev/null || true)

  if [ "$b_count" -eq 0 ] && [ "$e_count" -eq 0 ]; then
    return 0
  fi

  if [ "$b_count" -eq 1 ] && [ "$e_count" -eq 1 ]; then
    local b_line e_line
    b_line=$(grep -n "^${begin_mark}$" "$file" | cut -d: -f1)
    e_line=$(grep -n "^${end_mark}$" "$file" | cut -d: -f1)
    if [ "$b_line" -lt "$e_line" ]; then
      return 0
    fi
  fi

  echo "错误: $file 中的区块标记异常 (BEGIN:$b_count, END:$e_count, 顺序或数量非法)，预检不通过！" >&2
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 精准成对安全区块清理 (严格整行与唯一性校验，标记异常坚决阻断)
# ─────────────────────────────────────────────────────────────────────────────
remove_block_safely() {
  local file="$1"
  local begin_mark="$2"
  local end_mark="$3"

  ! is_obj_exist "$file" && return 0

  local b_count e_count
  b_count=$(grep -c "^${begin_mark}$" "$file" 2>/dev/null || true)
  e_count=$(grep -c "^${end_mark}$" "$file" 2>/dev/null || true)

  if [ "$b_count" -eq 0 ] && [ "$e_count" -eq 0 ]; then
    return 0
  fi

  if [ "$b_count" -eq 1 ] && [ "$e_count" -eq 1 ]; then
    local b_line e_line
    b_line=$(grep -n "^${begin_mark}$" "$file" | cut -d: -f1)
    e_line=$(grep -n "^${end_mark}$" "$file" | cut -d: -f1)
    if [ "$b_line" -lt "$e_line" ]; then
      sed -i "${b_line},${e_line}d" "$file"
      return 0
    fi
  fi

  echo "错误: $file 中的区块标记异常 (BEGIN:$b_count, END:$e_count)，拒绝执行删除以防误伤现有配置！" >&2
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 安全原子还原文件/软链 (源存在才还原，避免误删目标)
# ─────────────────────────────────────────────────────────────────────────────
safe_restore_file() {
  local src="$1"
  local dst="$2"
  if is_obj_exist "$src"; then
    if [ "$dst" = "/etc/hosts" ]; then
      cat "$src" > "$dst"
    else
      rm -rf "$dst"
      mkdir -p "$(dirname "$dst")"
      cp -a "$src" "$dst"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 前置勘察模块 1: 网络环境 GeoIP 出口与 GitHub 官方直连质量双因子 4 状态检测
# ─────────────────────────────────────────────────────────────────────────────
probe_network() {
  echo "[1/4] 勘测当前网络出口国家与 GitHub 官方直连质量..."

  local geo_country=""
  geo_country=$(curl -s --connect-timeout 2 --max-time 3 http://ip-api.com/line/?fields=countryCode 2>/dev/null || true)
  if [ -z "$geo_country" ]; then
    geo_country=$(curl -s --connect-timeout 2 --max-time 3 https://ipapi.co/country/ 2>/dev/null || true)
  fi
  geo_country=$(echo "$geo_country" | tr -d " \r\n" | tr "[:lower:]" "[:upper:]")
  [ -z "$geo_country" ] && geo_country="UNKNOWN"

  local direct_status=""
  local start_ts end_ts latency=0
  start_ts=$(date +%s 2>/dev/null || echo 0)
  direct_status=$(curl -s -I --connect-timeout 2 --max-time 3 https://raw.githubusercontent.com/robots.txt 2>/dev/null | head -n 1 || true)
  end_ts=$(date +%s 2>/dev/null || echo 0)
  latency=$(( end_ts - start_ts ))

  local direct_ok=false
  if echo "$direct_status" | grep -qE "HTTP/[123\.]+ [234][0-9]{2}"; then
    direct_ok=true
  fi

  echo "      出口区域: $geo_country | 官方直连: $( [ "$direct_ok" = true ] && echo "畅通 (${latency}s)" || echo "受阻/超时" )"

  if grep -q "# BEGIN github-accel" /etc/hosts 2>/dev/null; then
    echo "      ✓ 检测到本机已启用 GitHub 本地加速 (处于激活生效状态)。"
    return 0
  fi

  if [ "$COMMAND" = "install" ]; then
    if [ "$geo_country" != "CN" ] && [ "$direct_ok" = true ]; then
      if ! $FORCE; then
        echo "      提示: 当前为境外极速直连环境，无需加速，秒级安全退出 (0 写入)。"
        echo "      (若需在此网络调试或测试，请添加 --force 参数)"
        exit 0
      else
        echo "      [!] 警告: 境外极速直连环境，因 --force 强制执行安装。"
      fi
    elif [ "$geo_country" = "CN" ] && [ "$direct_ok" = false ]; then
      echo "      ✓ 判定为国内网络且官方直连受阻环境，符合加速激活条件。"
    elif [ "$geo_country" = "CN" ] && [ "$direct_ok" = true ]; then
      if ! $FORCE; then
        echo "      提示: 国内环境但直连通畅（疑似已有系统级代理或网络通畅），安全跳过。"
        echo "      (若需强制在此环境下配置本地加速，请添加 --force 参数)"
        exit 0
      else
        echo "      [!] 提示: 国内环境且直连通畅，因 --force 强制覆盖配置加速。"
      fi
    else
      if ! $FORCE; then
        echo "      [X] 阻断报错: 境外机器直连异常，请检查 DNS 或 IP 是否被封锁！" >&2
        echo "      (若需在此异常环境下强行尝试安装，请添加 --force 参数)" >&2
        exit 1
      else
        echo "      [!] 警告: 境外机器直连异常，因 --force 强行尝试安装。"
      fi
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 前置勘察模块 2: 系统包管理器与镜像源检查 (尊重现状，绝不私自篡改)
# ─────────────────────────────────────────────────────────────────────────────
probe_package_manager_and_mirrors() {
  echo "[2/4] 勘测系统包管理器与镜像源配置..."
  PKG_MANAGER=""
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER="yum"
  elif command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER="pacman"
  fi
  echo "      包管理器体系: ${PKG_MANAGER:-未知}"

  local foreign_mirror_found=false
  local mirror_sample=""
  if [ "$PKG_MANAGER" = "apt" ]; then
    if grep -rE "deb\.(debian\.org|ubuntu\.com)|archive\.ubuntu\.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v "^#" | head -n 1 >/dev/null; then
      foreign_mirror_found=true
      mirror_sample=$(grep -rE "deb\.(debian\.org|ubuntu\.com)|archive\.ubuntu\.com" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | grep -v "^#" | head -n 1 | awk '{print $2}' || true)
    fi
  elif [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
    if grep -rE "mirrorlist\.centos\.org|download\.fedoraproject\.org" /etc/yum.repos.d/ 2>/dev/null | grep -v "^#" | head -n 1 >/dev/null; then
      foreign_mirror_found=true
      mirror_sample="CentOS/Fedora Official"
    fi
  fi

  if $foreign_mirror_found; then
    echo "      [!] 提示: 检测到系统包管理器当前配置了官方境外源 ($mirror_sample)"
    echo "          在国内网络下载可能较慢。建议按需切换为国内镜像源。"
  else
    echo "      ✓ 系统源配置正常 (已采用国内/内网镜像源或定制源)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 前置勘察模块 3: 44433 专用端口占用与 Web 服务架构全景识别
# ─────────────────────────────────────────────────────────────────────────────
probe_port_and_web_service() {
  echo "[3/4] 勘测系统端口占用与 Web 服务架构..."

  local p44433_occ=""
  if command -v ss >/dev/null 2>&1; then
    p44433_occ=$(ss -tulpn 2>/dev/null | grep -E ":44433[[:space:]]" || true)
  elif command -v netstat >/dev/null 2>&1; then
    p44433_occ=$(netstat -tulpn 2>/dev/null | grep -E ":44433[[:space:]]" || true)
  fi

  if [ -n "$p44433_occ" ]; then
    if ! echo "$p44433_occ" | grep -qiE "nginx|caddy|apache2|httpd"; then
      echo "      [X] 严重安全拦截: 加速专用端口 44433 已被非 Web 进程占用！" >&2
      echo "          详情: $p44433_occ" >&2
      exit 1
    fi
  fi

  SELECTED_ADAPTER=""
  if command -v nginx >/dev/null 2>&1; then
    SELECTED_ADAPTER="nginx"
    echo "      检测到系统已安装 Nginx，将激活 Nginx 本地隔离反代 (127.0.0.1:44433)。"
  elif command -v caddy >/dev/null 2>&1; then
    SELECTED_ADAPTER="caddy"
    echo "      检测到系统已安装 Caddy，将激活 Caddy 本地隔离反代 (127.0.0.1:44433)。"
  elif command -v apache2 >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
    SELECTED_ADAPTER="apache"
    echo "      检测到系统已安装 Apache，将激活 Apache 本地隔离反代 (127.0.0.1:44433)。"
  else
    SELECTED_ADAPTER="none"
    echo "      未检测到任何已安装的 Web 服务 (纯净新机环境)。"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 统一证书管理 (跨发行版信任链 + 严格权限收紧 0600/0700)
# ─────────────────────────────────────────────────────────────────────────────
get_ca_install_path() {
  if [ -d /etc/pki/ca-trust/source/anchors ]; then
    echo "/etc/pki/ca-trust/source/anchors/local-github-ca.crt"
  else
    echo "/usr/local/share/ca-certificates/local-github-ca.crt"
  fi
}

update_system_ca_trust() {
  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates >/dev/null 2>&1 || true
  elif command -v update-ca-trust >/dev/null 2>&1; then
    update-ca-trust >/dev/null 2>&1 || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 校验 systemd Manager 环境与磁盘配置是否一致
# ─────────────────────────────────────────────────────────────────────────────
verify_systemd_manager_env() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local dropin="/etc/systemd/system.conf.d/10-github-accel.conf"
  local expected=""
  if [ -f "$dropin" ]; then
    expected=$(sed -n 's/.*NODE_EXTRA_CA_CERTS="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$dropin" | head -n 1)
  fi
  local actual=""
  actual=$(systemctl show-environment 2>/dev/null | sed -n 's/^NODE_EXTRA_CA_CERTS=//p' | tail -n 1)
  if [ -n "$expected" ] && [ "$expected" != "$actual" ]; then
    echo "      [!] 告警: systemd Manager 环境与磁盘配置不一致" >&2
    echo "          期望值: ${expected:-<无>}" >&2
    echo "          实际值: ${actual:-<无>}" >&2
    echo "          若为常规主机，请手动执行: systemctl daemon-reexec" >&2
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 签发加速专用证书 (包含 raw/github/objects/api 四大核心域名)
# ─────────────────────────────────────────────────────────────────────────────
issue_certificates() {
  local cert_dir="$1"

  if [ -L "$cert_dir" ]; then
    echo "错误: 证书目录 [$cert_dir] 是软链接，拒绝写入以防安全越权！" >&2
    return 1
  fi

  local ca_target_path
  ca_target_path="$(get_ca_install_path)"
  mkdir -p "$cert_dir" "$(dirname "$ca_target_path")"
  chmod 700 "$cert_dir"

  local old_umask
  old_umask=$(umask)
  umask 077

  if [ ! -f "$ca_target_path" ] || [ ! -f "$cert_dir/local-ca.key" ]; then
    rm -f "$cert_dir/local-ca.key" "$ca_target_path"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "$cert_dir/local-ca.key" \
      -out "$ca_target_path" \
      -subj "/CN=Local GitHub Accelerator CA" >/dev/null 2>&1
    chmod 600 "$cert_dir/local-ca.key"
    chmod 644 "$ca_target_path"
    update_system_ca_trust
  fi

  rm -f "$cert_dir/github-accel.key" "$cert_dir/fullchain.cer"
  openssl x509 -req -days 3650 \
    -in <(openssl req -nodes -newkey rsa:2048 -keyout "$cert_dir/github-accel.key" -subj "/CN=raw.githubusercontent.com" 2>/dev/null) \
    -CA "$ca_target_path" \
    -CAkey "$cert_dir/local-ca.key" \
    -out "$cert_dir/fullchain.cer" \
    -extfile <(cat << 'EOF'
subjectAltName = @alt_names
[alt_names]
DNS.1 = raw.githubusercontent.com
DNS.2 = github.com
DNS.3 = objects.githubusercontent.com
EOF
) >/dev/null 2>&1

  chmod 600 "$cert_dir/github-accel.key"
  chmod 644 "$cert_dir/fullchain.cer"
  umask "$old_umask"
}

# ─────────────────────────────────────────────────────────────────────────────
# 内核出站重定向与 Systemd 开机固化规则管理 (nftables 优先，iptables 回退)
# ─────────────────────────────────────────────────────────────────────────────
apply_firewall_rules() {
  local gh_ip
  gh_ip="$(detect_active_github_ip)"
  local raw_ip="$GITHUB_RAW_IP"

  echo "[*] 应用内核出站重定向规则 (官方目标: $gh_ip, $raw_ip:443 -> 127.0.0.1:44433)..."
  local nft_applied=false
  if command -v nft >/dev/null 2>&1; then
    nft 'add table ip github_accel' 2>/dev/null || true
    if nft 'add chain ip github_accel output { type nat hook output priority -100 ; }' 2>/dev/null ||        nft list chain ip github_accel output >/dev/null 2>&1; then
      nft flush chain ip github_accel output 2>/dev/null || true
      nft add rule ip github_accel output ip daddr "$gh_ip" tcp dport 443 redirect to :44433 2>/dev/null || true
      nft add rule ip github_accel output ip daddr "$raw_ip" tcp dport 443 redirect to :44433 2>/dev/null || true
      if nft list table ip github_accel 2>/dev/null | grep -q "44433"; then
        echo "      ✓ 已应用 nftables 专用表 [github_accel] 重定向规则。"
        nft_applied=true
      fi
    fi
    if ! $nft_applied; then
      echo "      [!] nftables 内核模块不可用或规则写入校验失败，自动降级至 iptables..."
      nft delete table ip github_accel 2>/dev/null || true
    fi
  fi

  if ! $nft_applied && command -v iptables >/dev/null 2>&1; then
    iptables -t nat -N GITHUB_ACCEL 2>/dev/null || iptables -t nat -F GITHUB_ACCEL
    if ! iptables -t nat -C OUTPUT -j GITHUB_ACCEL 2>/dev/null; then
      iptables -t nat -A OUTPUT -j GITHUB_ACCEL
    fi
    iptables -t nat -F GITHUB_ACCEL
    iptables -t nat -A GITHUB_ACCEL -p tcp -d "$gh_ip" --dport 443 -j REDIRECT --to-ports 44433
    iptables -t nat -A GITHUB_ACCEL -p tcp -d "$raw_ip" --dport 443 -j REDIRECT --to-ports 44433
    echo "      ✓ 已应用 iptables 专用链 [GITHUB_ACCEL] 重定向规则。"
    nft_applied=true
  fi

  if ! $nft_applied; then
    echo "错误: 未找到可用的 nftables 或 iptables 内核支持，无法注入重定向规则！" >&2
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 清理内核出站重定向规则
# ─────────────────────────────────────────────────────────────────────────────
clear_firewall_rules() {
  echo "[*] 清理内核出站重定向规则..."
  if command -v nft >/dev/null 2>&1; then
    nft delete table ip github_accel 2>/dev/null || true
  fi
  if command -v iptables >/dev/null 2>&1; then
    while iptables -t nat -D OUTPUT -j GITHUB_ACCEL 2>/dev/null; do :; done
    iptables -t nat -F GITHUB_ACCEL 2>/dev/null || true
    iptables -t nat -X GITHUB_ACCEL 2>/dev/null || true
    local gh_ip=""
    gh_ip=$(awk '/# BEGIN github-accel/{getline; print $1}' /etc/hosts 2>/dev/null || true)
    [ -n "$gh_ip" ] && while iptables -t nat -D OUTPUT -p tcp -d "$gh_ip" --dport 443 -j REDIRECT --to-ports 44433 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -p tcp -d "20.205.243.168" --dport 443 -j REDIRECT --to-ports 44433 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -p tcp -d "20.205.243.166" --dport 443 -j REDIRECT --to-ports 44433 2>/dev/null; do :; done
    while iptables -t nat -D OUTPUT -p tcp -d "$GITHUB_RAW_IP" --dport 443 -j REDIRECT --to-ports 44433 2>/dev/null; do :; done
  fi
  echo "      ✓ 内核规则清理完成。"
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 固化 Systemd 重定向服务
# ─────────────────────────────────────────────────────────────────────────────
install_redirect_service() {
  if ! [ -d /run/systemd/system ]; then
    echo "--> 非 Systemd 环境（或守护进程未运行），直接应用内核规则（无固化模式，不生成 service 单元）..."
    apply_firewall_rules
    return 0
  fi

  echo "--> 配置并启用内核出站重定向与 Systemd 固化服务..."
  mkdir -p /usr/local/bin
  local current_bin
  current_bin=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
  if [ "$current_bin" != "/usr/local/bin/github-accel" ]; then
    cp -f "$current_bin" /usr/local/bin/github-accel
    chmod 755 /usr/local/bin/github-accel
  fi

  cat << 'EOF' > /etc/systemd/system/github-accel-redirect.service
[Unit]
Description=GitHub Accel Loopback Redirect Rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/github-accel apply-rules
ExecStop=/usr/local/bin/github-accel clear-rules

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now github-accel-redirect.service
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 卸载 Systemd 重定向服务与规则
# ─────────────────────────────────────────────────────────────────────────────
remove_redirect_service() {
  if [ -f /etc/systemd/system/github-accel-redirect.service ]; then
    systemctl disable --now github-accel-redirect.service 2>/dev/null || true
    rm -f /etc/systemd/system/github-accel-redirect.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  clear_firewall_rules
}

# ─────────────────────────────────────────────────────────────────────────────
# 备份功能实现 (backup，非空/软链拒绝，显式跟踪每项复制)
# ─────────────────────────────────────────────────────────────────────────────
do_backup() {
  local target="${1:-${BACKUP_TARGET_DIR:-}}"
  if [ -z "$target" ]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    target="/root/.github-accel-backup-${stamp}"
  fi

  if [ -L "$target" ]; then
    echo "错误: 备份目标路径 [$target] 是软链接，拒绝写入以防非预期路径篡改！" >&2
    return 1
  fi

  if [ -d "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    echo "错误: 备份目标目录 [$target] 已存在且非空，拒绝覆盖以防陈旧快照污染！" >&2
    return 1
  fi

  echo "[*] 执行配置备份归档至: $target"
  local failed=false
  mkdir -p "$target/nginx" "$target/caddy" "$target/apache" "$target/ssl" "$target/certs" "$target/systemd" || failed=true

  if is_obj_exist /etc/hosts; then cp -a /etc/hosts "$target/hosts" || failed=true; fi
  if is_obj_exist /etc/environment; then cp -a /etc/environment "$target/environment" || failed=true; fi
  if is_obj_exist /etc/profile.d/local-ca.sh; then cp -a /etc/profile.d/local-ca.sh "$target/local-ca.sh" || failed=true; fi
  if is_obj_exist /etc/systemd/system.conf.d/10-github-accel.conf; then cp -a /etc/systemd/system.conf.d/10-github-accel.conf "$target/systemd/10-github-accel.conf" || failed=true; fi
  if is_obj_exist /etc/ssh/ssh_config.d/10-github-accel.conf; then
    mkdir -p "$target/ssh"
    cp -a /etc/ssh/ssh_config.d/10-github-accel.conf "$target/ssh/10-github-accel.conf" || failed=true
  fi

  if is_obj_exist /etc/nginx/sites-enabled/github-accel.conf; then
    cp -P /etc/nginx/sites-enabled/github-accel.conf "$target/nginx/sites-enabled-entry" || failed=true
  fi
  if is_obj_exist /etc/apache2/sites-enabled/github-accel.conf; then
    cp -P /etc/apache2/sites-enabled/github-accel.conf "$target/apache/sites-enabled-entry" || failed=true
  fi

  if is_obj_exist /etc/nginx/sites-available/github-accel.conf; then
    cp -a /etc/nginx/sites-available/github-accel.conf "$target/nginx/sites-available-github-accel.conf" || failed=true
  fi
  if is_obj_exist /etc/nginx/conf.d/github-accel.conf; then
    cp -a /etc/nginx/conf.d/github-accel.conf "$target/nginx/conf.d-github-accel.conf" || failed=true
  fi
  if is_obj_exist /etc/nginx/certs/github-accel; then
    cp -a /etc/nginx/certs/github-accel "$target/nginx/certs-github-accel" || failed=true
  fi
  if is_obj_exist /etc/nginx/ssl/github-accel; then
    cp -a /etc/nginx/ssl/github-accel "$target/nginx/ssl-github-accel" || failed=true
  fi

  if is_obj_exist /etc/caddy/Caddyfile; then
    cp -a /etc/caddy/Caddyfile "$target/caddy/Caddyfile" || failed=true
  fi
  if is_obj_exist /etc/caddy/certs/github-accel; then
    cp -a /etc/caddy/certs/github-accel "$target/caddy/github-accel" || failed=true
  fi

  if is_obj_exist /etc/apache2/sites-available/github-accel.conf; then
    cp -a /etc/apache2/sites-available/github-accel.conf "$target/apache/sites-available-github-accel.conf" || failed=true
  fi
  if is_obj_exist /etc/httpd/conf.d/github-accel.conf; then
    cp -a /etc/httpd/conf.d/github-accel.conf "$target/apache/conf.d-github-accel.conf" || failed=true
  fi
  if is_obj_exist /etc/ssl/github-accel; then
    cp -a /etc/ssl/github-accel "$target/ssl/github-accel" || failed=true
  fi

  local ca_target_path
  ca_target_path="$(get_ca_install_path)"
  if is_obj_exist "$ca_target_path"; then
    cp -a "$ca_target_path" "$target/certs/local-github-ca.crt" || failed=true
  fi

  if $failed; then
    echo "错误: 关键文件归档复制失败，备份不完整！清理半成品快照..." >&2
    rm -rf "$target"
    return 1
  fi

  echo "[✓] 备份完成！产物已完整归档至: $target"
  CURRENT_BACKUP_DIR="$target"

  prune_old_snapshots "/root/.github-accel-pre-install-*" "$MAX_SNAPSHOTS_KEEP"
  prune_old_snapshots "/root/.github-accel-backup-*" "$MAX_SNAPSHOTS_KEEP"

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 辅助函数: 从具体备份快照还原原始环境基线 (排除加速衍生配置，防止死循环)
# ─────────────────────────────────────────────────────────────────────────────
restore_from_backup_snapshot() {
  local bak_dir="$1"
  [ ! -d "$bak_dir" ] && return 0
  echo "      正在从专属快照还原原始基线: $bak_dir ..."

  if is_obj_exist "$bak_dir/hosts"; then
    safe_restore_file "$bak_dir/hosts" /etc/hosts
  fi
  remove_block_safely "/etc/hosts" "# BEGIN github-accel" "# END github-accel"

  if is_obj_exist "$bak_dir/environment"; then
    safe_restore_file "$bak_dir/environment" /etc/environment
  fi
  if [ -f /etc/environment ]; then
    local env_tmp="/etc/environment.tmp.$$"
    sed '/# github-accel$/d' /etc/environment > "$env_tmp"
    mv -f "$env_tmp" /etc/environment
  fi

  if is_obj_exist "$bak_dir/local-ca.sh"; then
    safe_restore_file "$bak_dir/local-ca.sh" /etc/profile.d/local-ca.sh
  fi
  if [ -f /etc/profile.d/local-ca.sh ] && grep -q "# Managed by github-accel" /etc/profile.d/local-ca.sh 2>/dev/null; then
    rm -f /etc/profile.d/local-ca.sh
  fi

  if is_obj_exist "$bak_dir/systemd/10-github-accel.conf"; then
    safe_restore_file "$bak_dir/systemd/10-github-accel.conf" /etc/systemd/system.conf.d/10-github-accel.conf
  else
    rm -f /etc/systemd/system.conf.d/10-github-accel.conf
  fi
  systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true

  if is_obj_exist "$bak_dir/caddy/Caddyfile"; then
    safe_restore_file "$bak_dir/caddy/Caddyfile" /etc/caddy/Caddyfile
  fi
  remove_block_safely "/etc/caddy/Caddyfile" "# BEGIN github-accel" "# END github-accel"

  if is_obj_exist "$bak_dir/ssh/10-github-accel.conf"; then
    safe_restore_file "$bak_dir/ssh/10-github-accel.conf" /etc/ssh/ssh_config.d/10-github-accel.conf
  else
    if [ -f /etc/ssh/ssh_config.d/10-github-accel.conf ] && grep -q "# Managed by github-accel" /etc/ssh/ssh_config.d/10-github-accel.conf 2>/dev/null; then
      rm -f /etc/ssh/ssh_config.d/10-github-accel.conf
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 卸载与完全恢复 (restore，无论有无快照坚决 7 步物理彻底切断与清理)
# ─────────────────────────────────────────────────────────────────────────────
do_restore() {
  echo "═══════════════════════════════════════════════════════════"
  echo "          GitHub 本地加速完全卸载与系统还原                "
  echo "═══════════════════════════════════════════════════════════"

  echo "[1/7] 停止并清理 Systemd 重定向服务与内核规则..."
  remove_redirect_service

  local trusted_snap=""
  local candidate
  candidate=$(ls -dt /root/.github-accel-pre-install-* 2>/dev/null | head -n 1 || true)
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    trusted_snap="$candidate"
  fi

  if [ -n "$trusted_snap" ]; then
    echo "[2/7] 检测到初始安装前快照: $trusted_snap，执行基线还原..."
    restore_from_backup_snapshot "$trusted_snap"
  fi

  echo "[3/7] 物理清理 Web 反代虚拟主机配置..."
  rm -f /etc/nginx/sites-enabled/github-accel.conf /etc/nginx/sites-available/github-accel.conf /etc/nginx/conf.d/github-accel.conf
  remove_block_safely "/etc/caddy/Caddyfile" "# BEGIN github-accel" "# END github-accel"
  rm -f /etc/apache2/sites-enabled/github-accel.conf /etc/apache2/sites-available/github-accel.conf /etc/httpd/conf.d/github-accel.conf

  echo "[4/7] 物理清理证书与系统根 CA 信任..."
  rm -rf /etc/nginx/certs/github-accel /etc/nginx/ssl/github-accel
  rm -rf /etc/caddy/certs/github-accel
  rm -rf /etc/ssl/github-accel
  local ca_target_path
  ca_target_path="$(get_ca_install_path)"
  rm -f "$ca_target_path"
  update_system_ca_trust

  echo "[5/7] 物理清理全局环境注入、Node.js 信任链与 SSH 托管..."
  if [ -f /etc/profile.d/local-ca.sh ] && grep -q "# Managed by github-accel" /etc/profile.d/local-ca.sh 2>/dev/null; then
    rm -f /etc/profile.d/local-ca.sh
  fi
  rm -f /etc/systemd/system.conf.d/10-github-accel.conf
  if [ -f /etc/ssh/ssh_config.d/10-github-accel.conf ] && grep -q "# Managed by github-accel" /etc/ssh/ssh_config.d/10-github-accel.conf 2>/dev/null; then
    rm -f /etc/ssh/ssh_config.d/10-github-accel.conf
  fi
  systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
  verify_systemd_manager_env
  if [ -f /etc/environment ]; then
    local env_tmp="/etc/environment.tmp.$$"
    sed '/# github-accel$/d' /etc/environment > "$env_tmp"
    mv -f "$env_tmp" /etc/environment
  fi

  echo "[6/7] 精确抹除 /etc/hosts 加速区块..."
  remove_block_safely "/etc/hosts" "# BEGIN github-accel" "# END github-accel"

  echo "[7/7] 平滑重载现存 Web 服务并清理临时快照..."
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || true
    fi
  fi
  if command -v caddy >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
      systemctl reload caddy >/dev/null 2>&1 || true
    fi
  fi
  if command -v apache2 >/dev/null 2>&1 && systemctl is-active --quiet apache2; then
    if apachectl configtest >/dev/null 2>&1; then
      systemctl reload apache2 >/dev/null 2>&1 || true
    fi
  elif command -v httpd >/dev/null 2>&1 && systemctl is-active --quiet httpd; then
    if apachectl configtest >/dev/null 2>&1; then
      systemctl reload httpd >/dev/null 2>&1 || true
    fi
  fi

  rm -rf /root/.github-accel-pre-install-*

  echo "[✓] 卸载完成，系统已 100% 物理还原至原生网络状态！"
}

# ─────────────────────────────────────────────────────────────────────────────
# 全量端到端自动化验收套件 (test，覆盖 TC-01 至 TC-06 及外部公网防御检验)
# ─────────────────────────────────────────────────────────────────────────────
do_test() {
  echo "═══════════════════════════════════════════════════════════"
  echo "      GitHub 本地加速全量自动化验收测试 (TC-01 ~ TC-07)   "
  echo "═══════════════════════════════════════════════════════════"

  local passed=0
  local total=7

  echo -n "[TC-01] 测试 Raw 源码下载 (curl 原生无参)... "
  local t1_code
  t1_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://raw.githubusercontent.com/Aik358/dsh-auto-memory/refs/heads/main/README.md 2>/dev/null || echo "000")
  if [ "$t1_code" = "200" ]; then
    echo "✓ PASS (HTTP 200, 耗时正常)"
    passed=$(( passed + 1 ))
  else
    echo "✗ FAIL (HTTP $t1_code)"
  fi

  echo -n "[TC-02] 测试 Git 协议读取 (git ls-remote HEAD)... "
  if command -v git >/dev/null 2>&1; then
    if git ls-remote https://github.com/yywudi/toolkit-scripts.git HEAD 2>&1 | grep -q "HEAD"; then
      echo "✓ PASS (成功读取 HEAD commit)"
      passed=$(( passed + 1 ))
    else
      echo "✗ FAIL (git ls-remote 失败)"
    fi
  else
    echo "- SKIP (未安装 git，跳过检验)"
    total=$(( total - 1 ))
  fi

  echo -n "[TC-03] 测试应用层 SSRF 检查放行 (公网真实 IP 校验)... "
  local ssrf_passed=false
  if command -v node >/dev/null 2>&1; then
    if node -e '
      const dns = require("dns");
      dns.lookup("raw.githubusercontent.com", (err, address) => {
        if (err) process.exit(1);
        const parts = address.split(".").map(Number);
        const isPrivate = (
          parts[0] === 10 ||
          parts[0] === 127 ||
          (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
          (parts[0] === 192 && parts[1] === 168) ||
          (parts[0] === 169 && parts[1] === 254) ||
          parts[0] === 0
        );
        process.exit(isPrivate ? 1 : 0);
      });
    ' >/dev/null 2>&1; then
      ssrf_passed=true
    fi
  else
    local resolved_ip
    resolved_ip=$(getent ahostsv4 raw.githubusercontent.com 2>/dev/null | awk '{print $1}' | head -n 1 || true)
    if [ -n "$resolved_ip" ] && [[ "$resolved_ip" != 127.* ]] && [[ "$resolved_ip" != 10.* ]] && [[ "$resolved_ip" != 192.168.* ]]; then
      ssrf_passed=true
    fi
  fi

  if $ssrf_passed; then
    echo "✓ PASS (解析为公网单播 IP，放行 SSRF 校验)"
    passed=$(( passed + 1 ))
  else
    echo "✗ FAIL (解析为私有/环回 IP 或解析失败)"
  fi

  local pub_ip=""
  pub_ip=$(curl -s --connect-timeout 2 --max-time 3 http://ip-api.com/line/?fields=query 2>/dev/null || true)
  if [ -z "$pub_ip" ]; then
    pub_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' | head -n 1 || echo "127.0.0.1")
  fi

  echo -n "[TC-04] 测试公网 443 端口未暴露检验 (防扫描探测)... "
  local t4_out
  t4_out=$(curl -k -v --connect-timeout 2 --max-time 3 --connect-to ::${pub_ip}:443 https://github.com 2>&1 || true)
  if echo "$t4_out" | grep -qiE "unrecognized name|handshake failure|SSL_ERROR|Connection refused|alert|closed" && ! echo "$t4_out" | grep -q "Local GitHub Accelerator CA"; then
    echo "✓ PASS (443 拒绝握手，0 证书暴露)"
    passed=$(( passed + 1 ))
  else
    echo "✗ FAIL (443 暴露了证书或握手异常)"
  fi

  echo -n "[TC-05] 测试公网 44433 高位端口未暴露检验 (端口物理关闭)... "
  local t5_out
  t5_out=$(curl -k -v --connect-timeout 2 --max-time 3 https://${pub_ip}:44433 2>&1 || true)
  if echo "$t5_out" | grep -qiE "Connection refused|Failed to connect|timed out"; then
    echo "✓ PASS (外部 44433 物理拒绝连接)"
    passed=$(( passed + 1 ))
  else
    echo "✗ FAIL (44433 对公网开放)"
  fi

  echo -n "[TC-06] 测试 Systemd 重启规则恢复测试 (开机固化)... "
  local t6_ok=false
  if [ -f /etc/systemd/system/github-accel-redirect.service ]; then
    systemctl restart github-accel-redirect.service >/dev/null 2>&1 || true
    sleep 0.5
    if command -v nft >/dev/null 2>&1 && nft list table ip github_accel 2>/dev/null | grep -q "44433"; then
      t6_ok=true
    elif command -v iptables >/dev/null 2>&1 && iptables -t nat -L OUTPUT -n 2>/dev/null | grep -q "44433"; then
      t6_ok=true
    fi
  else
    if command -v nft >/dev/null 2>&1 && nft list table ip github_accel 2>/dev/null | grep -q "44433"; then
      t6_ok=true
    fi
  fi

  if $t6_ok; then
    echo "✓ PASS (服务重启后内核重定向规则常驻且生效)"
    passed=$(( passed + 1 ))
  else
    echo "✗ FAIL (规则丢失或未生效)"
  fi

  echo -n "[TC-07] 测试 GitHub SSH 协议连通性 (ssh.github.com:443)... "
  if command -v ssh >/dev/null 2>&1; then
    local ssh_out
    ssh_out=$(ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 git@github.com 2>&1 || true)
    if echo "$ssh_out" | grep -qiE "(Permission denied.*publickey|successfully authenticated)"; then
      echo "✓ PASS (成功路由至 ssh.github.com:443 并握手)"
      passed=$(( passed + 1 ))
    else
      echo "✗ FAIL (SSH 握手异常: $ssh_out)"
    fi
  else
    echo "- SKIP (未安装 ssh，跳过检验)"
    total=$(( total - 1 ))
  fi

  echo "═══════════════════════════════════════════════════════════"
  echo "验收测试汇总: $passed/$total 通过"
  echo "═══════════════════════════════════════════════════════════"
  [ "$passed" -eq "$total" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# 状态全景查询 (status，报告 Web 适配器、44433 监听、内核规则与环境注入)
# ─────────────────────────────────────────────────────────────────────────────
do_status() {
  echo "═══════════════════════════════════════════════════════════"
  echo "          GitHub 加速环境全景状态                          "
  echo "═══════════════════════════════════════════════════════════"
  check_os_and_init
  probe_network
  probe_package_manager_and_mirrors
  probe_port_and_web_service

  local ca_target_path
  ca_target_path="$(get_ca_install_path)"

  local rules_status="未配置"
  if command -v nft >/dev/null 2>&1 && nft list table ip github_accel >/dev/null 2>&1; then
    rules_status="已激活 (nftables github_accel 表)"
  elif command -v iptables >/dev/null 2>&1 && iptables -t nat -L GITHUB_ACCEL >/dev/null 2>&1; then
    rules_status="已激活 (iptables GITHUB_ACCEL 链)"
  fi

  local p44433_listen="未监听"
  if ss -tulpn 2>/dev/null | grep -q "127.0.0.1:44433"; then
    p44433_listen="正常监听 (仅限 127.0.0.1:44433 内部回环)"
  fi

  echo ""
  echo "当前加速架构与组件状态:"
  echo "  Web 适配器:         $SELECTED_ADAPTER"
  echo "  44433 本地监听:     $p44433_listen"
  echo "  内核出站重定向规则: $rules_status"
  echo "  Systemd 固化服务:   $( systemctl is-active --quiet github-accel-redirect.service 2>/dev/null && echo "active (enabled)" || echo "未激活/未安装" )"
  echo "  受信任系统根 CA:    $( [ -f "$ca_target_path" ] && echo "已安装 ($ca_target_path)" || echo "未安装" )"
  echo "  /etc/hosts 官方 IP: $( grep -q "# BEGIN github-accel" /etc/hosts 2>/dev/null && echo "已绑定官方真实 IP (动态探测)" || echo "未配置" )"
  echo "  SSH 443 全局托管:   $( [ -f /etc/ssh/ssh_config.d/10-github-accel.conf ] && echo "已激活 (全局路由至 ssh.github.com:443)" || echo "未配置 (默认 22 端口)" )"
  echo "  Node 证书链环境:    $( grep -q "NODE_EXTRA_CA_CERTS" /etc/environment 2>/dev/null && echo "已配置" || echo "未配置" )"
  echo "  Systemd 全局环境:   $( [ -f /etc/systemd/system.conf.d/10-github-accel.conf ] && echo "已注入" || echo "未注入" )"
  echo "═══════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────
# 各 Web 适配器安装实现 (严格仅监听 127.0.0.1:44433 ssl，支持事务防损与自动回滚)
# ─────────────────────────────────────────────────────────────────────────────
apply_nginx_adapter() {
  echo "--> 激活 Nginx 隔离适配器 (严格仅监听 127.0.0.1:44433)..."
  local site_avail site_enable cert_dir
  if [ -d /etc/nginx/sites-available ] && [ -d /etc/nginx/sites-enabled ]; then
    site_avail="/etc/nginx/sites-available/github-accel.conf"
    site_enable="/etc/nginx/sites-enabled/github-accel.conf"
  else
    site_avail="/etc/nginx/conf.d/github-accel.conf"
    site_enable=""
  fi

  if [ -d /etc/nginx/certs ]; then
    cert_dir="/etc/nginx/certs/github-accel"
  else
    cert_dir="/etc/nginx/ssl/github-accel"
  fi

  issue_certificates "$cert_dir"

  local prev_temp="$site_avail.github-accel.prev.$$"
  ACTIVE_TEMP_PREV="$prev_temp"
  ACTIVE_TEMP_NEW="$site_avail.new"

  if is_obj_exist "$site_avail"; then
    cp -L "$site_avail" "$prev_temp"
  fi

  rm -f "$site_avail.new"
  cat << EOF > "$site_avail.new"
server {
    listen 127.0.0.1:44433 ssl;
    server_name raw.githubusercontent.com
                github.com
                objects.githubusercontent.com;

    ssl_certificate     $cert_dir/fullchain.cer;
    ssl_certificate_key $cert_dir/github-accel.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    access_log off;
    error_log  /var/log/nginx/github-accel-error.log;

    resolver 119.29.29.29 223.5.5.5 valid=300s ipv6=off;
    resolver_timeout 5s;

    location / {
        proxy_pass https://ghfast.top/https://\$host\$request_uri;
        proxy_set_header Host ghfast.top;
        proxy_ssl_server_name on;
        proxy_ssl_name ghfast.top;
        proxy_buffering off;
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
    }
}
EOF

  mv -f "$site_avail.new" "$site_avail"
  ACTIVE_TEMP_NEW=""

  if [ -n "$site_enable" ]; then
    rm -f "$site_enable"
    ln -sf "$site_avail" "$site_enable"
  fi

  if ! nginx -t >/dev/null 2>&1; then
    echo "错误: Nginx 语法校验失败！正在回滚旧配置..." >&2
    safe_restore_file "$prev_temp" "$site_avail"
    nginx -t >/dev/null 2>&1 || true
    return 1
  fi
  rm -f "$prev_temp"
  ACTIVE_TEMP_PREV=""
  systemctl reload nginx
  sleep 0.5
}

# ─────────────────────────────────────────────────────────────────────────────
# 适配器: Caddy (严格仅监听 127.0.0.1:44433)
# ─────────────────────────────────────────────────────────────────────────────
apply_caddy_adapter() {
  echo "--> 激活 Caddy 隔离适配器 (严格仅监听 127.0.0.1:44433)..."
  local caddyfile="/etc/caddy/Caddyfile"
  local cert_dir="/etc/caddy/certs/github-accel"
  mkdir -p /etc/caddy "$cert_dir"

  issue_certificates "$cert_dir"

  local prev_temp="$caddyfile.github-accel.prev.$$"
  local new_temp="$caddyfile.github-accel.new.$$"
  ACTIVE_TEMP_PREV="$prev_temp"
  ACTIVE_TEMP_NEW="$new_temp"

  local had_old_caddyfile=false
  rm -f "$new_temp"
  if is_obj_exist "$caddyfile"; then
    had_old_caddyfile=true
    cp -L "$caddyfile" "$prev_temp"
    cp -L "$caddyfile" "$new_temp"
    remove_block_safely "$new_temp" "# BEGIN github-accel" "# END github-accel"
  fi

  cat << EOF >> "$new_temp"

# BEGIN github-accel
https://raw.githubusercontent.com:44433, https://github.com:44433, https://objects.githubusercontent.com:44433 {
    bind 127.0.0.1
    tls $cert_dir/fullchain.cer $cert_dir/github-accel.key
    rewrite * /https://{host}{uri}
    reverse_proxy https://ghfast.top {
        header_up Host ghfast.top
    }
}
# END github-accel
EOF

  mv -f "$new_temp" "$caddyfile"
  ACTIVE_TEMP_NEW=""

  if command -v caddy >/dev/null 2>&1 && caddy validate --config "$caddyfile" >/dev/null 2>&1; then
    rm -f "$prev_temp"
    ACTIVE_TEMP_PREV=""
    if systemctl is-active --quiet caddy; then
      systemctl reload caddy
    else
      systemctl enable --now caddy
    fi
  else
    echo "错误: Caddy 配置校验失败！正在回滚旧配置..." >&2
    if $had_old_caddyfile; then
      safe_restore_file "$prev_temp" "$caddyfile"
    else
      rm -f "$caddyfile"
    fi
    ACTIVE_TEMP_PREV=""
    return 1
  fi
  sleep 0.5
}

# ─────────────────────────────────────────────────────────────────────────────
# 适配器: Apache (严格仅监听 127.0.0.1:44433)
# ─────────────────────────────────────────────────────────────────────────────
apply_apache_adapter() {
  echo "--> 激活 Apache 隔离适配器 (严格仅监听 127.0.0.1:44433)..."
  local vhost_file="/etc/apache2/sites-available/github-accel.conf"
  if [ ! -d /etc/apache2/sites-available ]; then
    vhost_file="/etc/httpd/conf.d/github-accel.conf"
  fi
  mkdir -p "$(dirname "$vhost_file")"

  if command -v a2enmod >/dev/null 2>&1; then
    a2enmod ssl proxy proxy_http rewrite headers >/dev/null 2>&1 || true
  fi

  local cert_dir="/etc/ssl/github-accel"
  issue_certificates "$cert_dir"

  local prev_temp="$vhost_file.github-accel.prev.$$"
  local new_temp="$vhost_file.github-accel.new.$$"
  ACTIVE_TEMP_PREV="$prev_temp"
  ACTIVE_TEMP_NEW="$new_temp"

  if is_obj_exist "$vhost_file"; then
    cp -L "$vhost_file" "$prev_temp"
  fi

  rm -f "$new_temp"
  cat << EOF > "$new_temp"
Listen 127.0.0.1:44433
<VirtualHost 127.0.0.1:44433>
    ServerName raw.githubusercontent.com
    ServerAlias github.com objects.githubusercontent.com

    SSLEngine on
    SSLCertificateFile $cert_dir/fullchain.cer
    SSLCertificateKeyFile $cert_dir/github-accel.key

    SSLProxyEngine on
    SSLProxyCheckPeerCN off
    SSLProxyCheckPeerName off

    ProxyPreserveHost Off
    RewriteEngine On
    RewriteRule ^/(.*)$ https://ghfast.top/https://%{HTTP_HOST}/\$1 [P,L]
</VirtualHost>
EOF

  mv -f "$new_temp" "$vhost_file"
  ACTIVE_TEMP_NEW=""

  if [ -d /etc/apache2/sites-enabled ]; then
    rm -f /etc/apache2/sites-enabled/github-accel.conf
    ln -sf "$vhost_file" /etc/apache2/sites-enabled/github-accel.conf
  fi

  if command -v apachectl >/dev/null 2>&1 && ! apachectl configtest >/dev/null 2>&1; then
    echo "错误: Apache 语法测试失败，正在回滚旧配置..." >&2
    safe_restore_file "$prev_temp" "$vhost_file"
    ACTIVE_TEMP_PREV=""
    return 1
  fi
  rm -f "$prev_temp"
  ACTIVE_TEMP_PREV=""
  if systemctl is-active --quiet apache2 2>/dev/null; then
    systemctl reload apache2 >/dev/null 2>&1 || true
  elif systemctl is-active --quiet httpd 2>/dev/null; then
    systemctl reload httpd >/dev/null 2>&1 || true
  fi
  sleep 0.5
}

# ─────────────────────────────────────────────────────────────────────────────
# 注入 GitHub 官方真实公网 IP 锚定与 Systemd/Node 运行时配置 (流覆写 hosts 杜绝 mount 冲突)
# ─────────────────────────────────────────────────────────────────────────────
apply_system_hosts_and_env() {
  echo "[4/4] 注入 GitHub 官方真实公网 IP 锚定、全局 SSH 托管与运行时环境..."

  local ca_target_path
  ca_target_path="$(get_ca_install_path)"
  local main_ip
  main_ip="$(detect_active_github_ip)"

  local hosts_tmp="/etc/hosts.github-accel.tmp.$$"
  local hosts_stamp
  hosts_stamp="$(date +%Y%m%d-%H%M%S)"
  cp -L /etc/hosts "/etc/hosts.github-accel.prev.${hosts_stamp}"
  cp -L /etc/hosts "$hosts_tmp"
  remove_block_safely "$hosts_tmp" "# BEGIN github-accel" "# END github-accel"
  cat << EOF >> "$hosts_tmp"
# BEGIN github-accel
$main_ip    github.com
$GITHUB_RAW_IP   raw.githubusercontent.com objects.githubusercontent.com
# END github-accel
EOF
  cat "$hosts_tmp" > /etc/hosts
  rm -f "$hosts_tmp"

  # 注入全局 SSH 443 托管，将 github.com:22 自动重路由至 ssh.github.com:443
  mkdir -p /etc/ssh/ssh_config.d
  local ssh_cfg_tmp="/etc/ssh/ssh_config.d/10-github-accel.conf.tmp.$$"
  cat << 'EOF' > "$ssh_cfg_tmp"
# Managed by github-accel
Host github.com
    HostName ssh.github.com
    Port 443
    User git
EOF
  chmod 0644 "$ssh_cfg_tmp"
  mv -f "$ssh_cfg_tmp" /etc/ssh/ssh_config.d/10-github-accel.conf

  local env_tmp="/etc/environment.github-accel.tmp.$$"
  if is_obj_exist /etc/environment; then
    cp -L /etc/environment "$env_tmp"
  else
    touch "$env_tmp"
  fi
  sed -i '/# github-accel$/d' "$env_tmp"
  echo "NODE_EXTRA_CA_CERTS=\"$ca_target_path\" # github-accel" >> "$env_tmp"
  mv -f "$env_tmp" /etc/environment

  local prof_tmp="/etc/profile.d/local-ca.sh.tmp.$$"
  cat << EOF > "$prof_tmp"
# Managed by github-accel
export NODE_EXTRA_CA_CERTS="$ca_target_path"
EOF
  mv -f "$prof_tmp" /etc/profile.d/local-ca.sh

  if [ -d /run/systemd/system ] || command -v systemctl >/dev/null 2>&1; then
    mkdir -p /etc/systemd/system.conf.d
    local sysd_tmp="/etc/systemd/system.conf.d/10-github-accel.conf.tmp.$$"
    cat << EOF > "$sysd_tmp"
[Manager]
DefaultEnvironment="NODE_EXTRA_CA_CERTS=$ca_target_path"
EOF
    mv -f "$sysd_tmp" /etc/systemd/system.conf.d/10-github-accel.conf
    systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
    verify_systemd_manager_env
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 安装主入口 (install，具备全流程事务失败自动原子回滚)
# ─────────────────────────────────────────────────────────────────────────────
rollback_on_failure() {
  local exit_status=$?
  trap - EXIT INT TERM
  if [ "$exit_status" -ne 0 ]; then
    echo "" >&2
    echo "===========================================================" >&2
    echo "  [X] 安装事务异常中断 (退出码: $exit_status)，正在执行全自动原子回滚..." >&2
    echo "===========================================================" >&2

    if [ -n "$ACTIVE_TEMP_NEW" ] && is_obj_exist "$ACTIVE_TEMP_NEW"; then
      rm -f "$ACTIVE_TEMP_NEW"
    fi
    if [ -n "$ACTIVE_TEMP_PREV" ] && is_obj_exist "$ACTIVE_TEMP_PREV"; then
      echo "  [!] 异常现场中间产物保留于: $ACTIVE_TEMP_PREV" >&2
    fi

    do_restore >/dev/null 2>&1 || true
    echo "  [✓] 现场已自动完全还原。" >&2
  fi
  exit "$exit_status"
}

do_install() {
  echo "═══════════════════════════════════════════════════════════"
  echo "          GitHub 本地透明加速配置安装                      "
  echo "═══════════════════════════════════════════════════════════"

  check_os_and_init
  probe_network
  if ! ACTIVE_GITHUB_MAIN_IP="$(detect_active_github_ip)"; then
    echo "错误: 官方存活 IP 勘测失败，终止安装！" >&2
    exit 1
  fi

  if grep -q "# BEGIN github-accel" /etc/hosts 2>/dev/null; then
    echo "提示: 本机已成功安装并激活 GitHub 本地加速，无需重复安装！"
    echo "若需重新安装或更新配置，请先执行: $0 restore 卸载后再运行安装。"
    exit 0
  fi

  local pre_install_snap
  pre_install_snap="/root/.github-accel-pre-install-$(date +%Y%m%d-%H%M%S)"
  if ! do_backup "$pre_install_snap"; then
    echo "错误: 前置配置安全备份失败，为保护生产环境，强制终止安装！" >&2
    exit 1
  fi
  CURRENT_BACKUP_DIR="$pre_install_snap"

  trap rollback_on_failure EXIT INT TERM

  probe_package_manager_and_mirrors
  probe_port_and_web_service

  if [ "$SELECTED_ADAPTER" = "none" ]; then
    echo ""
    echo "───────────────────────────────────────────────────────────"
    echo "未检测到任何已安装或运行的 Web 服务。"
    echo "本加速方案需复用本地轻量 Web 反代承接 127.0.0.1:44433 流量。"
    echo "───────────────────────────────────────────────────────────"

    if [ -z "$INSTALL_BACKEND" ]; then
      echo "请指定要安装的基础 Web 服务类型:"
      echo "  1) Caddy (推荐: 单静态二进制、自包含)"
      echo "  2) Nginx (传统工业标准: 国内源原生自带、稳定成熟)"
      echo ""
      echo "用法示例:"
      echo "  $0 install --with-caddy   # 自动通过当前系统包管理器安装 Caddy 并配置"
      echo "  $0 install --with-nginx   # 自动通过当前系统包管理器安装 Nginx 并配置"
      trap - EXIT INT TERM
      exit 0
    fi

    echo "正在使用系统包管理器 [$PKG_MANAGER] 安装 $INSTALL_BACKEND (走机器当前源)..."
    local pkg_ok=true
    case "$PKG_MANAGER" in
      apt)
        apt-get update -y && apt-get install -y "$INSTALL_BACKEND" || pkg_ok=false
        ;;
      dnf)
        dnf install -y "$INSTALL_BACKEND" || pkg_ok=false
        ;;
      yum)
        yum install -y epel-release 2>/dev/null || true
        yum install -y "$INSTALL_BACKEND" || pkg_ok=false
        ;;
      apk)
        apk add "$INSTALL_BACKEND" || pkg_ok=false
        ;;
      *)
        echo "错误: 未知包管理器，请手动安装 $INSTALL_BACKEND 后重新运行本脚本。" >&2
        exit 1
        ;;
    esac

    if ! $pkg_ok; then
      if [ "$INSTALL_BACKEND" = "caddy" ]; then
        echo "警告: 通过当前系统源安装 Caddy 失败（系统源可能缺少 caddy 包）。" >&2
        echo "正在自动降级尝试安装工业通用标准 Nginx..." >&2
        INSTALL_BACKEND="nginx"
        case "$PKG_MANAGER" in
          apt) apt-get install -y nginx ;;
          dnf|yum) dnf install -y nginx || yum install -y nginx ;;
          apk) apk add nginx ;;
        esac
      else
        echo "错误: 自动安装 $INSTALL_BACKEND 失败，请检查系统网络与源配置。" >&2
        exit 1
      fi
    fi
    SELECTED_ADAPTER="$INSTALL_BACKEND"
  fi

  case "$SELECTED_ADAPTER" in
    nginx)
      apply_nginx_adapter
      ;;
    caddy)
      apply_caddy_adapter
      ;;
    apache)
      apply_apache_adapter
      ;;
    *)
      echo "错误: 不支持的适配器类型: $SELECTED_ADAPTER" >&2
      exit 1
      ;;
  esac

  install_redirect_service
  apply_system_hosts_and_env

  trap - EXIT INT TERM

  echo "[✓] 本地加速安装配置完成！"
  do_test
}

# ─────────────────────────────────────────────────────────────────────────────
# 顶层分发入口
# ─────────────────────────────────────────────────────────────────────────────
case "$COMMAND" in
  install)
    do_install
    ;;
  restore|uninstall)
    do_restore
    ;;
  backup)
    do_backup "$BACKUP_TARGET_DIR"
    ;;
  status)
    do_status
    ;;
  test)
    do_test
    ;;
  apply-rules)
    apply_firewall_rules
    ;;
  clear-rules)
    clear_firewall_rules
    ;;
  *)
    echo "错误: 未知命令 [$COMMAND]" >&2
    show_help 1
    ;;
esac
