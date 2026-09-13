# toolkit-scripts

自研运维脚本子集。不含第三方归档。

## 目录

| 路径 | 说明 |
|---|---|
| `github-accel/` | 国内机 GitHub HTTPS 透明加速 |
| `neveridle/` | 可控 CPU/内存/网络负载，降低空闲回收概率（AGPL 衍生，可能违反云 ToS） |
| `cn-download/` | 国内机向公共镜像拉包丢弃以产生下行（默认不限速，可能违反 ToS） |
| `port-shaper/` | 按端口 tc 限速 |
| `sshguard-nft/` | sshguard + nftables |
| `u2b/` | YouTube 区域检测 |
| `debian13/` | Debian 13 + nginx/WordPress 初始化 |

单脚本看 `-h` / 文件头；已有 README 的目录看目录内文档。

`neveridle/`、`cn-download/` 可能违反云厂商或镜像站 ToS，账号与费用自负。详见各自目录 README。

## 许可

GNU Affero General Public License v3.0。见 `LICENSE`。

`neveridle/` 是 [layou233/NeverIdle](https://github.com/layou233/NeverIdle) 的 Python 衍生，整仓因此用 AGPL-3.0。
