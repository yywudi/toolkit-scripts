#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=${PORT_SHAPER_STATE_DIR:-/etc/port-shaper}
STATE_FILE=$STATE_DIR/rules
DEFAULT_MINOR=9999
CHILD_QDISC=fq

usage() {
    cat <<'EOF'
Usage:
  port-shaper.sh add PORT RATE [--peer IP|HOST] [--src-port|--dst-port] [--dev DEV] [--takeover]
  port-shaper.sh delete PORT [--peer IP|HOST] [--src-port|--dst-port] [--dev DEV]
  port-shaper.sh rules [--dev DEV]
  port-shaper.sh list [--dev DEV]       (alias for rules)
  port-shaper.sh status [--dev DEV] [--raw]
  port-shaper.sh restore [--dev DEV]

RATE without a unit means Mbps. Accepted units: kbit, mbit, gbit, kibps, mibps, gibps.
Default match: egress TCP source and destination port; device follows --peer route or the default route.
If an interface has another root qdisc, add prompts before replacing it; --takeover skips the prompt.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi

die() { echo "Error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "must run as root"

install_dependencies() {
    local missing=() dependency package_manager packages
    for dependency in tc ip awk getent mktemp flock grep head; do
        command -v "$dependency" >/dev/null || missing+=("$dependency")
    done
    ((${#missing[@]})) || return 0

    . /etc/os-release
    case ${ID:-} in
        debian|ubuntu)
            package_manager=apt-get
            packages=(iproute2 util-linux gawk libc-bin coreutils grep)
            ;;
        rhel|centos|fedora|rocky|almalinux)
            package_manager=$(command -v dnf || command -v yum || true)
            packages=(iproute util-linux gawk glibc-common coreutils grep)
            ;;
        *)
            die "missing commands: ${missing[*]}; unsupported distribution ${ID:-unknown}; install iproute2, util-linux, awk, libc utilities, coreutils and grep manually"
            ;;
    esac
    [[ -n ${package_manager:-} ]] || die "no supported package manager found"
    echo "Installing missing dependencies: ${missing[*]}"
    if [[ $package_manager == apt-get ]]; then
        apt-get update
    fi
    "$package_manager" install -y "${packages[@]}"
}

install_dependencies
for dependency in tc ip awk getent mktemp flock grep head; do
    command -v "$dependency" >/dev/null || die "$dependency is required after installation"
done

cmd=${1:-}; shift || true
[[ -n $cmd ]] || { usage; exit 2; }
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
exec 9>"$STATE_DIR/.lock"
flock -x 9

default_dev() {
    ip route show default | awk 'NR==1 {print $5; exit}'
}

route_dev() {
    ip route get "$1" | awk 'NR==1 {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

rate_to_bps() {
    local value=$1 number unit unit_raw multiplier
    if [[ $value =~ ^([0-9]+([.][0-9]+)?)([[:alpha:]]*)$ ]]; then
        number=${BASH_REMATCH[1]}; unit_raw=${BASH_REMATCH[3]}; unit=${unit_raw,,}
    else
        return 1
    fi
    [[ $unit_raw != *B* ]] || return 1
    [[ -n $unit ]] || unit=mbit
    case $unit in
        k|kbit|kbps) multiplier=1000 ;;
        m|mb|mbit|mbps) multiplier=1000000 ;;
        g|gbit|gbps) multiplier=1000000000 ;;
        kib|kibps) multiplier=1024 ;;
        mib|mibps) multiplier=1048576 ;;
        gib|gibps) multiplier=1073741824 ;;
        *) return 1 ;;
    esac
    awk -v n="$number" -v m="$multiplier" 'BEGIN { printf "%.0f\n", n*m }'
}

resolve_peer() {
    local peer=$1
    [[ -z $peer ]] && return 0
    if [[ $peer =~ ^([0-9]{1,3}[.]){3}[0-9]{1,3}$ ]]; then
        echo "$peer"
    else
        getent ahostsv4 "$peer" | awk 'NR==1 {print $1; exit}'
    fi
}

valid_ipv4() {
    local octet
    IFS=. read -r -a octets <<< "$1"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^[0-9]+$ && $octet -le 255 ]] || return 1
    done
}

# 人读格式: 字节按 1024 进位(B/KB/MB/GB/TB/PB), 包数按 1000 进位(K/M/G/T/P)
# 非纯数字输入原样返回("-" 占位符不受影响)
fmt_bytes() {
    awk -v raw="$1" 'BEGIN {
        if (raw !~ /^[0-9]+$/) { print raw; exit }
        split("B|KB|MB|GB|TB|PB", u, "|")
        v = raw; i = 1
        while (v >= 1024 && i < 6) { v /= 1024; i++ }
        f = (i == 1 || v >= 100) ? "%.0f %s" : "%.1f %s"
        printf f, v, u[i]; print ""
    }'
}
fmt_pkts() {
    awk -v raw="$1" 'BEGIN {
        if (raw !~ /^[0-9]+$/) { print raw; exit }
        split("|K|M|G|T|P", u, "|")
        v = raw; i = 1
        while (v >= 1000 && i < 6) { v /= 1000; i++ }
        f = (i == 1) ? "%d%s" : (v >= 100 ? "%.0f%s" : "%.1f%s")
        printf f, v, u[i]; print ""
    }'
}

