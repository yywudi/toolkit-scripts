#!/usr/bin/env python3
"""
cn_download.py — 国内服务器下行流量脚本（仿 NeverIdle 思路）

模仿国内用户"拉取大厂安装包 / 系统更新"的下行行为：
  - 只在**国内服务器**运行（geo 自检，非 CN 拒绝跑）
  - 只跑下行，不落盘（写入 /dev/null）
  - 多 target 随机选；默认**完整下载单个文件**（文件多大下多大）
  - 可选 -b 预算切片模式（兼容旧行为）；可选 --every 常驻循环
  - Ctrl-C 优雅退出

TARGETS 为国内 CN 主机实测 HTTP 200 可达的稳定国内直链（全为整包，95–144MB）。
新增 target：加一行并先在国内 CN 主机实测体积。

DISCLAIMER: 本脚本向公共镜像拉取整包并丢弃，用于产生下行流量。
可能违反云厂商 / 镜像站 ToS，账号与流量费用自负。作者不承担任何损失。

Usage:
    python3 cn_download.py                       # 随机下完一个文件即停
    python3 cn_download.py -e 6h                  # 每 6h 下完一个随机文件（常驻）
    python3 cn_download.py -e 6h -r 50            # 同上，限速 50Mbps
    python3 cn_download.py -b 1g -w 100-300        # 旧切片模式：预算 1g，切片 100-300MB
    python3 cn_download.py --list                 # 列出候选 target（HEAD 校验）
    python3 cn_download.py -h

Options:
    -b, --budget <n>     切片模式下行预算 e.g. 500m/1g（不指定则整包下载单个文件）
    -e, --every <dur>    常驻模式：每轮间隔 N 小时 e.g. 6h（支持小数 1.6h）
    -w, --window <lo-hi> 切片模式单次切片 MB 范围（默认 100-300，仅 -b 时生效）
    -t, --targets <csv>  仅用指定 target 名子集
    -r, --rate <Mbps>    限速（默认不限）
    --list               列出候选并打印 HEAD 校验，不跑流量
    --no-geo-check       跳过 CN geo 自检（仅调试）
    -h, --help           显示帮助
"""

import os, sys, time, random, signal, argparse, threading
import re, socket, json, http.client, urllib.request, urllib.error

VERSION = "0.1.4"
VERSION_NOTE = ("2026-09-13: 公开分发 DISCLAIMER；中性化主机别名；"
                "2026-08-23 banner 三元优先级 / -e 非法值 / 移除 is_iso 死代码")

MiB = 1024 * 1024
GiB = 1024 * MiB
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/121.0 Safari/537.36")

# ── Tunables ────────────────────────────────────────────────────────────────
TRANSFER_TIMEOUT = 30        # 单 socket 收发硬超时（秒）
MIN_SPEED_Mbps = 1.0         # 平均速率低于此持续 MIN_SPEED_WINDOW 秒则放弃该 target
MIN_SPEED_WINDOW = 8.0
PHASE_TIMEOUT = 600          # 单次切片/整包硬超时（秒）
PROBE_TIMEOUT = 12           # HEAD 校验超时
RATE_BUF = 1 << 16           # 限速读取块
SLEEP_TICK = 1               # 常驻间隔休眠分片（秒）；Ctrl-C 后 ≤1s 退出

# ── Targets ─────────────────────────────────────────────────────────────────
# 全部为整包（size_hint = 文件真实大小），国内 CN 主机实测 HTTP 200 可达。
# 下载时整包下完，文件多大下多大（随机大小即 95–144MB 不等）。
TARGETS = [
    {"name": "electron30-win", "url":
     "https://cdn.npmmirror.com/binaries/electron/30.0.0/electron-v30.0.0-win32-x64.zip",
     "size_hint": 108 * MiB},
    {"name": "electron29-win", "url":
     "https://cdn.npmmirror.com/binaries/electron/29.4.6/electron-v29.4.6-win32-x64.zip",
     "size_hint": 103 * MiB},
    {"name": "electron28-win", "url":
     "https://cdn.npmmirror.com/binaries/electron/28.3.3/electron-v28.3.3-win32-x64.zip",
     "size_hint": 102 * MiB},
    {"name": "electron27-linux", "url":
     "https://cdn.npmmirror.com/binaries/electron/27.3.11/electron-v27.3.11-linux-x64.zip",
     "size_hint": 95 * MiB},
    {"name": "chrome-linux", "url":
     "https://cdn.npmmirror.com/binaries/chrome-for-testing/121.0.6167.85/linux64/chrome-linux64.zip",
     "size_hint": 142 * MiB},
    {"name": "chrome-win", "url":
     "https://cdn.npmmirror.com/binaries/chrome-for-testing/121.0.6167.85/win64/chrome-win64.zip",
     "size_hint": 144 * MiB},
]

g_stop = threading.Event()
g_total_bytes = 0
g_lock = threading.Lock()


def _sig_handler(signum, frame):
    # 置停止标志；所有阻塞点（sleep 分片 / read 循环）周期性查 g_stop，
    # 故 Ctrl-C 后 ≤1s 内退出，不会被长 sleep / 长连接阻塞。
    g_stop.set()


