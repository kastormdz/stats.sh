# stats.sh

A lightweight system information script, similar to `fastfetch` or `neofetch`, designed for quick server diagnostics, no externals commands.

<p align="center">
  <img src="stats.png" alt="stats.sh dashboard screenshot" />
</p>

## Features
- **Visual Dashboard:** Clean, boxed layout with color-coded progress bars for CPU and RAM.
- **Service Monitoring:** Lists unique listening services (TCP/UDP) with their ports, automatically grouped and filtered (excluding loopback/multicast).
- **Robust OS Detection:** Accurately identifies installation date across multiple platforms:
  - **Cloud:** OpenStack, AWS, Azure, Google Cloud (via `cloud-init`).
  - **Virtualization:** oVirt, KVM, QEMU nodes.
  - **Linux Distros:** Arch, RHEL/CentOS, Debian/Ubuntu, CachyOS, and more.
- **Resource Alerts:** Real-time warnings (outside the box) for high load, disk space usage, or excess processes.
- **Legacy Compatibility:** Works on both modern systems and older versions (RedHat 5/6, etc.).

## Requirements

- `bash >= 3.2` and `awk` (any: gawk, mawk, busybox). Pure-POSIX awk, no extensions.
- Everything else degrades gracefully if missing:
  - listeners via `ss`, fallback to `netstat`;
  - primary interface via `ip`, fallback to `ifconfig`;
  - memory via `free`, fallback to `/proc/meminfo`.

## Quick run (no install)
```bash
curl -sSL https://raw.githubusercontent.com/kastormdz/stats.sh/master/stats.sh | bash
```

## Install
```bash
curl -sSL https://raw.githubusercontent.com/kastormdz/stats.sh/master/stats.sh -o /usr/local/bin/stats.sh
chmod +x /usr/local/bin/stats.sh
```

## Usage
Simply run the script:
```bash
./stats.sh
```

For Ansible/automation output (clean text):
```bash
./stats.sh -a
```

Machine-readable JSON (includes disks, services and versions):
```bash
./stats.sh -j
```

Fast mode (skips per-service versions and failed-services check):
```bash
./stats.sh --fast
```

All options: `-a/--ansible`, `-j/--json`, `-n/--no-color`,
`-w/--width N` (40-200), `-v/--verbose`, `-f/--fast`, `-h/--help`.
Legacy `./stats.sh 1` / `ansible` still works as `--ansible`.

Unknown options exit with status `1`, so a typo never looks like success in Ansible/cron.

## Language
Output is English unless `LANG` starts with `es`:

```bash
LANG=es_AR.UTF-8 ./stats.sh
```

## Tuning (environment variables)
| Variable | Default | Effect |
|---|---|---|
| `STATS_MAX_PROC` | 300 | Warn when the process count exceeds it |
| `STATS_MAX_CONN` | 200 | Warn when the connection count exceeds it |
| `STATS_MAX_SVC_PORTS` | 12 | Max ports listed per service; the rest collapse into `+N more` |

## Notes
- **Root vs user:** as a plain user, `ss`/`netstat` only resolve processes you own; the remaining
  ports fall back to `/etc/services` (generic names such as `http`, `domain`, `couchdb`). As root
  you get true process attribution (`smbd-scavenger` instead of `netbios-ssn`), but on a
  container host the only host-side process is usually `docker-proxy`, so dozens of container
  ports collapse into a single line. Running as a user is often the *more* readable overview;
  running as root is the accurate one.
- **Memory:** `available_mb` / `MEM_AVAILABLE_MB` is `MemAvailable` (usable RAM, page cache
  included, read from `/proc/meminfo`). `free_mb` / `MEM_FREE_MB` is the raw `MemFree`. The
  dashboard shows the available figure: on a host with a large page cache the raw free number
  looks alarming while available is what actually matters.
- **Network counters** use binary units (`GiB`, `MiB`), matching how they are computed.

## Compatibility
Verified running clean (all output modes, ES and EN, widths 40-200) on:

| Environment | bash | awk | Notes |
|---|---|---|---|
| Arch / CachyOS | 5.2 | gawk 5.4 | `ss`, `ip` |
| CentOS 6.10 | 4.1.2 | gawk 3.1.7 | no `ss` -> `netstat`; no `systemctl` |
| CentOS 5.11 | 3.2.25 | gawk 3.1.5 | no `nproc`, no `systemctl`, no `uptime -s` |
| Debian 11 slim | 5.1.4 | mawk | no `free`, no `ps`, no `ip`, no `ifconfig` -> pure `/proc` |
| CentOS 5.11 (no `ip`) | 3.2.25 | gawk 3.1.5 | `/proc/net/route` + `fib_trie` fallback |
| busybox (no bash) | - | busybox | re-execs bash, otherwise exits `1` with a clear message |

Older kernels without `MemAvailable` (< 3.14) fall back to `free + buffers + cached`.

## Authors
- **Cristian Gimenez** (cgimenez@gmail.com)
