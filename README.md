# Hertz

**A native macOS menu-bar system monitor.** CPU, memory, disk, network,
battery, and a live process tree — read straight from the kernel, in one tidy
dropdown.

Tiny, fast, no Electron. ~Few MB of RAM. Built in Swift.

![License](https://img.shields.io/github/license/pranshugupta54/hertz)
![Release](https://img.shields.io/github/v/release/pranshugupta54/hertz?sort=semver)
![Platform](https://img.shields.io/badge/macOS-14%2B-black)

## Install

### Homebrew

```sh
brew install --cask pranshugupta54/tap/hertz
```

or, for the short name afterwards:

```sh
brew tap pranshugupta54/tap
brew install --cask hertz
```

### One-line script

```sh
curl -fsSL https://raw.githubusercontent.com/pranshugupta54/hertz/main/install.sh | bash
```

Either way: the prebuilt app lands in `~/Applications`, launches into your
menu bar, and needs no Xcode and no admin password.

> Hertz is ad-hoc signed (not Apple-notarized). Both installers clear the
> download quarantine for you, so it opens with no Gatekeeper prompt.

## Auto-update

Once installed, Hertz **keeps itself current** — it checks GitHub Releases on
launch and every 24 hours and silently installs new versions. There's also a
manual check in the footer. Nothing to do.

## What it shows

- **CPU** — overall %, a live sparkline, per-core bars, load average, temperature,
  and thermal pressure when macOS reports throttling risk
- **Memory** — pressure, used / free / swap, with a trend graph
- **Disk** — usage donut, free space, live read/write throughput, filesystem
- **Network** — up / down throughput with a trend graph, local IP, Wi-Fi SSID, VPN state
- **Battery** — charge, live power rate, health, cycle count, temperature, adapter wattage,
  plus connected accessories (mouse, keyboard, trackpad)
- **Processes** — a tree grouped by app, with subtree CPU/memory totals,
  sortable by CPU or memory
- **Health score** — a composite 0–100 at a glance
- **Hardware header** — chip, cores, RAM, macOS version, uptime

## How it works

Everything is read directly from the OS — no shelling out, no polling `top`:

| Metric | Source |
| --- | --- |
| CPU / memory | Mach — `host_processor_info`, `host_statistics64` |
| Thermal pressure | Darwin notify — `com.apple.system.thermalpressurelevel` with `ProcessInfo` fallback |
| Processes | `libproc` — `proc_listallpids`, `proc_pidinfo`, `proc_pid_rusage` |
| Disk | `statfs` + IOKit `IOBlockStorageDriver` |
| Battery | IOKit power sources + the `AppleSmartBattery` registry |
| Temperature / fans | the `AppleSMC` user client |
| Network | `getifaddrs` + CoreWLAN |

Per-process CPU and memory match Activity Monitor — CPU-time deltas converted
from Mach absolute-time units, memory reported as physical footprint (not RSS).

## Requirements

macOS 14 (Sonoma) or later, Apple silicon. Intel Macs can build from source.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/pranshugupta54/hertz.git
cd hertz
swift run Hertz          # run it directly
./scripts/bundle.sh      # or build Hertz.app
```

## Uninstall

```sh
brew uninstall --cask pranshugupta54/tap/hertz
```

or, if you used the script installer:

```sh
curl -fsSL https://raw.githubusercontent.com/pranshugupta54/hertz/main/uninstall.sh | bash
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Cutting a release: [RELEASING.md](RELEASING.md).

## License

MIT — see [LICENSE](LICENSE).
