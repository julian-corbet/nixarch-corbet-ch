# modules/cachyos-tools.nix — CachyOS's own operator tooling: the update notifier, the welcome
# app, the kernel GUI and the package-installer GUI. Four packages, four independent `enable`
# options, all of them off by default.
#
# WHY THESE ARE NIXARCH'S OWN PACKAGES, NOT A DOMAIN REPO'S. The same argument modules/shelly.nix
# and modules/base-packages.nix already make: every other name that reaches
# `nixarch.packages.pacman`/`.aur` arrives from OUTSIDE this repo, a domain module publishing into
# the sink from its own tree. None of these four belongs to a domain. Their entire subject is the
# Arch/CachyOS platform — updating it, installing into it, choosing its kernel, introducing it —
# which is nixarch's own subject matter, so they are declared here and published into the sink from
# the inside.
#
# WHY GATED, UNLIKE modules/base-packages.nix. base-packages carries no `enable` because nothing in
# it is a choice: a nixarch host cannot meaningfully decline a keyring or a mirrorlist. Every
# package here IS a choice — an operator can run a CachyOS box for years and never open any of
# them. That is exactly the line modules/shelly.nix already draws for a GUI package manager, and
# these four sit on the same side of it, so they get the same shape: a small module living here,
# gated by its own `enable`, adding a name to the sink and nothing else.
#
# FOUR OPTIONS, ONE FILE, AND WHY THAT IS NOT A LUMPED TOGGLE. Each package is independently
# switchable — no option here implies another, and a host wanting only the update notifier gets
# only the update notifier. What they share is one hazard, stated once below rather than three more
# times: every one of these names exists ONLY in CachyOS's own repositories. Four separate files
# would either repeat that paragraph four times or, more likely, carry it in three of them.
#
# THE HAZARD, VERIFIED. Checked 2026-08-08, the three-source method modules/base-packages.nix's own
# header documents: `pacman -Si` on a live CachyOS box reports `Repository : cachyos` for all four —
# CachyOS's own repository, not one of its `*-v3` rebuilds of an Arch one; archlinux.org's package
# search returns ZERO results for each; the AUR RPC returns zero for each. So unlike an AUR-only
# package, which a plain Arch host can still reach through a helper, these have no upstream
# existence at all and no channel to fall back to. `pacman -S` aborts the ENTIRE transaction on one
# unknown target (modules/packages.nix's header on why that is the fatal direction), so a
# plain-Arch host enabling one of these would fail every OTHER declared package in the same
# reconcile. Hence every definition below is gated on `nixarch.packages.distro == "cachyos"` as
# well as its own `enable`, and an enabled-but-wrong-distro host gets an assertion rather than a
# silent no-op: silence there would read as "the option did nothing" when the truth is "this
# package cannot exist on this distro".
#
# CAUTION — TWO OF THESE ARE A SECOND PATH TO PACMAN, DELIBERATELY. `nixarch.packages` reconciles
# the installed set from Nix; `cachy-update` and `cachyos-packageinstaller` both drive
# `pacman -S`/`-Syu` imperatively from a GUI on the same box. modules/shelly.nix's own CAUTION
# paragraph covers the shape of that tension in full and it applies here unchanged: anything
# installed through them is invisible to the declaration and reads as undeclared drift the moment
# `pruneUndeclared`/`pruneOrphans` is ever turned on. Accepted, not missed.
{ lib, config, ... }:
let
  cfg = config.nixarch.cachyosTools;
  onCachyos = config.nixarch.packages.distro == "cachyos";

  # One assertion shape for all four, so the message names the option the reader actually set.
  distroAssertion = optionName: enabled: {
    assertion = !enabled || onCachyos;
    message = ''
      nixarch.cachyosTools.${optionName}.enable is true but nixarch.packages.distro is
      "${config.nixarch.packages.distro}". This package exists only in CachyOS's own repositories
      (not in upstream Arch, not in the AUR), so the name would abort the whole `pacman -S`
      reconcile transaction on a non-CachyOS host and take every other declared package with it.
      Either set nixarch.packages.distro = "cachyos" if this box really is CachyOS, or leave this
      option off.
    '';
  };
