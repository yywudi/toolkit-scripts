#!/usr/bin/env python3
"""
NeverIdle Python implementation — 0.2.4-python

Copyright (c) 2026 yywudi
Python port of NeverIdle by layou233
  https://github.com/layou233/NeverIdle
This file is a derivative work licensed under GNU Affero General Public
License v3.0 or later. See <https://www.gnu.org/licenses/agpl-3.0.html>.

DISCLAIMER: generating CPU/memory/network load to keep a cloud VM from
being reclaimed as idle may violate the provider's Terms of Service.
You run this at your own risk (account suspension, billing, etc.).
The authors are not liable for any loss.

Usage:
    python3 neveridle.py -cp 0.15 -m 2 -n 4h
    python3 neveridle.py -n cn 4h   # use China-friendly CDN nodes (Cloudflare)
    python3 neveridle.py -n 4h     # use overseas CDN nodes (auto-discovered)

Options:
    -c <interval>       CPU waste interval (e.g. 1h, 30m, 2.5h)
    -cp <percent>       CPU percentage waste (0.0~1.0), PID-controlled
    -d, --debug         Enable debug output (CPU%% bar, network details)
    -m <gib>            Memory to waste in GiB
    -n [cn] <interval>  Network speed test. 'cn' = China-friendly nodes
    -t <count>          Concurrent connections (default: 8)
    -p <nice>           Process priority (-20~19; default: 19 = lowest)
    --version           Show version and exit
"""

import os, sys, time, random, signal, argparse, threading, subprocess
import re, socket, ssl, json, http.client, urllib.request, urllib.error

VERSION = "0.2.4-python"
VERSION_NOTE = ("2026-09-13: AGPL-3.0 attribution + ToS disclaimer; "
                "unified deployment, parallel discovery, AliDNS DoH, clearer logging")

KiB = 1024; MiB = 1024*KiB; GiB = 1024*MiB
UA = "NeverIdle/1.0 (python)"

# ── Global state ──────────────────────────────────────────────────────────────
g_memory_objects = []
g_cpu_debug = False
g_pid_running = False
g_pid_lock = threading.Lock()
g_pid_busy_ns = 0; g_pid_idle_ns = 1_000_000_000
g_pid_revolution = 0.0
g_pid_max_step = 100_000_000_000.0

# ── Network tunables ─────────────────────────────────────────────────────────
MIN_SPEED_Mbps = 1.0           # abandon thread if avg speed stays below this
MIN_SPEED_WINDOW = 10.0         # for this many seconds continuously
THROTTLE_THRESHOLD_Mbps = 2.0   # if avg speed < this → endpoint is throttled, exit phase
TRANSFER_TIMEOUT = 20           # hard socket timeout per send/recv (seconds)
PHASE_TIMEOUT = 300             # hard timeout for entire phase (seconds)
DL_BUDGET = 200 * MiB          # download target per run
UL_BUDGET = 50 * MiB           # upload target per run
PROBE_TIMEOUT = 5               # seconds per latency probe
PROBE_CONCURRENCY = 8           # parallel probes during discovery
DEFAULT_NET_THREADS = 2          # safer default for sustained transfers
MAX_NET_THREADS = 2              # cap transfer concurrency to avoid short-conn overhead
RATE_LIMIT_RATIO = 0.80          # after first calibration run, hold near 80% of measured bandwidth
MIN_RATE_LIMIT_Mbps = 8.0        # do not throttle below a practical floor
MAX_RATE_LIMIT_Mbps = 1000.0     # sanity cap

# ── CDN Endpoints ─────────────────────────────────────────────────────────────
#
# Architecture:
#   1. Apple mensura CDN — preferred download backend (often domestic PoP in CN mode)
#   2. Cloudflare speedtest — reliable upload backend and overseas fallback
#      Both are anycast and broadly reachable from China and overseas.
#
# Strategy:
#   - Overseas mode: probe Apple + Cloudflare, pick the lower-latency download target
#   - CN mode:       probe both, prefer domestic Apple PoP for download if reachable
#   - Upload:        always use Cloudflare /__up for reliability
#
# Endpoints are resolved via DoH (Cloudflare DNS + AliDNS in parallel) to reduce
# resolver-related surprises inside China.

