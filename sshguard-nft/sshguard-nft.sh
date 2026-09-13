#!/bin/bash
# deploy-sshguard.sh

set -euo pipefail

TS=$(date +%F_%H%M%S)
NFT_MAIN_CONF="/etc/nftables.conf"
NFT_DIR="/etc/nftables.d"
NFT_SSHGUARD_CONF="$NFT_DIR/sshguard.conf"
SSHGUARD_CONF="/etc/sshguard/sshguard.conf"
SSHGUARD_WHITELIST="/etc/sshguard/whitelist"

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: must run as root" >&2
        exit 1
    fi
}

backup_if_exists() {
    local path="$1"
    local suffix="$2"
    if [ -e "$path" ]; then
        cp "$path" "${path}.${TS}-${suffix}"
        echo "[BACKUP] ${path}.${TS}-${suffix}"
    fi
}

get_ssh_ports() {
    python3 - <<'PY'
from pathlib import Path
import glob, re
paths = [Path('/etc/ssh/sshd_config')]
paths += [Path(p) for p in sorted(glob.glob('/etc/ssh/sshd_config.d/*.conf'))]
ports = []
for path in paths:
    if not path.exists():
        continue
    for raw in path.read_text(errors='ignore').splitlines():
        line = raw.split('#', 1)[0].strip()
        if not line:
            continue
        m = re.match(r'(?i)^Port\s+(\d+)$', line)
        if m:
            ports.append(m.group(1))
if not ports:
    ports = ['22']
seen = set()
out = []
for p in ports:
    if p not in seen:
        seen.add(p)
        out.append(p)
print(' '.join(out))
PY
}

ensure_main_include() {
    mkdir -p "$NFT_DIR"
    touch "$NFT_MAIN_CONF"
    if ! grep -Fq 'include "/etc/nftables.d/*.conf"' "$NFT_MAIN_CONF"; then
        backup_if_exists "$NFT_MAIN_CONF" "pre-sshguard-include-backup"
        printf '\ninclude "/etc/nftables.d/*.conf"\n' >> "$NFT_MAIN_CONF"
        echo "[INFO] Added include to $NFT_MAIN_CONF"
    else
        echo "[INFO] nftables include already present"
    fi
}

# ── H4: 认证日志源探测 ───────────────────────────────────────────────────
# Debian/Ubuntu 默认没有 /var/log/messages；硬编码错误源会让 sshguard 静默
# 读不到任何日志。按优先级自动探测：env 覆盖 > auth.log > journald > messages。
detect_log_reader() {
    if [ -n "${LOGREADER_OVERRIDE:-}" ]; then
        echo "$LOGREADER_OVERRIDE"
        return 0
    fi
    if [ -f /var/log/auth.log ]; then
        echo "tail -F -n 0 /var/log/auth.log"
    elif [ -d /run/systemd/journal ] && command -v journalctl >/dev/null 2>&1; then
        echo "journalctl -f -n0 -o cat"
    elif [ -f /var/log/messages ]; then
        echo "tail -F -n 0 /var/log/messages"
    else
        echo "ERROR: 未找到任何 SSH 认证日志源（auth.log / journald / messages）。" >&2
        echo "       请设置 LOGREADER_OVERRIDE=\"<读取命令>\" 后重跑。" >&2
        return 1
    fi
}

warn_ssh_socket() {
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
        echo "[WARN] systemd ssh.socket 已接管监听：SSH 端口可能不在 sshd_config 中，请人工核对 TARGETS。"
    fi
}

# ── H5: 白名单预置（防自锁）───────────────────────────────────────────────
# THRESHOLD=5 + BLOCK_TIME=10 天：不预置白名单时，管理员输错 5 次密码或
# CGNAT 撞车即自锁 10 天。仅当文件为空时预置，不覆盖已有条目。
ensure_whitelist_base() {
    mkdir -p /etc/sshguard
    touch "$SSHGUARD_WHITELIST"
    if [ -s "$SSHGUARD_WHITELIST" ]; then
        echo "[INFO] whitelist 已有条目，保留不动: $SSHGUARD_WHITELIST"
        return 0
    fi
    cat > "$SSHGUARD_WHITELIST" <<'EOF'
127.0.0.1/8
::1/128
10.0.0.0/8
172.16.0.0/12
192.168.0.0/16
EOF
    echo "[INFO] 已预置白名单（本机/内网段）: $SSHGUARD_WHITELIST"
    if [ -n "${SSH_CONNECTION:-}" ]; then
        local src_ip answer=""
        src_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
        printf "是否将当前 SSH 来源 IP 加入白名单 [%s]? [Y/n] " "$src_ip"
        # 注意：read 在"EOF 但已读到部分输入"时也返回非 0，此时应保留已读值
        read -r answer || true
        answer=${answer:-y}
        case "$answer" in
            [Nn]*)
                echo "[WARN] 未加入当前来源 IP；注意连续 5 次认证失败将封禁 10 天。"
                ;;
            *)
                echo "$src_ip" >> "$SSHGUARD_WHITELIST"
                echo "[INFO] 已加入白名单: $src_ip"
                ;;
        esac
    fi
    return 0
}

# ── H5: 安全 apply 前置（live ruleset 备份 + flush 风险确认）────────────
NFT_RULESET_BACKUP="/var/backups/nftables-ruleset.${TS}.nft"

backup_live_ruleset() {
    mkdir -p /var/backups
    if nft list ruleset > "$NFT_RULESET_BACKUP" 2>/dev/null; then
        echo "[BACKUP] live ruleset -> $NFT_RULESET_BACKUP"
    else
        : > "$NFT_RULESET_BACKUP"
        echo "[WARN] 无法导出 live ruleset（nft 不可用/权限不足），备份占位为空。"
    fi
}

