#!/usr/bin/env bash
# GitHub 本地透明加速一体化管理脚本 (Universal Linux Edition)
# 适用场景: 国内生产 Linux 服务器，免全局代理，复用/自适应 Web 服务透明加速 GitHub
# 支持功能: install (默认安装) | restore (卸载恢复) | backup (备份) | status (状态) | test (测试)
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
  restore          完全卸载加速配置，系统 100% 还原至原生网络状态
  backup [DIR]     备份当前加速相关的所有系统与服务配置至指定目录
  status           全景勘察报告：网络环境、端口监听、Web 服务与证书状态
  test             运行 GitHub 全链路连通性自检 (curl / wget / git / Node.js)

常用选项:
  --force          在网络直连正常或境外机器上强制执行安装
  --with-caddy     纯净新机（无 Web 服务）时，通过系统包管理器自动安装 Caddy
  --with-nginx     纯净新机（无 Web 服务）时，通过系统包管理器自动安装 Nginx

架构设计与生产安全原则:
  1. 基线快照严格锁定: 已处于加速状态时严禁覆盖初始 pre-install 备份，守住干净基线；
  2. 纯净隔离卸载: restore 仅做安全隔离清理，彻底关闭外部路径注入风险，精确按标记清理环境；
  3. 容器与宿主通用: 对 /etc/hosts 使用流覆写，彻底杜绝 bind-mount 下 Device or resource busy 报错；
  4. 跨发行版证书信任: 兼容 Debian/Ubuntu 与 RHEL/CentOS (update-ca-trust) 体系；
  5. 业务中立与完全解耦: 零特定业务硬编码，通过 systemd Manager 级全局 Drop-in 注入环境变量；
  6. 零痕迹前置勘测: 直连正常与海外环境在执行任何备份或磁盘写入前秒级退出，零残留；
  7. 容量治理与快照轮转: 自动限制快照最多保留 3 份，卸载后自动清理安装临时快照；
  8. 权限严格收敛: CA 与服务器私钥 0600、证书目录 0700 防护，杜绝非 root 用户越权读取；
  9. 精准成对区块防御: 严格整行与行号顺序校验，标记异常坚决阻断；
  10. 零全局网络污染: 不改 http_proxy/https_proxy，系统业务网络与云元数据 100% 原生直连。