ENDPOINTS = {
    "apple": {
        "name": "Apple-mensura",
        "host": "mensura.cdn-apple.com",
        "dl_path": "/api/v1/gm/large",
        "ul_path": "/api/v1/gm/slurp",
        "lat_path": "/api/v1/gm/small",
        "dl_size_hint": 50 * MiB,   # single request gives ~50MB
    },
    "cloudflare": {
        "name": "Cloudflare-speedtest",
        "host": "speed.cloudflare.com",
        "dl_path": "/__down?bytes=25000000",
        "ul_path": "/__up",
        "lat_path": "/__down?bytes=0",
        "dl_size_hint": 25 * MiB,
    },
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

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


# ─── Process Priority ─────────────────────────────────────────────────────────

def set_worst_priority_impl():
    try:
        os.nice(19)
    except (OSError, PermissionError) as e:
        print(f"[PRIORITY] os.nice(19) failed: {e}")
    try:
        subprocess.run(["ionice", "-c", "3", "-p", str(os.getpid())],
                       stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL, timeout=5)
    except Exception:
        pass

def set_priority(nice: int):
    try:
        os.nice(nice)
    except (OSError, PermissionError) as e:
        print(f"[PRIORITY] Failed to set nice={nice}: {e}")


# ─── CPU Monitor ─────────────────────────────────────────────────────────────

class CPUMonitor:
    def __init__(self):
        self._psutil_available = False
        try:
            import psutil
            self._psutil_available = True
            self._psutil = psutil
        except ImportError:
            pass
        self.last_idle = self.last_total = 0
        self._lock = threading.Lock()
        self._samples = []
        self._running = False
        self._thread = None

    def _read_proc_stat(self):
        with open("/proc/stat") as f:
            line = f.readline()
        fields = line.split()[1:8]
        total = sum(int(x) for x in fields)
        idle = int(fields[3])
        return idle, total

    def _get_cpu_percent(self) -> float:
        if self._psutil_available:
            try:
                return self._psutil.cpu_percent(interval=0.5)
            except Exception:
                pass
        idle, total = self._read_proc_stat()
        if self.last_total == 0:
            self.last_idle, self.last_total = idle, total
            time.sleep(0.5)
            idle, total = self._read_proc_stat()
        idle_delta = idle - self.last_idle
        total_delta = total - self.last_total
        self.last_idle, self.last_total = idle, total
        if total_delta == 0:
            return 0.0
        return 100.0 * (1.0 - idle_delta / total_delta)

    def _monitor_loop(self):
        while self._running:
            try:
                pct = self._get_cpu_percent()
                with self._lock:
                    self._samples.append((time.time(), pct))
                    if len(self._samples) > 30:
                        self._samples.pop(0)
                if g_cpu_debug:
                    self._print_bar(pct)
            except Exception as e:
                print(f"[CPU-MONITOR] {e}")
            time.sleep(2.0)

    def _print_bar(self, pct: float):
        bar = "#" * int(20 * pct / 100) + "-" * (20 - int(20 * pct / 100))
        try:
            l1, l5, l15 = os.getloadavg()
            print(f"[{time.strftime('%H:%M:%S')}] CPU: {pct:5.1f}%% [{bar}] load: {l1:.2f} {l5:.2f} {l15:.2f}")
        except Exception:
            print(f"[{time.strftime('%H:%M:%S')}] CPU: {pct:5.1f}%% [{bar}]")

    def start(self):
        self._running = True
        self._thread = threading.Thread(target=self._monitor_loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._running = False
        if self._thread:
            self._thread.join(timeout=3)

    def get_current_percent(self) -> float:
        with self._lock:
            return self._samples[-1][1] if self._samples else 0.0


# ─── Memory ─────────────────────────────────────────────────────────────────

def get_memory_mb() -> float:
    try:
        import psutil
        return psutil.Process(os.getpid()).memory_info().rss / MiB
    except Exception:
        try:
            with open(f"/proc/{os.getpid()}/status") as f:
                for line in f:
                    if line.startswith("VmRSS:"):
                        return float(line.split()[1]) / 1024
        except Exception:
            pass
    return 0.0


def waste_memory(gib: int, monitor: CPUMonitor = None):
    global g_memory_objects
    print("====================")
    print(f"Starting memory waste of {gib} GiB")
    g_memory_objects = []
    for i in range(gib):
        obj = bytearray(GiB)
        view = memoryview(obj)
        for offset in range(0, GiB, 65536):
            chunk = min(65536, GiB - offset)
            view[offset:offset+chunk] = bytes(random.getrandbits(8) for _ in range(chunk))
        g_memory_objects.append(obj)
        rss = get_memory_mb()
        print(f"[MEMORY] {i+1}/{gib} GiB  (RSS: {rss:.0f} MB)")
        time.sleep(0.05)
    print(f"[MEMORY] Holding {gib} GiB  (RSS: {get_memory_mb():.0f} MB)")
    print("====================")


# ─── Stream Cipher (CPU burn) ───────────────────────────────────────────────

def _get_cipher():
    return (bytes(random.getrandbits(8) for _ in range(32)),
            bytes(random.getrandbits(8) for _ in range(24)))

def _fill_buffer(buf: bytearray):
    view = memoryview(buf)
    for i in range(0, len(buf), 65536):
        chunk = min(65536, len(buf) - i)
        view[i:i+chunk] = bytes(random.getrandbits(8) for _ in range(chunk))

def _burn_cpu_block(buf: bytearray, key: bytes, nonce: bytes) -> bytearray:
    try:
        from Crypto.Cipher import ChaCha20
        return bytearray(ChaCha20.new(key=key, nonce=nonce).encrypt(bytes(buf)))
    except ImportError:
        state = list(range(256))
        j = 0
        for i in range(256):
            j = (j + state[i] + key[i % len(key)]) & 0xFF
            state[i], state[j] = state[j], state[i]
        i = j = 0
        out = bytearray(len(buf))
        for k in range(len(buf)):
            i = (i + 1) & 0xFF
            j = (j + state[i]) & 0xFF
            state[i], state[j] = state[j], state[i]
            out[k] = buf[k] ^ state[(state[i] + state[j]) & 0xFF]
        return out


# ─── CPU Waste ───────────────────────────────────────────────────────────────

def waste_cpu(interval_seconds: float, monitor: CPUMonitor):
    print("====================")
    print(f"Starting CPU waste with interval {format_duration(interval_seconds)}")
    buf = bytearray(4*MiB); _fill_buffer(buf)
    key, nonce = _get_cipher()
    _run_burn_round(buf, key, nonce)
    print(f"[CPU] First burn at {time.strftime('%Y-%m-%d %H:%M:%S')}")
    while True:
        time.sleep(interval_seconds)
        key, nonce = _get_cipher(); _fill_buffer(buf)
        _run_burn_round(buf, key, nonce)
        pct = monitor.get_current_percent()
        print(f"[CPU] Burned at {time.strftime('%Y-%m-%d %H:%M:%S')}  (CPU: {pct:.1f}%%)")

def _run_burn_round(buf: bytearray, key: bytes, nonce: bytes):
    def worker():
        b, k, n = buf, key, nonce
        for _ in range(64):
            b = _burn_cpu_block(b, k, n)
            k, n = _get_cipher()
    threads = [threading.Thread(target=worker, daemon=True) for _ in range(8)]
    for t in threads: t.start()
    for t in threads: t.join()


# ─── CPU Percent (PID) ──────────────────────────────────────────────────────

def waste_cpu_percent(reference_percent: float, monitor: CPUMonitor):
    global g_pid_running, g_pid_busy_ns, g_pid_idle_ns, g_pid_revolution
    ref_x_100 = reference_percent * 100.0
    Kp = g_pid_max_step / 1000.0; Ki = 1.0
    print("====================")
    print(f"Starting CPU waste with percent {reference_percent:.2f}")
    g_pid_running = True
    num_cpu = os.cpu_count() or 1

    def worker():
        global g_pid_busy_ns, g_pid_idle_ns, g_pid_lock, g_pid_running
        buf = bytearray(4*MiB); _fill_buffer(buf)
        key, nonce = _get_cipher()
        while g_pid_running:
            with g_pid_lock:
                busy_ns = g_pid_busy_ns; idle_ns = g_pid_idle_ns
            period_ns = busy_ns + idle_ns or 1_000_000_000
            start = time.perf_counter_ns()
            deadline = start + busy_ns
            while time.perf_counter_ns() < deadline and g_pid_running:
                buf = bytearray(_burn_cpu_block(buf, key, nonce))
                key, nonce = _get_cipher(); _fill_buffer(buf)
            elapsed = time.perf_counter_ns() - start
            sleep_ns = period_ns - elapsed
            if sleep_ns > 0:
                time.sleep(sleep_ns / 1e9)

    workers = [threading.Thread(target=worker, daemon=True) for _ in range(num_cpu)]
    for t in workers: t.start()
    print(f"[CPU-PID] {num_cpu} workers, target={ref_x_100:.1f}%%")
    print("====================")

    integral = 0.0
    while g_pid_running:
        actual = monitor.get_current_percent()
        error = ref_x_100 - actual
        integral += error
        control = Kp * error + Ki * integral
        with g_pid_lock:
            g_pid_revolution += control
            g_pid_revolution = max(0.0, min(g_pid_max_step, g_pid_revolution))
            if g_pid_revolution <= 0: integral = 0
            ratio = g_pid_revolution / g_pid_max_step
            ns = 1_000_000_000
            g_pid_busy_ns = int(ns * ratio)
            g_pid_idle_ns = ns - g_pid_busy_ns
        if g_cpu_debug:
            bar = "#" * int(20 * actual / 100) + "-" * (20 - int(20 * actual / 100))
            print(f"[CPU-PID] target={ref_x_100:.1f}%% actual={actual:5.1f}%% [{bar}] "
                  f"busy={g_pid_busy_ns/1e6:.1f}ms idle={g_pid_idle_ns/1e6:.1f}ms")
        time.sleep(1.0)


# ─── DNS Resolution ─────────────────────────────────────────────────────────

def _doh_query(url: str) -> tuple[list[str], bool]:
    """Query a DoH URL. Returns (ips, timed_out). Supports dict or list JSON bodies."""
    try:
        req = urllib.request.Request(url, headers={
            "Accept": "application/dns-json", "User-Agent": UA})
        with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT) as resp:
            raw = resp.read()
            data = json.loads(raw)

        ips = []
        if isinstance(data, dict):
            for a in data.get("Answer", []) or []:
                if isinstance(a, dict) and a.get("type") == 1 and a.get("data"):
                    ips.append(a["data"])
            # AliDNS may also return {"Answer": ["1.2.3.4", ...]} in some modes
            for a in data.get("Answer", []) or []:
                if isinstance(a, str):
                    ips.append(a)
        elif isinstance(data, list):
            for item in data:
                if isinstance(item, str):
                    ips.append(item)
                elif isinstance(item, dict) and item.get("type") == 1 and item.get("data"):
                    ips.append(item["data"])

        # keep IPv4 only and deduplicate while preserving order
        out, seen = [], set()
        for ip in ips:
            try:
                socket.inet_aton(ip)
            except OSError:
                continue
            if ip not in seen:
                seen.add(ip)
                out.append(ip)
        return out, False
    except Exception as e:
        if g_cpu_debug:
            print(f"[NET-DBG] DoH failed {url}: {e}")
        return [], ("timed out" in str(e).lower() or isinstance(e, socket.timeout))

def _resolve_apple_cdn() -> tuple[list[str], bool]:
    """Resolve mensura.cdn-apple.com via DoH. Returns (ips, doh_success)."""
    ips = _resolve_doh("mensura.cdn-apple.com")
    if ips:
        return ips, True
    # Fallback: system DNS
    ip = _resolve_system("mensura.cdn-apple.com")
    return [ip] if ip else [], False


def _resolve_cloudflare() -> tuple[list[str], bool]:
    """Resolve speed.cloudflare.com via DoH. Returns (ips, doh_success)."""
    ips = _resolve_doh("speed.cloudflare.com")
    if ips:
        return ips, True
    ip = _resolve_system("speed.cloudflare.com")
    return [ip] if ip else [], False


def _resolve_doh(host: str) -> list[str]:
    """Resolve via Cloudflare DoH + Ali DoH in parallel. Returns deduplicated IPs."""
    cf_url = f"https://cloudflare-dns.com/dns-query?name={host}&type=A"
    ali_url = f"https://dns.alidns.com/resolve?name={host}&type=A&short=1"
    results, timed_outs = {}, {}
    def q_cf():
        r, t = _doh_query(cf_url); results["cf"] = r; timed_outs["cf"] = t
    def q_ali():
        r, t = _doh_query(ali_url); results["ali"] = r; timed_outs["ali"] = t
    t1 = threading.Thread(target=q_cf, daemon=True)
    t2 = threading.Thread(target=q_ali, daemon=True)
    t1.start(); t2.start(); t1.join(); t2.join()
    all_ips = results.get("cf", []) + results.get("ali", [])
    seen = set(); unique = []
    for ip in all_ips:
        if ip not in seen: seen.add(ip); unique.append(ip)
    return unique

def _resolve_system(host: str) -> str:
    try:
        old = socket.getdefaulttimeout()
        socket.setdefaulttimeout(5)
        try:
            for family, _, _, _, (ip, *_) in socket.getaddrinfo(host, None):
                if family == socket.AF_INET:
                    return ip
        finally:
            socket.setdefaulttimeout(old)
    except Exception:
        pass
    return ""


# ─── SSL Context ─────────────────────────────────────────────────────────────

def _ssl_ctx() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    return ctx


# ─── IP-Pinned HTTPS Connection ──────────────────────────────────────────────

class PinnedHTTPSConnection(http.client.HTTPSConnection):
    """
    HTTPS connection that pins to a specific IP but sets SNI + Host header
    to the real hostname (for CDN anycast routing).
    Every socket operation has a timeout.
    """
    def __init__(self, real_host: str, ip: str, port: int = 443, timeout: int = TRANSFER_TIMEOUT):
        self._real_host = real_host
        super().__init__(ip, port=port, context=_ssl_ctx(), timeout=timeout)

    def connect(self):
        sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self._real_host)


