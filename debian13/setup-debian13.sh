#!/bin/bash

############################################################
# core functions
############################################################

set -eu
set -o pipefail

# Safety swapfile location used by configure_swap_safety (site convention).
SWAPFILE_PATH="/var/swap"

function check_install {
	if [ -z "$(command -v "$1" 2>/dev/null)" ]
	then
		executable=$1
		shift
		while [ -n "${1:-}" ]
		do
			DEBIAN_FRONTEND=noninteractive apt-get -q -y install "$1"
			apt-get clean
			print_info "$1 installed for $executable"
			shift
		done
	else
		print_warn "$1 already installed"
	fi
}

function check_remove {
	if [ -n "$(command -v "$1" 2>/dev/null)" ]
	then
		DEBIAN_FRONTEND=noninteractive apt-get -q -y remove --purge "$2"
		apt-get clean
		print_info "$2 removed"
	else
		print_warn "$2 is not installed"
	fi
}

function check_sanity {
	if [ "$(/usr/bin/id -u)" != "0" ]
	then
		die 'Must be run by root user'
	fi

	if [ ! -f /etc/debian_version ]
	then
		die "Distribution is not supported"
	fi
}

function die {
	echo "ERROR: $1" 1>&2
	exit 1
}

function get_domain_name() {
	domain=${1%.*}
	lowest=$(expr "$domain" : '.*\.\([a-z][a-z]*\)')
	case "$lowest" in
	com|net|org|gov|edu|co|me|info|name)
		domain=${domain%.*}
		;;
	esac
	lowest=$(expr "$domain" : '.*\.\([a-z][a-z]*\)')
	[ -z "$lowest" ] && echo "$domain" || echo "$lowest"
}

function get_password() {
	SALT=/var/lib/radom_salt
	if [ ! -f "$SALT" ]
	then
		head -c 512 /dev/urandom > "$SALT"
		chmod 400 "$SALT"
	fi
	password=$( (cat "$SALT"; echo "$1") | md5sum | base64 )
	echo ${password:0:13}
}

function print_info {
	echo -n -e '\e[1;36m'
	echo -n "$1"
	echo -e '\e[0m'
}

function print_warn {
	echo -n -e '\e[1;33m'
	echo -n "$1"
	echo -e '\e[0m'
}

function backup_file {
	if [ -e "$1" ]
	then
		ts=$(date +%F_%H%M%S)
		cp "$1" "$1.$ts-$2"
		print_info "Backup created: $1.$ts-$2"
	fi
}

function detect_virt_type {
	if command -v systemd-detect-virt >/dev/null 2>&1
	then
		systemd-detect-virt 2>/dev/null || echo "baremetal"
	else
		echo "baremetal"
	fi
}

# --- configuration transaction -------------------------------------------------
# install_nginx touches several files before it can run `nginx -t`. `set -e`
# aborts on the first failing command, so without a transaction a failure after
# the default site was written would leave an unverified (possibly unloadable)
# nginx configuration on disk. tx_begin arms an EXIT trap, tx_add snapshots a
# file just before it is modified, and tx_commit disarms the trap once the
# configuration has been validated.
TX_PATHS=()
TX_SNAPS=()
TX_ACTIVE=0

function tx_begin {
	TX_PATHS=()
	TX_SNAPS=()
	TX_ACTIVE=1
	trap 'tx_rollback' EXIT
}

function tx_add { # tx_add <path>  — snapshot a file before modifying it
	local path="$1"
	local i snap=""

	# Registering the same file twice must keep the FIRST snapshot: it is the
	# only one taken before the file was modified.
	if [ "${#TX_PATHS[@]}" -gt 0 ]
	then
		for i in "${!TX_PATHS[@]}"
		do
			if [ "${TX_PATHS[$i]}" = "$path" ]
			then
				return 0
			fi
		done
	fi

	if [ -e "$path" ]
	then
		snap=$(mktemp /tmp/setup-debian13-tx.XXXXXX)
		if ! cp -a "$path" "$snap"
		then
			rm -f "$snap"
			die "tx_add: could not snapshot $path"
		fi
	fi
	TX_PATHS+=("$path")
	TX_SNAPS+=("$snap")
}

function tx_commit {
	# Disarm the trap first: from here on the configuration is validated, so a
	# failing snapshot cleanup must not trigger a rollback of committed state.
	TX_ACTIVE=0
	trap - EXIT

	local i
	if [ "${#TX_SNAPS[@]}" -gt 0 ]
	then
		for i in "${!TX_SNAPS[@]}"
		do
			if [ -n "${TX_SNAPS[$i]}" ]
			then
				rm -f "${TX_SNAPS[$i]}" || print_warn "tx_commit: could not remove snapshot ${TX_SNAPS[$i]}"
			fi
		done
	fi
	TX_PATHS=()
	TX_SNAPS=()
}

function tx_rollback {
	if [ "$TX_ACTIVE" != "1" ]
	then
		return 0
	fi
	TX_ACTIVE=0
	trap - EXIT

	local i path snap restored=0 failed=0
	if [ "${#TX_PATHS[@]}" -gt 0 ]
	then
		for i in "${!TX_PATHS[@]}"
		do
			path="${TX_PATHS[$i]}"
			snap="${TX_SNAPS[$i]}"
			if [ -n "$snap" ] && [ -f "$snap" ]
			then
				# A rollback must never abort halfway: every step is guarded so
				# the remaining files still get restored.
				if cp -a "$snap" "$path"
				then
					rm -f "$snap" || true
					restored=$((restored + 1))
				else
					failed=$((failed + 1))
					print_warn "tx_rollback: could not restore $path from $snap"
				fi
			elif [ -e "$path" ]
			then
				if rm -f "$path"
				then
					restored=$((restored + 1))
				else
					failed=$((failed + 1))
					print_warn "tx_rollback: could not remove $path"
				fi
			fi
		done
	fi

	TX_PATHS=()
	TX_SNAPS=()
	if [ "$restored" -gt 0 ]
	then
		print_warn "Rolled back $restored nginx configuration file(s) changed by this run"
	fi
	if [ "$failed" -gt 0 ]
	then
		print_warn "tx_rollback: $failed file(s) could NOT be restored; manual inspection required"
	fi
}

