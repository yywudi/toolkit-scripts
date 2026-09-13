# GitHub Transparent Accelerator (Universal Linux Edition)

专为**中国大陆云服务器（阿里云/腾讯云等有外联风控要求的环境）**设计的 GitHub 零全局代理、多 Web 架构自适应透明加速脚本。

---

## 核心设计与生产安全原则

在受限的国内云主机上访问 GitHub，常规方案存在严重缺陷：
1. **全局代理环境变量 (`http_proxy`) 方案**：污染内网业务网络（RDS、内部云元数据 100.100.100.200、内部 RPC），`no_proxy` 覆盖不全，易引发次生灾害。
2. **境外 SSH 隧道 / SOCKS5 / 翻墙方案**：具有明显长连接与加密握手特征，极易被阿里云安全中心（云盾）与机房 DPI 抓取，触发违规外联告警。
3. **单个命令包装器方案 (`curl`/`wget` wrapper)**：头痛医头脚痛医脚，无法覆盖 Python、Node.js、Git、Docker 等海量工具。

### 本工具的前置勘察与工业级安全设计

- **网络与地域前置勘测（零痕迹退出）**：优先检测 GitHub 原生直连连通性。若为海外或网络直连畅通环境，**在产生任何备份或磁盘写入前直接退出**，零文件残留；
- **镜像源现状尊重**：默认使用机器既有源，绝不私自篡改配置；仅在国内机器配置了官方境外源时，友好打印国内大学高校镜像源建议（清华 TUNA / 中科大 USTC / 上交 SJTU）；
- **443 端口全景适配 (Port Listener Discovery)**：
  - 443 被 **Nginx** 监听 -> 自动适配 Nginx 虚拟主机与证书体系；
  - 443 被 **Caddy** 监听 -> 自动追加 Caddyfile 块，加载统一专用证书；
  - 443 被 **Apache** 监听 -> 自动适配 Apache 虚拟主机与 Rewrite 代理规则；
  - 443 被 **非 Web 进程占用** -> 严格阻断并报警，防止踩踏正在运行的生产业务；
  - 443 端口 **完全空闲** -> 提示并支持通过系统包管理器一键安装轻量 Caddy 或 Nginx。
- **业务解耦与工业级安全设计**：
  - **零业务侵入**：彻底与具体业务解耦，通过标准 `/etc/systemd/system.conf.d/10-github-accel.conf`（Manager 级全局 Drop-in）注入环境，整机所有 systemd 托管后台服务（Node/PM2等）全自动继承；
  - **容量治理与轮转**：快照最多保留最新 3 份，自动清理历史旧快照，卸载后自动清理临时快照，杜绝磁盘膨胀；
  - **权限严格收敛**：CA 与服务器私钥 `0600`、证书目录 `0700`、CA 根公钥 `0644`，仅在专用子目录 `github-accel` 内流转；
  - **安装事务原子回滚**：挂载 Failure Trap，任意步骤中断自动从安装前专属快照完全恢复；
  - **精准成对区块防御**：Hosts 与 Caddyfile 区块严格校验整行唯一性与行号顺序，标记异常拒绝删除并报错阻断；
  - **避免静态锁定 API**：仅加速静态资产与源码域名，不硬编码写入公网 API 动态 IP。

---

## 运行权限要求

⚠️ 本脚本涉及系统级 `/etc/hosts`、系统根 CA 信任库 (`/usr/local/share/ca-certificates`)、全局环境及 Web 服务的配置，**必须以 root 权限执行**（若为普通用户请使用 `sudo ./github-accel.sh [命令]`，脚本入口处已做硬性权限防御阻断）。

---

## 单脚本使用说明

```bash
# 1. 勘察并一键安全配置加速（网络正常时自动跳过；受限网络自动适配 Web 架构）
./github-accel.sh install

# 2. 全景状态查询（网络直连状况、镜像源建议、443 端口监听归属与证书状态）
./github-accel.sh status

# 3. 运行全链路连通性自检 (curl / wget / API / Node.js)
./github-accel.sh test

# 4. 手动备份加速相关配置至指定目录
./github-accel.sh backup [目标目录]

# 5. 一键完全卸载并恢复系统至初始状态（自动优先从安装前专属快照精确还原）
./github-accel.sh restore
```

---

## 常用选项

- `--force`：在海外或直连正常的机器上强制执行安装与测试；
- `--with-caddy`：全新纯净机器（未装任何 Web 服务）时，指定通过系统包管理器安装 Caddy 并配置；
- `--with-nginx`：全新纯净机器（未装任何 Web 服务）时，指定通过系统包管理器安装 Nginx 并配置。

---

## 手动恢复指南

若因极端异常需要完全脱离脚本手动还原系统:
1. 还原 Web 配置并平滑重载：
   - Nginx: `rm -f /etc/nginx/sites-enabled/github-accel.conf /etc/nginx/sites-available/github-accel.conf /etc/nginx/conf.d/github-accel.conf && systemctl reload nginx`
   - Caddy: `sed -i '/# BEGIN github-accel/,/# END github-accel/d' /etc/caddy/Caddyfile && systemctl reload caddy`
   - Apache: `rm -f /etc/apache2/sites-enabled/github-accel.conf /etc/httpd/conf.d/github-accel.conf && systemctl reload apache2`
2. 清理证书:
   `rm -rf /etc/nginx/certs/github-accel /etc/caddy/certs/github-accel /etc/ssl/github-accel /usr/local/share/ca-certificates/local-github-ca.crt /etc/pki/ca-trust/source/anchors/local-github-ca.crt && (update-ca-certificates --fresh 2>/dev/null || update-ca-trust 2>/dev/null || true)`
3. 清理 Hosts 与环境:
   - `sed -i '/# BEGIN github-accel/,/# END github-accel/d' /etc/hosts`
   - `rm -f /etc/systemd/system.conf.d/10-github-accel.conf && systemctl daemon-reexec`
   - `sed -i '/# github-accel$/d' /etc/environment`
   - `[ -f /etc/profile.d/local-ca.sh ] && grep -q "# Managed by github-accel" /etc/profile.d/local-ca.sh && rm -f /etc/profile.d/local-ca.sh`