# ─── Latency Probe ───────────────────────────────────────────────────────────

def _probe_latency(real_host: str, ip: str, path: str) -> float:
    """HTTP GET latency in ms. Returns -1 on failure."""
    start = time.time()
    try:
        conn = PinnedHTTPSConnection(real_host, ip, timeout=PROBE_TIMEOUT)
        conn.connect()
        req = (f"GET {path} HTTP/1.1\r\nHost: {real_host}\r\n"
               f"User-Agent: {UA}\r\nAccept: */*\r\nConnection: close\r\n\r\n".encode())
        conn.sock.sendall(req)
        conn.sock.recv(256)
        conn.sock.close()
        return (time.time() - start) * 1000
    except Exception:
        return -1.0


def _probe_latency_simple(host: str, path: str) -> float:
    """Direct HTTPS probe without IP pinning (for IPs used directly as host)."""
    ip = _resolve_system(host)
    if not ip:
        return -1.0
    start = time.time()
    try:
        sock = socket.create_connection((ip, 443), timeout=PROBE_TIMEOUT)
        ssock = _ssl_ctx().wrap_socket(sock, server_hostname=host)
        req = (f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
               f"User-Agent: {UA}\r\nAccept: */*\r\nConnection: close\r\n\r\n".encode())
        ssock.sendall(req)
        ssock.recv(256)
        ssock.close()
        return (time.time() - start) * 1000
    except Exception:
        return -1.0