dev=$(default_dev)
dev_explicit=0
raw=0
peer=
role=both
takeover=0
port=
rate=
while (($#)); do
    case $1 in
        --peer) peer=${2:?missing value for --peer}; shift 2 ;;
        --src-port) role=src; shift ;;
        --dst-port) role=dst; shift ;;
        --dev) dev=${2:?missing value for --dev}; dev_explicit=1; shift 2 ;;
        --takeover) takeover=1; shift ;;
        --raw) raw=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            if [[ -z $port ]]; then port=$1
            elif [[ -z $rate ]]; then rate=$1
            else die "unknown argument: $1"; fi
            shift
            ;;
    esac
done

[[ $cmd == list || $cmd == rules || $cmd == status || $cmd == restore || -n $port ]] || { usage; exit 2; }
if [[ $cmd == add ]]; then
    [[ $port =~ ^[1-9][0-9]{0,4}$ && $port -le 65535 ]] || die "invalid port"
    [[ -n $rate ]] || die "missing rate"
    bps=$(rate_to_bps "$rate") || die "invalid rate: $rate"
    [[ $bps =~ ^[0-9]+$ && $bps -gt 0 && $bps -le 1000000000000 ]] || die "rate must be between 1 bit/s and 1 Tbit/s"
    peer=$(resolve_peer "$peer")
    [[ -z ${peer:-} || $(valid_ipv4 "$peer"; echo $?) -eq 0 ]] || die "cannot resolve peer"
    [[ -z ${peer:-} || $role == dst ]] || die "--peer can only be used with --dst-port; proxy response traffic cannot be associated with its upstream peer"
fi
if [[ $cmd == delete ]]; then
    [[ $port =~ ^[1-9][0-9]{0,4}$ && $port -le 65535 ]] || die "invalid port"
    peer=$(resolve_peer "$peer")
    [[ -z ${peer:-} || $(valid_ipv4 "$peer"; echo $?) -eq 0 ]] || die "cannot resolve peer"
fi
if [[ $dev_explicit -eq 0 && -n ${peer:-} ]]; then
    dev=$(route_dev "$peer")
fi
[[ -n $dev ]] || die "cannot determine device; use --dev"

owner_file() { printf '%s/qdisc-%s\n' "$STATE_DIR" "$1"; }
qdisc_ready() { tc qdisc show dev "$1" | grep 'qdisc htb 1: root' >/dev/null && [[ -f $(owner_file "$1") ]]; }
confirm_takeover() {
    (( takeover )) && return 0
    if [[ ! -t 0 ]]; then
        die "$dev has no port-shaper HTB qdisc; use --takeover in non-interactive mode"
    fi
    local answer
    read -r -p "$dev has an existing root qdisc. Replace it with port-shaper HTB? [Y/n] " answer
    [[ -z $answer || $answer =~ ^[Yy]([Ee][Ss])?$ ]] || die "takeover cancelled"
}
install_child_qdisc() {
    local parent=$1 handle=$2
    if [[ $CHILD_QDISC == fq ]]; then
        tc qdisc replace dev "$dev" parent "$parent" handle "$handle": fq 2>/dev/null || CHILD_QDISC=fq_codel
    fi
    if [[ $CHILD_QDISC == fq_codel ]]; then
        tc qdisc replace dev "$dev" parent "$parent" handle "$handle": fq_codel 2>/dev/null || CHILD_QDISC=pfifo_fast
    fi
    if [[ $CHILD_QDISC == pfifo_fast ]]; then
        tc qdisc replace dev "$dev" parent "$parent" handle "$handle": pfifo_fast
    fi
}
setup_qdisc() {
    if ! qdisc_ready "$dev"; then
        [[ -f $(owner_file "$dev") ]] || confirm_takeover
        tc qdisc replace dev "$dev" root handle 1: htb default "$DEFAULT_MINOR" r2q 100000
        tc class replace dev "$dev" parent 1: classid 1:1 htb rate 100gbit ceil 100gbit
        tc class replace dev "$dev" parent 1:1 classid 1:$DEFAULT_MINOR htb rate 100gbit ceil 100gbit
        : > "$(owner_file "$dev")"
    fi
}

apply_rules() {
    setup_qdisc
    tc filter del dev "$dev" parent 1: 2>/dev/null || true
    while read -r minor; do
        [[ -n $minor ]] && tc class del dev "$dev" classid 1:"$minor" 2>/dev/null || true
    done < <(tc class show dev "$dev" | awk -v d="$DEFAULT_MINOR" '$3 ~ /^1:/ {sub(/^1:/, "", $3); if($3 != 1 && $3 != d) print $3}')
    install_child_qdisc "1:$DEFAULT_MINOR" "$DEFAULT_MINOR"
    while IFS='|' read -r id rp rb pp rr rd; do
        [[ -n ${id:-} && $rd == "$dev" ]] || continue
        tc class replace dev "$dev" parent 1:1 classid 1:"$id" htb rate "$rb"bit ceil "$rb"bit quantum 1514
        install_child_qdisc "1:$id" "$id"
        add_filter() {
            local direction=$1
            args=(protocol ip parent 1: prio 10 flower ip_proto tcp)
            [[ $direction == src ]] && args+=(src_port "$rp") || args+=(dst_port "$rp")
            [[ -n $pp ]] && args+=(dst_ip "$pp")
            tc filter replace dev "$dev" "${args[@]}" flowid 1:"$id"
        }
        [[ $rr == src || $rr == both ]] && add_filter src
        [[ $rr == dst || $rr == both ]] && add_filter dst
    done < "$STATE_FILE"
}