def parse_size(s: str) -> int:
    s = s.strip().lower()
    m = re.match(r'^(\d+(?:\.\d+)?)\s*([kmg]?)b?$', s)
    if not m:
        raise ValueError(f"无法解析大小: {s}")
    v = float(m.group(1))
    unit = m.group(2)
    return int(v * {"": 1, "k": 1024, "m": MiB, "g": GiB}[unit])


def parse_duration(s: str) -> float:
    s = s.strip()
    if not s:
        raise ValueError("empty duration")
    total = 0.0
    for m in re.finditer(r'(\d+(?:\.\d+)?)([hms])', s):
        v, u = float(m.group(1)), m.group(2)
        total += v * {"h": 3600, "m": 60, "s": 1}[u]
    if total <= 0:
        total = float(s)
    return total


def geo_is_cn() -> bool:
    try:
        req = urllib.request.Request("https://ipinfo.io/country",
                                     headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=8) as r:
            cc = r.read().decode(errors="replace").strip()
        return cc.upper() == "CN"
    except Exception:
        return False


def _head_size(url: str) -> tuple[int, bool]:
    """返回 (content_length_or_-1, ranges_supported)。"""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Range": "bytes=0-0"}, method="GET")
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT) as r:
            cl = r.headers.get("Content-Length")
            cr = r.headers.get("Content-Range")
            ar = r.headers.get("Accept-Ranges", "")
            total = -1
            if cr and "/" in cr:
                total = int(cr.split("/")[-1])
            elif cl:
                try:
                    total = int(cl)
                except ValueError:
                    total = -1
            supports_range = ("bytes" in ar.lower()) or cr is not None
            return total, supports_range
    except Exception:
        return -2, False


def do_download(tgt: dict, window: int, rate_mbps: float, whole: bool = False) -> int:
    """
    下载一个文件/切片，返回实际消费的字节数。
    - whole=True（整包模式）：从 0 下载到文件末尾，window 仅用于日志提示。
    - whole=False（切片模式）：最多读取 window 字节后停。
    """
    url = tgt["url"]
    headers = {"User-Agent": UA, "Accept": "*/*", "Connection": "close"}

    req = urllib.request.Request(url, headers=headers)
    fetched = 0
    t0 = time.time()
    slow_since = None
    try:
        with urllib.request.urlopen(req, timeout=1) as resp:
            rate_cap = (rate_mbps * 1_000_000 / 8.0) if rate_mbps > 0 else 0.0
            chunk_deadline = 0.0
            while not g_stop.is_set():
                if not whole and fetched >= window:
                    break
                if rate_cap > 0:
                    now = time.time()
                    if now < chunk_deadline:
                        time.sleep(chunk_deadline - now)
                try:
                    buf = resp.read(RATE_BUF)
                except socket.timeout:
                    # 1s 读超时：继续循环（会查 g_stop，Ctrl-C 即时退）；非错误
                    continue
                except (urllib.error.URLError, OSError) as e:
                    print(f"  [NET] {tgt['name']} 读取中断: {e}")
                    break
                if not buf:
                    break
                got = len(buf)
                fetched += got
                with g_lock:
                    global g_total_bytes
                    g_total_bytes += got
                if rate_cap > 0:
                    chunk_deadline = time.time() + got / rate_cap
                elapsed = time.time() - t0
                if elapsed > 1.0:
                    mbps = (fetched * 8.0) / (elapsed * 1_000_000)
                    if mbps < MIN_SPEED_Mbps:
                        if slow_since is None:
                            slow_since = time.time()
                        elif time.time() - slow_since >= MIN_SPEED_WINDOW:
                            print(f"  [SLOW] {tgt['name']} 低于 {MIN_SPEED_Mbps}Mbps 持续 "
                                  f"{MIN_SPEED_WINDOW:.0f}s，放弃")
                            break
                    else:
                        slow_since = None
                if elapsed > PHASE_TIMEOUT:
                    print(f"  [TIMEOUT] {tgt['name']} 超时，停止")
                    break
    except urllib.error.HTTPError as e:
        print(f"  [HTTP] {tgt['name']} HTTP {e.code}: {e.reason}")
    except (urllib.error.URLError, socket.timeout, OSError) as e:
        print(f"  [NET] {tgt['name']} 连接失败: {e}")
    return fetched