# ─── Endpoint Discovery ─────────────────────────────────────────────────────

def _probe_ep(name: str, ep: dict) -> tuple[dict, float]:
    """Resolve endpoint host via DoH, then probe latency. Returns (endpoint_with_ip, latency_ms)."""
    host = ep["host"]
    path = ep["lat_path"]
    if g_cpu_debug:
        print(f"[NET-DBG] Probing endpoint {name}: host={host} path={path}")

    # Resolve via DoH
    ips = _resolve_doh(host)
    if not ips:
        # Fallback: system DNS
        ip = _resolve_system(host)
        if ip:
            ips = [ip]
            if g_cpu_debug:
                print(f"[NET-DBG] {name}: system DNS fallback -> {ip}")
    if not ips:
        print(f"[NETWORK] {ep['name']}: DNS failed for {host}")
        return {}, -1.0

    # Probe each IP, pick lowest latency
    results = {}
    lock = threading.Lock()

    def probe(ip):
        if g_cpu_debug:
            print(f"[NET-DBG] {name}: probing {ip} ...")
        ms = _probe_latency(host, ip, path)
        if ms > 0:
            with lock:
                results[ip] = ms
        elif g_cpu_debug:
            print(f"[NET-DBG] {name}: {ip} probe failed")

    threads = [threading.Thread(target=probe, args=(ip,), daemon=True) for ip in ips[:PROBE_CONCURRENCY]]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=PROBE_TIMEOUT + 1)

    if not results:
        print(f"[NETWORK] {ep['name']}: all probes failed for {host}")
        return {}, -1.0

    best_ip = min(results, key=results.get)
    best_ms = results[best_ip]
    result = dict(ep)
    result["ip"] = best_ip
    result["latency_ms"] = best_ms
    result["name"] = f"{ep['name']} ({best_ip})"
    print(f"[NETWORK] {ep['name']}: selected {best_ip} latency={best_ms:.1f}ms")
    return result, best_ms


