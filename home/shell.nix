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
