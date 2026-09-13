# neveridle

Python 移植自 [layou233/NeverIdle](https://github.com/layou233/NeverIdle)（AGPL-3.0）。
用可控的 CPU / 内存 / 网络负载，降低云主机因空闲被回收的概率。

**可能违反云厂商 ToS**（停号、扣费等自负）。作者不承担任何损失。

```bash
python3 neveridle.py -cp 0.15 -m 2 -n 4h   # CPU 15% + 2GiB + 每 4h 测速
python3 neveridle.py -n cn 4h               # 国内友好 CDN
python3 neveridle.py -n 4h                  # 海外节点（自动发现）
python3 neveridle.py --version
```

| 参数 | 说明 |
|---|---|
| `-c <interval>` | CPU 空转间隔，如 `1h` / `30m` |
| `-cp <0.0~1.0>` | CPU 占用比例（PID 控制） |
| `-m <gib>` | 占用内存 GiB |
| `-n [cn] <interval>` | 网络测速；`cn` 用国内友好节点 |
| `-t <n>` | 并发连接（默认 8） |
| `-p <nice>` | 进程优先级（默认 19） |
| `-d` | 调试输出 |

依赖：Python 3 标准库。Ctrl-C 退出。