def discover_endpoints(cn_mode: bool = False) -> dict:
    """
    Discover best CDN endpoint.
    Overseas: probe Apple + Cloudflare in parallel, pick lower latency.
    CN:       probe Apple + Cloudflare in parallel, prefer Apple if available.
    Returns endpoint dict with 'ip', 'host', 'latency_ms', 'name', 'dl_path', 'ul_path'.
    """
    if cn_mode:
        print("[NETWORK] CN discovery: probing Apple and Cloudflare in parallel...")
    else:
        print("[NETWORK] Overseas discovery: probing Apple and Cloudflare in parallel...")

    results = {}
    lock = threading.Lock()

    def probe_named(ep_name: str):
        ep = ENDPOINTS[ep_name]
        result, ms = _probe_ep(ep_name, ep)
        with lock:
            results[ep_name] = (result, ms)

    threads = [
        threading.Thread(target=probe_named, args=("apple",), daemon=True),
        threading.Thread(target=probe_named, args=("cloudflare",), daemon=True),
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    r1, m1 = results.get("apple", ({}, -1.0))
    r2, m2 = results.get("cloudflare", ({}, -1.0))

    if cn_mode:
        if m1 > 0:
            print("[NETWORK] CN mode: preferring Apple for download")
            return r1
        if m2 > 0:
            print("[NETWORK] CN mode: Apple unavailable, falling back to Cloudflare")
            return r2
        return {}

    if m1 > 0 and m2 > 0:
        best = r1 if m1 <= m2 else r2
        print(f"[NETWORK] Apple latency={m1:.1f}ms  Cloudflare latency={m2:.1f}ms  → picking {best['name']}")
        return best
    if m1 > 0:
        return r1
    if m2 > 0:
        return r2
    return {}


# ─── Transfer helpers ───────────────────────────────────────────────────────

def _send_with_timeout(sock: ssl.SSLSocket, data: bytes, deadline: float) -> int:
    """Send all data with per-chunk timeout. Returns bytes sent."""
    sent = 0; chunk_size = 128*KiB
    while sent < len(data) and time.time() < deadline:
        sock.settimeout(min(TRANSFER_TIMEOUT, deadline - time.time()))
        try:
            end = min(sent + chunk_size, len(data))
            sock.sendall(data[sent:end]); sent = end
        except (socket.timeout, ssl.SSLError, OSError) as e:
            if g_cpu_debug:
                print(f"[NET-DBG] send error: {e}")
            break
    return sent

def _recv_with_timeout(sock: ssl.SSLSocket, max_bytes: int, deadline: float) -> bytes:
    """Receive up to max_bytes with per-read timeout. Returns body bytes."""
    buf = b''
    while len(buf) < max_bytes and time.time() < deadline:
        sock.settimeout(min(5.0, deadline - time.time()))
        try:
            chunk = sock.recv(min(65536, max_bytes - len(buf)))
            if not chunk: break
            buf += chunk
        except (socket.timeout, ssl.SSLError):
            break
    return buf

def _read_http_headers(sock: ssl.SSLSocket, deadline: float) -> tuple[str, bytes]:
    buf = b""
    marker = b"\r\n\r\n"
    while marker not in buf and time.time() < deadline:
        sock.settimeout(min(5.0, deadline - time.time()))
        chunk = sock.recv(65536)
        if not chunk:
            break
        buf += chunk
        if len(buf) > 512 * KiB:
            break
    if marker not in buf:
        return "", b""
    hdr_end = buf.index(marker)
    hdr = buf[:hdr_end].decode("latin-1", errors="replace")
    body = buf[hdr_end+4:]
    return hdr, body

def _parse_content_length(header_text: str) -> int:
    for line in header_text.split("\r\n"):
        if line.lower().startswith("content-length:"):
            try:
                return int(line.split(":", 1)[1].strip())
            except ValueError:
                return 0
    return 0

def _paced_sleep(sent_or_recv: int, started_at: float, limit_mbps: float | None):
    if not limit_mbps or limit_mbps <= 0:
        return
    target_elapsed = (sent_or_recv * 8) / (limit_mbps * 1e6)
    actual_elapsed = time.time() - started_at
    if target_elapsed > actual_elapsed:
        time.sleep(min(target_elapsed - actual_elapsed, 0.2))


# ─── Download ────────────────────────────────────────────────────────────────

def _run_download(ep: dict, num_threads: int,
                  byte_budget: int,
                  progress_cb=None,
                  limit_mbps: float | None = None) -> tuple[int, float]:
    """
    Download byte_budget bytes across num_threads using sustained reads.
    Each thread keeps a connection open and continuously drains the response
    until the shared budget is reached.
    Returns (total_bytes, elapsed_seconds).
    """
    host = ep["host"]; ip = ep["ip"]; port = ep.get("port", 443)
    path = ep["dl_path"]
    phase_deadline = time.time() + PHASE_TIMEOUT

    total = [0]; done = [False]
    lock = threading.Lock()
    t_start = time.time()
    per_thread_limit = (limit_mbps / max(1, num_threads)) if limit_mbps else None

    def dl_worker(wid: int):
        speed_samples = []
        below_min_since = None

        while True:
            with lock:
                if done[0] or total[0] >= byte_budget or time.time() > phase_deadline:
                    return
            conn = None
            local_bytes = 0
            local_start = time.time()
            try:
                conn = PinnedHTTPSConnection(host, ip, port, timeout=TRANSFER_TIMEOUT)
                conn.connect()
                req = (f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
                       f"User-Agent: {UA}\r\nAccept: */*\r\nAccept-Encoding: identity\r\n"
                       f"Connection: keep-alive\r\n\r\n".encode())
                conn.sock.sendall(req)
                header_text, initial_body = _read_http_headers(conn.sock, phase_deadline)
                if not header_text:
                    raise IOError("download response headers not received")
                content_length = _parse_content_length(header_text)

                def consume(data: bytes) -> bool:
                    nonlocal local_bytes, below_min_since
                    if not data:
                        return False
                    with lock:
                        remaining = byte_budget - total[0]
                        if remaining <= 0:
                            done[0] = True
                            return False
                        take = min(len(data), remaining)
                        total[0] += take
                        cur_total = total[0]
                        if total[0] >= byte_budget:
                            done[0] = True
                    local_bytes += take
                    now = time.time()
                    speed_samples.append((now, cur_total))
                    cutoff = now - MIN_SPEED_WINDOW * 2
                    while speed_samples and speed_samples[0][0] < cutoff:
                        speed_samples.pop(0)
                    if len(speed_samples) >= 2:
                        t0, b0 = speed_samples[0]; t1, b1 = speed_samples[-1]
                        dt = t1 - t0
                        if dt >= MIN_SPEED_WINDOW:
                            spd = ((b1-b0)*8)/(dt*1e6)
                            throttled = (spd < THROTTLE_THRESHOLD_Mbps)
                            too_slow = (spd < MIN_SPEED_Mbps)
                            if throttled or too_slow:
                                if below_min_since is None:
                                    below_min_since = now
                                elif now - below_min_since >= MIN_SPEED_WINDOW:
                                    with lock:
                                        done[0] = True
                                    return False
                            else:
                                below_min_since = None
                    _paced_sleep(local_bytes, local_start, per_thread_limit)
                    return take == len(data) and not done[0]

                if initial_body and not consume(initial_body):
                    return

                while time.time() < phase_deadline:
                    with lock:
                        if done[0] or total[0] >= byte_budget:
                            return
                    conn.sock.settimeout(min(5.0, phase_deadline - time.time()))
                    chunk = conn.sock.recv(256 * KiB)
                    if not chunk:
                        break
                    if not consume(chunk):
                        return
                    if content_length > 0 and local_bytes >= content_length:
                        break

            except Exception as e:
                if g_cpu_debug:
                    print(f"[NET-DBG] DL-{wid} error: {e}")
                return
            finally:
                if conn:
                    try: conn.sock.close()
                    except Exception: pass

    threads = [threading.Thread(target=dl_worker, args=(i,), daemon=True) for i in range(num_threads)]
    for t in threads: t.start()

    while not done[0]:
        time.sleep(0.5)
        cur = total[0]; elapsed = time.time() - t_start
        mbps = (cur*8)/(elapsed*1e6) if elapsed > 0 else 0
        pct = min(100, cur/byte_budget*100)
        bar = "#"*int(pct/5)+"-"*(20-int(pct/5))
        print(f"[NETWORK] DL {cur/MiB:7.1f}/{byte_budget/MiB:7.0f} MB  {mbps:7.1f} Mbps  [{bar}]  {elapsed:.0f}s")
        if elapsed >= PHASE_TIMEOUT:
            print(f"[NETWORK] Download phase timeout ({PHASE_TIMEOUT}s)")
            done[0] = True

    for t in threads: t.join(timeout=3)
    elapsed = time.time() - t_start
    return total[0], elapsed


# ─── Upload ─────────────────────────────────────────────────────────────────

def _run_upload(ep: dict, num_threads: int,
                byte_budget: int,
                progress_cb=None,
                limit_mbps: float | None = None) -> tuple[int, float]:
    """
    Upload byte_budget bytes across num_threads.
    Each worker keeps one HTTPS connection open and sends larger POST bodies.
    Returns (total_bytes_sent, elapsed_seconds).
    """
    host = ep["host"]; ip = ep["ip"]; port = ep.get("port", 443)
    path = ep["ul_path"]
    phase_deadline = time.time() + PHASE_TIMEOUT

    total = [0]; done = [False]
    lock = threading.Lock()
    t_start = time.time()
    per_thread_limit = (limit_mbps / max(1, num_threads)) if limit_mbps else None
    upload_chunk = 8 * 1024 * 1024
    payload_cache = {}
    payload_lock = threading.Lock()

    def get_payload(size: int) -> bytes:
        with payload_lock:
            buf = payload_cache.get(size)
            if buf is None:
                buf = os.urandom(size)
                payload_cache[size] = buf
            return buf

    def read_response(sock, deadline):
        status = _read_http_headers(sock, deadline)
        if not status:
            raise IOError('missing upload response header')
        _, hdrs = status
        content_len = 0
        chunked = False
        for line in hdrs.split(b"\r\n"):
            lower = line.lower()
            if lower.startswith(b'content-length:'):
                try:
                    content_len = int(line.split(b':', 1)[1].strip())
                except Exception:
                    content_len = 0
            elif lower.startswith(b'transfer-encoding:') and b'chunked' in lower:
                chunked = True
        if chunked:
            while True:
                line = b''
                while not line.endswith(b'\r\n'):
                    sock.settimeout(_remaining_deadline_timeout(deadline))
                    piece = sock.recv(1)
                    if not piece:
                        raise IOError('unexpected EOF in chunked header')
                    line += piece
                size = int(line.strip(), 16)
                if size == 0:
                    trailer = b''
                    while not trailer.endswith(b'\r\n\r\n'):
                        sock.settimeout(_remaining_deadline_timeout(deadline))
                        piece = sock.recv(1)
                        if not piece:
                            break
                        trailer += piece
                    return
                remaining = size + 2
                while remaining > 0:
                    sock.settimeout(_remaining_deadline_timeout(deadline))
                    piece = sock.recv(min(65536, remaining))
                    if not piece:
                        raise IOError('unexpected EOF in chunked body')
                    remaining -= len(piece)
            return
        remaining = content_len
        while remaining > 0:
            sock.settimeout(_remaining_deadline_timeout(deadline))
            piece = sock.recv(min(65536, remaining))
            if not piece:
                break
            remaining -= len(piece)

    def ul_worker(wid: int):
        below_min_since = None
        local_start = time.time()
        local_sent = 0
        conn = None
        try:
            conn = PinnedHTTPSConnection(host, ip, port, timeout=TRANSFER_TIMEOUT)
            conn.connect()
            sock = conn.sock
            speed_samples = []
            while True:
                with lock:
                    if done[0] or total[0] >= byte_budget or time.time() > phase_deadline:
                        return
                    chunk_size = min(upload_chunk, byte_budget - total[0])
                    total[0] += chunk_size
                    reserved_total = total[0]
                if chunk_size <= 0:
                    with lock:
                        done[0] = True
                    return

                data = get_payload(chunk_size)
                header = (
                    f"POST {path} HTTP/1.1\r\nHost: {host}\r\n"
                    f"User-Agent: {UA}\r\nContent-Type: application/octet-stream\r\n"
                    f"Content-Length: {chunk_size}\r\nAccept: */*\r\n"
                    f"Connection: keep-alive\r\n\r\n"
                ).encode()
                _send_with_timeout(sock, header, phase_deadline)
                _send_with_timeout(sock, data, phase_deadline)
                read_response(sock, phase_deadline)

                now = time.time()
                local_sent += chunk_size
                _paced_sleep(local_sent, local_start, per_thread_limit)

                speed_samples.append((now, local_sent))
                cutoff = now - MIN_SPEED_WINDOW * 2
                while speed_samples and speed_samples[0][0] < cutoff:
                    speed_samples.pop(0)
                if len(speed_samples) >= 2:
                    t0, b0 = speed_samples[0]; t1, b1 = speed_samples[-1]
                    dt = t1 - t0
                    if dt >= MIN_SPEED_WINDOW:
                        spd = ((b1-b0)*8)/(dt*1e6)
                        throttled = (spd < THROTTLE_THRESHOLD_Mbps)
                        too_slow = (spd < MIN_SPEED_Mbps)
                        if throttled or too_slow:
                            if below_min_since is None:
                                below_min_since = now
                            elif now - below_min_since >= MIN_SPEED_WINDOW:
                                if g_cpu_debug:
                                    reason = 'throttled' if throttled else 'too slow'
                                    print(f"[NET-DBG] UL-{wid} speed={spd:.2f}Mbps ({reason}) for {MIN_SPEED_WINDOW}s → exit this phase")
                                with lock:
                                    done[0] = True
                                return
                        else:
                            below_min_since = None

                if progress_cb:
                    elapsed = now - t_start
                    progress_cb('upload', reserved_total, byte_budget,
                                (reserved_total*8)/(elapsed*1e6) if elapsed > 0 else 0, elapsed)
                with lock:
                    if total[0] >= byte_budget:
                        done[0] = True
        except Exception as e:
            if g_cpu_debug:
                print(f"[NET-DBG] UL-{wid} error: {e}")
            with lock:
                unsent = max(0, min(upload_chunk, total[0] - local_sent))
                total[0] = max(0, total[0] - unsent)
                done[0] = True
            return
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    threads = [threading.Thread(target=ul_worker, args=(i,), daemon=True) for i in range(num_threads)]
    for t in threads: t.start()

    while not done[0]:
        time.sleep(1)
        cur = total[0]; elapsed = time.time() - t_start
        mbps = (cur*8)/(elapsed*1e6) if elapsed > 0 else 0
        if g_cpu_debug:
            pct = min(100, cur/byte_budget*100)
            bar = "#"*int(pct/5)+"-"*(20-int(pct/5))
            print(f"[NETWORK] UL {cur/MiB:7.1f}/{byte_budget/MiB:7.0f} MB  {mbps:7.1f} Mbps  [{bar}]  {elapsed:.0f}s")
        if elapsed >= PHASE_TIMEOUT:
            print(f"[NETWORK] Upload phase timeout ({PHASE_TIMEOUT}s)")
            done[0] = True

    for t in threads: t.join(timeout=3)
    elapsed = time.time() - t_start
    return min(total[0], byte_budget), elapsed


# ─── SpeedTest Result ─────────────────────────────────────────────────────────

class SpeedTestResult:
    def __init__(self):
        self.server_name = ""
        self.server_ip = ""
        self.latency_ms = -1.0
        self.download_mbps = -1.0
        self.download_bytes = 0
        self.download_seconds = 0.0
        self.upload_mbps = -1.0
        self.upload_bytes = 0
        self.upload_seconds = 0.0
        self.ok = False


# ─── Main SpeedTest Runner ───────────────────────────────────────────────────

def _ul_endpoint(ep: dict) -> dict:
    """
    Return the upload endpoint. For Apple, switch to Cloudflare for uploads
    (Apple's /gm/slurp is blocked from China). For Cloudflare, use itself.
    """
    if ep.get("host") == ENDPOINTS["apple"]["host"]:
        # Apple → use Cloudflare for upload
        cf = dict(ENDPOINTS["cloudflare"])
        # Resolve Cloudflare
        ips = _resolve_doh(cf["host"])
        if not ips:
            ip = _resolve_system(cf["host"])
            if ip: ips = [ip]
        if ips:
            cf["ip"] = ips[0]
            return cf
        # If CF also fails, fall back to Apple (will likely fail upload too)
    return ep


def run_speedtest(num_threads: int = 8, cn_mode: bool = False,
                  calibrate: bool = False,
                  limits: dict | None = None) -> SpeedTestResult:
    """
    Run a full NeverIdle network cycle.
    Download always prefers Apple; upload uses Cloudflare.
    cn_mode affects discovery/selection messaging and fallback preference.
    """
    result = SpeedTestResult()

    print(f"[NETWORK] Min speed: {MIN_SPEED_Mbps} Mbps (abandon if below for {MIN_SPEED_WINDOW}s)")
    print(f"[NETWORK] Phase timeout: {PHASE_TIMEOUT}s per phase")
    print(f"[NETWORK] Strategy: Apple for download, Cloudflare for upload")
    limits = limits or {}
    dl_limit_mbps = limits.get("download_mbps")
    ul_limit_mbps = limits.get("upload_mbps")
    if dl_limit_mbps:
        print(f"[NETWORK] Download limit: {dl_limit_mbps:.1f} Mbps")
    if ul_limit_mbps:
        print(f"[NETWORK] Upload limit: {ul_limit_mbps:.1f} Mbps")

    # Discovery with visible progress
    selected = discover_endpoints(cn_mode=cn_mode)
    if not selected:
        print("[NETWORK] Discovery failed: no reachable download endpoint")
        return result

    result.server_ip = selected["ip"]
    result.server_name = selected["name"]
    result.latency_ms = selected.get("latency_ms", -1.0)

    # Download endpoint = discovered preferred endpoint
    dl_ep = dict(selected)

    # Upload endpoint = Cloudflare (reliable /__up)
    print("[NETWORK] Resolving Cloudflare speedtest for upload...")
    cf = dict(ENDPOINTS["cloudflare"])
    cf_result, cf_ms = _probe_ep("cloudflare", cf)
    if not cf_result:
        print("[NETWORK] Cloudflare upload endpoint unavailable")
        return result
    ul_ep = dict(cf_result)

    if result.latency_ms > 0 or cf_ms > 0:
        print(f"[NETWORK] Selected download={dl_ep['name']} latency={result.latency_ms:.1f}ms; "
              f"upload={ul_ep['name']} latency={cf_ms:.1f}ms")

    def progress_cb(phase: str, cur: int, budget: int, mbps: float, elapsed: float):
        pct = min(100, cur/budget*100)
        bar = "#"*int(pct/5)+"-"*(20-int(pct/5))
        print(f"[NETWORK] {phase.capitalize():8s} {cur/MiB:7.1f}/{budget/MiB:7.0f} MB  "
              f"{mbps:7.1f} Mbps  [{bar}]  {elapsed:.0f}s")

    print(f"[NETWORK] Downloading ~{DL_BUDGET/MiB:.0f} MB via {dl_ep['name']} ({num_threads} threads)...")
    dl_bytes, dl_sec = _run_download(dl_ep, num_threads, DL_BUDGET, progress_cb, dl_limit_mbps)
    if dl_sec > 0:
        result.download_bytes = dl_bytes
        result.download_seconds = dl_sec
        result.download_mbps = (dl_bytes*8)/(dl_sec*1e6)
    dl_str = (f"{result.download_mbps:.2f} Mbps ({result.download_bytes/MiB:.1f} MB "
              f"in {result.download_seconds:.1f}s)") if result.download_bytes > 0 else "failed"
    print(f"[NETWORK] Download: {dl_str}")

    print(f"[NETWORK] Uploading ~{UL_BUDGET/MiB:.0f} MB via {ul_ep['name']} ({num_threads} threads)...")
    ul_bytes, ul_sec = _run_upload(ul_ep, num_threads, UL_BUDGET, progress_cb, ul_limit_mbps)
    if ul_sec > 0:
        result.upload_bytes = ul_bytes
        result.upload_seconds = ul_sec
        result.upload_mbps = (ul_bytes*8)/(ul_sec*1e6)
    ul_str = (f"{result.upload_mbps:.2f} Mbps ({result.upload_bytes/MiB:.1f} MB "
              f"in {result.upload_seconds:.1f}s)") if result.upload_bytes > 0 else "failed"
    print(f"[NETWORK] Upload: {ul_str}")

    result.ok = True
    return result


# ─── Network waste wrapper ───────────────────────────────────────────────────

def waste_network(interval_seconds: float, num_threads: int = DEFAULT_NET_THREADS, cn_mode: bool = False):
    print("====================")
    print(f"Starting network waste every {format_duration(interval_seconds)}")
    effective_threads = max(1, min(num_threads, MAX_NET_THREADS))
    if effective_threads != num_threads:
        print(f"[NETWORK] Requested threads={num_threads}, capped to {effective_threads}")
    print(f"[NETWORK] Mode: {'CN' if cn_mode else 'overseas'}, threads: {effective_threads}")
    learned_limits = None
    calibrated = False
    while True:
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"\n[NETWORK] === Speed test at {ts} ===")
        result = run_speedtest(num_threads=effective_threads, cn_mode=cn_mode, limits=learned_limits)
        print(f"[NETWORK] Summary: server={result.server_name}  "
              f"latency={result.latency_ms:.1f}ms  "
              f"dl={result.download_mbps:.2f}Mbps  ul={result.upload_mbps:.2f}Mbps")
        if result.ok and not calibrated and result.download_mbps > 0 and result.upload_mbps > 0:
            learned_limits = {
                "download_mbps": max(MIN_RATE_LIMIT_Mbps, min(MAX_RATE_LIMIT_Mbps, result.download_mbps * RATE_LIMIT_RATIO)),
                "upload_mbps": max(MIN_RATE_LIMIT_Mbps, min(MAX_RATE_LIMIT_Mbps, result.upload_mbps * RATE_LIMIT_RATIO)),
            }
            calibrated = True
            print(f"[NETWORK] Learned limits: dl={learned_limits['download_mbps']:.1f}Mbps  ul={learned_limits['upload_mbps']:.1f}Mbps")
        print("====================")
        time.sleep(interval_seconds)

