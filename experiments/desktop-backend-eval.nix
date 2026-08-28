# Throwaway eval check for the nixdesktop backend -- NOT part of the module surface. Confirms
# that roles declared by nixdesktop's profile actually resolve into Arch package names, and that
# the two halves of the backend (system packages, user spawn commands) agree about which binary
# a given role means. Safe to delete; nothing imports this file.
#
# Needs a nixdesktop checkout. Defaults to a sibling clone, which is how these two repos are
# normally worked on together:
#
#   nix-instantiate --eval --strict experiments/desktop-backend-eval.nix -A ok
{ nixpkgs ? <nixpkgs>
, nixdesktop ? ../../nixdesktop
}:
let
  lib = (import nixpkgs { }).lib;
  roles = import ../lib/desktop-roles.nix { inherit lib; };

  # System layer: nixdesktop's profile + this backend, one evaluation.
  sys = lib.evalModules {
    modules = [
      # Path concatenation, NOT "${nixdesktop}/..." -- string interpolation of a path copies the
      # whole checkout (.git and all) into the store and then fails on it. This imports the one
      # file.
      (nixdesktop + "/profiles/desktop.nix")
      ../modules/desktop-backend.nix

      # Stub of the surface the backend writes into, rather than importing modules/packages.nix
      # itself: that module declares `systemd.services`, which only exists inside system-manager's
      # module set and would need a whole system evaluation to satisfy. What is under test here is
      # role resolution, and this is the entire contract the backend has with the reconciler.
      ({ lib, ... }: {
        options.nixarch.packages = {
          enable = lib.mkEnableOption "stub";
          distro = lib.mkOption { type = lib.types.enum [ "arch" "cachyos" ]; default = "arch"; };
          pacman = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          # Both halves of the split, even though this experiment only reads `pacman`: the stub
          # has to cover everything the module WRITES, not just what the check reads.
          aur = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
        };
      })

      {
        nixarch.packages.enable = true;
        nixarch.desktopBackend = {
          enable = true;
          extraPacman = [ "blueman" ];
        };
        # `compositor` has no default -- nixdesktop refuses to prefer one, so it must be named.
        # defaults: thunar, soteria, waybar, foot...
        nixdesktop.desktop = { enable = true; compositor = "niri"; };
      }
    ];
  };

  pacman = sys.config.nixarch.packages.pacman;
  aur = sys.config.nixarch.packages.aur;
in
rec {
  inherit pacman aur;

  # The doctrinal defaults survive the whole round trip: role -> want -> Arch package.
  thunarResolved = lib.elem "thunar" pacman && lib.elem "tumbler" pacman && lib.elem "gvfs" pacman;
  soteriaResolved = lib.elem "soteria-git" aur;
  compositorResolved = lib.elem "niri" pacman && lib.elem "brightnessctl" pacman;
  capabilitiesResolved = lib.elem "grim" pacman && lib.elem "swayidle" pacman && lib.elem "xwayland-satellite" pacman;
  extraPacmanApplied = lib.elem "blueman" pacman;

  # KDE must NOT appear from the defaults -- this is the regression that mattered: nixarch's old
  # profile defaulted polkitAgent to polkit-kde-agent, so an unopinionated consumer silently got
  # a KDE Frameworks stack reinstalled on every activation.
  noKdeByDefault = !(lib.elem "polkit-kde-agent" pacman) && !(lib.elem "qt6ct" pacman);

  # The two halves agree: the agent the system layer installs is the binary the user layer
  # spawns. Drift here is the exact failure the shared table exists to prevent.
  halvesAgree =
    let r = roles.polkitAgents.soteria;
    in lib.elem (lib.head r.packages) aur
      && r.command == "/usr/lib/soteria-polkit/soteria";

  ok = thunarResolved && soteriaResolved && compositorResolved
    && capabilitiesResolved && extraPacmanApplied && noKdeByDefault && halvesAgree;
}
