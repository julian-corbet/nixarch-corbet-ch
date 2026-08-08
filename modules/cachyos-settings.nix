# modules/cachyos-settings.nix — CachyOS's whole-system tuning profile, declared as a deliberate
# BASE LAYER rather than as distro identity.
#
# READ THIS FIRST IF THE PACKAGE NAME MADE YOU ASSUME BRANDING. It is not branding. `cachyos-hooks`
# is the package that rewrites `/etc/os-release`; this one ships 46 files (measured, not
# estimated), and every one of them is a tuning or policy decision about the running system:
#
#   - `/usr/lib/sysctl.d/70-cachyos-settings.conf` — 12 kernel/vm/net keys, enumerated below
#   - `/usr/lib/systemd/zram-generator.conf` + `udev/rules.d/30-zram.rules` — the swap device
#   - `tmpfiles.d/thp.conf` + `thp-shrinker.conf` — transparent hugepages, `coredump.conf`
#   - `systemd/journald.conf.d/00-journal-size.conf` — journal size caps
#   - `systemd/{system,user}.conf.d/00-timeout.conf` and `10-limits.conf` — unit timeouts + rlimits
#   - `systemd/timesyncd.conf.d/10-timesyncd.conf` — NTP sources
#   - `udev/rules.d/60-ioschedulers.rules` — per-device-class I/O scheduler
#   - `udev/rules.d/50-sata.rules`, `69-hdparm.rules`, `99-cpu-dma-latency.rules` — device power
#   - `udev/rules.d/20-audio-pm.rules`, `rtkit-daemon.service.d/override.conf`,
#     `/etc/security/limits.d/20-audio.conf` — audio latency and scheduling
#   - `modprobe.d/{amdgpu,nvidia,blacklist}.conf` — driver parameters
#   - `systemd/system/user@.service.d/delegate.conf` — cgroup delegation to the user manager
#   - a dozen binaries: `game-performance`, `dlss-swapper`, `zink-run`, `topmem`, `pci-latency`,
#     `kerver`, `sbctl-batch-sign`, `cachyos-bugreport.sh`, `paste-cachyos`
#
# WHY KEEPING IT IS COHERENT WITH A DECLARATIVE SYSTEM, which is the part that is not obvious.
# Every directory above is a TWO-LAYER system by design: `/usr/lib/...` is the vendor layer,
# `/etc/...` is the local layer, and the local layer wins — for sysctl by numeric filename order,
# for udev/modprobe/tmpfiles/systemd drop-ins by same-name shadowing. So this package is not a
# competing writer at all; it is the floor that a host's own declarations sit ON TOP OF. Keeping it
# means inheriting a tuned baseline for everything nobody has formed an opinion about yet, while
# every opinion that HAS been formed still wins. That is the trade this option exists to take
# deliberately rather than by accident.
#
# THE MEASURED STATE, AS NUMBERS RATHER THAN ADJECTIVES (verified live 2026-08-08 on a host with
# this package installed, reading the vendor file, the local file and the running kernel):
#
#   CachyOS sets 12 sysctl keys. Three of them are overridden by a local `/etc/sysctl.d/*` file,
#   and the local value is what the running kernel actually reports — the two-layer story above,
#   confirmed rather than assumed:
#
#     vm.page-cluster         vendor 0    -> local 2    (live: 2)
#     vm.swappiness           vendor 100  -> local 25   (live: 25)
#     vm.vfs_cache_pressure   vendor 50   -> local 80   (live: 80)
#
#   The other NINE are inherited, and inherited is not the same as chosen. Nobody has looked at
#   them; they are in force because this package is installed:
#
#     fs.file-max · kernel.kptr_restrict · kernel.nmi_watchdog · kernel.printk ·
#     kernel.unprivileged_userns_clone · net.core.netdev_max_backlog ·
#     vm.dirty_background_bytes · vm.dirty_bytes · vm.dirty_writeback_centisecs
#
# ONE OF THOSE NINE IS SECURITY-RELEVANT AND IS NAMED HERE ON PURPOSE.
# `kernel.unprivileged_userns_clone = 1` enables unprivileged user namespaces. Flatpak, rootless
# containers and most sandboxing need it; it is also a long-standing kernel attack surface and a
# recurring source of local privilege-escalation CVEs. On a host that declares this package, that
# value is INHERITED, not chosen. A host that wants the other answer writes its own
# `/etc/sysctl.d/` entry with a higher-sorting name and gets it, exactly like the three above.
#
# WHAT THIS COSTS IN DOMAIN OWNERSHIP, recorded so a reader can see it rather than rediscover it.
# Several of the files above land squarely inside subjects that sibling repos in this family own:
#
#   - zram and transparent hugepages -> the memory-subsystem repo's domain (nixram)
#   - SATA/hdparm/CPU-DMA-latency rules -> the power repo's domain (nixpower)
#   - `modprobe.d/amdgpu.conf` -> the GPU repo's domain (nixgpu)
#   - the rtkit override and `limits.d/20-audio.conf` -> the audio repo's domain (nixaudio)
#
# Keeping this package means those four repos do not FULLY own their domains on such a host: they
# own the top layer, and this package owns the floor beneath it. That is the accepted trade for the
# base layer, stated plainly. Nothing here tries to arbitrate it, and no assertion is raised for it.
#
# THE DISTRO GATE. Same hazard, same verification, same mechanism as modules/cachyos-tools.nix —
# `pacman -Si` resolves this in CachyOS's own repository, archlinux.org returns zero results and
# the AUR RPC returns zero, so on a plain Arch host the name is an unknown target and `pacman -S`
# aborts the WHOLE transaction on one of those. Gated on `nixarch.packages.distro == "cachyos"`,
# with an assertion rather than a silent no-op for the enabled-but-wrong-distro case.
{ lib, config, ... }:
let
  cfg = config.nixarch.cachyosSettings;
  onCachyos = config.nixarch.packages.distro == "cachyos";