confirm_apply_safe() {
    grep -q '^[[:space:]]*flush ruleset' "$NFT_MAIN_CONF" 2>/dev/null || return 0
    local ufw_active="no" docker_running="no"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw_active="yes"
    fi
    if [ -S /var/run/docker.sock ]; then
        docker_running="yes"
    fi
    echo "[WARN] $NFT_MAIN_CONF 含 'flush ruleset'：nftables.service（重）启动时会清空运行时规则。"
    [ "$ufw_active" = "yes" ] && echo "[WARN]   - ufw active：重启后需 ufw reload（或重启）才会重建规则"
    [ "$docker_running" = "yes" ] && echo "[WARN]   - Docker 运行中：容器 NAT 规则需 docker 守护进程重建"
    if [ "${SSHGUARD_YES:-0}" = "1" ]; then
        echo "[INFO] SSHGUARD_YES=1，跳过交互确认。"
        return 0
    fi
    local answer=""
    printf "继续执行 nftables 应用? [y/N] "
    read -r answer || true   # EOF 但已读到部分输入时保留该输入
    answer=${answer:-n}
    case "$answer" in
        [Yy]*) return 0 ;;
        *)
            echo "[INFO] 已中止。处理 ufw/docker 后重跑，或设置 SSHGUARD_YES=1 跳过确认。"
            exit 1
            ;;
    esac
}

write_sshguard_nft_conf() {
    local ports_csv="$1"
    cat > "$NFT_SSHGUARD_CONF" <<EOF
#!/usr/sbin/nft -f

table inet sshguard {
    set sshguard-blacklist {
        type ipv4_addr
        flags timeout
        # 必须 >= sshguard BLOCK_TIME(10d)，否则集合默认 TTL 会提前解除封禁
        timeout 11d
    }

    chain input {
        type filter hook input priority filter; policy accept;
        ip saddr @sshguard-blacklist drop
    }
}
EOF
    echo "[INFO] Wrote $NFT_SSHGUARD_CONF"
}

write_sshguard_conf() {
    local ports_csv="$1"
    local logreader="$2"
    local targets=""
    IFS=',' read -r -a ports <<< "$ports_csv"
    for p in "${ports[@]}"; do
        if [ -n "$targets" ]; then
            targets="$targets,"
        fi
        targets="${targets}${p}/tcp"
    done

    cat > "$SSHGUARD_CONF" <<EOF
BACKEND="/usr/libexec/sshguard/sshg-fw-nft-sets"
LOGREADER="$logreader"

THRESHOLD=5
BLOCK_TIME=864000
DETECTION_TIME=600

TARGETS="$targets"
WHITELIST_FILE="$SSHGUARD_WHITELIST"
EOF
    echo "[INFO] Wrote $SSHGUARD_CONF"
}

validate_nft_conf() {
    nft -c -f "$NFT_MAIN_CONF"
    echo "[INFO] nft syntax check passed"
}

print_rollback_hint() {
    echo "[ROLLBACK] If needed, restore backups under:"
    echo "  $NFT_MAIN_CONF.${TS}-pre-sshguard-include-backup"
    echo "  $NFT_SSHGUARD_CONF.${TS}-pre-sshguard-conf-backup"
    echo "  $SSHGUARD_CONF.${TS}-pre-sshguard-conf-backup"
    echo "  live ruleset snapshot: $NFT_RULESET_BACKUP"
    echo "    restore with: nft -f $NFT_RULESET_BACKUP"
    echo "Unblock an IP: nft delete element inet sshguard sshguard-blacklist { <IP> }"
    echo "Then run: systemctl restart sshguard"
}

main() {
    need_root

    echo "安装 SSHGuard 和 nftables..."
    DEBIAN_FRONTEND=noninteractive apt update
    DEBIAN_FRONTEND=noninteractive apt install -y sshguard nftables python3

    SSH_PORTS=$(get_ssh_ports)
    PORTS_CSV=$(echo "$SSH_PORTS" | tr ' ' ',')
    echo "[INFO] Detected SSH port(s): $SSH_PORTS"

    warn_ssh_socket
    LOGREADER_CMD=$(detect_log_reader)

    backup_if_exists "$NFT_SSHGUARD_CONF" "pre-sshguard-conf-backup"
    backup_if_exists "$SSHGUARD_CONF" "pre-sshguard-conf-backup"

    ensure_main_include
    write_sshguard_nft_conf "$PORTS_CSV"
    ensure_whitelist_base
    write_sshguard_conf "$PORTS_CSV" "$LOGREADER_CMD"
    validate_nft_conf

    echo "[INFO] LOGREADER: $LOGREADER_CMD"
    confirm_apply_safe
    backup_live_ruleset

    # 只加载 sshguard 自己的表（原子增量），绝不整包加载 main conf——
    # 后者首行的 flush ruleset 会当场清空 ufw/docker/iptables-nft 运行时规则。
    echo "应用 nftables 配置..."
    nft -f "$NFT_SSHGUARD_CONF"

    echo "启动服务..."
    # nftables 仅 enable（开机持久化），部署时不 restart——sshguard 表已由上一步
    # 直接载入内核；此时 restart 反而会执行 flush ruleset 清掉现有运行时规则。
    systemctl enable nftables
    systemctl enable sshguard
    systemctl restart sshguard

    echo "完成"
    echo "[INFO] sshguard nft config: $NFT_SSHGUARD_CONF"
    echo "[INFO] sshguard app config: $SSHGUARD_CONF"
    echo "[INFO] blacklist set check: nft list set inet sshguard sshguard-blacklist"
    print_rollback_hint
    systemctl --no-pager --full status sshguard || true
}

main "$@"
