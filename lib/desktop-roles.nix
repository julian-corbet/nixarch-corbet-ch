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
# nixdesktop declares roles ("thunar", "soteria") and never names a package or a path; that
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
    soteria = {
      # Soteria is not in Arch's binary repositories. The AUR package builds the current upstream
      # main branch from source and installs its deliberately non-PATH agent binary here.
      packages = [ "soteria-git" ];
      command = "/usr/lib/soteria-polkit/soteria";
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
    # The GTK4 bar. Same repo (`extra`) and same shape as waybar here -- the difference between
    # them is a rendering property, not a packaging one; see nixdesktop's own `bar` option for
    # which to pick and why fractional scaling decides it.
    ironbar = [ "ironbar" ];
    eww = [ "eww" ];
    # noctalia is installed from its own flake through home-manager, not from pacman — the
    # Arch repos carry the older Qt/QML generation, not the current rewrite. Empty on purpose,
    # not an oversight.
    noctalia = [ ];
  };

  notificationDaemons = {
    mako = [ "mako" ];
    # `swaync` on Arch, where the package, the binary and the config directory agree. nixpkgs is
    # the odd one out and calls the attribute `swaynotificationcenter` -- one of the plainer
    # illustrations of why this table is per-platform rather than shared.
    swaync = [ "swaync" ];
  };

  osds.swayosd = [ "swayosd" ];

  # The input substrate — a keyboard remapping daemon below the compositor, rewriting events at
  # the evdev/uinput layer so its mappings hold in a TTY, in a display manager and in every
  # compositor alike. See nixdesktop's own `input` option for the full role description.
  #
  # ON ARCH, INSTALLING IT IS MOST OF THE WORK, which is the usual asymmetry this file exists for.
  # The package drops `/usr/bin/keyd`, the `keyd.service` unit and the udev rules into the one
  # shared prefix everything already reads; nixdesktop's NixOS table can say none of that, because
  # there the daemon comes from `services.keyd.enable` and the package alone yields only the client
  # binaries. Same role, two genuinely different amounts of work, which is exactly the split the
  # backend indirection is for.
  #
  # WHAT IT STILL DOES NOT DO HERE: start. `keyd.service` ships disabled, and the daemon reads
  # `/etc/keyd/*.conf`, which this package does not create. Neither is nixdesktop's business — the
  # role installs a mechanism and takes no position on which key becomes which. A consumer wanting
  # it running enables the vendor unit through its own mechanism (nixarch's own
  # modules/foreign-service.nix is the declarative surface for exactly that class of unit).
  #
  # Verified 2026-08-08, the three-source method modules/base-packages.nix documents: `pacman -Si
  # keyd` resolves in an official repository (`extra` upstream, served as a `cachyos-extra-v3`
  # rebuild on a v3 host — a rebuild of the Arch repo, not a derivative-only package),
  # archlinux.org's package search returns one result in `extra`, and the AUR RPC returns zero. So
  # it is genuinely repo, not AUR, and correctly absent from `aurOnly` below.
  inputRemappers.keyd = [ "keyd" ];

  # ── Capability roles: booleans in `want`, package sets here ─────────────────────────────────

  capabilities = {
    # niri probes for xwayland-satellite by name at startup and, if absent, WARNS and continues
    # with X11 integration silently disabled — which surfaces much later as "X11 apps don't
    # start" with nothing obvious to blame.
    xwayland = [ "xwayland-satellite" ];
    screenshots = [ "grim" "slurp" ];
    clipboardHistory = [ "cliphist" "wl-clipboard" ];
    idleAndLock = [ "swayidle" "swaylock" ];
    # THE GENERAL BACKEND ONLY. Most Wayland compositors declare a hard dependency on some
    # `xdg-desktop-portal-impl`, so one general-purpose backend is close to mandatory, and gtk is
    # it: file chooser, settings, print, "open with".
    #
    # NO GNOME BACKEND, and the reason it used to be here is worth keeping because it is a plausible
    # mistake to make twice. It was added to supply the screencast portal that gtk's does not — true
    # as far as it goes, and the wrong package for it on every compositor this role table serves.
    # `xdg-desktop-portal-gnome` implements Screenshot and ScreenCast against Mutter's own D-Bus
    # API, so on a wlroots session it answers with a backend that cannot do the job. The right one
    # is `xdg-desktop-portal-wlr`, which speaks `wlr-screencopy`/`wlr-export-dmabuf`, and it is
    # deliberately NOT here: it is meaningless without a wlroots compositor, so it belongs to
    # whichever module owns that compositor rather than to a general desktop capability. nixscroll's
    # Arch plane declares it (`nixscroll.install.portal.enable`) along with the `portals.conf` that
    # actually selects it (`nixscroll.portals.pin.enable`).
    #
    # IT NEVER SERVED ANYTHING HERE, which is a sharper reason to drop it than "redundant" and a
    # duller one than "it was stealing capture". xdg-desktop-portal resolves an interface through a
    # portals.conf, then through the deprecated `UseIn` key matched against XDG_CURRENT_DESKTOP,
    # then through one last resort: `xdg-desktop-portal-gtk` SPECIFICALLY. A wlroots session sets no
    # XDG_CURRENT_DESKTOP and matched no config file, so the GNOME backend was never a candidate for
    # anything — it sat installed and inert, never even D-Bus-activated, while Screenshot and
    # ScreenCast went unresolved and unexported because gtk implements neither.
    #
    # So it is dead weight, and dead weight that turns into a live wrong answer the moment anything
    # puts `gnome` in XDG_CURRENT_DESKTOP, since gnome.portal claims both interfaces with
    # `UseIn=gnome`. Dropping it costs nothing and closes that.
    portals = [ "xdg-desktop-portal-gtk" ];

    # The Arch half of nixdesktop's `browsers` capability. A fixed PAIR rather than a
    # single-choice role like fileManager or polkitAgent: a desktop routinely wants both at once
    # and neither substitutes for the other -- one is the daily driver, the other is what you open
    # when a site only works in a Chromium engine.
    #
    # Both are official-repo (`pacman -Si`: `extra`, with a cachyos-extra-v3 overlay build), so
    # neither belongs in the AUR partition. Note the NixOS side is `pkgs.chromium` and NOT
    # `google-chrome` -- the former is the BSD-3-Clause build that needs no allowUnfree, and the
    # two are different programs, not two names for one.
    browsers = [ "firefox" "chromium" ];

    # BOTH application-indicator libraries. See nixdesktop's own `appIndicators` option for the
    # full account; the short version is that they ship different sonames
    # (`libappindicator3.so.1` vs `libayatana-appindicator3.so.1`), so they are not substitutes
    # and a desktop carrying only the fork loses the tray for everything still asking for the
    # original name.
    #
    # BOTH ARE OFFICIAL-REPO, verified 2026-08-08 the three-source way modules/base-packages.nix
    # documents: `pacman -Si` resolves each in an official repository (`extra` upstream; the fork
    # is served as a `cachyos-extra-v3` rebuild on a v3 host, which is a rebuild of the Arch repo
    # rather than a derivative-only package), archlinux.org returns one result in `extra` for each,
    # and the AUR RPC returns zero for both. So neither belongs in `aurOnly` below.
    appIndicators = [ "libappindicator" "libayatana-appindicator" ];

    # A graphical duplicate/waste finder. The GUI has its OWN package name here -- the project
    # also ships a headless `czkawka-cli`, which is a separate package and deliberately not
    # declared: a terminal-first tool belongs to whichever repo owns the terminal, not to the
    # desktop. nixdesktop's NixOS table needs no such distinction; one attribute there provides
    # the GUI outright.
    #
    # AUR-ONLY UPSTREAM, LIFTED ON A DERIVATIVE -- see `aurOnly` and `archRepoOn` below for the
    # verification and the mechanism. Named flatly here regardless: which channel a package comes
    # from is a property of the package, not of the role, so the tables stay free of it.
    duplicateFinder = [ "czkawka-gui" ];

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

      # libopenraw, for exactly ffmpegthumbnailer's reason one file type over: it is what lets the
      # thumbnailer read a RAW photo. Arch's tumbler names it an optdepend and nothing else pulls
      # it (`Required By: None`, `Optional For: gdk-pixbuf2 tumbler`), so on this platform it is a
      # real "you must ask for this". nixpkgs takes it as a buildInput of tumbler alongside
      # ffmpegthumbnailer, so the NIXOS TABLE MUST NOT MIRROR IT either -- same conclusion, same
      # evidence shape, one decision applied twice.
      "libopenraw"

      "thunar-archive-plugin"

      # engrampa, and NOT xarchiver, even though xarchiver works perfectly well here. Arch's
      # shared `/usr/lib/thunar-archive-plugin` means BOTH resolve on this platform, so the choice
      # is free — and nixdesktop's NixOS table has no such freedom: thunar-archive-plugin resolves
      # its `<desktop-id>.tap` under a LIBEXECDIR baked in at compile time, which on NixOS is the
      # plugin's own store path, and the only wrappers it ships are ark/engrampa/file-roller.
      # Picking the one name that works on both platforms costs nothing here and removes a
      # divergence that would otherwise have to be remembered every time either side changed.
      # Of the three, engrampa is GTK3 (ark drags KDE Frameworks, file-roller is GTK4+libadwaita),
      # matching the same CPU-rendering constraint applied to the Soteria polkit agent.
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

    # Synthetic typing -- `wtype`, "xdotool type for wayland" in the package's own description.
    # See nixdesktop's own `syntheticTyping` option for what the capability is for and for why it
    # is NOT the same thing as the `input` role above it (that one is a remapping daemon BELOW the
    # compositor; this is a client that injects new events through `virtual-keyboard-v1`).
    #
    # THE ONE ENTRY IN THIS FILE WHERE ARCH AND NIXOS ARE THE SAME AMOUNT OF WORK, which is worth
    # stating because so few of them are: wtype is an unprivileged Wayland client, so the package is
    # the whole mechanism on both platforms -- no daemon, no unit, no udev rule, and therefore no
    # NixOS option that would have to substitute for one. The alternative implementation, ydotool,
    # would NOT have been symmetric (it injects at uinput and needs a privileged daemon); nixdesktop's
    # NixOS table names the same package for the same reason.
    #
    # OFFICIAL-REPO, verified 2026-08-08 the three-source way modules/base-packages.nix documents:
    # `pacman -Si wtype` resolves on both live CachyOS hosts (`cachyos-extra-v3`, a rebuild of the
    # Arch repo rather than a derivative-only package), archlinux.org returns one result in `extra`,
    # and the AUR RPC returns zero. So it belongs in neither `aurOnly` nor `archRepoOn` below.
    syntheticTyping = [ "wtype" ];

    # General input automation -- `ydotool`, "generic command-line automation tool (no X!)" in the
    # package's own description. See nixdesktop's own `inputAutomation` option for why this is a
    # third role rather than a second `syntheticTyping` or another value of `input`: that one is a
    # compositor client typing TEXT through `virtual-keyboard-v1`, this writes keys, pointer
    # motion, buttons and scroll into `uinput`, and `input` above rewrites events that already
    # exist rather than producing any.
    #
    # THE PACKAGE IS MOST OF THE MECHANISM HERE, WHICH IT IS NOT ON NIXOS -- the same asymmetry
    # `inputRemappers.keyd` above already carries, and the reason the backend indirection exists at
    # all. Arch's package installs `/usr/bin/ydotool` AND `/usr/bin/ydotoold`, a udev rule
    # (`80-uinput.rules`: `KERNEL=="uinput", GROUP="input", MODE="0660"`) that makes `/dev/uinput`
    # reachable by the `input` group, and a systemd USER unit for the daemon. nixpkgs ships the two
    # binaries and the unit file and no rule at all, which is what `programs.ydotool.enable` is for
    # over there.
    #
    # WHAT IT STILL DOES NOT DO HERE: start, and grant. `ydotool.service` ships disabled, exactly
    # like `keyd.service` above, and nothing in this table enables a vendor unit -- a consumer
    # wanting the daemon running uses its own mechanism (../modules/foreign-service.nix is the
    # declarative surface for precisely that class of unit). The udev rule is a GROUP grant, not a
    # blanket one: a user outside `input` still cannot open the device, and nothing here adds
    # anyone to that group.
    #
    # OFFICIAL-REPO, verified 2026-08-08 the three-source way modules/base-packages.nix documents:
    # `pacman -Si ydotool` resolves on both live CachyOS hosts (`cachyos-extra-v3`, a rebuild of
    # the Arch repo rather than a derivative-only package), archlinux.org returns one result in
    # `extra`, and the AUR RPC returns zero. So it belongs in neither `aurOnly` nor `archRepoOn`
    # below. Both platforms are on 1.0.4, both URLs resolve to github.com/ReimuNotMoe/ydotool, and
    # the command surface agrees exactly -- `ydotool` and `ydotoold` on each.
    inputAutomation = [ "ydotool" ];
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
    # Rust/GTK4 polkit agent, built directly from upstream main by the AUR package.
    "soteria-git"
    # In the AUR only; the repos carry no eww.
    "eww"
    # In the AUR only; see the `compositors.scroll` entry above for the full account.
    "sway-scroll"
    # In the AUR only UPSTREAM -- but see `archRepoOn` immediately below, which lifts it back into
    # the pacman transaction on a derivative whose own repository ships a prebuilt one.
    "czkawka-gui"

    # `char-white` -- an icon theme, and the one name in this list that is NOT in the AUR either.
    # Verified 2026-08-08 the three-source way modules/base-packages.nix documents: `pacman -Si`
    # resolves `Repository : cachyos` on both live hosts -- that derivative's OWN repository, not
    # one of its `*-v3` rebuilds of an Arch one; archlinux.org's package search returns ZERO; and
    # the AUR RPC returns zero for both an exact `info` query and a `search`. Upstream Arch has no
    # source for it at all, which is the same shape as the six CachyOS repository packages in
    # modules/base-packages.nix.
    #
    # SO WHY IS IT IN A LIST CALLED `aurOnly`? Because of what this list MECHANICALLY means, which
    # is narrower than its name: it is what `partitionAur` below holds OUT of the pacman half. That
    # is the only correct answer for a name plain Arch cannot resolve, and the reason is the one
    # this list's own header gives -- `pacman -S` aborts the ENTIRE transaction on one unknown
    # target, taking every other declared package on the host down with it, while an AUR helper
    # handed a name it cannot find fails on that name alone and installs the rest. One of those two
    # failures is recoverable and the other is a box that cannot converge at all. `archRepoOn`
    # immediately below then lifts it back into the pacman half on the distro that genuinely
    # carries it, which is where every real consumer of it is.
    #
    # The name is left as it is rather than generalised: `czkawka-gui` above really is AUR-only
    # upstream, this one is nowhere upstream, and both want the same treatment -- so a rename would
    # buy accuracy on one entry at the cost of churning a field two other repos' catalogues mirror.
    # Stating the difference on the entry is cheaper and does not move anything.
    "char-white"
  ];

  # ── Names that are AUR-only UPSTREAM but repo-carried on a derivative ────────────────────────
  #
  # The same fact `paru` has in modules/base-packages.nix, and the same field nixagent, nixmsg and
  # nixgames each carry on their own catalogue entries: a package upstream Arch does not build,
  # which a derivative chose to ship a prebuilt binary of. `aurOnly` above is the FLOOR -- correct
  # for plain Arch, and the direction that cannot abort a pacman transaction, since an AUR helper
  # happily installs a repo package but `pacman -S` on an AUR-only name kills the whole batch.
  # This lifts a name off that floor, and only for a distro whose repository is known to carry it.
  #
  # Keyed by distro rather than expressed as a per-entry field, matching `aurOnly`'s own reasoning
  # one paragraph up: which repository carries a package is a property of the PACKAGE, not of the
  # role it happens to fill, and these tables are read by home/desktop.nix too.
  #
  # `czkawka-gui`, verified 2026-08-08 the three-source way modules/base-packages.nix documents:
  # `pacman -Si czkawka-gui` on a live CachyOS box resolves `Repository : cachyos` -- that
  # derivative's OWN repository, not one of its `*-v3` rebuilds of an Arch one; archlinux.org's
  # package search returns ZERO results, so upstream Arch packages it nowhere; the AUR RPC returns
  # one, which is where a plain Arch host gets it.
  # `char-white`, verified the same three ways and in the same session, differs from czkawka-gui in
  # one respect that does not change the mechanism: the AUR does not carry it either (see its own
  # entry in `aurOnly` above). It is a CachyOS icon theme -- `/usr/share/icons/char-white/`, an
  # ordinary freedesktop theme directory with an `index.theme`, which is why nixdesktop reaches it
  # through `iconThemes` and not through any role table here. `Groups : cachyos`, `Architecture :
  # any`, built from github.com/CachyOS/char-white.
  #
  # THE NEAR MISS THAT BELONGS IN NEITHER LIST, recorded here because it arrives through the same
  # option and a careless application of the same method would put it in both. `breeze-icons` is
  # the other icon theme the family's Arch hosts declare, and `pacman -Si` on a CachyOS box answers
  # `Repository : cachyos-extra-v3` FIRST -- which reads like a derivative repository and is not
  # one. It is that derivative's `x86_64_v3` REBUILD of Arch's own `extra` package: same upstream,
  # same version, same name, recompiled for a newer baseline, and `pacman -Si` goes on to print the
  # `extra` entry immediately below it. archlinux.org resolves it, so the plain-Arch floor is
  # already right and there is nothing to lift. Adding it here would be actively wrong in the
  # expensive direction -- an `aurOnly` entry to lift FROM would first have to be invented, and
  # that entry would hold a perfectly resolvable package out of every plain-Arch host's pacman
  # transaction and hand it to an AUR helper that would try to BUILD KDE Frameworks from source.
  # The rule the two real entries share is what the first line of this block says: a name belongs
  # here only when upstream Arch has NO source for it, never merely because a derivative also
  # ships a copy.
  archRepoOn = {
    cachyos = [ "czkawka-gui" "char-white" ];
  };

  # Partition a resolved package list into what `pacman -S` can take and what needs an AUR helper.
  # Takes the host's declared distro (`nixarch.packages.distro`) so `archRepoOn` above can lift a
  # name back into the pacman half; a caller that has no distro to offer passes "arch", which is
  # the floor and is never wrong in the fatal direction.
  partitionAur = distro: packages:
    let
      lifted = archRepoOn.${distro} or [ ];
      fromAur = p: lib.elem p aurOnly && !(lib.elem p lifted);
    in
    {
      repo = lib.filter (p: !(fromAur p)) packages;
      aur = lib.filter fromAur packages;
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
      ++ resolve inputRemappers (want.input or null)
      ++ lib.optionals (want.launcher or null != null) [ want.launcher ]
      ++ lib.optionals (want.terminal or null != null) [ want.terminal ]

      # ── brightness AND wallpapers, WHICH THIS TABLE SIMPLY DID NOT READ ───────────────────────
      #
      # Both have been in nixdesktop's `want` contract all along and were dropped on the floor
      # here, so a host declaring them got the declaration and not the package. In practice that is
      # worse than a plainly missing package, because something else supplied them for a while and
      # then stopped:
      #
      #   · `brightnessctl` arrived only as a passenger on `compositors.niri` below. When niri was
      #     retired fleet-wide (2026-08-02) and scroll took over, nothing carried it any more -- so
      #     a box that had declared `brightness = "brightnessctl"` since April kept working purely
      #     because the package was still installed from the niri days, while a fresh install of
      #     the same declared config would have come up with dead brightness keys.
      #   · `wallpapers` was never resolved by anything at all.
      #
      # Same passthrough shape as `launcher`/`terminal` above and `iconThemes` below, for the same
      # reason: these option values ARE Arch package names (`brightness` is an enum of them,
      # `wallpapers` is a list), so there is nothing to look up and a table would only add a second
      # place to edit for an answer it could not give.
      ++ lib.optionals (want.brightness or null != null) [ want.brightness ]
      ++ (want.wallpapers or [ ])
      # Icon themes: free-form names passed through, exactly like `launcher`/`terminal` above and
      # `extraComponents` below -- nixdesktop names no theme, so there is no table to look one up
      # in. They still go through `partitionAur` in ../modules/desktop-backend.nix like every other
      # name here, which is what lets a theme that only one derivative's repository carries be
      # handled correctly rather than aborting a plain Arch host's whole pacman transaction.
      ++ (want.iconThemes or [ ])
      ++ lib.concatLists (lib.mapAttrsToList
        (name: pkgs: lib.optionals (want.${name} or false) pkgs)
        capabilities)
      ++ (want.extraComponents or [ ])
    );
}
