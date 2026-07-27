# checks/default.nix
#
# EVAL-TIME checks for nixarch's system-manager modules. No build, no VM: every check evaluates
# a `lib.evalModules` tree over just the module(s) under test -- stubbing the option surface only
# system-manager itself (or nixdesktop, for desktop-backend) would normally provide
# (systemd.services, environment.systemPackages, users.groups) -- and then inspects what the
# module RENDERS into `config`. This is the same trick experiments/desktop-backend-eval.nix and
# experiments/gcroot-guard-eval.nix already used ad hoc; this file is the permanent, wired-once
# version of that pattern, covering every module nixarch ships except foreign-service.nix and the
# ai-workstation profile (not yet covered -- see checks/README.md).
#
# These check the module's OUTPUT VALUES (units, package lists, gid maps), never runtime behavior
# on a real box: whether pacman actually converges, whether grpconv actually heals gshadow,
# whether the gcroot really gets rooted are all facts about a live machine, and deliberately out
# of scope here -- see the header comments on modules/gcroot-guard.nix and
# experiments/gcroot-guard-eval.nix for what WAS verified against a live CachyOS box.
{ nixpkgs ? <nixpkgs>
, nixdesktop ? ../../nixdesktop
  # Threaded in rather than left to `builtins.currentSystem`, which does not exist during pure
  # flake evaluation — reaching for it is what kept this suite unreachable from `flake check`.
  # The default preserves the standalone `nix-instantiate --eval` invocation documented below.
, system ? builtins.currentSystem
}:
let
  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;
  roles = import ../lib/desktop-roles.nix { inherit lib; };
  hostPaths = import ../lib/host-path.nix { inherit lib; };

  # Stub of the surface only system-manager itself provides. `systemd.services` and
  # `users.groups` are deliberately typed as opaque `attrsOf attrs` (mergeOneOption), exactly the
  # way experiments/gcroot-guard-eval.nix already does it: with a single definition per key --
  # which is all any module here ever provides, since none of them are merging with a second
  # module's opinion about the same unit -- the module system hands the raw authored value
  # straight back, INCLUDING any `lib.mkForce` wrapper left unresolved. `unwrap` below undoes
  # that where a check needs the plain value underneath.
  systemManagerSurfaceStub = { lib, ... }: {
    options = {
      systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
      users.groups = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
    };
  };

  unwrap = v: if lib.isAttrs v && (v._type or null) == "override" then v.content else v;

  check = name: ok: detail: { inherit name ok detail; };

  # Evaluate one or more nixarch modules against the stub above, plus whatever config a test
  # needs. `pkgs` is threaded in via `_module.args` because several modules call
  # `pkgs.writeShellScript`/`pkgs.writeShellApplication` directly (not via `config._module.args.pkgs`
  # the way a real system-manager evaluation supplies it).
  evalMod = modules: (lib.evalModules {
    modules = [ systemManagerSurfaceStub { _module.args.pkgs = pkgs; } ] ++ modules;
  }).config;

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # packages (modules/packages.nix)
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalPackages = extraConfig: evalMod [ ../modules/packages.nix extraConfig ];

  pkgsDefault = evalPackages { nixarch.packages.enable = true; };
  pkgsDeclared = evalPackages {
    nixarch.packages = {
      enable = true;
      pacman = [ "git" "vim" ];
      aur = [ "yay" ];
    };
  };
  # Two separate modules contributing to the same list -- the shape desktop-backend.nix's
  # `resolved ++ cfg.extraPacman` and a host's own extra list actually produce together on a
  # real box (see modules/desktop-backend.nix's own comment: "a plain listOf at the default
  # priority, so this concatenates with a consumer's own list rather than fighting it").
  pkgsMultiModule = evalMod [
    ../modules/packages.nix
    { nixarch.packages = { enable = true; pacman = [ "git" ]; }; }
    { nixarch.packages.pacman = [ "curl" ]; }
  ];
  pkgsDisabled = evalPackages { };
  pkgsPruneOn = evalPackages { nixarch.packages = { enable = true; pruneUndeclared = true; }; };
  # A consumer who sets `keep` at all: the default is gone, so only the module's own
  # non-overridable union can still protect the package manager here.
  pkgsKeepOverridden = evalPackages {
    nixarch.packages = { enable = true; pruneUndeclared = true; keep = [ "cachyos-keyring" ]; };
  };
  # A derivative host that ALSO overrides `keep` for its own unrelated reasons: the distro floor
  # must survive that, on the same terms as the Arch one.
  pkgsCachyos = evalPackages {
    nixarch.packages = {
      enable = true;
      pruneUndeclared = true;
      distro = "cachyos";
      keep = [ "something-unrelated" ];
    };
  };
  pkgsExtraCritical = evalPackages {
    nixarch.packages = {
      enable = true;
      distro = "arch";
      extraCriticalKeep = [ "endeavouros-keyring" ];
      keep = [ "something-unrelated" ];
    };
  };

  packagesChecks = [
    (check "packages/pacman-declared-round-trips"
      (pkgsDeclared.nixarch.packages.pacman == [ "git" "vim" ])
      "got: ${builtins.toJSON pkgsDeclared.nixarch.packages.pacman}")

    (check "packages/aur-declared-round-trips"
      (pkgsDeclared.nixarch.packages.aur == [ "yay" ])
      "got: ${builtins.toJSON pkgsDeclared.nixarch.packages.aur}")

    (check "packages/pacman-default-empty"
      (pkgsDefault.nixarch.packages.pacman == [ ])
      "got: ${builtins.toJSON pkgsDefault.nixarch.packages.pacman}")

    (check "packages/multi-module-pacman-list-concatenates"
      (lib.elem "git" pkgsMultiModule.nixarch.packages.pacman
        && lib.elem "curl" pkgsMultiModule.nixarch.packages.pacman)
      "got: ${builtins.toJSON pkgsMultiModule.nixarch.packages.pacman}")

    # The safety property the module's own header calls "DANGEROUS" in capitals: pruneUndeclared
    # runs `pacman -Rns` on a real machine for anything not declared, and pacman has no concept
    # of "installed before this declaration existed" -- a wrong or incomplete list can uninstall
    # things a caller genuinely needs, with no atomic undo. It must stay off unless a caller
    # deliberately opts in.
    (check "packages/prune-undeclared-defaults-off"
      (pkgsDefault.nixarch.packages.pruneUndeclared == false)
      "got: ${builtins.toJSON pkgsDefault.nixarch.packages.pruneUndeclared}")

    (check "packages/prune-undeclared-explicit-opt-in-works"
      (pkgsPruneOn.nixarch.packages.pruneUndeclared == true)
      "got: ${builtins.toJSON pkgsPruneOn.nixarch.packages.pruneUndeclared}")

    # The floor a consumer never touches.
    (check "packages/keep-default-floor"
      (pkgsDefault.nixarch.packages.keep == [ "base" "base-devel" ])
      "got: ${builtins.toJSON pkgsDefault.nixarch.packages.keep}")

    # THE ONE THAT MATTERS. `keep` is a plain listOf, so a consumer who SETS it replaces the
    # default outright -- meaning any protection expressed only as a default evaporates the
    # moment someone customises, which is exactly when they are most likely to have forgotten
    # something. The package manager is therefore union'd in by the module itself and must
    # survive an override that mentions none of it. Asserted against `effectiveKeep`, the
    # read-only option that IS what the reconciler interpolates -- reading the rendered script
    # instead would force a build and break the eval-only property of this suite.
    (check "packages/prune-cannot-delete-the-package-manager"
      (builtins.all (p: lib.elem p pkgsKeepOverridden.nixarch.packages.effectiveKeep)
        [ "pacman" "archlinux-keyring" "pacman-mirrorlist" ])
      "consumer set keep = [ cachyos-keyring ]; effectiveKeep = ${builtins.toJSON pkgsKeepOverridden.nixarch.packages.effectiveKeep}")

    # THE SAME PROPERTY ONE DISTRO LAYER DOWN. A derivative serves its own repos from its own
    # mirrorlists signed by its own keyring; those packages are the precondition for fetching
    # anything, so pruning them leaves a machine that cannot reinstall them. Before `distro`
    # existed this was the consumer's job via `keep` -- which is the one place it could not
    # safely live, because setting `keep` for any unrelated reason silently dropped it. Asserted
    # against a config that does exactly that.
    (check "packages/prune-cannot-delete-a-derivative-package-manager"
      (builtins.all (p: lib.elem p pkgsCachyos.nixarch.packages.effectiveKeep)
        [ "cachyos-keyring" "cachyos-mirrorlist" "cachyos-v3-mirrorlist" "cachyos-v4-mirrorlist" "cachyos-hooks" ])
      "distro = cachyos with keep = [ something-unrelated ]; effectiveKeep = ${builtins.toJSON pkgsCachyos.nixarch.packages.effectiveKeep}")

    # ADDITIVE, not a replacement: on CachyOS `[core]`/`[extra]`/`[multilib]` still resolve
    # through Arch's own /etc/pacman.d/mirrorlist, so both keyrings and both mirrorlists are
    # load-bearing. Verified against a live box; this pins it.
    (check "packages/derivative-floor-adds-to-the-arch-floor"
      (builtins.all (p: lib.elem p pkgsCachyos.nixarch.packages.effectiveKeep)
        [ "pacman" "archlinux-keyring" "pacman-mirrorlist" ])
      "distro = cachyos; effectiveKeep = ${builtins.toJSON pkgsCachyos.nixarch.packages.effectiveKeep}")

    # A plain Arch host must NOT acquire another distro's packages -- the floor is selected, not
    # accumulated. Without this, adding a distro to the table could silently widen every host.
    (check "packages/arch-default-carries-no-derivative-floor"
      (!lib.elem "cachyos-keyring" pkgsPruneOn.nixarch.packages.effectiveKeep)
      "distro defaults to arch; effectiveKeep = ${builtins.toJSON pkgsPruneOn.nixarch.packages.effectiveKeep}")

    # The escape hatch for a derivative the table does not model yet, on the same
    # survives-an-override terms as the built-ins.
    (check "packages/extra-critical-keep-survives-a-keep-override"
      (lib.elem "endeavouros-keyring" pkgsExtraCritical.nixarch.packages.effectiveKeep
        && lib.elem "pacman" pkgsExtraCritical.nixarch.packages.effectiveKeep)
      "effectiveKeep = ${builtins.toJSON pkgsExtraCritical.nixarch.packages.effectiveKeep}")

    (check "packages/unit-exists-when-enabled"
      (pkgsDeclared.systemd.services ? "nixarch-packages-reconcile")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames pkgsDeclared.systemd.services)}")

    (check "packages/unit-absent-when-disabled"
      (pkgsDisabled.systemd.services == { })
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames pkgsDisabled.systemd.services)}")

    (check "packages/unit-wanted-by-multi-user-target"
      (lib.elem "multi-user.target" (pkgsDeclared.systemd.services.nixarch-packages-reconcile.wantedBy or [ ]))
      "wantedBy: ${builtins.toJSON (pkgsDeclared.systemd.services.nixarch-packages-reconcile.wantedBy or null)}")

    # system-manager injects a nix-store-only PATH into every unit it declares (lib/host-path.nix)
    # -- without the `lib.mkForce` this checks for, pacman/runuser would silently fail to resolve
    # on a real activation.
    (check "packages/unit-path-forced-to-host-tools"
      ((unwrap (pkgsDeclared.systemd.services.nixarch-packages-reconcile.environment.PATH or null)) == hostPaths.hostPath)
      "got: ${builtins.toJSON (unwrap (pkgsDeclared.systemd.services.nixarch-packages-reconcile.environment.PATH or null))}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # device-gids (modules/device-gids.nix)
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalDeviceGids = extraConfig: evalMod [ ../modules/device-gids.nix extraConfig ];

  gidsRendered = evalDeviceGids {
    nixarch.deviceGidsEnable = true;
    nixarch.deviceGids = { render = 501; video = 502; };
  };
  gidsWithTty = evalDeviceGids {
    nixarch.deviceGidsEnable = true;
    nixarch.deviceGids = { tty = 5; };
  };
  gidsEmptyMap = evalDeviceGids {
    nixarch.deviceGidsEnable = true;
    nixarch.deviceGids = { };
  };
  gidsDisabledWithMap = evalDeviceGids {
    nixarch.deviceGidsEnable = false;
    nixarch.deviceGids = { render = 501; };
  };

  deviceGidsChecks = [
    (check "device-gids/gid-map-renders-render"
      ((unwrap (gidsRendered.users.groups.render.gid or null)) == 501)
      "got: ${builtins.toJSON (unwrap (gidsRendered.users.groups.render.gid or null))}")

    (check "device-gids/gid-map-renders-video"
      ((unwrap (gidsRendered.users.groups.video.gid or null)) == 502)
      "got: ${builtins.toJSON (unwrap (gidsRendered.users.groups.video.gid or null))}")

    (check "device-gids/migrate-unit-exists-when-map-non-empty"
      (gidsRendered.systemd.services ? "gid-migrate")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames gidsRendered.systemd.services)}")

    (check "device-gids/devpts-unit-absent-without-tty"
      (!(gidsRendered.systemd.services ? "devpts-gid"))
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames gidsRendered.systemd.services)}")

    (check "device-gids/devpts-unit-present-with-tty"
      (gidsWithTty.systemd.services ? "devpts-gid")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames gidsWithTty.systemd.services)}")

    (check "device-gids/devpts-execstart-carries-tty-gid-and-defaults"
      (let execStart = gidsWithTty.systemd.services.devpts-gid.serviceConfig.ExecStart or [ ];
       in lib.any (l: lib.hasInfix "gid=5,mode=620,ptmxmode=666" l) execStart)
      "ExecStart: ${builtins.toJSON (gidsWithTty.systemd.services.devpts-gid.serviceConfig.ExecStart or null)}")

    (check "device-gids/devpts-chgrp-step-is-tolerant"
      (let execStart = gidsWithTty.systemd.services.devpts-gid.serviceConfig.ExecStart or [ ];
       in lib.any (l: lib.hasPrefix "-" l && lib.hasInfix "chgrp" l) execStart)
      "ExecStart: ${builtins.toJSON (gidsWithTty.systemd.services.devpts-gid.serviceConfig.ExecStart or null)}")

    # An empty map is a genuine no-op, not an empty-but-present unit -- the module's own header
    # promises exactly this ("With an empty map it is a complete no-op").
    (check "device-gids/empty-map-is-a-no-op-groups"
      (gidsEmptyMap.users.groups == { })
      "got: ${builtins.toJSON gidsEmptyMap.users.groups}")

    (check "device-gids/empty-map-is-a-no-op-services"
      (gidsEmptyMap.systemd.services == { })
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames gidsEmptyMap.systemd.services)}")

    (check "device-gids/disabled-with-populated-map-is-inert"
      (gidsDisabledWithMap.users.groups == { } && gidsDisabledWithMap.systemd.services == { })
      "users.groups: ${builtins.toJSON gidsDisabledWithMap.users.groups}, systemd.services: ${builtins.toJSON (builtins.attrNames gidsDisabledWithMap.systemd.services)}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # gshadow-sync (modules/gshadow-sync.nix)
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalGshadowSync = extraConfig: evalMod [ ../modules/gshadow-sync.nix extraConfig ];

  gshadowEnabled = evalGshadowSync { nixarch.gshadowSync.enable = true; };
  gshadowDisabled = evalGshadowSync { };

  gshadowSyncChecks = [
    (check "gshadow-sync/unit-exists-when-enabled"
      (gshadowEnabled.systemd.services ? "gshadow-sync")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames gshadowEnabled.systemd.services)}")

    (check "gshadow-sync/unit-wanted-by-multi-user-and-shadow-service"
      (let w = gshadowEnabled.systemd.services.gshadow-sync.wantedBy or [ ];
       in lib.elem "multi-user.target" w && lib.elem "shadow.service" w)
      "wantedBy: ${builtins.toJSON (gshadowEnabled.systemd.services.gshadow-sync.wantedBy or null)}")

    (check "gshadow-sync/unit-ordered-before-shadow-service"
      (lib.elem "shadow.service" (gshadowEnabled.systemd.services.gshadow-sync.before or [ ]))
      "before: ${builtins.toJSON (gshadowEnabled.systemd.services.gshadow-sync.before or null)}")

    (check "gshadow-sync/unit-ordered-after-userborn-and-gid-migrate"
      (let a = gshadowEnabled.systemd.services.gshadow-sync.after or [ ];
       in lib.elem "userborn.service" a && lib.elem "gid-migrate.service" a)
      "after: ${builtins.toJSON (gshadowEnabled.systemd.services.gshadow-sync.after or null)}")

    # NOT RemainAfterExit, on purpose (module comment): the unit must be startable again for the
    # shadow.service pull-in to actually re-run it every day.
    (check "gshadow-sync/unit-is-oneshot-and-not-remain-after-exit"
      (gshadowEnabled.systemd.services.gshadow-sync.serviceConfig.Type or null == "oneshot"
        && !((gshadowEnabled.systemd.services.gshadow-sync.serviceConfig or { }) ? "RemainAfterExit"))
      "serviceConfig: ${builtins.toJSON (gshadowEnabled.systemd.services.gshadow-sync.serviceConfig or null)}")

    (check "gshadow-sync/disabled-contributes-nothing"
      (gshadowDisabled.systemd.services == { })
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames gshadowDisabled.systemd.services)}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # desktop-backend (modules/desktop-backend.nix) -- needs a nixdesktop checkout, see the
  # function's `nixdesktop` arg above. Mirrors experiments/desktop-backend-eval.nix, which this
  # supersedes as the permanently-run version of the same check.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  # Stub of the surface `nixarch.packages` provides -- deliberately NOT `../modules/packages.nix`
  # itself, which declares `systemd.services` and would need the system-manager surface stub too.
  # What is under test here is role resolution into `nixarch.packages.pacman`, and this option
  # alone is the entire contract desktop-backend.nix has with the reconciler.
  desktopBackendStub = { lib, ... }: {
    options.nixarch.packages = {
      enable = lib.mkEnableOption "stub";
      pacman = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalDesktopBackend = extraConfig: (lib.evalModules {
    modules = [
      # Path concatenation, NOT "${nixdesktop}/..." -- string interpolation of a path copies the
      # whole checkout (.git and all) into the store and then fails on it. This imports one file.
      (nixdesktop + "/profiles/niri-desktop.nix")
      ../modules/desktop-backend.nix
      desktopBackendStub
      extraConfig
    ];
  }).config;

  desktopDefault = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend = { enable = true; extraPacman = [ "blueman" ]; };
    nixdesktop.niriDesktop.enable = true; # defaults: thunar, mate-polkit, waybar, foot...
  };
  pacmanDefault = desktopDefault.nixarch.packages.pacman;

  # Positive control for the no-KDE check below: prove polkit-kde-agent CAN appear on an
  # explicit opt-in, so "never by default" isn't vacuously true because the role can never
  # resolve to it at all.
  desktopKdeOptIn = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.niriDesktop = { enable = true; polkitAgent = "polkit-kde-agent"; };
  };
  pacmanKdeOptIn = desktopKdeOptIn.nixarch.packages.pacman;

  desktopProfileDisabled = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.niriDesktop.enable = false;
  };

  # Gated on a nixdesktop checkout being reachable. nixarch deliberately does NOT take nixdesktop
  # as a flake input -- the family contract's R4 is that modules couple by option value, never by
  # dependency edge, and this backend reads `nixdesktop.want` precisely so no edge is needed. That
  # means the flake cannot hand these checks a nixdesktop path, so `nix flake check` runs the suite
  # WITHOUT them and the standalone invocation (which resolves a sibling checkout) runs them.
  # The count of what was skipped is reported rather than swallowed -- see the derivation below.
  desktopBackendChecks = if nixdesktop == null then [ ] else [
    (check "desktop-backend/file-manager-role-resolved"
      (lib.elem "thunar" pacmanDefault && lib.elem "tumbler" pacmanDefault && lib.elem "gvfs" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/polkit-agent-role-resolved"
      (lib.elem "mate-polkit" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/compositor-role-resolved"
      (lib.elem "niri" pacmanDefault && lib.elem "brightnessctl" pacmanDefault && lib.elem "playerctl" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/capability-roles-resolved"
      (lib.elem "grim" pacmanDefault && lib.elem "slurp" pacmanDefault
        && lib.elem "swayidle" pacmanDefault && lib.elem "swaylock" pacmanDefault
        && lib.elem "cliphist" pacmanDefault && lib.elem "wl-clipboard" pacmanDefault
        && lib.elem "xwayland-satellite" pacmanDefault
        && lib.elem "xdg-desktop-portal-gnome" pacmanDefault && lib.elem "xdg-desktop-portal-gtk" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/extra-pacman-applied"
      (lib.elem "blueman" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    # THE regression this suite exists to catch: the old profile defaulted polkitAgent to
    # polkit-kde-agent, so an unopinionated consumer silently got a KDE Frameworks stack
    # reinstalled on every activation. See nixdesktop's profiles/niri-desktop.nix header and
    # lib/desktop-roles.nix's polkitAgents table.
    (check "desktop-backend/no-kde-packages-by-default"
      (!(lib.elem "polkit-kde-agent" pacmanDefault) && !(lib.elem "qt6ct" pacmanDefault))
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/kde-packages-appear-on-explicit-opt-in"
      (lib.elem "polkit-kde-agent" pacmanKdeOptIn && lib.elem "qt6ct" pacmanKdeOptIn)
      "pacman: ${builtins.toJSON pacmanKdeOptIn}")

    # The system layer installs the package; the user layer (home/desktop.nix) spawns its binary
    # by absolute path. Both read lib/desktop-roles.nix's tables directly instead of one
    # importing the other -- this is the check that they cannot silently drift apart.
    (check "desktop-backend/system-and-user-layers-agree-on-mate-polkit"
      (let r = roles.polkitAgents.mate-polkit;
       in lib.elem (lib.head r.packages) pacmanDefault && lib.hasPrefix "/usr/lib/mate-polkit/" r.command)
      "packages: ${builtins.toJSON roles.polkitAgents.mate-polkit.packages}, command: ${roles.polkitAgents.mate-polkit.command}")

    (check "desktop-backend/disabled-nixdesktop-profile-is-inert"
      (desktopProfileDisabled.nixarch.packages.pacman == [ ])
      "got: ${builtins.toJSON desktopProfileDisabled.nixarch.packages.pacman}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # gcroot-guard (modules/gcroot-guard.nix) -- lifted from experiments/gcroot-guard-eval.nix,
  # which this supersedes as the permanently-run version of the same check.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalGcrootGuard = extraConfig: evalMod [ ../modules/gcroot-guard.nix extraConfig ];

  gcrootDefault = evalGcrootGuard { nixarch.gcrootGuard.enable = true; };
  gcrootLoud = evalGcrootGuard { nixarch.gcrootGuard = { enable = true; failLoudly = true; }; };
  gcrootQuiet = evalGcrootGuard { nixarch.gcrootGuard = { enable = true; failLoudly = false; }; };
  gcrootOff = evalGcrootGuard { nixarch.gcrootGuard.enable = false; };

  gcrootLoudPath = unwrap (gcrootLoud.systemd.services.nixarch-gcroot-guard.environment.PATH or null);
  gcrootLoudExecStart = unwrap (gcrootLoud.systemd.services.nixarch-gcroot-guard.serviceConfig.ExecStart or null);
  gcrootQuietExecStart = unwrap (gcrootQuiet.systemd.services.nixarch-gcroot-guard.serviceConfig.ExecStart or null);

  gcrootGuardChecks = [
    # The unit shells out to nix-store, which is precisely the binary missing from
    # system-manager's injected PATH -- the same gap this module exists to catch. Without this
    # PATH the check cannot even run, let alone catch the real bug.
    (check "gcroot-guard/unit-path-reaches-nix-store"
      (lib.hasInfix hostPaths.nixPath gcrootLoudPath)
      "PATH: ${builtins.toJSON gcrootLoudPath}")

    (check "gcroot-guard/unit-path-also-carries-host-tools"
      (lib.hasInfix "/usr/bin" gcrootLoudPath)
      "PATH: ${builtins.toJSON gcrootLoudPath}")

    (check "gcroot-guard/fail-loudly-defaults-true"
      (gcrootDefault.nixarch.gcrootGuard.failLoudly == true)
      "got: ${builtins.toJSON gcrootDefault.nixarch.gcrootGuard.failLoudly}")

    (check "gcroot-guard/fail-loudly-execstart-has-no-dash-prefix"
      (!(lib.hasPrefix "-" gcrootLoudExecStart))
      "ExecStart: ${builtins.toJSON gcrootLoudExecStart}")

    # failLoudly = false must flip the "-" prefix that tells systemd to record the failure
    # without marking the unit failed -- the one bit of behavior the whole option exists for.
    (check "gcroot-guard/fail-loudly-false-flips-execstart-prefix"
      (lib.hasPrefix "-" gcrootQuietExecStart)
      "ExecStart: ${builtins.toJSON gcrootQuietExecStart}")

    (check "gcroot-guard/disabled-is-inert"
      (gcrootOff.systemd.services == { } && gcrootOff.environment.systemPackages == [ ])
      "systemd.services: ${builtins.toJSON (builtins.attrNames gcrootOff.systemd.services)}, environment.systemPackages: ${builtins.toJSON gcrootOff.environment.systemPackages}")

    # The wrapper is installed so the error message's suggested fix ("sudo nixarch-register")
    # actually exists on the box.
    (check "gcroot-guard/ships-register-wrapper-when-enabled"
      (lib.length gcrootLoud.environment.systemPackages == 1)
      "environment.systemPackages: ${builtins.toJSON gcrootLoud.environment.systemPackages}")
  ];

  results = packagesChecks ++ deviceGidsChecks ++ gshadowSyncChecks ++ desktopBackendChecks ++ gcrootGuardChecks;

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n"
    (r: "  - ${r.name}: ${r.detail}")
    failed;
in
if failed != [ ]
then throw ''
  nixarch eval-checks FAILED (${toString (builtins.length failed)}/${toString (builtins.length results)}):
  ${report}
''
else {
  # Constructing this derivation depends on `passedCount`, which forces `results` (and therefore
  # every `check` assertion above) even if nothing else ever reads the attribute -- so the checks
  # really do run, not just get defined.
  eval-checks = pkgs.runCommand "nixarch-eval-checks"
    {
      passedCount = toString (builtins.length results);
      # NOT silent: a suite that quietly covers less than it appears to is the failure this
      # whole file exists to prevent, and it already happened once -- these assertions sat
      # unreachable from any flake output and reported success without running.
      skipped = if nixdesktop == null
        then "desktop-backend (no nixdesktop checkout; run standalone for those)"
        else "none";
    }
    ''
      echo "all $passedCount nixarch eval checks passed"
      echo "skipped: $skipped"
      touch $out
    '';
}
