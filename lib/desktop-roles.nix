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
  # media tags, archive context menus) are the `fileManagerExtras` capability below.
  #
  # THESE NAMES ARE THE FLOOR ON ARCH AND NOWHERE ELSE. nixdesktop's NixOS table names neither
  # gvfs nor tumbler nor thunar itself, because there each is installed by a real NixOS option
  # (`services.gvfs.enable`, `services.tumbler.enable`, `programs.thunar.enable`) and a second
  # copy in the package list actively breaks things. Here installing the package IS enabling it:
  # pacman drops the daemons, the udev rules, the D-Bus activation files and the `.mount`
  # descriptions into the one shared prefix everything already reads. Same role, same floor,
  # expressed as packages only because on Arch that is what a package does.
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

    # oo7 — the modern Secret Service provider, and the only entry in this file whose `command` is
    # NOT what the user layer ends up spawning. Both halves of that need saying.
    #
    # THE PACKAGE. `extra/oo7`, an official repo, no AUR (verified `pacman -Si oo7`), shipping the
    # daemon at `/usr/lib/oo7-daemon` — NOT `/usr/bin`, so a bare "oo7-daemon" resolves via PATH
    # nowhere, exactly like the polkit agents above and unlike gnome-keyring/kwallet. It also
    # declares `Conflicts With: gnome-keyring`, so on Arch the two providers are mutually exclusive
    # at the package-manager level rather than merely racing for `org.freedesktop.secrets` at
    # runtime the way nixdesktop's option doc describes. Switching a host from one to the other is
    # therefore a removal followed by an install, in that order — `nixarch.packages` reconciles the
    # other way round (`pacman -S --needed` first, prune afterwards; see modules/packages.nix), so
    # the outgoing provider has to be gone before the incoming one is declared.
    #
    # THE COMMAND, AND WHY home/desktop.nix DOES NOT PASS IT ON. The pacman package also installs
    # its own `--user` unit at `/usr/lib/systemd/user/oo7-daemon.service`, `WantedBy=default.target`
    # — a target a user manager reaches at startup, strictly before any compositor pulls in
    # `graphical-session.target`. So the vendor daemon has already claimed the bus name by the time
    # anything nixdesktop renders could start, and a second unit loses the `RequestName` race every
    # time and sits permanently failed. home/desktop.nix routes this entry through nixdesktop's
    # `session.keyring.oo7.renderDaemon = false` for exactly that reason and never hands the string
    # below to `session.keyring.command`. The path stays here anyway, because it is the true fact
    # about where this package puts its daemon and the next reader of this table should not have to
    # go find it again to answer "and what would run it".
    oo7 = {
      packages = [ "oo7" ];
      command = "/usr/lib/oo7-daemon";
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

    # ── fileManagerExtras ─────────────────────────────────────────────────────────────────────
    #
    # A flat name list, which is the whole Arch story for this role: a thunarx plugin here is an
    # ordinary package that drops a `.so` into the SHARED `/usr/lib/thunarx-3/`, and the stock
    # Thunar scans that directory, so installing a plugin IS loading it. nixdesktop's NixOS table
    # cannot say the same about the identical three plugins — there they have to reach
    # `programs.thunar.plugins`, because only the wrapper that option builds ever sets
    # `THUNARX_DIRS`, and a plugin in the package list installs a file nothing reads.
    #
    # ffmpegthumbnailer IS REQUIRED HERE AND MUST NOT BE MIRRORED INTO THE NIXOS TABLE. Arch's
    # `tumbler` does ship `usr/lib/tumbler-1/plugins/tumbler-ffmpeg-thumbnailer.so`, so the plugin
    # is not missing — but that `.so` carries a `DT_NEEDED` on `libffmpegthumbnailer.so.4`
    # (`readelf -d`), a library only the separate `ffmpegthumbnailer` package owns (`pacman -Qo`).
    # Without it the plugin fails to load and video files silently never get a thumbnail; Arch's
    # tumbler states the same thing as an optdepend, which is a real "you must ask for this",
    # not a suggestion. nixpkgs takes ffmpegthumbnailer as a buildInput of tumbler instead, so the
    # RPATH already resolves there and a second package would install nothing but noise.
    #
    # xarchiver, where nixdesktop's NixOS table names engrampa — the one entry in this file whose
    # right ANSWER differs across platforms rather than only its spelling. thunar-archive-plugin
    # never runs an archiver itself: it looks up a `<desktop-id>.tap` wrapper script under the
    # LIBEXECDIR baked in at compile time and drops every candidate that has none. Here that is the
    # shared `/usr/lib/xfce4/thunar-archive-plugin/`, where the plugin's own bundled
    # ark/engrampa/file-roller taps and xarchiver's `xarchiver.tap` land side by side, so all four
    # resolve; xarchiver is the GTK3 one that belongs to no desktop environment (its whole
    # dependency set is gtk3 + gdk-pixbuf2 + glib2), where engrampa is MATE's and the other two
    # drag GNOME or KDE in. On NixOS that LIBEXECDIR is the plugin's OWN store path, which
    # xarchiver's tap can never be inside, so engrampa is the only choice that resolves there at
    # all — different platform, different correct answer, same role.
    #
    # NOT GATED ON `fileManager` BEING THUNAR, unlike the NixOS backend's `programs.thunar.plugins`
    # wiring: `packagesFor` walks this table as plain booleans and knows nothing about which file
    # manager was named. On a host that sets `fileManager = "nautilus"` and this to true, the
    # archiver and the thumbnailer library still do their job and three thunarx plugins sit on disk
    # unloaded. A few unused `.so` files, not a broken anything — cheap enough to be worth keeping
    # this table free of cross-role conditionals.
    fileManagerExtras = [
      "ffmpegthumbnailer"
      "thunar-archive-plugin"

      # engrampa, and NOT xarchiver, even though xarchiver works perfectly well here. Arch's
      # shared `/usr/lib/thunar-archive-plugin` means BOTH resolve on this platform, so the choice
      # is free — and nixdesktop's NixOS table has no such freedom: thunar-archive-plugin resolves
      # its `<desktop-id>.tap` under a LIBEXECDIR baked in at compile time, which on NixOS is the
      # plugin's own store path, and the only wrappers it ships are ark/engrampa/file-roller.
      # Picking the one name that works on both platforms costs nothing here and removes a
      # divergence that would otherwise have to be remembered every time either side changed.
      # Of the three, engrampa is GTK3 (ark drags KDE Frameworks, file-roller is GTK4+libadwaita),
      # matching the same constraint that makes mate-polkit the polkit agent.
      "engrampa"

      # ── The format backends ─────────────────────────────────────────────────────────────────
      #
      # engrampa is a dispatcher: one `fr-command-*` module per format, each exec'ing an external
      # command by bare name. Its own hard deps cover tar/gzip/zip/unzip only, so everything below
      # is the difference between an archive manager that opens what people actually send you and
      # one that handles three formats.
      #
      # `7zip`, not `p7zip`: Arch retired p7zip from its repos in favour of upstream's own package.
      # engrampa's own optdepend metadata still says `p7zip` and is therefore unsatisfiable by
      # name — following it literally installs nothing and silently leaves 7z broken. Both provide
      # `/usr/bin/7z`, which is what the backend actually calls.
      "7zip"

      # RAR. Arch packages unrar without the licence question NixOS has to answer, so this side
      # gets the real thing rather than the free reader nixdesktop's table uses.
      "unrar"

      "unace" # ACE — no nixpkgs equivalent, so Arch-only by package availability, not by choice
      "lhasa" # lha/lzh
      "lrzip"
      "lzop"
      "cpio" # cpio, and half of rpm
      "rpm-tools" # rpm2cpio  (nixpkgs spells this one `rpm`)
      "brotli"

      "thunar-media-tags-plugin"
      "thunar-vcs-plugin"
    ];

    # ── gvfsBackends ──────────────────────────────────────────────────────────────────────────
    #
    # THE ROLE THAT ONLY EXISTS BECAUSE OF ARCH, and the plainest argument in this repo for a
    # per-platform catalogue over a shared name list. Arch's `gvfs` carries the core plus a good
    # many backends (sftp, ftp, http, archive, trash, cdda...) and splits precisely these four out
    # into separate packages listed as OPTDEPENDS, each shipping its own daemon and mount
    # description — `gvfs-smb` is `usr/lib/gvfsd-smb` plus `usr/share/gvfs/mounts/smb.mount`, and
    # nothing pulls it in for you. Without them the local disk browses fine and `smb://`, `nfs://`,
    # `mtp://` and `gphoto2://` each fail to resolve.
    #
    # nixpkgs has NO equivalent names AT ALL: it builds one monolithic gvfs with samba, libnfs,
    # libmtp and libgphoto2 compiled in, which arrives whole with `services.gvfs.enable`. So
    # nixdesktop's table keeps this key deliberately empty and the role is a documented no-op
    # there. Four packages here, zero there, one policy boolean — which is the asymmetry the split
    # is for, stated rather than papered over.
    gvfsBackends = [ "gvfs-smb" "gvfs-nfs" "gvfs-mtp" "gvfs-gphoto2" ];

    # ── theming ───────────────────────────────────────────────────────────────────────────────
    #
    # A wlroots session ships no control centre, so the GTK and Qt appearance settings every
    # toolkit still reads have nothing writing them: nwg-look writes the GTK ones, qt6ct gives Qt a
    # platform theme, and adw-gtk-theme is what makes GTK3 applications match the GTK4/libadwaita
    # ones beside them instead of looking a decade older. The usual first symptom of leaving this
    # off is a Qt dialog rendering unstyled next to GTK windows.
    #
    # TWO OF THE THREE ARE SPELLED DIFFERENTLY IN NIXPKGS, the mundane half of why a catalogue
    # exists: `adw-gtk-theme` is `adw-gtk3` there (no `adw-gtk-theme` attribute exists at all), and
    # `qt6ct` is `qt6Packages.qt6ct` there (the top-level `qt6ct` still exists but is a throwing
    # alias, so naming it fails evaluation). Only nwg-look is the same word on both platforms.
    #
    # qt6ct already appears in the `polkit-kde-agent` entry above for its own unrelated reason;
    # `lib.unique` in `packagesFor` makes naming it twice free.
    theming = [ "nwg-look" "adw-gtk-theme" "qt6ct" ];
  };

  # The compositor plus what its own default keybinds shell out to. niri's stock media and
  # brightness binds call these by name, so a compositor installed without them has keys that
  # silently do nothing.
  compositors.niri = [ "niri" "brightnessctl" "playerctl" ];

  # `resolve`'s own fallthrough (see below: "on Arch the role name is usually already the package
  # name") is wrong for scroll specifically — the repos carry no package literally named `scroll`
  # at all, official or AUR (verified live, `pacman -Si scroll` / `-Ss scroll`, 2026-08-04). The
  # real package is `sway-scroll` (a sway/wlroots fork, AUR-only, maintained by scroll's own
  # upstream author) — without this entry, `resolve compositors "scroll"` fell through to
  # `[ "scroll" ]`, and every reconcile run failed outright on "target not found: scroll" before
  # ever reaching any other package, AUR or repo. Found live chasing an unrelated AUR install.
  compositors.scroll = [ "sway-scroll" ];

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
    # In the AUR only; see the `compositors.scroll` entry above for the full account.
    "sway-scroll"
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
