# Distro packages that configure rather than install

An Arch derivative ships some packages whose payload is not software but **system configuration** —
sysctls, systemd drop-ins, udev rules, modprobe options. They are invisible to a package list and
they silently supply defaults that a declarative module will otherwise appear to "inherit for free".

Worked example: CachyOS's `cachyos-settings`, measured on a live install 2026-07-27.

## What it actually contains

46 files. Grouped by what they touch:

| Area | Files |
|---|---|
| Kernel sysctls | `/usr/lib/sysctl.d/70-cachyos-settings.conf` |
| Memory / swap | `zram-generator.conf`, `udev/rules.d/30-zram.rules`, `tmpfiles.d/thp.conf`, `tmpfiles.d/thp-shrinker.conf` |
| systemd defaults | `system.conf.d/00-timeout.conf`, `system.conf.d/10-limits.conf`, `user.conf.d/00-timeout.conf`, `user.conf.d/10-limits.conf`, `user@.service.d/delegate.conf` |
| Journal / coredumps | `journald.conf.d/00-journal-size.conf`, `tmpfiles.d/coredump.conf` |
| Storage | `udev/rules.d/{50-sata,60-ioschedulers,69-hdparm}.rules` |
| Latency | `udev/rules.d/{99-cpu-dma-latency,40-hpet-permissions}.rules`, `pci-latency.service` |
| Audio | `security/limits.d/20-audio.conf`, `udev/rules.d/20-audio-pm.rules`, `rtkit-daemon.service.d/override.conf` |
| Graphics | `modprobe.d/{amdgpu,nvidia}.conf`, `udev/rules.d/71-nvidia.rules` |
| Wireless regulatory | `iw-set-regdomain`, `cachyos-iw-set-regdomain.{path,service}`, `udev/rules.d/85-iw-regulatory.rules` |
| Misc | NetworkManager DNS conf, `modules-load.d/ntsync.conf`, `blacklist.conf`, touchpad xorg conf, a GNOME gschema override, tools (`game-performance`, `topmem`, `pci-latency`, `sbctl-batch-sign`, …) |

## Why this matters: it overlaps declarative modules

Four of those files land squarely on ground a `nix*` module claims:

| Distro file | Module that also claims it |
|---|---|
| `zram-generator.conf`, `30-zram.rules` | nixram (zram is its subsystem outright) |
| `70-cachyos-settings.conf` | nixram (vm.* sysctls) |
| `system.conf.d/00-timeout.conf` | anything relying on `DefaultTimeoutStartSec` — mount units especially |
| `tmpfiles.d/coredump.conf` | nixpower (`deviceCoredumps`) |

## Who wins, verified

`/etc/` beats `/usr/lib/` in every one of these hierarchies, so an explicit declaration wins. Checked
live for the zram pair — both `zram-generator.conf` and `30-zram.rules` exist in **both** locations,
the `/usr/lib` copy owned by `cachyos-settings`, the `/etc` copy unowned by pacman, and the `/etc`
one is authoritative.

**So the risk is not being overridden. The risk is not knowing you were relying on the distro.**
Two real incidents on one host, both from this single package:

1. **`vm.page-cluster`** read as `0` and nothing in the fleet had set it — it came from
   `70-cachyos-settings.conf`. Declaring it `2` was then recorded as a deliberate behavioural
   change rather than a mystery.
2. **NFS mount `TimeoutSec=15s`** was believed to come from the mount options. It did not — it came
   from this package's `DefaultTimeoutStartSec`. The unit's own option was inert. A distro bump, or
   a move to NixOS (upstream default 90s), would have silently tripled it and deleted an
   offline fail-fast property with no change to any file in the repo.

The second is the general shape: **a default you never declared is a default you cannot notice
changing.**

## What to do about it

Not "declare the package". It is already installed, and listing it changes nothing.

1. **Audit before declaring a subsystem.** Before a module claims sysctls, systemd defaults, udev
   or zram on a derivative distro, list what the distro already sets there:
   `pacman -Ql <distro>-settings | grep -E 'sysctl|systemd|udev|modprobe|tmpfiles'`.
2. **Declare explicitly even when the inherited value is right.** Pinning a value you agree with
   costs one line and converts an invisible dependency into a visible one.
3. **Harvest deliberately.** These defaults are generally well-chosen — I/O schedulers per device
   class, CPU DMA latency, audio rtkit limits, THP shrinker. Adopting one is legitimate; adopting
   it *by accident* is what this study exists to prevent.
4. **Keep the distro's own trust packages out of prune's way** — see `keep` in
   `modules/packages.nix`.

## Open question

Whether a module should ASSERT on a conflicting `/usr/lib` file rather than silently winning.
Arguments both ways: an assertion catches the surprise early, but it fires on every derivative that
ships a sane default the module happens to agree with, which trains people to ignore it. Not
resolved; recorded so the next person does not have to rediscover the trade-off.