def run(args):
    targets = TARGETS
    if args.targets:
        want = {t.strip() for t in args.targets.split(",") if t.strip()}
        targets = [t for t in TARGETS if t["name"] in want]
        if not targets:
            print(f"[ERR] 无匹配 target：{args.targets}")
            sys.exit(1)

    lo, hi = args.window
    budget = args.budget          # 0 = 整包模式（每轮下载一个完整文件）
    rate = args.rate
    every = args.every
    slice_mode = budget > 0       # 仅 -b 显式指定时走切片模式

    mode_desc = (f"切片模式 budget={budget/MiB:.0f}MiB window={lo/MiB:.0f}-{hi/MiB:.0f}MiB"
                 if slice_mode else "整包模式（每轮完整下载一个随机文件）")
    print(f"================ 国内下行流量脚本 v{VERSION} ================")
    print(f"target 数: {len(targets)}  模式: {mode_desc}  "
          f"rate: {rate if rate else 'unlimited'}Mbps"
          + (f"  every: {every/3600:.2f}h" if every else ""))
    print("============================================================")

    round_no = 0
    while not g_stop.is_set():
        round_no += 1
        with g_lock:
            global g_total_bytes
            g_total_bytes = 0
        if every:
            print(f"\n########## ROUND #{round_no} 开始 @ {time.strftime('%Y-%m-%d %H:%M:%S')} ##########")
        while not g_stop.is_set():
            if slice_mode and g_total_bytes >= budget:
                print(f"[DONE] 预算到量 {g_total_bytes/MiB:.0f}MiB")
                break

            tgt = random.choice(targets)
            if slice_mode:
                window = random.randint(lo, hi)
                print(f"[{time.strftime('%H:%M:%S')}] {tgt['name']} window={window/MiB:.0f}MiB …", flush=True)
                got = do_download(tgt, window, rate, whole=False)
            else:
                fsize = tgt["size_hint"]
                print(f"[{time.strftime('%H:%M:%S')}] {tgt['name']} 整包={fsize/MiB:.0f}MiB …", flush=True)
                got = do_download(tgt, fsize, rate, whole=True)
            print(f"         ↳ {got/MiB:.1f}MiB")
            if not slice_mode:
                print(f"[DONE] 单文件整包完成")
                break

        if not every or g_stop.is_set():
            break

        slept = 0.0
        print(f"[SLEEP] 本轮结束，间隔 {every/3600:.2f}h 后开始下一轮 "
              f"(Ctrl-C 可退出)…", flush=True)
        while slept < every and not g_stop.is_set():
            chunk = min(SLEEP_TICK, every - slept)
            time.sleep(chunk)
            slept += chunk


def cmd_list(args):
    print(f"候选 target（国内 CN 主机实测 HTTP 200 可达，均为整包）：")
    for t in TARGETS:
        total, rng = _head_size(t["url"])
        print(f"  {t['name']:<18} 文件大小={total/MiB if total>0 else total}MiB  "
              f"range={'Y' if rng else 'N'}")


def main():
    ap = argparse.ArgumentParser(
        description="国内服务器下行流量脚本（仿 NeverIdle，纯下行）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="DISCLAIMER: 向公共镜像拉包丢弃以产生下行流量，可能违反 ToS，风险自负。")
    ap.add_argument("-b", "--budget", default="", help="切片模式下行预算 e.g. 500m/1g（不指定=整包下载单个文件）")
    ap.add_argument("-e", "--every", default="", help="常驻模式：每轮间隔 N 小时 e.g. 6h（支持小数 1.6h）")
    ap.add_argument("-w", "--window", default="100-300", help="切片模式单次切片 MB 范围 e.g. 100-300（仅 -b 时生效）")
    ap.add_argument("-t", "--targets", default="", help="target 名子集，逗号分隔")
    ap.add_argument("-r", "--rate", type=float, default=0.0, help="限速 Mbps（默认不限）")
    ap.add_argument("--list", action="store_true", help="列出候选并 HEAD 校验")
    ap.add_argument("--no-geo-check", action="store_true", help="跳过 CN geo 自检")
    ap.add_argument("--version", action="store_true", help="版本")
    args = ap.parse_args()

    if args.version:
        print(f"cn_download.py {VERSION} — {VERSION_NOTE}")
        sys.exit(0)
    if args.list:
        cmd_list(args)
        sys.exit(0)

    try:
        args.budget = parse_size(args.budget) if args.budget else 0
    except ValueError as e:
        print(f"[ERR] budget: {e}")
        sys.exit(1)
    try:
        args.every = parse_duration(args.every) if args.every else 0.0
        if args.every < 0:
            raise ValueError("间隔不能为负")
    except ValueError as e:
        print(f"[ERR] every: {e}")
        sys.exit(1)
    try:
        lo_s, hi_s = args.window.split("-")
        lo = int(float(lo_s)) * MiB
        hi = int(float(hi_s)) * MiB
        if lo <= 0 or hi < lo:
            raise ValueError()
    except Exception:
        print(f"[ERR] window 格式应为 lo-hi（MB），如 100-300")
        sys.exit(1)
    args.window = (lo, hi)

    if not args.no_geo_check:
        print("[GEO] 自检中…", flush=True)
        if not geo_is_cn():
            print("[ERR] 非国内 IP（geo 自检未通过）。本脚本仅应在国内服务器运行。\n"
                  "       若确认在国内，加 --no-geo-check 跳过。")
            sys.exit(1)
        print("[GEO] CN ✓", flush=True)

    signal.signal(signal.SIGINT, _sig_handler)
    signal.signal(signal.SIGTERM, _sig_handler)
    try:
        run(args)
    finally:
        print(f"\n[EXIT] 累计下行 {g_total_bytes/MiB:.1f} MiB "
              f"({(g_total_bytes*8)/1e6:.1f} Mbit)")


if __name__ == "__main__":
    main()
