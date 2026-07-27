# studies

Written-up findings: things that were tried in
[`../experiments/`](../experiments/README.md), worked (or failed
instructively), and are worth recording properly — with the reasoning,
not just the result.

A study earns its place here once it changed a decision in the main
project. See the main [README](../README.md) for the project itself.

| File | Finding |
|---|---|
| `distro-config-packages.md` | An Arch derivative ships packages whose payload is system CONFIG, not software — sysctls, systemd drop-ins, udev, zram. They silently supply defaults a module appears to inherit for free. Worked example: CachyOS's `cachyos-settings`, 46 files, two real incidents. |