手动完全恢复指南:
  若需脱离脚本手动还原系统:
    1. 还原 Web 配置:
       - Nginx:  rm -f /etc/nginx/sites-enabled/github-accel.conf /etc/nginx/sites-available/github-accel.conf /etc/nginx/conf.d/github-accel.conf && systemctl reload nginx
       - Caddy:  sed -i '/# BEGIN github-accel/,/# END github-accel/d' /etc/caddy/Caddyfile && systemctl reload caddy
       - Apache: rm -f /etc/apache2/sites-enabled/github-accel.conf /etc/httpd/conf.d/github-accel.conf && systemctl reload apache2
    2. 清理证书: rm -rf /etc/nginx/certs/github-accel /etc/nginx/ssl/github-accel /etc/caddy/certs/github-accel /etc/ssl/github-accel /usr/local/share/ca-certificates/local-github-ca.crt /etc/pki/ca-trust/source/anchors/local-github-ca.crt && (update-ca-certificates --fresh 2>/dev/null || update-ca-trust 2>/dev/null || true)
    3. 清理 Hosts 与环境:
       - sed -i '/# BEGIN github-accel/,/# END github-accel/d' /etc/hosts
       - rm -f /etc/systemd/system.conf.d/10-github-accel.conf && systemctl daemon-reload
       - sed -i '/# github-accel$/d' /etc/environment
       - [ -f /etc/profile.d/local-ca.sh ] && grep -q "# Managed by github-accel" /etc/profile.d/local-ca.sh && rm -f /etc/profile.d/local-ca.sh
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

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help)
      show_help 0
      ;;
    install|status|test|restore|uninstall)
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
# Root 权限硬性校验 (涉及系统网络 hosts、系统证书库与 Web 服务配置，非 root 坚决阻断)
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 本脚本涉及底层系统网络 (/etc/hosts)、根证书库与 Web 服务配置，必须使用 root 权限运行！" >&2
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
# 辅助函数: 安全原子同步目录 (清理旧目录后再考入，杜绝嵌套)
# ─────────────────────────────────────────────────────────────────────────────
safe_replace_dir() {
  local src="$1"
  local dst="$2"
  rm -rf "$dst"
  if [ -d "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 前置勘察模块 1: 网络环境与 GitHub 原生直连检测
# ─────────────────────────────────────────────────────────────────────────────
probe_network() {
  echo "[1/4] 勘测当前网络与 GitHub 直连连通性..."
  local already_installed=false
  if grep -q "# BEGIN github-accel" /etc/hosts 2>/dev/null; then
    already_installed=true
  fi

  if $already_installed; then
    echo "      ✓ 检测到本机已启用 GitHub 本地加速 (处于激活生效状态)。"
    return 0
  fi

  local direct_ok=false
  local latency=0
  local start_ts end_ts
  start_ts=$(date +%s 2>/dev/null || echo 0)
  if curl -fsSL --connect-timeout 2 --max-time 3 -o /dev/null https://raw.githubusercontent.com/vuejs/core/main/package.json 2>/dev/null; then
    direct_ok=true
    end_ts=$(date +%s 2>/dev/null || echo 0)
    latency=$(( end_ts - start_ts ))
  fi

  if $direct_ok; then
    echo "      ✓ 检测到当前网络可原生直连访问 GitHub (耗时约 ${latency}s)！"
    if ! $FORCE && [ "$COMMAND" = "install" ]; then
      echo "      提示: 当前机器处于海外或网络直连畅通环境，无需配置本地透明加速，脚本自动退出。"
      echo "      (若需在此网络强制测试或调试，请添加 --force 参数)"
      exit 0
    elif $FORCE; then
      echo "      注意: 检测到 --force 参数，继续执行加速配置。"
    fi
  else
    echo "      ✗ 检测到 GitHub 官方原生直连超时/被阻断 (典型国内受限网络环境)，需要配置加速。"
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
    echo "          在国内网络下载可能较慢。建议按需切换为国内大学高校镜像源:"
    echo "          - 清华大学 TUNA 镜像站 (https://mirrors.tuna.tsinghua.edu.cn/)"
    echo "          - 中国科学技术大学 USTC (https://mirrors.ustc.edu.cn/)"
    echo "          - 上海交通大学 SJTU (https://mirror.sjtu.edu.cn/)"
    echo "          (本脚本默认使用机器既有源，不会私自改写任何源文件)"
  else
    echo "      ✓ 系统源配置正常 (已采用国内/内网镜像源或定制源)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 前置勘察模块 3: 443 端口监听归属全景识别 (Port Listener Discovery)
# ─────────────────────────────────────────────────────────────────────────────
probe_port_and_web_service() {
  echo "[3/4] 勘测系统 443 端口占用与 Web 服务架构..."
  PORT_443_STATUS="free"
  PORT_443_OWNER=""

  local ss_output=""
  if command -v ss >/dev/null 2>&1; then
    ss_output=$(ss -tulpn 2>/dev/null | grep -E ":443[[:space:]]" || true)
  elif command -v netstat >/dev/null 2>&1; then
    ss_output=$(netstat -tulpn 2>/dev/null | grep -E ":443[[:space:]]" || true)
  fi

  if [ -n "$ss_output" ]; then
    PORT_443_STATUS="occupied"
    if echo "$ss_output" | grep -qi "nginx"; then
      PORT_443_OWNER="nginx"
    elif echo "$ss_output" | grep -qi "caddy"; then
      PORT_443_OWNER="caddy"
    elif echo "$ss_output" | grep -qiE "apache2|httpd"; then
      PORT_443_OWNER="apache"
    else
      PORT_443_OWNER=$(echo "$ss_output" | sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/\1 (pid:\2)/p' | head -n 1)
      [ -z "$PORT_443_OWNER" ] && PORT_443_OWNER="unknown"
    fi
  fi

  echo "      443 端口状态: $PORT_443_STATUS $( [ -n "$PORT_443_OWNER" ] && echo "(归属: $PORT_443_OWNER)" )"

  SELECTED_ADAPTER=""
  if [ "$PORT_443_OWNER" = "nginx" ]; then
    SELECTED_ADAPTER="nginx"
  elif [ "$PORT_443_OWNER" = "caddy" ]; then
    SELECTED_ADAPTER="caddy"
  elif [ "$PORT_443_OWNER" = "apache" ]; then
    SELECTED_ADAPTER="apache"
  elif [ "$PORT_443_STATUS" = "occupied" ]; then
    echo "      [X] 严重安全拦截: 443 端口已被非 Web 进程 [$PORT_443_OWNER] 占用！" >&2
    echo "          为防止损坏正在运行的业务，脚本终止执行。请排查该进程或更换端口。" >&2
    exit 1
  else
    if command -v nginx >/dev/null 2>&1; then
      SELECTED_ADAPTER="nginx"
      echo "      443 空闲，检测到系统已安装 Nginx，将激活 Nginx 适配器。"
    elif command -v caddy >/dev/null 2>&1; then
      SELECTED_ADAPTER="caddy"
      echo "      443 空闲，检测到系统已安装 Caddy，将激活 Caddy 适配器。"
    elif command -v apache2 >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
      SELECTED_ADAPTER="apache"
      echo "      443 空闲，检测到系统已安装 Apache，将激活 Apache 适配器。"
    else
      SELECTED_ADAPTER="none"
      echo "      443 空闲，未检测到任何已安装的 Web 服务 (纯净新机环境)。"
    fi
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
# (daemon-reexec 失败时不一致会暴露出来；仅告警不阻断，容器/无 systemd 环境属正常)
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
  if [ "$expected" != "$actual" ]; then
    echo "      [!] 告警: systemd Manager 环境与磁盘配置不一致" >&2
    echo "          期望值: ${expected:-<无>}" >&2
    echo "          实际值: ${actual:-<无>}" >&2
    echo "          若为常规主机，请手动执行: systemctl daemon-reexec" >&2
    echo "          （容器或无 systemd 环境下此告警可忽略）" >&2
  fi
}

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

  # 1. 本地自签根 CA (跨发行版安装)
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

  # 2. 签发多域名服务器证书
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
# 辅助函数: 从具体备份快照完整还原旧配置与证书 (原子回滚专用)
# ─────────────────────────────────────────────────────────────────────────────
restore_from_backup_snapshot() {
  local bak_dir="$1"
  [ ! -d "$bak_dir" ] && return 0
  echo "      正在从专属快照恢复旧配置与证书: $bak_dir ..."

  # 1. 还原 hosts (源存在才还原，源不存在仅清理标记)
  if is_obj_exist "$bak_dir/hosts"; then
    safe_restore_file "$bak_dir/hosts" /etc/hosts
  else
    remove_block_safely "/etc/hosts" "# BEGIN github-accel" "# END github-accel"
  fi

  # 2. 还原 environment (仅清理带有精确标记的行)
  if is_obj_exist "$bak_dir/environment"; then
    safe_restore_file "$bak_dir/environment" /etc/environment
  else
    if [ -f /etc/environment ]; then
      local env_tmp="/etc/environment.tmp.$$"
      sed '/# github-accel$/d' /etc/environment > "$env_tmp"
      mv -f "$env_tmp" /etc/environment
    fi
  fi

  # 3. 还原 profile.d
  if is_obj_exist "$bak_dir/local-ca.sh"; then
    safe_restore_file "$bak_dir/local-ca.sh" /etc/profile.d/local-ca.sh
  else
    if [ -f /etc/profile.d/local-ca.sh ] && grep -q "# Managed by github-accel" /etc/profile.d/local-ca.sh 2>/dev/null; then
      rm -f /etc/profile.d/local-ca.sh
    fi
  fi

  # 4. 还原 systemd 全局 drop-in 配置
  if is_obj_exist "$bak_dir/systemd/10-github-accel.conf"; then
    safe_restore_file "$bak_dir/systemd/10-github-accel.conf" /etc/systemd/system.conf.d/10-github-accel.conf
  else
    rm -f /etc/systemd/system.conf.d/10-github-accel.conf
  fi
  systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
  verify_systemd_manager_env

  # 5. 还原 Nginx 配置、软链与证书
  if is_obj_exist "$bak_dir/nginx/sites-available-github-accel.conf"; then
    safe_restore_file "$bak_dir/nginx/sites-available-github-accel.conf" /etc/nginx/sites-available/github-accel.conf
  else
    rm -f /etc/nginx/sites-available/github-accel.conf
  fi
  if is_obj_exist "$bak_dir/nginx/conf.d-github-accel.conf"; then
    safe_restore_file "$bak_dir/nginx/conf.d-github-accel.conf" /etc/nginx/conf.d/github-accel.conf
  else
    rm -f /etc/nginx/conf.d/github-accel.conf
  fi
  rm -f /etc/nginx/sites-enabled/github-accel.conf
  if is_obj_exist "$bak_dir/nginx/sites-enabled-entry"; then
    safe_restore_file "$bak_dir/nginx/sites-enabled-entry" /etc/nginx/sites-enabled/github-accel.conf
  fi
  safe_replace_dir "$bak_dir/nginx/certs-github-accel" /etc/nginx/certs/github-accel
  safe_replace_dir "$bak_dir/nginx/ssl-github-accel" /etc/nginx/ssl/github-accel

  # 6. 还原 Caddy
  if is_obj_exist "$bak_dir/caddy/Caddyfile"; then
    safe_restore_file "$bak_dir/caddy/Caddyfile" /etc/caddy/Caddyfile
  else
    remove_block_safely "/etc/caddy/Caddyfile" "# BEGIN github-accel" "# END github-accel"
  fi
  safe_replace_dir "$bak_dir/caddy/github-accel" /etc/caddy/certs/github-accel

  # 7. 还原 Apache 配置、软链与证书
  if is_obj_exist "$bak_dir/apache/sites-available-github-accel.conf"; then
    safe_restore_file "$bak_dir/apache/sites-available-github-accel.conf" /etc/apache2/sites-available/github-accel.conf
  else
    rm -f /etc/apache2/sites-available/github-accel.conf
  fi
  if is_obj_exist "$bak_dir/apache/conf.d-github-accel.conf"; then
    safe_restore_file "$bak_dir/apache/conf.d-github-accel.conf" /etc/httpd/conf.d/github-accel.conf
  else
    rm -f /etc/httpd/conf.d/github-accel.conf
  fi
  rm -f /etc/apache2/sites-enabled/github-accel.conf
  if is_obj_exist "$bak_dir/apache/sites-enabled-entry"; then
    safe_restore_file "$bak_dir/apache/sites-enabled-entry" /etc/apache2/sites-enabled/github-accel.conf
  fi
  safe_replace_dir "$bak_dir/ssl/github-accel" /etc/ssl/github-accel

  # 8. 还原 CA 根证书并刷新信任库
  local ca_target_path
  ca_target_path="$(get_ca_install_path)"
  if is_obj_exist "$bak_dir/certs/local-github-ca.crt"; then
    safe_restore_file "$bak_dir/certs/local-github-ca.crt" "$ca_target_path"
  else
    rm -f "$ca_target_path"
  fi
  update_system_ca_trust

  # 9. 平滑重载服务
  if command -v nginx >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx >/dev/null 2>&1 || true
    fi
  fi
  if command -v caddy >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
    systemctl reload caddy >/dev/null 2>&1 || true
  fi
  if command -v apache2 >/dev/null 2>&1 && systemctl is-active --quiet apache2; then
    systemctl reload apache2 >/dev/null 2>&1 || true
  elif command -v httpd >/dev/null 2>&1 && systemctl is-active --quiet httpd; then
    systemctl reload httpd >/dev/null 2>&1 || true
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 卸载与完全恢复 (restore，带严格预检与精准隔离清理)
# ─────────────────────────────────────────────────────────────────────────────
do_restore() {
  echo "═══════════════════════════════════════════════════════════"
  echo "          GitHub 本地加速完全卸载与系统还原                "
  echo "═══════════════════════════════════════════════════════════"

  # 1. 优先自动查找由本脚本自身规范创建的受信任安装前专属快照
  local trusted_snap=""
  local candidate
  candidate=$(ls -dt /root/.github-accel-pre-install-* 2>/dev/null | head -n 1 || true)
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    trusted_snap="$candidate"
  fi

  if [ -n "$trusted_snap" ]; then
    echo "[*] 检测到受信任的安装前专属快照: $trusted_snap"
    echo "    正在从该快照完整还原初始配置与证书拓扑..."
    restore_from_backup_snapshot "$trusted_snap"
    rm -rf /root/.github-accel-pre-install-*
    echo "[✓] 已完全从安装前快照精确还原系统！"
    return 0
  fi

  # 2. 若无快照（例如首次安装前本身即无任何旧配置），走安全隔离清理流程
  # 0. 严格预检待清理文件的区块标记
  echo "[1/6] 预检待清理文件的区块标记完整性..."
  validate_block_syntax "/etc/hosts" "# BEGIN github-accel" "# END github-accel"
  validate_block_syntax "/etc/caddy/Caddyfile" "# BEGIN github-accel" "# END github-accel"

  echo "[2/6] 清理 Nginx 站点与证书..."
  rm -f /etc/nginx/sites-enabled/github-accel.conf /etc/nginx/sites-available/github-accel.conf /etc/nginx/conf.d/github-accel.conf
  rm -rf /etc/nginx/certs/github-accel /etc/nginx/ssl/github-accel

  echo "[3/6] 清理 Caddy 加速配置块与专用证书..."
  remove_block_safely "/etc/caddy/Caddyfile" "# BEGIN github-accel" "# END github-accel"
  rm -rf /etc/caddy/certs/github-accel

  echo "[4/6] 清理 Apache 加速配置与专用证书..."
  rm -f /etc/apache2/sites-enabled/github-accel.conf /etc/apache2/sites-available/github-accel.conf /etc/httpd/conf.d/github-accel.conf
  rm -rf /etc/ssl/github-accel

  echo "[5/6] 清理系统根 CA、全局 Systemd 与 Node.js 信任环境..."
  local ca_target_path
  ca_target_path="$(get_ca_install_path)"
  rm -f "$ca_target_path"
  update_system_ca_trust

  if [ -f /etc/profile.d/local-ca.sh ] && grep -q "# Managed by github-accel" /etc/profile.d/local-ca.sh 2>/dev/null; then
    rm -f /etc/profile.d/local-ca.sh
  fi

  rm -f /etc/systemd/system.conf.d/10-github-accel.conf
  systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
  verify_systemd_manager_env

  if [ -f /etc/environment ]; then
    local env_tmp="/etc/environment.tmp.$$"
    sed '/# github-accel$/d' /etc/environment > "$env_tmp"
    mv -f "$env_tmp" /etc/environment
  fi

  echo "[6/6] 清理 /etc/hosts 精准区块..."
  remove_block_safely "/etc/hosts" "# BEGIN github-accel" "# END github-accel"

  # 平滑重载现存服务
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

  echo "[✓] 卸载完成，系统已还原至原生网络状态！"
}

# ─────────────────────────────────────────────────────────────────────────────
# 连通性测试 (test，覆盖 curl / wget / 真实 git clone / Node.js)
# ─────────────────────────────────────────────────────────────────────────────
do_test() {
  echo "═══════════════════════════════════════════════════════════"
  echo "          GitHub 全链路连通性自检报告                      "
  echo "═══════════════════════════════════════════════════════════"

  echo -n "[1/4] 测试 Raw 源码下载 (curl 原生无参)... "
  if curl -fsSL --max-time 10 https://raw.githubusercontent.com/vuejs/core/main/package.json >/dev/null 2>&1; then
    echo "✓ 成功 (HTTP 200, 证书合法)"
  else
    echo "✗ 失败"
  fi

  echo -n "[2/4] 测试 Raw 源码下载 (wget 原生无参)... "
  if wget -qO- --timeout=10 https://raw.githubusercontent.com/vuejs/core/main/package.json >/dev/null 2>&1; then
    echo "✓ 成功"
  else
    echo "✗ 失败"
  fi

  echo -n "[3/4] 测试 Git 协议拉取 (git ls-remote 源码库)... "
  if command -v git >/dev/null 2>&1; then
    if git ls-remote --heads https://github.com/vuejs/core.git main >/dev/null 2>&1; then
      echo "✓ 成功 (Git 握手与证书链正常)"
    else
      echo "✗ 失败"
    fi
  else
    echo "- 跳过 (未安装 git)"
  fi

  echo -n "[4/4] 测试 Node.js 运行时 fetch... "
  local ca_target_path
  ca_target_path="$(get_ca_install_path)"
  if command -v node >/dev/null 2>&1; then
    if NODE_EXTRA_CA_CERTS="$ca_target_path" node -e 'fetch("https://raw.githubusercontent.com/vuejs/core/main/package.json").then(r=>r.json()).then(j=>{if(!j.version)process.exit(1)}).catch(()=>process.exit(1))' >/dev/null 2>&1; then
      echo "✓ 成功"
    else
      echo "✗ 失败"
    fi
  else
    echo "- 跳过 (未安装 node)"
  fi
  echo "═══════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────
# 状态查询 (status，绝不意外提前退出)
# ─────────────────────────────────────────────────────────────────────────────
do_status() {
  echo "═══════════════════════════════════════════════════════════"
  echo "          GitHub 加速环境全景状态                          "
  echo "═══════════════════════════════════════════════════════════"
  probe_network
  probe_package_manager_and_mirrors
  probe_port_and_web_service

  local ca_target_path
  ca_target_path="$(get_ca_install_path)"

  echo ""
  echo "当前配置状态:"
  echo "  选定适配器:     $SELECTED_ADAPTER"
  echo "  系统受信任根 CA: $( [ -f "$ca_target_path" ] && echo "已安装 ($ca_target_path)" || echo "未安装" )"
  echo "  /etc/hosts 劫持: $( grep -q "# BEGIN github-accel" /etc/hosts 2>/dev/null && echo "已配置重定向区块" || echo "未配置" )"
  echo "  Node 证书链环境: $( grep -q "NODE_EXTRA_CA_CERTS" /etc/environment 2>/dev/null && echo "已配置" || echo "未配置" )"
  echo "  Systemd 全局环境: $( [ -f /etc/systemd/system.conf.d/10-github-accel.conf ] && echo "已注入" || echo "未注入" )"
  echo "═══════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────
# 各适配器安装实现 (支持事务防损与自动回滚)
# ─────────────────────────────────────────────────────────────────────────────

apply_nginx_adapter() {
  echo "--> 激活 Nginx 适配器..."
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

  local ns
  ns=$(grep -E "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ' || true)
  local resolvers="${ns}223.5.5.5"

  local prev_temp="$site_avail.github-accel.prev.$$"
  ACTIVE_TEMP_PREV="$prev_temp"
  ACTIVE_TEMP_NEW="$site_avail.new"

  if is_obj_exist "$site_avail"; then
    cp -L "$site_avail" "$prev_temp"
  fi

  rm -f "$site_avail.new"
  cat << EOF > "$site_avail.new"
server {
    listen 443 ssl;
    server_name raw.githubusercontent.com
                github.com
                objects.githubusercontent.com;

    ssl_certificate     $cert_dir/fullchain.cer;
    ssl_certificate_key $cert_dir/github-accel.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    access_log /var/log/nginx/github-accel-access.log;
    error_log  /var/log/nginx/github-accel-error.log;

    resolver $resolvers valid=300s ipv6=off;
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

apply_caddy_adapter() {
  echo "--> 激活 Caddy 适配器..."
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
raw.githubusercontent.com, github.com, objects.githubusercontent.com {
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

apply_apache_adapter() {
  echo "--> 激活 Apache 适配器..."
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
<VirtualHost *:443>
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
# 注入精准区块 Hosts 与 Node 运行时配置 (解引用安全读取 + 流覆写 hosts 杜绝 mount 冲突)
# ─────────────────────────────────────────────────────────────────────────────
apply_system_hosts_and_env() {
  echo "[4/4] 注入精准 Hosts 区块与 Node.js 信任链..."

  local ca_target_path
  ca_target_path="$(get_ca_install_path)"

  # 1. Hosts 流覆写（不变更 inode，彻底避免容器内 Device or resource busy 崩溃）
  local hosts_tmp="/etc/hosts.github-accel.tmp.$$"
  local hosts_stamp
  hosts_stamp="$(date +%Y%m%d-%H%M%S)"
  cp -L /etc/hosts "/etc/hosts.github-accel.prev.${hosts_stamp}"
  cp -L /etc/hosts "$hosts_tmp"
  remove_block_safely "$hosts_tmp" "# BEGIN github-accel" "# END github-accel"
  cat << EOF >> "$hosts_tmp"
# BEGIN github-accel
127.0.0.1 raw.githubusercontent.com github.com objects.githubusercontent.com
# END github-accel
EOF
  cat "$hosts_tmp" > /etc/hosts
  rm -f "$hosts_tmp"

  # 2. Environment 解引用生成新普通文件并原子 mv -f (精准打上行末标记)
  local env_tmp="/etc/environment.github-accel.tmp.$$"
  if is_obj_exist /etc/environment; then
    cp -L /etc/environment "$env_tmp"
  else
    touch "$env_tmp"
  fi
  sed -i '/# github-accel$/d' "$env_tmp"
  echo "NODE_EXTRA_CA_CERTS=\"$ca_target_path\" # github-accel" >> "$env_tmp"
  mv -f "$env_tmp" /etc/environment

  # 3. Profile 原子生成普通文件并 mv -f (打上文件所有权标记)
  local prof_tmp="/etc/profile.d/local-ca.sh.tmp.$$"
  cat << EOF > "$prof_tmp"
# Managed by github-accel
export NODE_EXTRA_CA_CERTS="$ca_target_path"
EOF
  mv -f "$prof_tmp" /etc/profile.d/local-ca.sh

  # 4. Systemd Manager 级全局 Drop-in 注入 (零业务侵入，整机守护进程全自动继承)
  mkdir -p /etc/systemd/system.conf.d
  local sysd_tmp="/etc/systemd/system.conf.d/10-github-accel.conf.tmp.$$"
  cat << EOF > "$sysd_tmp"
[Manager]
DefaultEnvironment="NODE_EXTRA_CA_CERTS=$ca_target_path"
EOF
  mv -f "$sysd_tmp" /etc/systemd/system.conf.d/10-github-accel.conf
  systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
  verify_systemd_manager_env
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

    if [ -n "$CURRENT_BACKUP_DIR" ] && [ -d "$CURRENT_BACKUP_DIR" ]; then
      restore_from_backup_snapshot "$CURRENT_BACKUP_DIR"
    else
      do_restore >/dev/null 2>&1 || true
    fi
    echo "  [✓] 现场已自动从安装前快照完全还原。" >&2
  fi
  exit "$exit_status"
}

do_install() {
  echo "═══════════════════════════════════════════════════════════"
  echo "          GitHub 本地透明加速配置安装                      "
  echo "═══════════════════════════════════════════════════════════"

  # 1. 严格前置勘测网络 (海外/直连正常在进行任何磁盘 IO 与备份前秒级退出，零残留)
  probe_network

  # 2. 幂等防重入检查 (已安装状态严格阻断覆盖 baseline 备份快照)
  if grep -q "# BEGIN github-accel" /etc/hosts 2>/dev/null; then
    echo "提示: 本机已成功安装并激活 GitHub 本地加速，无需重复安装！"
    echo "若需重新安装或更新配置，请先执行: $0 restore 卸载后再运行安装。"
    exit 0
  fi

  # 3. 严格执行前置备份，生成安装专属快照，备份失败强制阻断
  local pre_install_snap
  pre_install_snap="/root/.github-accel-pre-install-$(date +%Y%m%d-%H%M%S)"
  if ! do_backup "$pre_install_snap"; then
    echo "错误: 前置配置安全备份失败，为保护生产环境，强制终止安装！" >&2
    exit 1
  fi
  CURRENT_BACKUP_DIR="$pre_install_snap"

  # 4. 挂载全局安装事务失败回滚 Trap (优先恢复本次安装前快照)
  trap rollback_on_failure EXIT INT TERM

  probe_package_manager_and_mirrors
  probe_port_and_web_service

  if [ "$SELECTED_ADAPTER" = "none" ]; then
    echo ""
    echo "───────────────────────────────────────────────────────────"
    echo "未检测到任何已安装或运行的 Web 服务 (443 端口空闲)。"
    echo "本加速方案需复用本地轻量 Web 反代承接 443 SNI 流量。"
    echo "───────────────────────────────────────────────────────────"

    if [ -z "$INSTALL_BACKEND" ]; then
      echo "请指定要安装的基础 Web 服务类型:"
      echo "  1) Caddy (极力推荐: 单静态二进制、内存仅 ~15MB、自包含)"
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

  apply_system_hosts_and_env

  # 成功后卸载回滚 Trap
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
  *)
    echo "错误: 未知命令 [$COMMAND]" >&2
    show_help 1
    ;;
esac