show_rules() {
    printf '%-5s %-8s %-12s %-24s %-8s %-8s\n' ID PORT RATE PEER ROLE DEVICE
    while IFS='|' read -r id rp rb pp rr rd; do
        [[ -n ${id:-} ]] || continue
        [[ $dev_explicit -eq 0 || $rd == "$dev" ]] || continue
        rate=$(awk -v b="$rb" 'BEGIN { printf "%.3f Mbps", b/1000000 }')
        printf '%-5s %-8s %-12s %-24s %-8s %-8s\n' "$id" "$rp" "$rate" "${pp:--}" "$rr" "$rd"
    done < "$STATE_FILE"
}

show_status() {
    local root active count=0 id rp rb pp rr rd stats bytes packets raw_bytes raw_packets
    root=$(tc qdisc show dev "$dev")
    root=${root%%$'\n'*}
    active=0
    qdisc_ready "$dev" && active=1
    while IFS='|' read -r id rp rb pp rr rd; do
        [[ -n ${id:-} && $rd == "$dev" ]] || continue
        count=$((count + 1))
    done < "$STATE_FILE"
    echo "Device: $dev"
    if (( active )); then
        echo "Runtime: ACTIVE (port-shaper HTB)"
    else
        echo "Runtime: INACTIVE (saved rules exist; run: $0 restore)"
    fi
    echo "Saved rules: $count"
    echo "Root qdisc: ${root#qdisc }"
    echo
    printf '%-8s %-12s %-24s %-8s %-12s %-12s\n' PORT RATE PEER ROLE BYTES PACKETS
    while IFS='|' read -r id rp rb pp rr rd; do
        [[ -n ${id:-} && $rd == "$dev" ]] || continue
        rate=$(awk -v b="$rb" 'BEGIN { printf "%.3f Mbps", b/1000000 }')
        bytes=-; packets=-
        if (( active )); then
            stats=$(tc -s class show dev "$dev" | awk -v target="class htb 1:$id " '$0 ~ target {found=1; next} found && !done && / Sent / {print $2, $4; done=1}')
            read -r raw_bytes raw_packets <<< "${stats:-- -}"
            bytes=$(fmt_bytes "$raw_bytes")
            packets=$(fmt_pkts "$raw_packets")
        fi
        printf '%-8s %-12s %-24s %-8s %-12s %-12s\n' "$rp" "$rate" "${pp:--}" "$rr" "$bytes" "$packets"
    done < "$STATE_FILE"
}

case $cmd in
    add)
        next=$(awk -F'|' 'BEGIN{n=1000} $1>n{n=$1} END{print n+1}' "$STATE_FILE")
        key="$port|${peer:-}|$role|$dev"
        tmp=$(mktemp "$STATE_DIR/.rules.XXXXXX")
        awk -F'|' -v p="$port" -v q="${peer:-}" -v r="$role" -v d="$dev" 'BEGIN{OFS="|"} {same=($2==p && $4==q && $6==d && (r=="both" || $5==r)); if(!same) print}' "$STATE_FILE" > "$tmp"
        if [[ $role == both ]]; then
            printf '%s|%s|%s|%s|src|%s\n' "$next" "$port" "$bps" "${peer:-}" "$dev" >> "$tmp"
            printf '%s|%s|%s|%s|dst|%s\n' "$((next + 1))" "$port" "$bps" "${peer:-}" "$dev" >> "$tmp"
        else
            printf '%s|%s|%s|%s|%s|%s\n' "$next" "$port" "$bps" "${peer:-}" "$role" "$dev" >> "$tmp"
        fi
        mv "$tmp" "$STATE_FILE"
        apply_rules
        ;;
    delete)
        tmp=$(mktemp "$STATE_DIR/.rules.XXXXXX")
        awk -F'|' -v p="$port" -v q="${peer:-}" -v r="$role" -v d="$dev" 'BEGIN{OFS="|"} {match_rule=($2==p && $4==q && $6==d && (r=="both" || $5==r)); if(!match_rule) print}' "$STATE_FILE" > "$tmp"
        mv "$tmp" "$STATE_FILE"
        apply_rules
        ;;
    rules|list) show_rules ;;
    status)
        if (( raw )); then
            tc -s qdisc show dev "$dev"; tc -s class show dev "$dev"; tc -s filter show dev "$dev" parent 1:
        else
            show_status
        fi
        ;;
    restore) apply_rules ;;
    *) usage; exit 2 ;;
esac
