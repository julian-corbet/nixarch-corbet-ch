# modules/shelly.nix — Shelly, nixarch's own graphical package manager.
#
# WHAT IT IS. A GTK4 front-end for pacman and the AUR — search, install, remove, browse
# dependencies from a window, next to the `pacman`/paru CLIs, not a replacement for either.
# Official CachyOS repo, not AUR (verified live: `pacman -Si shelly` resolves `Repository :
# cachyos`), so it reconciles through the plain `pacman` list below rather than `aur`.
#
# WHY THIS IS NIXARCH'S OWN PACKAGE, NOT A DOMAIN REPO'S. Every other name that has ever landed
# in `nixarch.packages.pacman`/`.aur` arrived from OUTSIDE this repo: a domain module (nixgpu's
# CUDA toolchain, nixdev's language toolchains, this project's own modules/desktop-backend.nix
# resolving nixdesktop's roles) sets the option from its own tree, and `nixarch.packages` is only
# ever the sink that receives it. Shelly belongs to none of those domains — it is a tool for
# managing the Arch package set itself, which is nixarch's own subject matter, on the same
# footing as `packages` (the reconciler) and `desktop-backend` (the Arch resolution table). So it
# gets the same shape those get: a small module living HERE, gated by its own `enable`, that
# publishes into the sink from the inside — the act of nixarch declaring a package it owns —
# rather than being published into the sink from outside, the way a domain repo does it.
#
# CAUTION — A SECOND PACKAGE MANAGER, DELIBERATELY. `nixarch.packages` declaratively reconciles
# the installed set from Nix; Shelly is a separate, imperative path to `pacman -S`/`-R` with its
# own GUI, on the same box. Anything installed (or removed) through Shelly is invisible to that
# declaration — it will not appear in `pacman`/`aur` here, and will read as undeclared drift the
# moment `pruneUndeclared`/`pruneOrphans` is ever turned on. That tension is accepted, not missed:
# Shelly is for browsing and the occasional one-off install; the declared lists stay the source of
# truth for what a box is SUPPOSED to have.
{ lib, config, ... }:
let
  cfg = config.nixarch.shelly;
in
{
  options.nixarch.shelly.enable = lib.mkEnableOption ''
    Shelly, a graphical package manager (pacman/AUR GUI front-end) alongside pacman/paru.

    Requires `nixarch.packages.enable` to actually install anything — this module only adds
    the name to `nixarch.packages.pacman`; the reconciler in modules/packages.nix does the rest.
  '';

  config = lib.mkIf cfg.enable {
    # A plain listOf at the default priority, same as modules/desktop-backend.nix's identical
    # line — concatenates with whatever else a consumer's evaluation already contributes to
    # `nixarch.packages.pacman`, rather than fighting it.
    nixarch.packages.pacman = [ "shelly" ];
  };
}