# OpenVZ / LXC share the host kernel: the clock is host-managed and swapon is
# not permitted inside the container, so both must be skipped there.
function is_container_virt {
	case "$1" in
	openvz|lxc)
		return 0
		;;
	esac
	return 1
}

function is_uint {
	case "${1:-}" in
	''|*[!0-9]*)
		return 1
		;;
	esac
	# `[ ]` is 64-bit: a longer digit string makes it emit
	# "integer expression expected" and take the wrong branch. Real values here
	# are MB/GB totals, so anything beyond 18 digits is treated as unparseable.
	if [ "${#1}" -gt 18 ]
	then
		return 1
	fi
	return 0
}

# Remove every root crontab line matching an extended regex.
# Uses a variable instead of a bare `crontab -l | grep -v ... | crontab -`
# pipeline: under `set -e` + `pipefail` an empty filter result makes grep exit
# 1 and would abort the whole script.
function prune_cron_pattern {
	local pattern="$1"
	local cur_cron filtered

	if ! command -v crontab >/dev/null 2>&1
	then
		print_warn "crontab is not available; skipping crontab pruning for: $pattern"
		return 0
	fi

	cur_cron=$(crontab -l 2>/dev/null || true)
	[ -n "$cur_cron" ] || return 0

	filtered=$(printf '%s\n' "$cur_cron" | grep -v "$pattern" || true)
	if [ "$filtered" = "$cur_cron" ]
	then
		return 0
	fi

	if [ -n "$filtered" ]
	then
		printf '%s\n' "$filtered" | crontab -
	else
		printf '' | crontab -
	fi
	print_info "Pruned legacy crontab entries matching: $pattern"
}

function detect_php_version {
	php_version=$(dpkg -l 'php*-fpm' 2>/dev/null | awk '/^ii  php[0-9]+\.[0-9]+-fpm/ {print $2}' | sed 's/^php//; s/-fpm$//' | head -n1)
	if [ -z "$php_version" ]
	then
		php_version=$(apt-cache search '^php[0-9]+\.[0-9]+-fpm$' 2>/dev/null | awk '{print $1}' | sed 's/^php//; s/-fpm$//' | sort -Vr | head -n1)
	fi
	[ -n "$php_version" ] || die "Unable to detect PHP-FPM version"
	echo "$php_version"
}

function ensure_timezone {
	if command -v timedatectl >/dev/null 2>&1
	then
		timedatectl set-timezone Asia/Shanghai
	else
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		echo 'Asia/Shanghai' > /etc/timezone
		dpkg-reconfigure -f noninteractive tzdata
	fi
	print_info "Timezone set to Asia/Shanghai"
}

############################################################
# system baseline hardening
############################################################

function configure_journald {
	print_info "Configuring systemd-journald size limits (50M cap)"
	mkdir -p /etc/systemd/journald.conf.d
	backup_file /etc/systemd/journald.conf.d/00-journal-size.conf pre-journal-limit-backup
	cat > /etc/systemd/journald.conf.d/00-journal-size.conf <<'END'
# Managed by setup-debian13.sh: keep the journal from filling the root filesystem.
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
RuntimeMaxUse=20M
MaxRetentionSec=1month
END
	systemctl restart systemd-journald ||
		print_warn "systemd-journald restart failed; the 50M cap applies at its next start"
	journalctl --vacuum-size=50M >/dev/null 2>&1 || true
	print_info "Journald limited to 50M"
}

function configure_timesync {
	print_info "Configuring continuous time synchronization"
	ensure_timezone

	local virt_type
	virt_type=$(detect_virt_type)
	if is_container_virt "$virt_type"
	then
		print_warn "Container environment ($virt_type) detected: the clock is managed by the host. Skipping systemd-timesyncd."
		return 0
	fi

	# systemd-timesyncd is shipped with systemd itself; check_install also works
	# with an absolute path, so this is a no-op on a standard install.
	check_install /usr/lib/systemd/systemd-timesyncd systemd-timesyncd
	systemctl unmask systemd-timesyncd >/dev/null 2>&1 || true
	systemctl enable systemd-timesyncd >/dev/null 2>&1 || true
	systemctl restart systemd-timesyncd ||
		print_warn "systemd-timesyncd did not start; check 'systemctl status systemd-timesyncd'"
	timedatectl set-ntp true >/dev/null 2>&1 || true

	# ntpdate does destructive one-shot jumps and is gone from Debian 12/13.
	prune_cron_pattern 'ntpdate'
	print_info "Continuous time synchronization active via systemd-timesyncd"
}

function configure_sysctl {
	print_info "Applying security sysctl parameters (anti-spoofing)"
	mkdir -p /etc/sysctl.d
	backup_file /etc/sysctl.d/99-security.conf pre-sysctl-security-backup
	cat > /etc/sysctl.d/99-security.conf <<'END'
# Managed by setup-debian13.sh.
# Reverse-path filtering: drop packets whose source address cannot be routed back.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# SYN cookies: keep accepting connections while under a SYN flood.
net.ipv4.tcp_syncookies = 1
END
	sysctl -p /etc/sysctl.d/99-security.conf >/dev/null 2>&1 || print_warn "sysctl -p failed; the parameters take effect after reboot"
	print_info "Kernel network anti-spoofing enabled"
}

