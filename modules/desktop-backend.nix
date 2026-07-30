# modules/desktop-backend.nix — the Arch/CachyOS platform backend for nixdesktop.
#
# nixdesktop declares WHAT a desktop session needs (roles: a file manager, a polkit agent, a
# bar). This module answers WITH WHAT, for Arch: it reads the read-only `nixdesktop.want` attrset
# that nixdesktop's profile publishes, resolves every role through lib/desktop-roles.nix, and
# feeds the result into `nixarch.packages.pacman` — the same reconciler everything else here
# uses. It adds no mechanism of its own.
#
# This is the entire system-layer contract with nixdesktop: one attrset in, packages out. The
# user-layer half (spawn commands for the polkit agent and keyring) is home/desktop.nix, which
# reads the same tables from the same file.
#
# IMPORT ORDER: this module reads an option that nixdesktop's profile declares, so both must be
# in the same evaluation. Import `nixdesktop.systemManagerModules.desktop` alongside it.
{ lib, config, ... }:
let
  cfg = config.nixarch.desktopBackend;
  roles = import ../lib/desktop-roles.nix { inherit lib; };
  want = config.nixdesktop.want or { };
  # Split before publishing: `pacman -S` fails the whole transaction on one unknown target, so an
  # AUR-only component left in the repo list takes the entire desktop down with it. extraPacman
  # goes through the same split -- AUR membership is a fact about the package name, and a host
  # that names an AUR package there deserves a working desktop, not a cryptic `target not found`.
  split = roles.partitionAur (roles.packagesFor want ++ cfg.extraPacman);
in
{
  options.nixarch.desktopBackend = {
    enable = lib.mkEnableOption ''
      resolving nixdesktop's declared roles into Arch packages.

      Requires nixdesktop's own profile in the same evaluation (it declares the
      `nixdesktop.want` option this reads) and `nixarch.packages` to actually install anything
    '';

    extraPacman = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Packages appended verbatim, for host-specific desktop needs that are not a nixdesktop
        role — a Bluetooth applet, a GTK theme, an audio mixer. Prefer nixdesktop's own
        `extraComponents` when the thing is genuinely part of the desktop policy; use this when
        it is specific to one machine.

        Names known to be AUR-only are routed to `nixarch.packages.aur` rather than failing the
        pacman transaction, so the option name is about intent, not about which repo it must
        come from.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # A no-op when nixdesktop's profile is absent or disabled: `want` is then `{}` and
    # packagesFor yields nothing, so enabling this module without a desktop is harmless rather
    # than an evaluation error.
    # `pacman` is a plain listOf at the default priority, so this concatenates with a consumer's
    # own list rather than fighting it.
    #
    # Deliberately NOT guarded by a warning when `nixarch.packages.enable` is false. `warnings`
    # and `assertions` are not part of the core module system -- they come from nixpkgs' own
    # assertions module -- so a module that defines them fails to evaluate anywhere that does not
    # supply them. Resolving roles into a list a consumer inspects without installing anything is
    # a legitimate use anyway; leave `packages.enable` to them.
    nixarch.packages.pacman = split.repo;
    nixarch.packages.aur = split.aur;
  };
}
