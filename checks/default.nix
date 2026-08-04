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
  # `lib.probeFact` (github:julian-corbet/nixhost-corbet-ch) -- device-gids.nix now takes this as
  # a closed-over function argument (see its own header + flake.nix's input comment), so its
  # checks need one too. Defaults to resolving a sibling checkout the same way `nixdesktop` above
  # does for the standalone invocation; `flake.nix`'s own `checks` composition overrides this with
  # the REAL locked `nixhost.lib.probeFact` from its own flake input.
, probeFact ? (import (../../nixhost + "/lib/facts.nix") { lib = (import nixpkgs { inherit system; }).lib; }).probeFact
}:
let
  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;
  roles = import ../lib/desktop-roles.nix { inherit lib; };
  hostPaths = import ../lib/host-path.nix { inherit lib; };
  deviceGidsModule = import ../modules/device-gids.nix { inherit probeFact; };

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
      # A real system-manager/NixOS tree declares these itself (the assertions/warnings
      # machinery); this hand-stubbed surface has to, too, now that device-gids.nix's own
      # `probeFact` adoption writes to `config.warnings`.
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = [ ]; };
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

  # pruneOrphans is a SEPARATE toggle from pruneUndeclared above -- deliberately not combined
  # with pkgsPruneOn, so the checks below can prove the two do not silently imply each other.
  pkgsOrphanPruneOn = evalPackages { nixarch.packages = { enable = true; pruneOrphans = true; }; };
  # The orphan sweep reuses the exact same `keep_list` computation as pruneUndeclared (see
  # `expand_keep` in modules/packages.nix) -- this proves the package-manager floor survives a
  # `keep` override on THIS path too, not just pruneUndeclared's.
  pkgsOrphanKeepOverridden = evalPackages {
    nixarch.packages = { enable = true; pruneOrphans = true; keep = [ "something-unrelated" ]; };
  };
  pkgsOrphanMaxRoundsCustom = evalPackages {
    nixarch.packages = { enable = true; pruneOrphans = true; orphanSweepMaxRounds = 3; };
  };

  # AUR-isolation (step 2 of the reconcile script): a batch AUR failure must not silently drop
  # every OTHER declared AUR package (the defect this step exists to prevent -- see
  # modules/packages.nix's own header comment on this step for the zoom/sway-scroll/evdi-dkms
  # case that motivated it). These read the STATIC TEXT of the actual generated reconcile script
  # via `pkgs.writeShellScript`'s own `.text` passthru -- the literal string handed to it, which
  # Nix can read at eval time with no build/store-realisation of the script itself. That proves
  # the SHAPE of the control flow (the batch attempt is `if`-guarded rather than bare; a
  # per-package fallback loop exists and is reachable; a partial failure is tracked into a
  # non-zero exit) is really present in the module's own output, not a hand-copied duplicate of
  # it living only in this test file. It does NOT prove paru/pacman actually behave this way when
  # invoked on a live box -- that is a fact about a running system, out of reach for any amount of
  # Nix evaluation; see checks/README.md's "Is/Isn't" section. That side was instead verified by
  # rendering this exact script and running it under stubbed pacman/paru/runuser (one run with a
  # bad package isolated and everything else still installing; one clean run proving the batch
  # attempt alone still costs the one invocation it always did) -- a transcript, not something
  # this suite can re-check on every `nix flake check` without a real Arch box to run pacman on.
  pkgsAurWithUser = evalPackages {
    nixarch.packages = { enable = true; aur = [ "yay" "zoom" ]; aurUser = "julian"; };
  };
  aurWithUserText = pkgsAurWithUser.nixarch.packages.reconcileScript.text;
  # `aurUser` left at its null default: the whole fallback branch is compiled OUT, not merely
  # unreachable -- `pkgsDeclared` already covers `aur = [ "yay" ]` with no `aurUser` set.
  noAurUserText = pkgsDeclared.nixarch.packages.reconcileScript.text;

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

    # pruneOrphans: the separate, `-Qdtq`-keyed sweep. Same off-by-default safety posture as
    # pruneUndeclared, proven the same way.
    (check "packages/prune-orphans-defaults-off"
      (pkgsDefault.nixarch.packages.pruneOrphans == false)
      "got: ${builtins.toJSON pkgsDefault.nixarch.packages.pruneOrphans}")

    (check "packages/prune-orphans-explicit-opt-in-works"
      (pkgsOrphanPruneOn.nixarch.packages.pruneOrphans == true)
      "got: ${builtins.toJSON pkgsOrphanPruneOn.nixarch.packages.pruneOrphans}")

    # The two prune paths are INDEPENDENT toggles -- turning one on must never silently flip
    # the other, since they sweep structurally different things (explicit vs. dependency-reason
    # installs) and a caller may legitimately want only one.
    (check "packages/prune-orphans-does-not-imply-prune-undeclared"
      (pkgsOrphanPruneOn.nixarch.packages.pruneUndeclared == false)
      "got: ${builtins.toJSON pkgsOrphanPruneOn.nixarch.packages.pruneUndeclared}")

    (check "packages/prune-undeclared-does-not-imply-prune-orphans"
      (pkgsPruneOn.nixarch.packages.pruneOrphans == false)
      "got: ${builtins.toJSON pkgsPruneOn.nixarch.packages.pruneOrphans}")

    (check "packages/orphan-sweep-max-rounds-default"
      (pkgsDefault.nixarch.packages.orphanSweepMaxRounds == 5)
      "got: ${builtins.toJSON pkgsDefault.nixarch.packages.orphanSweepMaxRounds}")

    (check "packages/orphan-sweep-max-rounds-round-trips"
      (pkgsOrphanMaxRoundsCustom.nixarch.packages.orphanSweepMaxRounds == 3)
      "got: ${builtins.toJSON pkgsOrphanMaxRoundsCustom.nixarch.packages.orphanSweepMaxRounds}")

    # THE SAME PROPERTY `prune-cannot-delete-the-package-manager` proves for pruneUndeclared,
    # proven on the orphan-sweep path too: both prune blocks call the same `expand_keep` helper
    # over the same `keep_list`, so this pins that the sharing is real rather than incidental --
    # if a future edit gave pruneOrphans its own, un-union'd keep computation, this would catch it.
    (check "packages/prune-orphans-cannot-delete-the-package-manager"
      (builtins.all (p: lib.elem p pkgsOrphanKeepOverridden.nixarch.packages.effectiveKeep)
        [ "pacman" "archlinux-keyring" "pacman-mirrorlist" ])
      "consumer set keep = [ something-unrelated ] with pruneOrphans = true; effectiveKeep = ${builtins.toJSON pkgsOrphanKeepOverridden.nixarch.packages.effectiveKeep}")

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
    # anything, so pruning them leaves a machine that cannot reinstall them. `keep` alone cannot
    # safely hold this: setting it for any unrelated reason would silently drop it. Asserted
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

    # The happy-path cost claim: the FIRST AUR attempt is still one invocation over the whole
    # declared list, exactly as before this step existed -- not a pre-emptive one-by-one loop
    # that would pay the extra cost on every run instead of only a failed one.
    (check "packages/aur-batch-attempt-covers-the-whole-list-in-one-call"
      (lib.hasInfix ''-- paru -S --needed --noconfirm "''${assume_args[@]}" "''${aur_pkgs[@]}"'' aurWithUserText)
      "reconcileScript.text did not contain the expected one-shot batch invocation")

    # The batch attempt must be the CONDITION of an `if`, not a bare statement -- a bare failing
    # command in this position is exactly what let `set -eu` kill the whole reconcile on one bad
    # AUR package (see modules/packages.nix's header comment on this step).
    (check "packages/aur-batch-attempt-is-if-guarded-not-bare"
      (lib.hasInfix "if runuser -u julian -- paru -S --needed --noconfirm" aurWithUserText)
      "reconcileScript.text did not contain an `if`-guarded runuser invocation")

    # The fallback: on batch failure, isolate by trying each declared AUR package on its own.
    (check "packages/aur-batch-failure-falls-back-per-package"
      (lib.hasInfix "falling back to one" aurWithUserText
        && lib.hasInfix "for pkg in" aurWithUserText)
      "reconcileScript.text is missing the per-package fallback loop")

    # Isolating the failure must not also HIDE it -- see this step's own header comment. Both the
    # bookkeeping (which package(s) failed, collected rather than dropped) and the consequence (a
    # non-zero exit, the only thing that makes systemd itself show the unit as failed) must
    # survive in the generated script.
    (check "packages/aur-partial-failure-is-tracked-and-reported"
      (lib.hasInfix "failed_aur+=" aurWithUserText
        && lib.hasInfix "reconcile_failed=1" aurWithUserText)
      "reconcileScript.text does not collect failed AUR package names")

    (check "packages/aur-partial-failure-exits-non-zero"
      (lib.hasInfix ''reconcile_failed:-0'' aurWithUserText
        && lib.hasInfix "exit 1" aurWithUserText)
      "reconcileScript.text does not exit non-zero on a tracked AUR failure")

    # `aurUser == null` compiles OUT the whole AUR branch (including the fallback added by this
    # step) in favour of a loud skip warning -- not merely a fallback that never gets reached.
    (check "packages/aur-fallback-absent-when-aur-user-unset"
      (!(lib.hasInfix "falling back to one" noAurUserText)
        && lib.hasInfix "aurUser is null" noAurUserText)
      "reconcileScript.text (no aurUser) unexpectedly contains AUR-fallback logic")

    # Scope check, not a regression net for step 1 itself: official-repo packages stay a bare,
    # un-isolated single command, unlike AUR -- the repo IS the source, signed and mirrored by
    # pacman, so it doesn't share AUR's exposure to a vendor rotating a pinned checksum URL out
    # from under a stale PKGBUILD (see this step's header comment). If step 1 ever grows the same
    # isolation, this check should change WITH it, deliberately, not by silent drift.
    (check "packages/pacman-step-unchanged-bare-single-command"
      (lib.hasInfix ''pacman -S --needed --noconfirm "''${assume_args[@]}" "''${pacman_pkgs[@]}"'' aurWithUserText
        && !(lib.hasInfix ''if pacman -S --needed'' aurWithUserText))
      "reconcileScript.text: step 1 (official-repo packages) no longer matches the expected bare, un-isolated shape")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # device-gids (modules/device-gids.nix)
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalDeviceGids = extraConfig: evalMod [ deviceGidsModule extraConfig ];

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

  # A minimal stand-in for nixiam's own `options.nixiam.posix.deviceGroups` (modules/posix.nix) --
  # not a checkout of that repo, since nixarch takes it as neither a flake input nor an
  # import (see modules/device-gids.nix's header). What is under test here is only that
  # device-gids.nix reads `config.nixiam.posix.deviceGroups` defensively and lets it become the
  # DEFAULT for `nixarch.deviceGids` -- the same shape nixiam's real option declares
  # (`attrsOf int`), stubbed the same way `systemManagerSurfaceStub` above stands in for
  # system-manager's own option surface.
  nixiamDeviceGroupsStub = { lib, ... }: {
    options.nixiam.posix.deviceGroups = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = { };
    };
  };

  # nixiam present, host names no explicit deviceGids of its own: the cross-host table becomes
  # the default. This is the whole point of the wiring -- see the module header's incident
  # (400-416 restated by hand on three machines with nothing asserting they agreed).
  gidsFromNixiam = (lib.evalModules {
    modules = [
      systemManagerSurfaceStub
      { _module.args.pkgs = pkgs; }
      nixiamDeviceGroupsStub
      deviceGidsModule
      { nixarch.deviceGidsEnable = true; nixiam.posix.deviceGroups = { render = 400; tty = 403; }; }
    ];
  }).config;

  # A host that DOES declare its own map keeps it, even with nixiam present and non-empty --
  # rule 2 of the wiring: a hand-typed value is never second-guessed by the default it
  # overrides.
  gidsExplicitOverridesNixiam = (lib.evalModules {
    modules = [
      systemManagerSurfaceStub
      { _module.args.pkgs = pkgs; }
      nixiamDeviceGroupsStub
      deviceGidsModule
      {
        nixarch.deviceGidsEnable = true;
        nixiam.posix.deviceGroups = { render = 400; };
        nixarch.deviceGids = { render = 999; };
      }
    ];
  }).config;

  # No nixiam stub at all -- module must still evaluate (the no-op promise in its own
  # header), exactly the host that has "never heard of nixiam" the header describes.
  gidsWithoutNixiamAtAll = evalDeviceGids { nixarch.deviceGidsEnable = true; };

  # THE BUG THIS FIX CLOSES: nixiam derives TWO entries (render, tty); a host pins only ONE of
  # them by hand -- the realistic case `gidsExplicitOverridesNixiam` above can't distinguish from
  # a full replace, because its nixiam fixture only ever has the one key the host also names.
  # Before this fix, `nixarch.deviceGids.render = 999;` sat at normal priority for the WHOLE
  # option (a bare `default = nixiamGroups;`) and wholly replaced the nixiam-derived default --
  # `tty` would have silently vanished, taking the devpts lockstep with it, with no error. See
  # the `deviceGids` option's own comment for the mechanism, and `nixaudio.fabric.peers` for the
  # live incident that first exposed it fleet-wide.
  gidsPartialOverrideKeepsSiblings = (lib.evalModules {
    modules = [
      systemManagerSurfaceStub
      { _module.args.pkgs = pkgs; }
      nixiamDeviceGroupsStub
      deviceGidsModule
      {
        nixarch.deviceGidsEnable = true;
        nixiam.posix.deviceGroups = { render = 400; tty = 403; };
        nixarch.deviceGids.render = 999;
      }
    ];
  }).config;

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

    # THE property this whole default exists for: a host that names no map of its own
    # inherits nixiam's cross-host table, including the `tty` entry driving the devpts
    # lockstep it would otherwise have had to also restate by hand.
    (check "device-gids/default-inherits-nixiam-posix-device-groups"
      (gidsFromNixiam.nixarch.deviceGids == { render = 400; tty = 403; })
      "got: ${builtins.toJSON gidsFromNixiam.nixarch.deviceGids}")

    (check "device-gids/default-from-nixiam-renders-into-users-groups"
      ((unwrap (gidsFromNixiam.users.groups.render.gid or null)) == 400)
      "got: ${builtins.toJSON (unwrap (gidsFromNixiam.users.groups.render.gid or null))}")

    (check "device-gids/default-from-nixiam-activates-devpts-lockstep"
      (gidsFromNixiam.systemd.services ? "devpts-gid")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames gidsFromNixiam.systemd.services)}")

    # A hand-typed map is never second-guessed by the default it overrides -- a host
    # carving its own numbering must be unaffected by nixiam being present at all.
    (check "device-gids/explicit-map-overrides-nixiam-default"
      (gidsExplicitOverridesNixiam.nixarch.deviceGids == { render = 999; })
      "got: ${builtins.toJSON gidsExplicitOverridesNixiam.nixarch.deviceGids}")

    # The other half of the defensiveness promise: a host that has never composed nixiam's
    # posix module in at all (no stub, no option declared for it) must still evaluate,
    # with the module staying the complete no-op its own header promises.
    (check "device-gids/no-nixiam-at-all-is-still-a-no-op"
      (gidsWithoutNixiamAtAll.nixarch.deviceGids == { }
        && gidsWithoutNixiamAtAll.users.groups == { }
        && gidsWithoutNixiamAtAll.systemd.services == { })
      "deviceGids: ${builtins.toJSON gidsWithoutNixiamAtAll.nixarch.deviceGids}, users.groups: ${builtins.toJSON gidsWithoutNixiamAtAll.users.groups}, systemd.services: ${builtins.toJSON (builtins.attrNames gidsWithoutNixiamAtAll.systemd.services)}")

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

    (check "device-gids/partial-override-keeps-untouched-nixiam-siblings"
      (gidsPartialOverrideKeepsSiblings.nixarch.deviceGids == { render = 999; tty = 403; })
      "got: ${builtins.toJSON gidsPartialOverrideKeepsSiblings.nixarch.deviceGids}")

    (check "device-gids/partial-override-keeps-devpts-lockstep-from-untouched-tty"
      (gidsPartialOverrideKeepsSiblings.systemd.services ? "devpts-gid")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames gidsPartialOverrideKeepsSiblings.systemd.services)}")
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
  # What is under test here is role resolution into `nixarch.packages.{pacman,aur}`, and those two
  # options are the entire contract desktop-backend.nix has with the reconciler.
  #
  # BOTH halves must be stubbed, not just the one a given check reads. A stub narrower than the
  # real option surface does not fail where it is incomplete -- it fails wherever the module under
  # test writes an option the stub omits, with "the option does not exist" pointing at
  # desktop-backend.nix rather than at this file. That is what happened when packages.nix split AUR
  # names out of `pacman` into their own `aur` list: desktop-backend.nix followed the split, and
  # this stub silently became a narrower surface than the thing it stands in for.
  desktopBackendStub = { lib, ... }: {
    options.nixarch.packages = {
      enable = lib.mkEnableOption "stub";
      pacman = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      aur = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  evalDesktopBackend = extraConfig: (lib.evalModules {
    modules = [
      # Path concatenation, NOT "${nixdesktop}/..." -- string interpolation of a path copies the
      # whole checkout (.git and all) into the store and then fails on it. This imports one file.
      (nixdesktop + "/profiles/desktop.nix")
      ../modules/desktop-backend.nix
      desktopBackendStub
      extraConfig
    ];
  }).config;

  # `compositor` has no default and is therefore mandatory wherever the profile is ENABLED:
  # nixdesktop draws no distinction between compositors and refuses to prefer one, so the consumer
  # must name it. It is deliberately absent from `desktopProfileDisabled` below -- a disabled
  # profile resolves `nixdesktop.want` to `{}` without ever reading it, and setting it there would
  # hide a regression that made the option load-bearing even when the desktop is off.
  desktopDefault = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend = { enable = true; extraPacman = [ "blueman" ]; };
    # defaults: thunar, mate-polkit, waybar, foot...
    nixdesktop.desktop = { enable = true; compositor = "niri"; };
  };
  pacmanDefault = desktopDefault.nixarch.packages.pacman;

  # Positive control for the no-KDE check below: prove polkit-kde-agent CAN appear on an
  # explicit opt-in, so "never by default" isn't vacuously true because the role can never
  # resolve to it at all.
  desktopKdeOptIn = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; polkitAgent = "polkit-kde-agent"; };
  };
  pacmanKdeOptIn = desktopKdeOptIn.nixarch.packages.pacman;

  desktopProfileDisabled = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop.enable = false;
  };

  # The three capability booleans nixdesktop ships at `default = false`. Turned on together
  # because they are independent of each other and of everything above -- what is under test is
  # that `packagesFor`'s generic capability loop picks up a key purely by NAME MATCH with a `want`
  # boolean, which is the property that lets nixdesktop add a role without this repo changing
  # anything but the table.
  desktopExtrasOptIn = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = {
      enable = true;
      compositor = "niri";
      fileManagerExtras = true;
      gvfsBackends = true;
      theming = true;
    };
  };
  pacmanExtrasOptIn = desktopExtrasOptIn.nixarch.packages.pacman;

  desktopOo7 = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; keyring = "oo7"; };
  };
  pacmanOo7 = desktopOo7.nixarch.packages.pacman;

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
    # reinstalled on every activation. See nixdesktop's profiles/desktop.nix header and
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

    # ── the three opt-in capability roles ────────────────────────────────────────────────────
    #
    # OFF BY DEFAULT IS THE CONTRACT, not an accident of the current table. All three install
    # taste-level software a consumer may well want to own outright (a theme especially), so an
    # unopinionated `nixdesktop.desktop.enable = true` must never drag them in. This is the
    # `no-kde-packages-by-default` property one role over, for roles that are booleans instead of
    # named choices.
    (check "desktop-backend/capability-extras-absent-by-default"
      (!(lib.elem "thunar-archive-plugin" pacmanDefault) && !(lib.elem "ffmpegthumbnailer" pacmanDefault)
        && !(lib.elem "gvfs-smb" pacmanDefault) && !(lib.elem "gvfs-mtp" pacmanDefault)
        && !(lib.elem "nwg-look" pacmanDefault) && !(lib.elem "adw-gtk-theme" pacmanDefault))
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/file-manager-extras-resolved-on-opt-in"
      (builtins.all (p: lib.elem p pacmanExtrasOptIn)
        [ "ffmpegthumbnailer" "thunar-archive-plugin" "xarchiver"
          "thunar-media-tags-plugin" "thunar-vcs-plugin" ])
      "pacman: ${builtins.toJSON pacmanExtrasOptIn}")

    # The four names nixpkgs has no equivalent for at all -- nixdesktop's own table keeps this key
    # empty because one monolithic gvfs already carries every one of these backends. This is the
    # per-platform catalogue earning its keep, so it gets its own assertion rather than riding
    # along in the one above.
    (check "desktop-backend/gvfs-backends-resolved-on-opt-in"
      (builtins.all (p: lib.elem p pacmanExtrasOptIn)
        [ "gvfs-smb" "gvfs-nfs" "gvfs-mtp" "gvfs-gphoto2" ])
      "pacman: ${builtins.toJSON pacmanExtrasOptIn}")

    # ARCH NAMES, not nixpkgs ones: `adw-gtk-theme` here is `adw-gtk3` in nixpkgs, and `qt6ct`
    # here is `qt6Packages.qt6ct` there. Copying either spelling across would produce a package
    # `pacman -S` cannot find, which fails the WHOLE transaction (see `aurOnly`'s own comment) --
    # so pinning the Arch spelling is pinning that the two tables stayed genuinely separate.
    (check "desktop-backend/theming-resolved-on-opt-in-with-arch-names"
      (builtins.all (p: lib.elem p pacmanExtrasOptIn) [ "nwg-look" "adw-gtk-theme" "qt6ct" ]
        && !(lib.elem "adw-gtk3" pacmanExtrasOptIn))
      "pacman: ${builtins.toJSON pacmanExtrasOptIn}")

    # Every capability name must be a repo package, since one unknown target aborts the whole
    # pacman transaction and takes the rest of the desktop with it. The partition is what stops
    # that, so it has to be right about these too: nothing new here belongs in `aurOnly`.
    (check "desktop-backend/capability-extras-are-repo-packages-not-aur"
      (desktopExtrasOptIn.nixarch.packages.aur == [ ])
      "aur: ${builtins.toJSON desktopExtrasOptIn.nixarch.packages.aur}")

    # ── oo7 ──────────────────────────────────────────────────────────────────────────────────
    #
    # nixdesktop's `keyring` option accepts "oo7"; without a table entry that resolved through
    # `resolve`'s fallthrough instead -- which on Arch would have happened to land on the right
    # package name by luck, while leaving `home/desktop.nix` unable to select it at all (its enum
    # is `lib.attrNames roles.keyrings`) and with no daemon path anywhere. The entry makes both
    # deliberate.
    (check "desktop-backend/oo7-keyring-role-resolved"
      (lib.elem "oo7" pacmanOo7 && !(lib.elem "gnome-keyring" pacmanOo7))
      "pacman: ${builtins.toJSON pacmanOo7}")

    (check "desktop-backend/oo7-is-a-real-table-entry-not-a-fallthrough"
      (roles.keyrings ? oo7 && roles.keyrings.oo7.packages == [ "oo7" ])
      "keyrings keys: ${builtins.toJSON (builtins.attrNames roles.keyrings)}")

    # The daemon is at `/usr/lib/oo7-daemon`, NOT `/usr/bin` -- so unlike gnome-keyring-daemon and
    # kwalletd6 a bare name would resolve nowhere. Pinned as an absolute path for the same reason
    # the mate-polkit check above pins its `/usr/lib/` prefix.
    (check "desktop-backend/oo7-command-is-an-absolute-libexec-path"
      (lib.hasPrefix "/usr/lib/" roles.keyrings.oo7.command)
      "command: ${roles.keyrings.oo7.command}")

    # home/desktop.nix derives its `keyring` enum from this table, so a missing entry is a hard
    # eval error for a consumer rather than a silent fallthrough. This is the check that the two
    # layers offer the same set of providers.
    (check "desktop-backend/user-layer-can-select-every-keyring-role"
      (builtins.all (k: roles.keyrings ? ${k}) [ "gnome-keyring" "kwallet" "oo7" ])
      "keyrings keys: ${builtins.toJSON (builtins.attrNames roles.keyrings)}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # home-desktop (home/desktop.nix) -- the USER-layer half of the same backend, gated on the same
  # nixdesktop checkout as desktop-backend above.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  # Stub of the surface home-manager provides, the mirror of `systemManagerSurfaceStub` above and
  # opaque for the same reason. nixdesktop's home/session.nix takes only `{ lib, config, ... }` and
  # writes only `systemd.user.services` (plus assertions/warnings), so this is the whole surface --
  # no `pkgs`, no `home.*`.
  homeManagerSurfaceStub = { lib, ... }: {
    options = {
      systemd.user.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  # THE REAL nixdesktop home/session.nix, not a stub of it -- everything worth asserting here is
  # produced by ITS provider dispatch (which unit gets rendered, with which process shape) from
  # the values home/desktop.nix hands it. A stub would only prove this module writes the options
  # it writes, which is not the question.
  evalHomeDesktop = extraConfig: (lib.evalModules {
    modules = [
      homeManagerSurfaceStub
      (nixdesktop + "/home/session.nix")
      ../home/desktop.nix
      extraConfig
    ];
  }).config;

  homeGnomeKeyring = evalHomeDesktop {
    nixdesktop.session.enable = true;
    nixarch.home.desktop = { enable = true; polkitAgent = "mate-polkit"; keyring = "gnome-keyring"; };
  };

  homeOo7 = evalHomeDesktop {
    nixdesktop.session.enable = true;
    nixarch.home.desktop = { enable = true; polkitAgent = "mate-polkit"; keyring = "oo7"; };
  };

  failedAssertions = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);

  homeDesktopChecks = if nixdesktop == null then [ ] else [
    (check "home-desktop/gnome-keyring-renders-a-daemon-unit"
      (homeGnomeKeyring.systemd.user.services ? "keyring"
        && homeGnomeKeyring.nixdesktop.session.keyring.command == roles.keyrings.gnome-keyring.command)
      "units: ${builtins.toJSON (builtins.attrNames homeGnomeKeyring.systemd.user.services)}, command: ${builtins.toJSON homeGnomeKeyring.nixdesktop.session.keyring.command}")

    (check "home-desktop/polkit-agent-renders-a-unit"
      (homeGnomeKeyring.systemd.user.services ? "polkit-agent")
      "units: ${builtins.toJSON (builtins.attrNames homeGnomeKeyring.systemd.user.services)}")

    # THE oo7 PROPERTY, and the reason this section exists at all. The pacman `oo7` package ships
    # its own `--user` unit at `WantedBy=default.target`, which a user manager reaches strictly
    # before any compositor pulls in `graphical-session.target` -- so anything rendered here would
    # lose the `org.freedesktop.secrets` RequestName race every time and sit permanently failed.
    # Selecting oo7 must therefore render NO keyring unit, while still leaving oo7 the active,
    # configurable provider (the assertion below).
    (check "home-desktop/oo7-renders-no-duplicate-daemon-unit"
      (!(homeOo7.systemd.user.services ? "keyring")
        && homeOo7.systemd.user.services ? "polkit-agent")
      "units: ${builtins.toJSON (builtins.attrNames homeOo7.systemd.user.services)}")

    # Not the same claim as "no unit": nixdesktop distinguishes "oo7 is the provider, rendered
    # elsewhere" (`oo7.enable` + `renderDaemon = false`) from "nobody chose a provider", and only
    # the first keeps `credential.*` -- the credential-based unlock oo7 is chosen FOR -- reachable.
    (check "home-desktop/oo7-is-still-the-selected-provider"
      (homeOo7.nixdesktop.session.keyring.enable
        && homeOo7.nixdesktop.session.keyring.oo7.enable
        && !homeOo7.nixdesktop.session.keyring.oo7.renderDaemon)
      "keyring.enable: ${builtins.toJSON homeOo7.nixdesktop.session.keyring.enable}, oo7.enable: ${builtins.toJSON homeOo7.nixdesktop.session.keyring.oo7.enable}, renderDaemon: ${builtins.toJSON homeOo7.nixdesktop.session.keyring.oo7.renderDaemon}")

    # NEVER through the generic `command` escape hatch, which would be wrong twice: it renders the
    # duplicate unit above, AND nixdesktop derives serviceType/restart from which PROVIDER is
    # enabled rather than from the string -- with only `command` set, oo7-daemon would get
    # gnome-keyring's `Type=forking` and hang until TimeoutStartSec waiting for a fork that a
    # `Type=simple` daemon never performs.
    (check "home-desktop/oo7-does-not-use-the-generic-command-escape-hatch"
      (homeOo7.nixdesktop.session.keyring.command == null)
      "command: ${builtins.toJSON homeOo7.nixdesktop.session.keyring.command}")

    # `keyring.oo7.command` is MANDATORY with no default in nixdesktop, so any wiring that touches
    # it while `renderDaemon = false` throws "used but not defined" -- a failure that would surface
    # as an unlabelled evaluation error in a consumer's config, not here. Forcing the assertion
    # list is what proves nothing on this path reaches it.
    (check "home-desktop/oo7-selection-raises-no-assertions"
      (failedAssertions homeOo7 == [ ])
      "failed assertions: ${builtins.toJSON (failedAssertions homeOo7)}")

    (check "home-desktop/gnome-keyring-selection-raises-no-assertions"
      (failedAssertions homeGnomeKeyring == [ ])
      "failed assertions: ${builtins.toJSON (failedAssertions homeGnomeKeyring)}")
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

  results = packagesChecks ++ deviceGidsChecks ++ gshadowSyncChecks ++ desktopBackendChecks
    ++ homeDesktopChecks ++ gcrootGuardChecks;

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
        then "desktop-backend, home-desktop (no nixdesktop checkout; run standalone for those)"
        else "none";
    }
    ''
      echo "all $passedCount nixarch eval checks passed"
      echo "skipped: $skipped"
      touch $out
    '';
}