function configure_cron_safety {
	print_info "Securing root crontab against dead-mail spool overflow"

	if ! command -v crontab >/dev/null 2>&1
	then
		print_warn "crontab is not available; skipping MAILTO hardening"
		return 0
	fi

	local cur_cron clean_cron
	cur_cron=$(crontab -l 2>/dev/null || true)

	if printf '%s\n' "$cur_cron" | grep -q '^MAILTO=""'
	then
		print_info 'MAILTO="" already present in root crontab'
		return 0
	fi

	clean_cron=$(printf '%s\n' "$cur_cron" | grep -v '^MAILTO=' || true)
	if [ -n "$clean_cron" ]
	then
		printf 'MAILTO=""\n%s\n' "$clean_cron" | crontab -
	else
		printf 'MAILTO=""\n' | crontab -
	fi
	print_info 'Injected MAILTO="" into root crontab'
}

function configure_swap_safety {
	print_info "Checking memory and swap safety margin"

	local virt_type
	virt_type=$(detect_virt_type)
	if is_container_virt "$virt_type"
	then
		print_warn "Container environment ($virt_type) detected: swapon is not permitted. Skipping the safety swapfile."
		return 0
	fi

	local total_ram_mb total_swap_mb
	total_ram_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || true)
	total_swap_mb=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || true)

	# Validate before comparing: `[ "" -gt 1024 ]` aborts the shell, and a
	# non-numeric value would make the branch decision on an error, not a fact.
	if ! is_uint "$total_ram_mb" || ! is_uint "$total_swap_mb"
	then
		print_warn "Could not read memory/swap totals from 'free'; skipping the safety swapfile"
		return 0
	fi

	# Only <=1GB hosts that have no swap at all need the protective swapfile.
	if [ "$total_ram_mb" -gt 1024 ] || [ "$total_swap_mb" -ne 0 ]
	then
		return 0
	fi

	if swapon --show 2>/dev/null | grep -q .
	then
		print_info "Swap is already active; skipping the safety swapfile"
		return 0
	fi

	local free_disk_gb
	free_disk_gb=$(df -BG "$(dirname "$SWAPFILE_PATH")" 2>/dev/null | awk 'NR==2{sub(/G/,"",$4); print $4}')
	if ! is_uint "$free_disk_gb" || [ "$free_disk_gb" -lt 2 ]
	then
		print_warn "Not enough free space for a 512M safety swapfile at $SWAPFILE_PATH; skipping"
		return 0
	fi

	if [ -e "$SWAPFILE_PATH" ]
	then
		print_warn "An inactive $SWAPFILE_PATH already exists; leaving it untouched for manual review"
		return 0
	fi

	print_info "Low RAM (<=1GB) with zero swap detected. Creating a 512MB safety swapfile at $SWAPFILE_PATH"

	# Every step between creating and activating the file must clean up after
	# itself: a half-built file would trigger the "already exists" branch above
	# on the next run and block the retry forever.
	if ! { fallocate -l 512M "$SWAPFILE_PATH" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE_PATH" bs=1M count=512 status=none; }
	then
		print_warn "Could not create $SWAPFILE_PATH; skipping the safety swapfile"
		rm -f "$SWAPFILE_PATH"
		return 0
	fi

	if ! chmod 600 "$SWAPFILE_PATH"
	then
		print_warn "chmod 600 $SWAPFILE_PATH failed; removing the incomplete swapfile"
		rm -f "$SWAPFILE_PATH"
		return 0
	fi

	if ! mkswap "$SWAPFILE_PATH" >/dev/null 2>&1
	then
		print_warn "mkswap $SWAPFILE_PATH failed; removing the incomplete swapfile"
		rm -f "$SWAPFILE_PATH"
		return 0
	fi

	if ! swapon "$SWAPFILE_PATH"
	then
		print_warn "swapon $SWAPFILE_PATH failed; removing the incomplete swapfile"
		rm -f "$SWAPFILE_PATH"
		return 0
	fi

	# Persist only what is actually active. A failure here leaves swap working
	# for this boot, so warn instead of aborting the whole 'system' branch.
	if ! grep -q "^$SWAPFILE_PATH " /etc/fstab
	then
		printf '%s none swap sw 0 0\n' "$SWAPFILE_PATH" >> /etc/fstab ||
			print_warn "Could not add $SWAPFILE_PATH to /etc/fstab; swap is active but will not survive a reboot"
	fi
	if mkdir -p /etc/sysctl.d
	then
		printf 'vm.swappiness=10\n' > /etc/sysctl.d/99-swap.conf ||
			print_warn "Could not write /etc/sysctl.d/99-swap.conf"
		sysctl -p /etc/sysctl.d/99-swap.conf >/dev/null 2>&1 ||
			print_warn "sysctl -p failed; vm.swappiness takes effect after reboot"
	else
		print_warn "Could not create /etc/sysctl.d; vm.swappiness was not set"
	fi
	print_info "Allocated 512MB safety swapfile at $SWAPFILE_PATH; vm.swappiness set to 10"
}

############################################################
# applications
############################################################

function install_dash {
	check_install dash dash
	rm -f /bin/sh
	ln -s dash /bin/sh
}

function install_nano {
	check_install nano nano
}

function install_htop {
	check_install htop htop
}

function install_mc {
	check_install mc mc
}

function install_iotop {
	check_install iotop iotop
}

function install_iftop {
	check_install iftop iftop
	print_warn "Run ip addr to find your network device name"
	print_warn "Example usage: iftop -i eth0"
}

function install_vim {
	check_install vim vim
}

function install_dropbear {
	if [ -z "${1:-}" ]
	then
		die "Usage: $(basename "$0") dropbear [ssh-port-#]"
	fi

	check_install dropbear dropbear
	check_install /usr/sbin/xinetd xinetd
	touch /etc/ssh/sshd_not_to_be_run
	invoke-rc.d ssh stop

	cat > /etc/xinetd.d/dropbear <<END
service ssh
{
	socket_type  = stream
	only_from    = 0.0.0.0
	wait         = no
	user         = root
	protocol     = tcp
	server       = /usr/sbin/dropbear
	server_args  = -i
	disable      = no
	port         = $1
	type         = unlisted
}
END
	invoke-rc.d xinetd restart

	print_info "dropbear is installed and running"
}

