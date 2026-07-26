# home/shell.nix — the CONFIG/dotfiles layer (home-manager) that complements
# nixarch's SYSTEM layer. System-wide package breadth (pacman/AUR) is
# `nixarch.packages`'s job; this module is home-manager's side of the same
# "system-manager AND home-manager" pitch — it owns the user's shell config,
# not the box's package inventory.
#
# HONEST HYBRID NOTE: home-manager installs the nixpkgs build of fish/
# starship/zoxide/fzf into the user's profile by default, which can coexist
# with (or duplicate) pacman-installed copies of the same tools — a user who
# prefers the pacman build can override `programs.<x>.package` to a null/
# pacman-provided derivation, or drop these `programs.*.enable` lines and
# manage the binaries via `nixarch.packages` instead.
#
# This module is deliberately LEAN: it enables a coherent, modern interactive
# shell bundle (fish + starship + zoxide + fzf) with sane defaults and adds
# NO personal content — no aliases, no keybindings, no prompt config, no
# functions. That belongs in a consumer's own home-manager config layered on
# top.
#
# ── FIRST-SWITCH TRAP: read before enabling this on an existing machine ───
#
# Setting `programs.fish.enable` for the first time on a box that ALREADY has
# a plain, non-home-manager-owned ~/.config/fish/config.fish makes
# `home-manager switch` REFUSE to activate: its collision check
# (checkLinkTargets) errors out before touching anything. This is the common
# case on an Arch desktop, where a vendor package (e.g. cachyos-fish-config)
# has already written that file — precisely the situation this module's own
# `programs.fish.enable` below walks into.
#
# The fix is a ONE-TIME flag on the switch itself, not a config option:
#   home-manager switch -b hm-bak          # standalone CLI
#   home-manager.backupFileExtension = "hm-bak";   # via the NixOS module
# That moves the vendor file aside as config.fish.hm-bak — diffable and
# reversible. Do NOT reach for per-file `force = true`: home-manager's own
# docs describe it as a silent one-way delete with no backup.
#
# The full treatment of safe fish adoption (plus a typed primitive for
# universal variables, `set -U` state that home-manager's file management
# cannot reach) is the subject of a dedicated sibling project, nixfish. This
# module intentionally does not depend on it — the bundle here stays
# standalone — but a consumer who wants fish managed properly should prefer
# nixfish's module over this convenience line.
{ lib, config, ... }:
let
  cfg = config.nixarch.home.shell;
in
{
  options.nixarch.home.shell = {
    enable = lib.mkEnableOption "modern interactive shell bundle (fish + starship + zoxide + fzf)";
  };

  config = lib.mkIf cfg.enable {
    programs.fish.enable = lib.mkDefault true;
    programs.starship.enable = lib.mkDefault true;
    programs.zoxide.enable = lib.mkDefault true;
    programs.fzf.enable = lib.mkDefault true;

    # No manual init wiring needed: when `programs.fish.enable` is true
    # alongside `programs.starship`/`programs.zoxide`/`programs.fzf`,
    # home-manager automatically injects each tool's fish integration
    # (starship's prompt hook, zoxide's `z`/`zi` functions, fzf's key
    # bindings) into the generated fish config — that wiring is home-manager
    # module glue, not something this module needs to reproduce.
  };
}
