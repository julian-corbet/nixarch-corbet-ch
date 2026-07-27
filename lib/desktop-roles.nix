# lib/desktop-roles.nix — the Arch/CachyOS resolution tables for nixdesktop's roles. Pure data,
# no module system: imported by BOTH modules/desktop-backend.nix (system layer, roles -> pacman
# packages) and home/desktop.nix (user layer, roles -> spawn commands).
#
# WHY THE TABLES LIVE HERE AND NOT IN EITHER MODULE. The system layer and the user layer are
# separate module evaluations — system-manager and home-manager do not share a config tree — so
# nothing computed in one is visible to the other. The polkit agent is the case that hurts: the
# system layer must install the package, and the user layer must spawn a binary at an absolute
# path, and those two facts are the same fact. Keeping them in one attrset means they cannot
# drift apart; keeping them in a plain .nix file means neither module has to import the other.
#
# THIS FILE IS THE ONLY PLACE IN THE PROJECT THAT KNOWS ARCH PACKAGE NAMES for the desktop.
# nixdesktop declares roles ("thunar", "mate-polkit") and never names a package or a path; that
# is the whole point of the split. A NixOS backend would be this file with nixpkgs attributes
# instead, and no change to nixdesktop at all.
{ lib }:
rec {
  # ── Roles whose implementation is a named choice ────────────────────────────────────────────

  # A file manager alone is not a working file manager. Thumbnails need a thumbnailer service,
  # and mounting/browsing anything (removable media, network shares, MTP phones) needs gvfs.
  # Ship the floor that makes the role actually function; taste-level plugins (VCS integration,
  # media tags, archive context menus) stay the consumer's business via `extraComponents`.
  fileManagers = {
    thunar = [ "thunar" "tumbler" "gvfs" "thunar-volman" ];
    nautilus = [ "nautilus" "gvfs" ];
    dolphin = [ "dolphin" "kio-extras" ];
    nemo = [ "nemo" "gvfs" ];
    pcmanfm = [ "pcmanfm-gtk3" "gvfs" ];
  };

  polkitAgents = {
    mate-polkit = {
      packages = [ "mate-polkit" ];
      command = "/usr/lib/mate-polkit/polkit-mate-authentication-agent-1";
    };
    polkit-kde-agent = {
      # qt6ct rides along deliberately: this agent is the only Qt component on an otherwise-GTK
      # desktop, and without a Qt platform theme it renders unstyled against everything else.
      packages = [ "polkit-kde-agent" "qt6ct" ];
      command = "/usr/lib/polkit-kde-authentication-agent-1";
    };
    lxqt-policykit = {
      packages = [ "lxqt-policykit" ];
      command = "/usr/bin/lxqt-policykit-agent";
    };
  };

  keyrings = {
    gnome-keyring = {
      packages = [ "gnome-keyring" ];
      # --components=secrets only: this is the secret-service role, not the ssh-agent or pkcs11
      # ones. A consumer wanting those should say so rather than get them by accident.
      command = "gnome-keyring-daemon --start --components=secrets";
    };
    kwallet = {
      packages = [ "kwalletd6" ];
      command = "kwalletd6";
    };
  };

  bars = {
    waybar = [ "waybar" ];
    eww = [ "eww" ];
    # noctalia is installed from its own flake through home-manager, not from pacman — the
    # Arch repos carry the older Qt/QML generation, not the current rewrite. Empty on purpose,
    # not an oversight.
    noctalia = [ ];
  };

  notificationDaemons.mako = [ "mako" ];

  osds.swayosd = [ "swayosd" ];

  # ── Capability roles: booleans in `want`, package sets here ─────────────────────────────────

  capabilities = {
    # niri probes for xwayland-satellite by name at startup and, if absent, WARNS and continues
    # with X11 integration silently disabled — which surfaces much later as "X11 apps don't
    # start" with nothing obvious to blame.
    xwayland = [ "xwayland-satellite" ];
    screenshots = [ "grim" "slurp" ];
    clipboardHistory = [ "cliphist" "wl-clipboard" ];
    idleAndLock = [ "swayidle" "swaylock" ];
    # niri declares a hard dependency on xdg-desktop-portal-impl, so SOME portal backend is
    # mandatory. gtk is the general-purpose fallback; gnome supplies the screencast portal that
    # gtk's does not, which is what screen sharing actually needs on wlroots-adjacent stacks.
    portals = [ "xdg-desktop-portal-gnome" "xdg-desktop-portal-gtk" ];
  };

  # The compositor plus what its own default keybinds shell out to. niri's stock media and
  # brightness binds call these by name, so a compositor installed without them has keys that
  # silently do nothing.
  compositors.niri = [ "niri" "brightnessctl" "playerctl" ];

  # ── Which of the names above are AUR-only ───────────────────────────────────────────────────

  # `pacman -S` aborts the ENTIRE transaction on one unknown target, so a single AUR name mixed
  # into the repo list fails every other package in it too. Splitting the two lists is therefore
  # not a nicety — it is what stops one AUR component from blocking the whole desktop.
  #
  # A flat set of names, not a field on every table entry: whether a package is in the repos or
  # the AUR is a property of the PACKAGE, not of the role it happens to fill, and the tables above
  # are read by home/desktop.nix too — changing their shape to carry a flag would churn a consumer
  # that has no interest in the distinction. It also covers free-form values (`extraComponents`,
  # `launcher`, `terminal`) that never appear in a table at all.
  aurOnly = [
    # In the AUR only; the repos carry no eww.
    "eww"
  ];

  # Partition a resolved package list into what `pacman -S` can take and what needs an AUR helper.
  partitionAur = packages: {
    repo = lib.filter (p: !(lib.elem p aurOnly)) packages;
    aur = lib.filter (p: lib.elem p aurOnly) packages;
  };

  # ── Resolution ──────────────────────────────────────────────────────────────────────────────

  # Look a role value up in a table; fall through to the value itself as a package name. The
  # fallthrough is deliberate: nixdesktop's `fileManager`, `launcher` and `terminal` are
  # free-form strings precisely so a consumer is not gated on this table being exhaustive, and
  # on Arch the role name is usually already the package name.
  resolve = table: value:
    if value == null then [ ]
    else if table ? ${value} then
      (if lib.isList table.${value} then table.${value} else table.${value}.packages)
    else [ value ];

  # Packages for a resolved `nixdesktop.want`. An empty want (profile disabled) yields nothing.
  packagesFor = want:
    if want == { } then [ ] else
    lib.unique (
      resolve compositors (want.compositor or null)
      ++ resolve bars (want.bar or null)
      ++ resolve notificationDaemons (want.notifications or null)
      ++ resolve fileManagers (want.fileManager or null)
      ++ resolve polkitAgents (want.polkitAgent or null)
      ++ resolve keyrings (want.keyring or null)
      ++ resolve osds (want.osd or null)
      ++ lib.optionals (want.launcher or null != null) [ want.launcher ]
      ++ lib.optionals (want.terminal or null != null) [ want.terminal ]
      ++ lib.concatLists (lib.mapAttrsToList
        (name: pkgs: lib.optionals (want.${name} or false) pkgs)
        capabilities)
      ++ (want.extraComponents or [ ])
    );
}