function install_exim4 {
	check_install mail exim4
	if [ -f /etc/exim4/update-exim4.conf.conf ]
	then
		sed -i "s/dc_eximconfig_configtype='local'/dc_eximconfig_configtype='internet'/" /etc/exim4/update-exim4.conf.conf
		invoke-rc.d exim4 restart
	fi
}

function install_dotdeb {
	print_warn "dotdeb is legacy and not supported on modern Debian releases"
}

function install_syslogd {
	print_info "Installing rsyslog and configuring /var/log/messages for SSH logs"
	DEBIAN_FRONTEND=noninteractive apt-get -q -y install rsyslog logrotate

	backup_file /etc/rsyslog.d/20-messages.conf pre-rsyslog-messages-backup
	cat > /etc/rsyslog.d/20-messages.conf <<'END'
# Consolidated messages log for system and SSH-related events.
*.info;mail.none;cron.none;authpriv.none                -/var/log/messages
auth,authpriv.*                                         -/var/log/messages
cron.*                                                  -/var/log/cron
mail.*                                                  -/var/log/mail
END

	# NOTE: never place the backup inside /etc/logrotate.d — logrotate parses
	# every file in that directory, so a timestamped copy would be read as a
	# second rule and make logrotate fail with "duplicate log entry".
	if [ -f /etc/logrotate.d/rsyslog-custom ]
	then
		mkdir -p /var/backups/setup-debian13
		cp /etc/logrotate.d/rsyslog-custom "/var/backups/setup-debian13/rsyslog-custom.$(date +%F_%H%M%S).prev"
		print_info "Backup created: /var/backups/setup-debian13/rsyslog-custom.<timestamp>.prev"
	fi
	cat > /etc/logrotate.d/rsyslog-custom <<'END'
/var/log/messages
/var/log/cron
/var/log/mail {
	rotate 8
	weekly
	missingok
	notifempty
	compress
	delaycompress
	sharedscripts
	postrotate
		/usr/lib/rsyslog/rsyslog-rotate >/dev/null 2>&1 || true
	endscript
}
END

	touch /var/log/messages /var/log/cron /var/log/mail
	chmod 640 /var/log/messages /var/log/cron /var/log/mail
	chown root:adm /var/log/messages /var/log/cron /var/log/mail 2>/dev/null || true

	systemctl enable rsyslog >/dev/null 2>&1 || true
	systemctl restart rsyslog
	logger -t setup-debian13 "rsyslog test message"
	print_info "rsyslog configured; SSH logs should be available in /var/log/messages"
}

function install_mysql {
	print_info "Installing MariaDB server and client"
	DEBIAN_FRONTEND=noninteractive apt-get -q -y install mariadb-server mariadb-client

	mkdir -p /etc/mysql/mariadb.conf.d
	backup_file /etc/mysql/mariadb.conf.d/60-setup-debian13.cnf pre-mariadb-modern-backup
	cat > /etc/mysql/mariadb.conf.d/60-setup-debian13.cnf <<'END'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[client]
default-character-set = utf8mb4
END

	systemctl enable mariadb
	systemctl restart mariadb

	if mariadb -e 'SELECT 1;' >/dev/null 2>&1
	then
		print_info "MariaDB installed and root local login is working"
	else
		print_warn "MariaDB installed, but root local login via 'mariadb' needs manual verification"
	fi

	print_warn "Root login method is left at the distro default (recommended for Debian 13)."
	print_warn "Test with: mariadb"
}

function install_php {
	print_info "Installing PHP-FPM and common extensions"
	DEBIAN_FRONTEND=noninteractive apt-get -q -y install php-fpm php-cli php-curl php-gd php-intl php-mysql php-sqlite3 php-mbstring php-xml php-zip php-apcu php-opcache gettext

	php_version=$(detect_php_version)
	php_ini="/etc/php/$php_version/fpm/php.ini"
	fpm_service="php$php_version-fpm"
	fpm_pool="/etc/php/$php_version/fpm/pool.d/www.conf"

	[ -f "$php_ini" ] || die "PHP ini not found at $php_ini"
	backup_file "$php_ini" pre-php-ini-backup

	sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 200M/" "$php_ini"
	sed -i "s/^post_max_size = .*/post_max_size = 200M/" "$php_ini"
	sed -i "s/^memory_limit = .*/memory_limit = 256M/" "$php_ini"
	if grep -q '^;*cgi.fix_pathinfo' "$php_ini"
	then
		sed -i "s/^;*cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/" "$php_ini"
	else
		printf '\ncgi.fix_pathinfo=0\n' >> "$php_ini"
	fi

	# date.timezone is commented out by default; the sed may not match every
	# packaging variant, so verify and append as a fallback.
	if grep -q '^;*date\.timezone' "$php_ini"
	then
		sed -i "s|^;*date\.timezone =.*|date.timezone = Asia/Shanghai|" "$php_ini"
	fi
	if ! grep -q '^date\.timezone = Asia/Shanghai' "$php_ini"
	then
		printf '\ndate.timezone = Asia/Shanghai\n' >> "$php_ini"
	fi

	# Recycle every worker after 500 requests so long-running processes cannot
	# accumulate memory leaks.
	if [ -f "$fpm_pool" ]
	then
		backup_file "$fpm_pool" pre-php-fpm-pool-backup
		if grep -q '^;*pm\.max_requests' "$fpm_pool"
		then
			sed -i "s|^;*pm\.max_requests =.*|pm.max_requests = 500|" "$fpm_pool"
		else
			printf '\npm.max_requests = 500\n' >> "$fpm_pool"
		fi
	else
		print_warn "PHP-FPM pool not found at $fpm_pool; skipping pm.max_requests"
	fi

	systemctl enable "$fpm_service"
	systemctl restart "$fpm_service"
	print_info "PHP $php_version configured"
}

