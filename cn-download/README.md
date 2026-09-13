# cn-download

国内服务器下行流量脚本。只跑下行、不落盘（写入 `/dev/null`），模拟拉取大厂安装包。

**仅应在国内 IP 运行**（默认 geo 自检，非 CN 拒绝）。向公共镜像拉包并丢弃，**可能违反云厂商 / 镜像站 ToS**，账号与流量费用自负。

```bash
python3 cn_download.py                  # 随机下完一个文件即停
python3 cn_download.py -e 6h            # 每 6h 下一包（常驻）
python3 cn_download.py -e 6h -r 50      # 同上，限速 50Mbps
python3 cn_download.py --list           # HEAD 校验候选，不跑流量
python3 cn_download.py -h
```

| 参数 | 说明 |
|---|---|
| （无） | 默认整包下载单个文件，**不限速** |
| `-e, --every <dur>` | 常驻：每轮间隔，如 `6h` |
| `-r, --rate <Mbps>` | 限速；默认不限 |
| `-b, --budget <n>` | 切片模式预算，如 `1g` |
| `-w, --window <lo-hi>` | 切片 MB 范围（仅 `-b`，默认 100-300） |
| `-t, --targets <csv>` | 只用指定 target |
| `--list` | 列出候选并 HEAD 校验 |
| `--no-geo-check` | 跳过 CN geo 自检（仅调试） |

依赖：Python 3 标准库。Ctrl-C 后约 1s 内退出。
