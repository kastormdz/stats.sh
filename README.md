# stats.sh

A lightweight system information script, similar to `fastfetch` or `neofetch`, designed for quick server diagnostics, no externals commands.

## Features
- **Visual Dashboard:** Clean, boxed layout with color-coded progress bars for CPU and RAM.
- **Service Monitoring:** Lists unique listening services (TCP/UDP) with their ports, automatically grouped and filtered (excluding loopback/multicast).
- **Robust OS Detection:** Accurately identifies installation date across multiple platforms:
  - **Cloud:** OpenStack, AWS, Azure, Google Cloud (via `cloud-init`).
  - **Virtualization:** oVirt, KVM, QEMU nodes.
  - **Linux Distros:** Arch, RHEL/CentOS, Debian/Ubuntu, CachyOS, and more.
- **Resource Alerts:** Real-time warnings (outside the box) for high load, disk space usage, or excess processes.
- **Legacy Compatibility:** Works on both modern systems and older versions (RedHat 5/6, etc.).

## Usage
Simply run the script:
```bash
./stats.sh
```

For Ansible/automation output (clean text):
```bash
./stats.sh 1
```

## Authors
- **Cristian Gimenez** (cgimenez@gmail.com)