# A single listen address:port may only be claimed by one default_server.
# The anti-SNI block is written into the default site by install_nginx itself,
# so any *other* loaded file declaring a 443 default_server would make
# `nginx -t` fail with "a duplicate default server". Warn instead of silently
# rewriting files the operator may own.
# Only files nginx actually loads are inspected: sites-available is not part of
# nginx.conf, and scanning it would flag our own timestamped backups.
function check_reject_sni_conflicts {
	local conf conflicts=""
	local default_real
	default_real=$(readlink -f /etc/nginx/sites-available/default 2>/dev/null || true)

	for conf in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*
	do
		[ -f "$conf" ] || continue
		if [ -n "$default_real" ] && [ "$(readlink -f "$conf" 2>/dev/null || true)" = "$default_real" ]
		then
			continue
		fi
		if grep -Eq '^[[:space:]]*listen[[:space:]]+(\[::\]:)?443[^;]*default_server' "$conf"
		then
			conflicts="$conflicts $conf"
		fi
	done

	if [ -n "$conflicts" ]
	then
		print_warn "Another nginx file also declares a 443 default_server:$conflicts"
		print_warn "That will make 'nginx -t' fail. Remove the duplicate 'default_server' keyword and re-run."
	fi
}

# Global logrotate policy for every vhost log written under /var/www.
# daily + maxsize 10M keeps a single file bounded even on busy sites, and the
# 14-day retention replaces the previous unmanaged growth.
function ensure_vhost_logrotate {
	print_info "Ensuring logrotate policy for /var/www vhost logs"

	# Non-critical helper: it is also called from install_site/install_wordpress
	# outside any transaction, so it must not abort them on its own failure.
	if ! mkdir -p /etc/logrotate.d
	then
		print_warn "Could not create /etc/logrotate.d; skipping the vhost logrotate policy"
		return 0
	fi

	local rule
	rule=$(mktemp /tmp/custom-vhosts.XXXXXX)
	cat > "$rule" <<'END'
# Managed by setup-debian13.sh.
/var/www/*/*.log /var/www/*/logs/*.log {
	daily
	maxsize 10M
	rotate 14
	compress
	delaycompress
	missingok
	notifempty
	create 0640 www-data adm
	sharedscripts
	postrotate
		if [ -d /run/systemd/system ]; then
			systemctl reload nginx > /dev/null 2>&1 || true
		fi
	endscript
}
END

	# logrotate reads every file in /etc/logrotate.d, so a timestamped backup
	# left in that directory would itself be parsed as a second rule and make
	# logrotate fail with "duplicate log entry" on every run. Backups therefore
	# go to /var/backups, and an unchanged rule is left completely alone.
	if [ -f /etc/logrotate.d/custom-vhosts ] && cmp -s "$rule" /etc/logrotate.d/custom-vhosts
	then
		rm -f "$rule"
		print_info "logrotate policy already up to date"
		return 0
	fi

	if [ -f /etc/logrotate.d/custom-vhosts ]
	then
		mkdir -p /var/backups/setup-debian13
		cp /etc/logrotate.d/custom-vhosts "/var/backups/setup-debian13/custom-vhosts.$(date +%F_%H%M%S).prev"
		print_info "Backup created: /var/backups/setup-debian13/custom-vhosts.$(date +%F_%H%M%S).prev"
	fi

	if ! mv "$rule" /etc/logrotate.d/custom-vhosts
	then
		rm -f "$rule"
		print_warn "Could not install /etc/logrotate.d/custom-vhosts"
		return 0
	fi
	print_info "logrotate policy installed at /etc/logrotate.d/custom-vhosts"
}

function install_nginx {
	print_info "Installing nginx and writing safe default configuration"
	DEBIAN_FRONTEND=noninteractive apt-get -q -y install nginx
	check_install logrotate logrotate

	# PHP-FPM may not be installed yet: install_nginx is also valid standalone.
	# Degrade to an html-only default site instead of aborting the whole run.
	# NOTE: the `||` must wrap the assignment — `detect_php_version` calls `die`,
	# whose `exit 1` runs inside the command substitution subshell, so
	# `$(detect_php_version || true)` would still abort under `set -e`.
	php_version=""
	php_version=$(detect_php_version) || php_version=""
	php_sock="/run/php/php$php_version-fpm.sock"

	mkdir -p /var/www/default/public /etc/nginx/snippets
	echo 'Default nginx site is ready.' > /var/www/default/public/index.html

	check_reject_sni_conflicts

	# Everything below rewrites live nginx configuration, so it runs inside a
	# transaction: each target is snapshotted just before it is modified, and an
	# EXIT trap restores them all if any step fails (`set -e` aborts on the first
	# failing command, including the ones before `nginx -t`). A single listen
	# directive may only have one default_server, and the 443 reject block below
	# lives in this very file so a fresh install can never conflict.
	tx_begin

	if [ -n "$php_version" ]
	then
		tx_add /etc/nginx/snippets/php-fpm.conf
		backup_file /etc/nginx/snippets/php-fpm.conf pre-nginx-php-snippet-backup
		cat > /etc/nginx/snippets/php-fpm.conf <<END
location / {
	try_files \$uri \$uri/ /index.php?\$query_string;
}

location ~ \.php$ {
	include snippets/fastcgi-php.conf;
	fastcgi_pass unix:$php_sock;
	fastcgi_read_timeout 180;
}

location ~ /\.ht {
	deny all;
}
END
	else
		print_warn "PHP-FPM not detected; skipping the PHP snippet (run '$(basename "$0") php' later)"
	fi

	tx_add /etc/nginx/sites-available/default
	backup_file /etc/nginx/sites-available/default pre-nginx-default-site-backup
	cat > /etc/nginx/sites-available/default <<'END'
# Managed by setup-debian13.sh.
server {
	listen 80 default_server;
	listen [::]:80 default_server;
	server_name _;
	root /var/www/default/public;
	index index.html;

	location / {
		try_files $uri $uri/ =404;
	}
}

# Anti-SNI: drop TLS handshakes for direct-IP probes and unknown SNI values
# instead of falling back to the first SSL vhost and leaking its certificate.
# ssl_reject_handshake needs no certificate; real vhosts (listen 443 ssl without
# default_server) keep working because SNI matching takes priority.
server {
	listen 443 ssl default_server;
	listen [::]:443 ssl default_server;
	server_name _;
	ssl_reject_handshake on;
}
END

	# The logrotate rule is part of the same transaction: a later failure must
	# not leave it deployed against a configuration that never validated.
	tx_add /etc/logrotate.d/custom-vhosts
	ensure_vhost_logrotate

	if [ -f /etc/nginx/nginx.conf ]
	then
		tx_add /etc/nginx/nginx.conf
		backup_file /etc/nginx/nginx.conf pre-nginx-conf-backup
		sed -i 's/worker_processes .*/worker_processes auto;/' /etc/nginx/nginx.conf
	fi

	# Validate before committing. If the test fails — or if any earlier step
	# already aborted under `set -e` — the EXIT trap restores every file this
	# run touched, so the machine never keeps an unloadable nginx config.
	if ! nginx -t
	then
		die "nginx configuration test failed"
	fi
	tx_commit

	systemctl enable nginx
	systemctl restart nginx
	print_info "nginx configured with safe default site and anti-SNI rejection"
}

