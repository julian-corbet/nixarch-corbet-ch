# modules/base-packages.nix — the pacman packages every nixarch host wants, unconditionally.
#
# WHY THIS IS NIXARCH'S OWN PACKAGE SET, NOT A DOMAIN REPO'S. Same reasoning as
# modules/shelly.nix: everything else that ends up in `nixarch.packages.pacman`/`.aur` arrives
# from OUTSIDE this repo, a domain module (nixgpu, nixdev, this project's own desktop-backend.nix)
# publishing into that sink from its own tree. Every name below manages the Arch host itself
# (mirrors, rebuild detection, chroot/provisioning, the base install, the AUR helper this very
# repo's own reconciler shells out to) — nixarch's own subject matter, not any domain's — so, like
# Shelly, they are declared HERE and published into the sink from the inside.
#
# WHY UNCONDITIONAL, UNLIKE SHELLY. Shelly is a taste choice — a GUI package manager some hosts
# want and others don't — so it gets its own `nixarch.shelly.enable` gate; a host opts in by
# naming it. Nothing below is a choice: every nixarch host benefits from ranked mirrors, rebuild
# detection after a library bump, the chroot tools needed to recover one, the base Arch package
# set, the build tools that make an AUR package buildable at all, and the AUR helper the
# reconciler itself invokes. There is no meaningful "off" state for a nixarch host, so this module
# carries no `enable` option of its own — unlike EVERY other module in this repo that touches
# `nixarch.packages.pacman`, all of which gate themselves (shelly.enable; desktop-backend.enable
# plus nixdesktop's own `want`). Importing this module IS the opt-in, the same way
# `nixarch.packages.enable` itself is: whether anything actually gets installed still depends on
# that master switch, exactly as desktop-backend.nix's own config comment already establishes
# ("Resolving roles into a list a consumer inspects without installing anything is a legitimate
# use anyway; leave `packages.enable` to them.") — this module just never adds a SECOND, redundant
# gate on top.
#
# VERIFICATION METHOD, per entry below (checked 2026-08-07, three independent sources, the same
# method modules/packages.nix's own reconciler already assumes and nixagent's lib/agents.nix
# documents in full): `pacman -Si <name>` on a live CachyOS box, which reports the repository a
# name resolves in but CANNOT by itself distinguish a derivative's own repository from its rebuild
# of an upstream Arch one; archlinux.org's package-search API
# (`/packages/search/json/?name=<name>`), which is upstream Arch and knows nothing about a
# derivative's extra repositories; and the AUR RPC (`https://aur.archlinux.org/rpc/v5/info?arg[]=
# <name>`). `reflector`, `rebuild-detector` and `arch-install-scripts` were already established
# this way. `base` and `base-devel` resolve `Repository : core` on `pacman -Si` AND on
# archlinux.org, with zero AUR RPC hits — genuinely official on every Arch-family host, so both
# go straight into `pacman` alongside the first three. `paru` is the one exception; see its own
# comment below for why it does not get the same treatment.
{ lib, config, ... }:
{
  config.nixarch.packages.pacman = [
    # Ranks pacman mirrors by speed and rewrites the mirrorlist. Every host benefits from mirrors
    # that are actually fast for it, not just alphabetically or geographically first.
    "reflector"

    # `checkrebuild` — finds installed packages that need rebuilding after a library bump (a
    # soname change landing before every reverse-dependent has been rebuilt against it). Detection
    # only; it does not rebuild anything itself.
    "rebuild-detector"

    # `arch-chroot`, `genfstab`, `pacstrap`. Reported installed today on the container host
    # (corbet-archlxc); confirmed ABSENT here on the Elitebook laptop (`pacman -Qi
    # arch-install-scripts` — not found). So this is not currently a uniform fact about the
    # fleet, only a uniform declaration. Its use is provisioning and disaster recovery
    # (building/chrooting into a new or broken install), not daily operation, which is why a
    # host going without it day-to-day was never a problem worth noticing before now.
    "arch-install-scripts"

    # `base` — a ZERO-BYTE metapackage (`Installed Size : 0.00 KiB`, confirmed live) depending on
    # the ~26 packages that define a minimal Arch install: filesystem, glibc, bash, coreutils,
    # pacman, systemd, shadow, util-linux, and the rest of what makes a box an Arch box at all.
    # nixarch IS the Arch platform layer, so "the package set that makes this an Arch system" is
    # squarely its remit, on the same footing as everything else in this file. Declaring it also
    # means `pruneUndeclared`/`pruneOrphans` (modules/packages.nix) never mistake it for drift —
    # a layer of protection independent of that module's `keep` default already floor-listing
    # `[ "base" "base-devel" ]`, which stops it being REMOVED but says nothing about a box that
    # converges toward this module's declared set never having had it INSTALLED in the first place.
    "base"

    # `base-devel` — the same shape, zero-byte, depending on ~26 build tools: gcc, make, autoconf,
    # binutils, fakeroot, patch, sudo, pkgconf, and the rest of what `makepkg` needs. The
    # strongest FUNCTIONAL case of the four above it: this is what makes building an AUR package
    # possible at all — including, on a plain Arch host, `paru` itself below.
    "base-devel"
  ]
  # `paru` — nixarch's OWN reconciler shells out to it (modules/packages.nix, `aurHelper` defaults
  # to `"paru"`), so leaving it undeclared meant this repo depended on a binary it never named —
  # closing that is the point. But UNLIKE the four packages above, `paru` is not the same answer
  # on every Arch-family host, which is why it is not simply added to the plain list:
  #
  #   `pacman -Si paru` (this CachyOS box) -> resolves, `Repository : cachyos` — CachyOS's OWN
  #                                           repository, not one of its `*-v3` rebuilds of an
  #                                           Arch repo, so this exists because the derivative
  #                                           chose to ship a prebuilt binary of it.
  #   archlinux.org package search          -> 0 results. Upstream Arch does not package it, in
  #                                           any repository, on any architecture.
  #   AUR RPC                               -> present, PackageBase `paru`, maintained (Morganamilo,
  #                                           1242 votes). This is where a plain Arch host gets it.
  #
  # The exact shape nixagent's lib/agents.nix documents for `claude-code`, its own one entry with
  # this property: official on a derivative's own repository, AUR-only upstream. That module ports
  # a full `archRepoOn` catalogue field plus a `fromAur` resolver for it, because its catalogue has
  # many entries and needs a reusable mechanism. nixarch has exactly ONE package with this
  # property and no catalogue to extend, so porting that machinery here would duplicate
  # infrastructure this repo does not otherwise need — what it DOES need, the underlying gate, it
  # already has: `nixarch.packages.distro` (modules/packages.nix), declared for the identical
  # reason (choosing the right keyring/mirrorlist floor for `criticalKeep`) and already read here
  # rather than re-invented.
  #
  # So: `aur = true` is the FLOOR (correct for upstream Arch, and the direction that cannot abort
  # a pacman transaction — see modules/packages.nix's own header on why an AUR name in the
  # `pacman` list is fatal), lifted to `pacman` only where `distro` says the box's own repository
  # is known to carry a prebuilt paru.
  #
  # BOOTSTRAPPING, CHECKED: does declaring `paru` in ITS OWN `aur` list on a plain Arch host make
  # this module the thing that has to install paru in order to install paru? No — the circularity
  # modules/packages.nix's header already documents (`aurHelper` MUST already be on the box before
  # `aur` is non-empty; installing it is a one-time manual step this module deliberately does not
  # attempt) applies identically to every entry in `aur`, not specially to this one. The reconcile
  # script's AUR step runs `runuser -u <aurUser> -- paru -S --needed .. "$pkg"` — that line cannot
  # execute AT ALL, for ANY package, until `paru` is already on PATH; the moment it is, `paru -S
  # --needed paru` is a same-package no-op like any other already-satisfied `--needed` target, not
  # a self-install. Naming `paru` here is therefore never load-bearing for getting paru onto a
  # fresh box — the manual bootstrap the module header already requires still is — only for
  # keeping paru's presence DECLARED once that bootstrap has happened, so prune never treats the
  # tool the reconciler itself depends on as undeclared drift.
  ++ lib.optional (config.nixarch.packages.distro == "cachyos") "paru";

  config.nixarch.packages.aur =
    lib.optional (config.nixarch.packages.distro != "cachyos") "paru";
}
