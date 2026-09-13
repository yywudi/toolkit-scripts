# port-shaper

`port-shaper.sh` uses Linux `tc` HTB and flower to limit each selected TCP port independently.

## Defaults

```text
direction: egress
port role: source and destination port (separate class and rate per direction)
protocol: TCP
device: route-selected interface (default route, or route to --peer)
peer: all IPv4 destinations unless --peer is supplied
rate: an unqualified number means Mbps
```

Examples:

```bash
chmod +x port-shaper.sh
sudo ./port-shaper.sh add 30001 80 --dst-port --peer ixjp --takeover
sudo ./port-shaper.sh add 30002 80mbit --peer 192.0.2.10
sudo ./port-shaper.sh list
sudo ./port-shaper.sh status
sudo ./port-shaper.sh delete 30001 --peer ixjp
```

Use `rules` to view the saved configuration. By default, one port command creates two independent aggregate classes: one source-port class and one destination-port class, each at the requested rate. Thus `80` allows up to 80 Mbps in each direction, not a combined 80 Mbps. All connections using the same port and direction share that direction's class. Use `--src-port` or `--dst-port` to select only one direction. Use `status` to see whether that configuration is active in the kernel, its current class counters, and the current root qdisc. Counters are shown in human-readable units (bytes as B/KB/MB/GB/TB, packets as K/M/G); use `--raw` for exact values. Add `--raw` to `status` for unprocessed `tc` diagnostic output. `list` remains an alias for `rules`.

`--peer` is supported with `--dst-port`. A proxied response leaves the host toward the client, so an egress source-port filter cannot identify its upstream peer using only packet headers.

The first takeover is interactive: when the interface has another root qdisc, the script asks `Replace it ...? [Y/n]`; empty input means yes and `n` cancels. Use `--takeover` to skip this prompt in automation. It replaces that interface's root qdisc, so inspect existing `tc qdisc show` output first. The script only manages its own HTB qdisc after takeover.

## Requirements

Run as root. The script checks required commands and automatically installs missing packages using the host's package manager. Existing dependencies are not reinstalled. Package installation requires network access and a configured package repository.

Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y iproute2 util-linux gawk libc-bin coreutils grep
```

RHEL/CentOS/Fedora:

```bash
sudo dnf install -y iproute util-linux gawk glibc-common coreutils grep
```

## Persistence and recovery

Rules are stored in `/etc/port-shaper/rules`. Each `add` or `delete` updates this file before applying the kernel qdisc; each line records the class id, port, rate in bit/s, optional peer IPv4, source/destination role, and device. If applying the qdisc fails, the saved state remains available for a later retry.

The kernel qdisc is runtime state and is not automatically restored by this script. After reboot, `restore` reads the saved rules file and rebuilds the HTB/classes/flower filters:

```bash
sudo ./port-shaper.sh restore
```

The script automatically selects the default-route device, or the route to `--peer`. Use `--dev` only when a host has multiple interfaces, policy routing, or when you intentionally want to manage a specific device.

To automate recovery, call that command from a separately managed systemd oneshot service. This script does not install or enable a service automatically.

Before takeover, record the existing qdisc for manual recovery:

```bash
tc qdisc show dev ens5
```

To remove the managed root qdisc and return to the device default:

```bash
sudo tc qdisc del dev ens5 root
```

The child queue is selected automatically: `fq`, then `fq_codel`, then `pfifo_fast`. BBR is optional; if `sch_fq` is unavailable, shaping still works but BBR pacing optimization cannot be preserved. This script currently supports IPv4 flower matches and egress shaping. Ingress shaping and automatic systemd installation are intentionally outside its scope.