function install_site {
	if [ -z "${1:-}" ]
	then
		die "Usage: $(basename "$0") site [domain]"
	fi

	domain="$1"
	site_root="/var/www/$domain"
	site_public="$site_root/public"
	site_logs="$site_root/logs"
	site_conf="/etc/nginx/sites-available/$domain.conf"
	site_link="/etc/nginx/sites-enabled/$domain.conf"

	if [ -e "$site_conf" ]
	then
		die "nginx vhost already exists: $site_conf"
	fi

	if [ -d "$site_root" ]
	then
		print_warn "Site root already exists, will reuse: $site_root"
	else
		mkdir -p "$site_root"
	fi

	php_version=$(detect_php_version)
	php_sock="/run/php/php$php_version-fpm.sock"

	mkdir -p "$site_public" "$site_logs"
	if [ ! -e "$site_public/index.html" ]
	then
		cat > "$site_public/index.html" <<END
Hello World
END
	else
		print_warn "Existing file kept: $site_public/index.html"
	fi
	if [ ! -e "$site_public/phpinfo.php" ]
	then
		cat > "$site_public/phpinfo.php" <<END
<?php phpinfo(); ?>
END
	else
		print_warn "Existing file kept: $site_public/phpinfo.php"
	fi

	cat > "$site_conf" <<END
server {
	listen 80;
	listen [::]:80;
	server_name $domain www.$domain;
	root $site_public;
	index index.html index.htm index.php;
	client_max_body_size 32m;

	access_log $site_logs/access.log;
	error_log $site_logs/error.log;

	location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|webp)$ {
		expires max;
		log_not_found off;
		access_log off;
	}

	location = /favicon.ico {
		log_not_found off;
		access_log off;
	}

	location = /robots.txt {
		allow all;
		log_not_found off;
		access_log off;
	}

	location / {
		try_files \$uri \$uri/ /index.php?\$query_string;
	}

	location ~ \.php$ {
		include snippets/fastcgi-php.conf;
		fastcgi_pass unix:$php_sock;
		fastcgi_read_timeout 180;
	}

	location ~ /\.ht {
		deny all;
	}
}
END

	ln -s "$site_conf" "$site_link"
	chown -R www-data:www-data "$site_root"
	ensure_vhost_logrotate
	nginx -t || die "nginx configuration test failed for $domain"
	systemctl reload nginx

	print_warn "New site successfully installed."
	print_warn "Document root: $site_public"
	print_warn "Test PHP by accessing http://$domain/phpinfo.php and remove phpinfo.php afterwards"
}

function install_wordpress {

	if [ -z "${1:-}" ]
	then
		die "Usage: $(basename "$0") wordpress [domain]"
	fi

	domain="$1"
	site_root="/var/www/$domain"
	site_public="$site_root/public"
	site_logs="$site_root/logs"
	site_conf="/etc/nginx/sites-available/$domain.conf"
	site_link="/etc/nginx/sites-enabled/$domain.conf"
	mysql_conf="$site_root/mysql.conf"

	if [ -e "$site_conf" ]
	then
		die "WordPress nginx vhost already exists: $site_conf"
	fi

	if [ -d "$site_root" ]
	then
		print_warn "WordPress site root already exists, checking reuse safety: $site_root"
	else
		mkdir -p "$site_root"
	fi

	if [ -d "$site_public" ] && [ -n "$(find "$site_public" -mindepth 1 -maxdepth 1 2>/dev/null)" ]
	then
		die "WordPress public dir is not empty, refusing to overwrite: $site_public"
	fi

	check_install curl curl
	check_install ed ed
	php_version=$(detect_php_version)
	php_sock="/run/php/php$php_version-fpm.sock"

	mkdir -p "$site_public" "$site_logs"
	tmpdir=$(mktemp -d /tmp/wordpress.XXXXXX)
	wget -O - https://wordpress.org/latest.tar.gz | tar zxf - -C "$tmpdir"
	cp -a "$tmpdir/wordpress/." "$site_public"
	rm -rf "$tmpdir"

	install_mysqluser "$domain"
	[ -f "$mysql_conf" ] || die "mysql.conf was not created for $domain"
	dbname=$(awk -F' = ' '/^database = / {print $2}' "$mysql_conf")
	userid=$(awk -F' = ' '/^user = / {print $2}' "$mysql_conf")
	passwd=$(awk -F' = ' '/^password = / {print $2}' "$mysql_conf")

	cp "$site_public/wp-config-sample.php" "$site_public/wp-config.php"
	salt=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/)
	defineString='put your unique phrase here'
	printf '%s\n' "g/$defineString/d" a "$salt" . w | ed -s "$site_public/wp-config.php"
	sed -i "s/database_name_here/$dbname/; s/username_here/$userid/; s/password_here/$passwd/" "$site_public/wp-config.php"

	cat > "$site_conf" <<END