# ─── Helpers ──────────────────────────────────────────────────────────────────

def format_duration(seconds: float) -> str:
    if seconds >= 3600:
        h, rem = divmod(int(seconds), 3600); m, s = divmod(rem, 60)
        return f"{h}h{m}m{s}s"
    elif seconds >= 60:
        m, s = divmod(int(seconds), 60)
        return f"{m}m{s}s"
    else:
        return f"{seconds:.0f}s" if seconds == int(seconds) else f"{seconds}s"

def print_version():
    print(f"NeverIdle {VERSION}")
    print(f"Version note: {VERSION_NOTE}")
    print(f"Platform: {sys.platform}, Python {sys.version.split()[0]}")
    print(f"Upstream: https://github.com/layou233/NeverIdle (AGPL-3.0)")
    print(f"License: GNU Affero General Public License v3.0 or later")
    print(f"DISCLAIMER: idle-reclaim evasion may violate cloud ToS; use at your own risk.")

def signal_handler(sig, frame):
    print("\n[NeverIdle] Shutting down...")
    global g_pid_running; g_pid_running = False
    sys.exit(0)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main():
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    parser = argparse.ArgumentParser(
        description="NeverIdle Python – prevent cloud VMs being marked idle",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"""Version: {VERSION}
Version note: {VERSION_NOTE}

Examples:
  python3 neveridle.py -cp 0.3 -n 2.5h
  python3 neveridle.py -n cn 2.5h    # prefer domestic Apple PoP for download
  python3 neveridle.py -n 2.5h       # overseas: probe Apple + Cloudflare, pick lower latency
  python3 neveridle.py -d -cp 0.2 -m 4 -n 1h -t 8 -p 10
        """,
        add_help=False,
    )
    parser.add_argument("-c", dest="cpu_interval", metavar="DURATION",
                        help="CPU waste interval (e.g. 1h, 30m, 2.5h)")
    parser.add_argument("-cp", dest="cpu_percent", type=float, metavar="PERCENT",
                        help="CPU percentage waste (0.0~1.0, e.g. 0.15 = 15%%)")
    parser.add_argument("-d", "--debug", dest="debug", action="store_true",
                        help="Enable debug output (CPU%% bar, network details)")
    parser.add_argument("-m", dest="memory_gib", type=int, metavar="GiB",
                        help="Memory to waste in GiB")
    parser.add_argument("-n", dest="network", nargs="+", metavar="[cn] DURATION",
                        help="Network speed test. 'cn' prefers domestic Apple PoP for download")
    parser.add_argument("-t", dest="connections", type=int, default=DEFAULT_NET_THREADS, metavar="N",
                        help="Concurrent connections (default: 2, capped for sustained transfers)")
    parser.add_argument("-p", dest="priority", type=int, metavar="NICE",
                        help="Process priority (-20~19; default: 19 = lowest)")
    parser.add_argument("--version", action="store_true", help="Show version and exit")
    parser.add_argument("-h", "--help", action="help", help="Show this help message")

    args = parser.parse_args()
    global g_cpu_debug; g_cpu_debug = args.debug

    if args.version:
        print_version(); return

    print_version()

    nothing = True
    monitor = CPUMonitor(); monitor.start()

    if args.priority is None:
        print("[PRIORITY] Worst priority by default (nice=19, ionice idle)")
        set_worst_priority_impl()
    else:
        print(f"[PRIORITY] Setting priority to {args.priority}")
        set_priority(args.priority)

    if args.memory_gib and args.memory_gib > 0:
        nothing = False
        threading.Thread(target=waste_memory, args=(args.memory_gib, monitor), daemon=True).start()

    if args.cpu_interval:
        nothing = False
        interval = parse_duration(args.cpu_interval)
        print(f"[CPU] Will waste CPU every {format_duration(interval)}")
        threading.Thread(target=waste_cpu, args=(interval, monitor), daemon=True).start()

    if args.cpu_percent:
        nothing = False
        threading.Thread(target=waste_cpu_percent, args=(args.cpu_percent, monitor), daemon=True).start()

    if args.network:
        nothing = False
        na = args.network
        cn_mode = len(na) == 2 and na[0].lower() == "cn"
        dur = na[-1]
        interval = parse_duration(dur)
        print(f"[NETWORK] Speed test every {format_duration(interval)}, "
              f"mode={'CN (prefer domestic Apple PoP, Cloudflare upload)' if cn_mode else 'overseas (Apple+Cloudflare probe, Cloudflare upload)'}")
        threading.Thread(target=waste_network,
                         args=(interval, args.connections, cn_mode),
                         daemon=True).start()

    if nothing:
        parser.print_help()
    else:
        print(f"\n[NeverIdle] All workers started. Press Ctrl+C to stop.")
        try:
            while True: time.sleep(86400)
        except KeyboardInterrupt:
            pass
        finally:
            monitor.stop()

if __name__ == "__main__":
    main()
