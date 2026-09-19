# GitHub Transparent Accelerator (Universal Linux Edition)

专为**中国大陆云服务器（阿里云/腾讯云等有外联风控要求的合规环境）**设计的 GitHub 零全局代理、公网物理零暴露、出站内核级透明加速脚本。

---

## 核心架构与生产安全原则

在受限的国内云主机上访问 GitHub，常规方案存在严重缺陷：
1. **全局代理环境变量 (`http_proxy`) 方案**：污染内网业务网络（RDS、内部云元数据 `100.100.100.200`、内部 RPC），`no_proxy` 覆盖不全，极易引发次生灾害；
2. **境外 SSH 隧道 / SOCKS5 / 翻墙方案**：具有明显长连接与加密握手特征，极易被云安全中心（云盾）与机房 DPI 抓取，触发违规外联告警；
3. **传统 443 端口反代方案**：在公网 443 端口吐出自签 GitHub 域名证书，外部端口扫描直接触发未备案域名与非法跨境代理审查；
4. **127.0.0.1 本地 Hosts 劫持方案**：现代 AI Agent（如 DSH `web_fetch`）以及集成 SSRF 安全检查的 Node.js/Python 工具在解析到私有/回环 IP 时主动中断，无法正常请求。

### 本工具的新一代工业级安全设计

- **公网物理零暴露（Zero Exposure）**：
  - Web 反代服务（Nginx 等）**严格仅监听 `127.0.0.1:44433 ssl;`**，物理清空主 443 端口的 GitHub 虚拟主机；
  - 外部公网扫描器探测 443 端口维持原生 `ssl_reject_handshake`（未配置状态）；探测 44433 端口物理无监听进程，直接返回 `Connection refused`。
- **真实公网 IP 欺骗与应用层 SSRF 放行**：
  - `/etc/hosts` 杜绝写入 `127.0.0.1`，精准绑定 GitHub 官方真实公网单播 IP（带动态存活探测与 443 连通性校验，兜底活跃节点 `20.205.243.166`）；
  - 完美放行应用层安全审计与 SSRF 检验（判定为公共公网 IP，顺利调用底层 `connect`）。
- **全局 SSH 443 极速通道托管（专解国内 22 端口超时）**：
  - 自动向 `/etc/ssh/ssh_config.d/10-github-accel.conf` 注入标准配置，全局将发往 `github.com:22` 的 SSH 请求重路由至官方 `ssh.github.com:443`；
  - `git clone git@...`、`git push`、GitHub CLI (`gh`) 与 CI Runner 无感切换至 SSH 443 专用通道，彻底绕过国内 22 封锁与 hosts 劫持。
- **控制面与数据面严格解耦保密**：
  - `api.github.com` 坚决不走 hosts 劫持与第三方公共反代，走官方原生直连；
  - 彻底规避用户敏感 GitHub Token 泄露给第三方公共镜像的合规风险，杜绝第三方镜像 403 阻断。
- **Linux 内核网络层精准出站截胡（Netfilter NAT）**：
  - 在内核协议栈 `OUTPUT` 链将出站至官方 IP 的 443 端口流量精准重定向至本地高位端口 `:44433`；
  - 支持 **nftables（现代内核优先）** 与 **iptables（通用兼容回退，专用 `GITHUB_ACCEL` 链）**，入站（INPUT）流量完全隔离不经过此重定向。
- **单脚本自包含与 Systemd 重启自动固化**：
  - 由主脚本内置 `apply-rules` / `clear-rules` 子命令承接内核规则注入与清理，不生成任何外部子脚本；
  - 自动部署 `github-accel-redirect.service`，保障主机重启后重定向规则无缝自启挂载，卸载时一键物理抹除。
- **双因子 4 状态前置决策（零痕迹退出）**：
  - 结合出口公网 GeoIP 与官方直连质量（探针：`https://raw.githubusercontent.com/robots.txt`）；
  - 若为海外环境或直连畅通环境，**在产生任何配置修改或磁盘写入前秒级退出**，保证零文件污染。
- **主流 Linux 发行版精确白名单准入**：
  - 严格校验 `/etc/os-release`（涵盖 Debian, Ubuntu, CentOS, Rocky, AlmaLinux, RHEL, Fedora, openEuler, Anolis, Alinux, TencentOS, Kylin, Deepin, UOS 等），非白名单或非 Systemd 友好阻断。
- **快照与彻底卸载保障**：
  - `restore` 命令不论安装前快照状态如何，均坚决物理拔除加速虚拟主机配置、本地证书、系统信任 CA、内核防火墙规则及自启单元，杜绝死循环残留。

---

## 运行权限要求

⚠️ 本脚本涉及系统级 `/etc/hosts`、系统根 CA 信任库、内核 Netfilter 防火墙及 Systemd 服务配置，**必须以 root 权限执行**（若为普通用户请使用 `sudo ./github-accel.sh [命令]`，脚本入口已做硬性权限拦截）。