server {
	listen 80;
	listen [::]:80;
	server_name $domain www.$domain;
	root $site_public;
	index index.php index.html index.htm;
	client_max_body_size 32m;

	access_log $site_logs/access.log;
	error_log $site_logs/error.log;

	location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|webp)$ {
		expires max;
		log_not_found off;
		access_log off;
	}

	location = /favicon.ico {
		log_not_found off;
		access_log off;
	}

	location = /robots.txt {
		allow all;
		log_not_found off;
		access_log off;
	}

	location / {
		try_files \$uri \$uri/ /index.php?\$args;
	}

	location ~ \.php$ {
		include snippets/fastcgi-php.conf;
		fastcgi_pass unix:$php_sock;
		fastcgi_read_timeout 180;
	}

	location ~ /\.ht {
		deny all;
	}
}
END
	ln -s "$site_conf" "$site_link"
	chown -R www-data:www-data "$site_root"
	ensure_vhost_logrotate
	nginx -t || die "nginx configuration test failed for WordPress site $domain"
	systemctl reload nginx

	print_warn "New WordPress site successfully installed."
	print_warn "Document root: $site_public"
	print_warn "MySQL config: $mysql_conf"
	print_warn "Finish setup by opening http://$domain/ in your browser"
}

function install_mysqluser {

	if [ -z "${1:-}" ]
	then
		die "Usage: $(basename "$0") mysqluser [domain]"
	fi

	domain="$1"
	site_root="/var/www/$domain"
	mysql_conf="$site_root/mysql.conf"

	if [ ! -d "$site_root/" ]
	then
		die "no site found at $site_root/"
	fi

	dbname=$(echo "$domain" | tr '.-' '__')
	userid=$(echo "$(get_domain_name "$domain")" | tr -c '[:alnum:]' '_' | cut -c1-32)
	passwd=$(get_password "$userid@mysql")

	mariadb >/dev/null 2>&1 <<END || die "MariaDB root local login failed; run 'mariadb' manually to verify authentication first"
CREATE DATABASE IF NOT EXISTS \`$dbname\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$userid'@'localhost' IDENTIFIED BY '$passwd';
ALTER USER '$userid'@'localhost' IDENTIFIED BY '$passwd';
GRANT ALL PRIVILEGES ON \`$dbname\`.* TO '$userid'@'localhost';
FLUSH PRIVILEGES;
END

	backup_file "$mysql_conf" pre-mysql-conf-backup
	cat > "$mysql_conf" <<END
[mysql]
user = $userid
password = $passwd
database = $dbname
END
	chmod 600 "$mysql_conf"

	echo 'MySQL Username: ' $userid
	echo 'MySQL Password: ' $passwd
	echo 'MySQL Database: ' $dbname
	echo 'MySQL Config: ' $mysql_conf
}

function install_iptables {

	check_install iptables iptables

	if [ -z "${1:-}" ]
	then
		die "Usage: $(basename "$0") iptables [ssh-port-#]"
	fi

	cat > /etc/iptables.up.rules <<END
*filter
-A INPUT -i lo -j ACCEPT
-A INPUT ! -i lo -d 127.0.0.0/8 -j REJECT
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
-A OUTPUT -j ACCEPT
-A INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -p tcp -m tcp --dport $1 -m state --state NEW -m recent --set --name DEFAULT --rsource
-A INPUT -p tcp -m tcp --dport $1 -m state --state NEW -m recent --update --seconds 60 --hitcount 3 --name DEFAULT --rsource -j DROP
-A INPUT -p tcp -m state --state NEW --dport $1 -j ACCEPT
-A INPUT -p icmp -m icmp --icmp-type 8 -j ACCEPT
-A INPUT -j DROP
-A FORWARD -j DROP
COMMIT
END

	cat > /etc/network/if-pre-up.d/iptables <<END
#!/bin/sh
/sbin/iptables-restore < /etc/iptables.up.rules
END

	chmod +x /etc/network/if-pre-up.d/iptables
	iptables-restore < /etc/iptables.up.rules
	echo 'Created /etc/iptables.up.rules and startup script /etc/network/if-pre-up.d/iptables'
}

function remove_unneeded {
	print_warn "remove_unneeded is disabled in Debian 13 modernization path"
}

function install_ps_mem {
	print_info "Installing ps_mem"
	if apt-cache show ps-mem >/dev/null 2>&1
	then
		DEBIAN_FRONTEND=noninteractive apt-get -q -y install ps-mem
		if command -v ps_mem >/dev/null 2>&1
		then
			ln -sf "$(command -v ps_mem)" /usr/local/bin/ps_mem
			print_info "ps_mem installed from apt"
			return
		fi
	fi

	wget https://raw.githubusercontent.com/pixelb/ps_mem/master/ps_mem.py -O /root/ps_mem.py
	chmod 700 /root/ps_mem.py
	ln -sf /root/ps_mem.py /usr/local/bin/ps_mem
	print_info "ps_mem.py has been setup successfully"
	print_warn "Use /root/ps_mem.py or ps_mem to execute"
}

function update_apt_sources {
	die "Ubuntu-only apt sources update is legacy and unsupported in this Debian 13 script"
}

function install_vzfree {
	print_warn "vzfree is legacy and not supported in the Debian 13 path"
}

function install_webmin {
	print_warn "webmin path is legacy and not modernized yet"
}

function install_curl {
	print_info "Checking curl"
	check_install curl curl
}

function gen_ssh_key {
	print_warn "Generating the ssh-key (ed25519)"
	if [ -z "${1:-}" ]
	then
		ssh-keygen -t ed25519 -f ~/id_ed25519
		print_warn "generated ~/id_ed25519"
	else
		ssh-keygen -t ed25519 -f ~/"$1"
		print_warn "generated ~/$1"
	fi
}

function configure_motd {
	apt_clean
	update_upgrade
	check_install landscape-common landscape-common
	dpkg-reconfigure landscape-common
}

function runtests {
	print_info "Classic I/O test"
	print_info "dd if=/dev/zero of=iotest bs=64k count=16k conv=fdatasync && rm -fr iotest"
	dd if=/dev/zero of=iotest bs=64k count=16k conv=fdatasync && rm -fr iotest

	print_info "Network test"
	print_info "wget cachefly.cachefly.net/100mb.test -O 100mb.test && rm -fr 100mb.test"
	wget cachefly.cachefly.net/100mb.test -O 100mb.test && rm -fr 100mb.test
}

function show_os_arch_version {
	ARCH=$(uname -m | sed 's/x86_//;s/i[3-6]86/32/')

	if [ -f /etc/lsb-release ]; then
		. /etc/lsb-release
		OS=$DISTRIB_ID
		VERSION=$DISTRIB_RELEASE
	elif [ -f /etc/debian_version ]; then
		OS=$(lsb_release -si)
		VERSION=$(lsb_release -sr)
	elif [ -f /etc/redhat-release ]; then
		OS=Redhat
		VERSION=$(uname -r)
	else
		OS=$(uname -s)
		VERSION=$(uname -r)
	fi

	OS_SUMMARY="$OS $VERSION ${ARCH}bit"
	print_info "$OS_SUMMARY"
}

function fix_locale {
	check_install multipath-tools multipath-tools
	export LANGUAGE=en_US.UTF-8
	export LANG=en_US.UTF-8
	export LC_ALL=en_US.UTF-8
	locale-gen en_US.UTF-8
	dpkg-reconfigure locales
}

function apt_clean {
	apt-get -q -y autoclean
	apt-get -q -y clean
}

function update_upgrade {
	apt-get -q -y update
	apt-get -q -y upgrade
	apt-get -q -y autoremove
}

function update_timezone {
	ensure_timezone
}

function install_3proxy {
	die "3proxy path is legacy and intentionally not modernized in this Debian 13 script"
}

function install_3proxyauth {
	die "3proxy path is legacy and intentionally not modernized in this Debian 13 script"
}

########################################################################
# START OF PROGRAM
########################################################################
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

check_sanity
case "${1:-}" in
mysql)
	install_mysql
	;;
exim4)
	install_exim4
	;;
nginx)
	install_nginx
	;;
php)
	install_php
	;;
dotdeb)
	install_dotdeb
	;;
site)
	install_site "${2:-}"
	;;
wordpress)
	install_wordpress "${2:-}"
	;;
mysqluser)
	install_mysqluser "${2:-}"
	;;
iptables)
	install_iptables "${2:-}"
	;;
dropbear)
	install_dropbear "${2:-}"
	;;
3proxy)
	install_3proxy "${2:-}"
	;;
3proxyauth)
	install_3proxyauth "${2:-}" "${3:-}"
	;;
ps_mem)
	install_ps_mem
	;;
apt)
	update_apt_sources
	;;
vzfree)
	install_vzfree
	;;
webmin)
	install_webmin
	;;
sshkey)
	gen_ssh_key "${2:-}"
	;;
motd)
	configure_motd
	;;
locale)
	fix_locale
	;;
test)
	runtests
	;;
info)
	show_os_arch_version
	;;
system)
	# Refresh apt lists first: the baseline functions below may install packages.
	update_upgrade
	ensure_timezone
	configure_timesync
	configure_journald
	configure_sysctl
	configure_cron_safety
	configure_swap_safety
	install_vim
	install_htop
	install_mc
	install_iotop
	install_iftop
	install_curl
	install_syslogd
	apt_clean
	;;
*)
	show_os_arch_version
	echo '  '
	echo 'Usage:' "$(basename "$0")" '[option] [argument]'
	echo 'Primary commands:'
	echo '  - system                 (baseline hardening: timezone, timesyncd, journald 50M, sysctl, cron MAILTO, safety swap, base tools, rsyslog)'
	echo '  - nginx                  (install nginx with a safe default site, 443 anti-SNI rejection and vhost logrotate)'
	echo '  - php                    (install PHP-FPM and common development extensions)'
	echo '  - site      [domain.tld] (create nginx vhost and /var/www/domain/public)'
	echo '  - ps_mem                 (install ps_mem helper)'
	echo '  - info                   (display OS, ARCH and VERSION)'
	echo '  '
	echo 'Legacy / review-needed commands:'
	echo '  - mysql                  (install MariaDB with Debian 13 friendly defaults)'
	echo '  - mysqluser [domain.tld] (create/update per-site database user and mysql.conf)'
	echo '  - wordpress [domain.tld] (create WordPress site using current PHP-FPM and MariaDB helpers)'
	echo '  - dropbear / iptables / exim4 / webmin / vzfree / apt / locale / test / sshkey / 3proxy'
	echo '  '
	;;
esac