in
{
  options.nixarch.cachyosSettings.enable = lib.mkEnableOption ''
    `cachyos-settings`, CachyOS's whole-system tuning profile, as a deliberate BASE LAYER.

    Not distro identity and not branding: 46 files of sysctl, zram, transparent-hugepage,
    journald, systemd timeout/rlimit, timesyncd, I/O-scheduler, device-power, audio-latency,
    modprobe and cgroup-delegation policy, plus a handful of helper binaries. See this module's
    own header for the full inventory, the measured sysctl state, and the domain overlaps
    keeping it implies.

    THE REASON THIS IS COHERENT rather than drift: every directory involved is a two-layer
    system, `/usr/lib` for the vendor and `/etc` for the local, and the local layer wins. So this
    package is the floor your own declarations sit on top of — you inherit a tuned baseline for
    everything you have not formed an opinion about, and every opinion you HAVE formed still
    takes precedence. Inheriting is not the same as choosing, though, which is why the header
    enumerates exactly which values are inherited unexamined — including
    `kernel.unprivileged_userns_clone = 1`, which is security-relevant.

    Requires `nixarch.packages.enable` for the package itself to be installed, and
    `nixarch.packages.distro = "cachyos"` (asserted).
  '';

  config = {
    assertions = [{
      assertion = !cfg.enable || onCachyos;
      message = ''
        nixarch.cachyosSettings.enable is true but nixarch.packages.distro is
        "${config.nixarch.packages.distro}". This package exists only in CachyOS's own
        repositories (not in upstream Arch, not in the AUR), so the name would abort the whole
        `pacman -S` reconcile transaction on a non-CachyOS host and take every other declared
        package with it. Either set nixarch.packages.distro = "cachyos" if this box really is
        CachyOS, or leave this option off.
      '';
    }];

    # Plain listOf at the default priority, same as modules/shelly.nix and
    # modules/cachyos-tools.nix — concatenates with whatever else a consumer's evaluation
    # contributes to `nixarch.packages.pacman` rather than fighting it.
    nixarch.packages.pacman = lib.optional (cfg.enable && onCachyos) "cachyos-settings";
  };
}