---

## 单脚本使用说明

```bash
# 1. 勘察并一键安全配置加速（网络正常/境外自动跳过；受限网络自动闭环配置）
./github-accel.sh install

# 2. 全景勘察报告（网络环境、端口监听归属、Web 服务与内核规则状态）
./github-accel.sh status

# 3. 运行全链路自动化验收用例 (TC-01 至 TC-07，含 SSH 与公网防御测试)
./github-accel.sh test

# 4. 手动备份加速相关配置至指定目录
./github-accel.sh backup [目标目录]

# 5. 一键完全卸载并恢复系统至初始状态（100% 物理清除 Web 配置、证书、规则与自启单元）
./github-accel.sh restore

# 6. (底层运维) 手动重新应用内核出站重定向规则
./github-accel.sh apply-rules

# 7. (底层运维) 手动清理内核出站重定向规则
./github-accel.sh clear-rules
```

---

## 常用选项

- `--force`：在海外机器、直连正常的网络或非白名单发行版上强制执行安装与测试；
- `--with-caddy`：全新纯净主机（无任何 Web 服务）时，指定通过系统包管理器安装 Caddy 并配置；
- `--with-nginx`：全新纯净主机（无任何 Web 服务）时，指定通过系统包管理器安装 Nginx 并配置。

---

## 自动化验收测试套件 (Test Suite)

运行 `./github-accel.sh test` 将顺序执行 6 项工业级断言：
- **TC-01**：本地 curl 连通性测试（验证直连 raw.githubusercontent.com 获取 200 OK）；
- **TC-02**：本地 git ls-remote 连通性测试（验证 git 协议栈与 TLS 证书链）；
- **TC-03**：应用层 SSRF 防护放行测试（验证 Node.js 域名解析结果判定为公共 unicast IP）；
- **TC-04**：公网 443 端口零暴露验证（模拟外网探测，断言 TLS 握手拒绝，无证书泄漏）；
- **TC-05**：公网 44433 高位端口未暴露验证（模拟外网探测，断言 TCP 物理阻断 Connection refused）；
- **TC-06**：Systemd 重启规则恢复测试（重启 redirect 服务后断言内核重定向规则完整常驻）；
- **TC-07**：GitHub SSH 协议连通性测试（验证通过 `ssh.github.com:443` 成功完成 SSH 认证握手）。

---

## 手动完全恢复指南

若因极端异常需要完全脱离脚本手动还原系统：
1. **停止并清理 Systemd 重定向服务与内核规则（关键！必须首先执行）**：
   ```bash
   systemctl disable --now github-accel-redirect.service 2>/dev/null || true
   rm -f /etc/systemd/system/github-accel-redirect.service && systemctl daemon-reload
   nft delete table ip github_accel 2>/dev/null || true
   iptables -t nat -D OUTPUT -j GITHUB_ACCEL 2>/dev/null || true
   iptables -t nat -F GITHUB_ACCEL 2>/dev/null || true
   iptables -t nat -X GITHUB_ACCEL 2>/dev/null || true
   ```
2. **还原 Web 配置并平滑重载**：
   - Nginx: `rm -f /etc/nginx/sites-enabled/github-accel.conf /etc/nginx/sites-available/github-accel.conf /etc/nginx/conf.d/github-accel.conf && systemctl reload nginx`
   - Caddy: `sed -i '/# BEGIN github-accel/,/# END github-accel/d' /etc/caddy/Caddyfile && systemctl reload caddy`
   - Apache: `rm -f /etc/apache2/sites-enabled/github-accel.conf /etc/apache2/sites-available/github-accel.conf /etc/httpd/conf.d/github-accel.conf && systemctl reload apache2`
3. **清理证书及系统信任库**：
   ```bash
   rm -rf /etc/nginx/certs/github-accel /etc/nginx/ssl/github-accel /etc/caddy/certs/github-accel /etc/ssl/github-accel
   rm -f /usr/local/share/ca-certificates/local-github-ca.crt /etc/pki/ca-trust/source/anchors/local-github-ca.crt
   (update-ca-certificates --fresh 2>/dev/null || update-ca-trust 2>/dev/null || true)
   ```
4. **清理 Hosts 与环境变量**：
   ```bash
   sed -i '/# BEGIN github-accel/,/# END github-accel/d' /etc/hosts
   rm -f /etc/systemd/system.conf.d/10-github-accel.conf && systemctl daemon-reload
   sed -i '/# github-accel$/d' /etc/environment
   [ -f /etc/profile.d/local-ca.sh ] && grep -q "# Managed by github-accel" /etc/profile.d/local-ca.sh && rm -f /etc/profile.d/local-ca.sh
   [ -f /etc/ssh/ssh_config.d/10-github-accel.conf ] && grep -q "# Managed by github-accel" /etc/ssh/ssh_config.d/10-github-accel.conf && rm -f /etc/ssh/ssh_config.d/10-github-accel.conf
   ```