in
{
  options.nixarch.cachyosTools = {
    # ── cachy-update ──────────────────────────────────────────────────────────────────────────
    cachyUpdate.enable = lib.mkEnableOption ''
      `cachy-update`, CachyOS's interactive update notifier and applier.

      Ships two commands — `/usr/bin/cachy-update` and `/usr/bin/arch-update` — plus a tray applet
      autostarted for every graphical session through `/etc/xdg/autostart/arch-update-tray.desktop`,
      plus a systemd USER service and timer pair, `arch-update.service` and `arch-update.timer`.

      THE TIMER IS ENABLED WHERE THIS IS INSTALLED, and that is recorded rather than changed: on
      the host this option was written for, `systemctl --user list-unit-files 'arch-update*'`
      reports `arch-update.timer` as `enabled` (vendor preset `enabled` too). This module neither
      enables nor disables it — it declares the package and nothing more.

      WORTH SEEING PLAINLY: this is an INTERACTIVE updater living alongside a declaratively managed
      package set. `nixarch.packages` reconciles toward a list written in Nix; this notifies a
      human that upgrades are pending and applies them when clicked. Both are legitimate, they are
      simply not the same mechanism, and a package upgraded through the tray is not thereby
      declared anywhere. Requires `nixarch.packages.enable` for the package itself to be installed.
    '';

    # ── cachyos-hello ─────────────────────────────────────────────────────────────────────────
    cachyosHello.enable = lib.mkEnableOption ''
      `cachyos-hello`, the CachyOS welcome/onboarding application (`/usr/bin/cachyos-hello`).

      AUTOSTARTS PER USER, FROM A COPY, WHICH IS WHY IT KEEPS APPEARING. The package installs
      `/etc/skel/.config/autostart/cachyos-hello.desktop`, and `/etc/skel` is copied into a home
      directory ONCE, at account creation. So the autostart entry that actually runs lives at
      `~/.config/autostart/cachyos-hello.desktop` and belongs to the account, not to the package:
      removing the package does not remove it, and reinstalling does not restore it for an account
      that already exists. Deleting that per-user file is the way to stop it launching, and it is
      outside anything this module or `nixarch.packages` can reconcile.

      Requires `nixarch.packages.enable` for the package itself to be installed.
    '';

    # ── cachyos-kernel-manager ────────────────────────────────────────────────────────────────
    cachyosKernelManager.enable = lib.mkEnableOption ''
      `cachyos-kernel-manager`, a GUI for browsing, installing and switching CachyOS kernels
      (`/usr/bin/cachyos-kernel-manager`).

      THE INTERACTION TO KNOW ABOUT, stated as a fact rather than a warning: on a host whose
      kernels are DECLARED — nixboot pinning specific kernel packages and their headers, for
      instance — this GUI writes to exactly the thing that declaration owns. Installing or
      switching a kernel here does not update the declaration, and the next declarative activation
      does not know a human changed the kernel set. Two writers, one subject; they can disagree
      silently. Nothing in this module tries to arbitrate that, and no assertion is raised for it:
      keeping the GUI available is a deliberate choice where this option is enabled.

      Requires `nixarch.packages.enable` for the package itself to be installed.
    '';

    # ── cachyos-packageinstaller ──────────────────────────────────────────────────────────────
    cachyosPackageinstaller.enable = lib.mkEnableOption ''
      `cachyos-packageinstaller`, CachyOS's curated graphical package installer — the binary is
      `/usr/bin/cachyos-pi`, not the package name.

      WHY IT IS KEPT NEXT TO A DECLARATIVE PACKAGE SET, because a reader will otherwise assume it
      is drift: it is deliberately a SCRATCHPAD. The workflow it supports is trying a package out,
      removing it again if it disappoints, and writing a declaration only for what survives that.
      The GUI is for evaluation; the declaration is the commitment. That division is the reason a
      graphical installer is a reasonable thing to have on a box whose package set is otherwise
      reconciled from Nix — and it only works while the second half actually happens.

      See this module's own CAUTION header: anything installed through it is invisible to
      `nixarch.packages` until someone declares it, which is the whole point, and also exactly what
      `pruneUndeclared`/`pruneOrphans` would remove. Requires `nixarch.packages.enable` for the
      package itself to be installed.
    '';
  };

  config = {
    assertions = [
      (distroAssertion "cachyUpdate" cfg.cachyUpdate.enable)
      (distroAssertion "cachyosHello" cfg.cachyosHello.enable)
      (distroAssertion "cachyosKernelManager" cfg.cachyosKernelManager.enable)
      (distroAssertion "cachyosPackageinstaller" cfg.cachyosPackageinstaller.enable)
    ];

    # Plain listOf definitions at the default priority, same as modules/shelly.nix and
    # modules/desktop-backend.nix — these concatenate with whatever else a consumer's evaluation
    # contributes to `nixarch.packages.pacman` rather than fighting it.
    nixarch.packages.pacman =
      lib.optional (cfg.cachyUpdate.enable && onCachyos) "cachy-update"
      ++ lib.optional (cfg.cachyosHello.enable && onCachyos) "cachyos-hello"
      ++ lib.optional (cfg.cachyosKernelManager.enable && onCachyos) "cachyos-kernel-manager"
      ++ lib.optional (cfg.cachyosPackageinstaller.enable && onCachyos) "cachyos-packageinstaller";
  };
}
