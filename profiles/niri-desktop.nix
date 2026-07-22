# profiles/niri-desktop.nix — an OPT-IN system-manager profile: the package floor for a niri
# desktop session on Arch/CachyOS.
#
# A PROFILE, not a new mechanism, same doctrine as profiles/ai-workstation.nix: composes
# `nixarch.packages` into a curated pacman list, every list is `mkDefault` so a consumer can
# override without a `mkForce` fight. Pairs with home/niri.nix (the config-generation half);
# this module only installs binaries.
#
# Chosen over an alternative full-shell bundle (a DMS/Quickshell-style "material" desktop shell)
# on measured evidence, not taste: mango+DMS (the tested alternative-compositor-plus-shell combo)
# cost ~860-930MB VRAM mastering a real display vs. niri+waybar's ~83-131MB doing the identical
# job — reproduced 5+ times, restart-immune, shell-independent (isolating the shell out of the
# mango measurement made no difference to mango's own cost). See the (private, this author's own)
# fleet's knowledge/fleet/desktop/mango-vs-niri-vram.md for the full investigation. The general
# lesson generalizes: a wlroots compositor with its own eye-candy effects renderer (blur/shadow/
# corner-radius layered on top, e.g. via scenefx) carries a real, structural VRAM cost independent
# of the shell paired with it; niri (Smithay-based, no such effects layer) and a plain
# GTK/C bar+notifier stack (waybar+mako, zero GPU client of their own) avoid it entirely.
{ lib, config, ... }:
let
  cfg = config.nixarch.niriDesktop;
in
{
  options.nixarch.niriDesktop = {
    enable = lib.mkEnableOption
      "niri desktop package base (lean, opt-in package set over nixarch.packages)";

    fileManager = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "nautilus";
      description = ''
        File manager pacman package, or null to install none. Default matches the pairing
        CachyOS's own official mango-desktop profile makes, kept here for consistency rather
        than re-litigated.
      '';
    };

    keyring = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "gnome-keyring" "kwallet" ]);
      default = "gnome-keyring";
      description = ''
        Secret-service provider, or null for none. `"kwallet"` installs `kwalletd6`; niri has
        no Plasma session to host it, so kwallet needs its own explicit spawn wiring (not
        provided by this profile) if chosen.
      '';
    };

    screenshots = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install grim + slurp. niri has a built-in screenshot bind that doesn't strictly need these, but region-select workflows via other tools often do.";
    };

    extraPacman = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Escape hatch: extra official-repo packages appended to the computed nixarch.packages.pacman list.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixarch.packages.enable = lib.mkDefault true;

    nixarch.packages.pacman = lib.mkDefault (
      [
        "niri"
        "waybar"
        "mako"
        "fuzzel"
        "swayidle"
        "swaylock"
        "cliphist"
        "wl-clipboard"
        "playerctl"
        "brightnessctl"
        "xdg-desktop-portal-gnome"
        "xdg-desktop-portal-gtk"
        "polkit-kde-agent"
        "qt6ct"
        "nwg-look"
        "adw-gtk-theme"
      ]
      ++ lib.optional (cfg.fileManager != null) cfg.fileManager
      ++ lib.optional (cfg.keyring == "gnome-keyring") "gnome-keyring"
      ++ lib.optional (cfg.keyring == "kwallet") "kwalletd6"
      ++ lib.optionals cfg.screenshots [ "grim" "slurp" ]
      ++ cfg.extraPacman
    );
  };
}
