#!/bin/bash

############################################################
# core functions
############################################################

set -eu
set -o pipefail

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

	backup_file /etc/logrotate.d/rsyslog-custom pre-rsyslog-logrotate-backup
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

	systemctl enable "$fpm_service"
	systemctl restart "$fpm_service"
	print_info "PHP $php_version configured"
}

function install_nginx {
	print_info "Installing nginx and writing safe default configuration"
	DEBIAN_FRONTEND=noninteractive apt-get -q -y install nginx

	php_version=$(detect_php_version)
	php_sock="/run/php/php$php_version-fpm.sock"

	mkdir -p /var/www/default/public /etc/nginx/snippets
	echo 'Default nginx site is ready.' > /var/www/default/public/index.html

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

	backup_file /etc/nginx/sites-available/default pre-nginx-default-site-backup
	cat > /etc/nginx/sites-available/default <<'END'
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
END

	if [ -f /etc/nginx/nginx.conf ]
	then
		backup_file /etc/nginx/nginx.conf pre-nginx-conf-backup
		sed -i 's/worker_processes .*/worker_processes auto;/' /etc/nginx/nginx.conf
	fi

	nginx -t || die "nginx configuration test failed"
	systemctl enable nginx
	systemctl restart nginx
	print_info "nginx configured with safe default site"
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
	ensure_timezone
	update_upgrade
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
	echo '  - system                 (set Asia/Shanghai timezone, update system, install base tools, configure rsyslog)' 
	echo '  - nginx                  (install nginx and create a safe default site)'
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
