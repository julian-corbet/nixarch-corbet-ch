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
      systemd.timers = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
      # Opaque, same shape as systemd.services/users.groups above -- added for modules/logrotate.nix,
      # which is the first module in this suite to touch `environment.etc`
      # (modules/foreign-service.nix does too, but is not yet in this suite -- see checks/README.md's
      # "Not covered yet"). A real system-manager tree renders each entry into a submodule with its
      # own `source`/`text`/`replaceExisting`; stubbing it as `attrsOf attrs` is enough to let a check
      # read back the plain attrset a module authored, same as `systemd.services` already does for
      # units, without pulling in system-manager's real option type just for this.
      environment.etc = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
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

  # Character offset of the first occurrence of `needle` in `haystack`, or `null`. `lib.hasInfix`
  # can say a construct is PRESENT in a generated script; some properties are about two constructs
  # being present IN A PARTICULAR ORDER -- a guard that runs after the thing it guards is not a
  # guard -- and that needs an offset to compare. Implemented by splitting rather than by walking
  # the string one index at a time, which on a 15 kB script would recurse deeper than Nix's
  # evaluator is comfortable with. `lib.splitString` escapes its separator, so needles carrying
  # shell punctuation (`[`, `!`, `$`) are literal here, not patterns.
  firstInfixIndex = needle: haystack:
    let parts = lib.splitString needle haystack;
    in if builtins.length parts < 2 then null else builtins.stringLength (builtins.head parts);

  # The slice of `s` between the first occurrence of `from` and the first `to` after it, or `""`.
  #
  # WHY A TEXT CHECK NEEDS SCOPING AT ALL. These modules generate shell scripts that carry their
  # own reasoning as comments, and a comment explaining a message necessarily uses the same words
  # as the message. A bare `hasInfix "partial upgrade"` over the whole script therefore stays green
  # after the sentence has been deleted from the operator-facing `echo`, because the comment above
  # it still says the words. An assertion about what a particular MESSAGE says has to be scoped to
  # that message; this is what scopes it.
  infixBetween = from: to: s:
    let head = lib.splitString from s;
    in if builtins.length head < 2 then ""
    else builtins.head (lib.splitString to (builtins.elemAt head 1));

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

  # The generated reconcile script under each `syncDbPolicy`, read the same static-text way the
  # AUR-isolation checks above read theirs. `syncDbPolicy` selects between three quite different
  # scripts at EVAL time (the module renders only the branch a host chose), so "what does the
  # default actually do" and "does any policy smuggle in a bare `pacman -Sy`" are both questions
  # about text, answerable here without a build and without an Arch box.
  syncPolicyText = policy: extra: (evalPackages {
    nixarch.packages = {
      enable = true;
      pacman = [ "git" ];
      aur = [ "yay" ];
      aurUser = "julian";
      syncDbPolicy = policy;
    } // extra;
  }).nixarch.packages.reconcileScript.text;

  requireFreshText = syncPolicyText "require-fresh" { };
  fullUpgradeText = syncPolicyText "full-upgrade" { };
  ignoreText = syncPolicyText "ignore" { };
  customMaxAgeText = syncPolicyText "require-fresh" { syncDbMaxAge = 3600; };

  # Just the operator-facing abort, from the first word of the message to the `exit 1` that ends
  # the block -- so an assertion about what the message SAYS cannot be satisfied by the comment
  # that explains it. See `infixBetween`.
  staleAbortMessage =
    infixBetween "ABORTING -- pacman's sync databases are" "exit 1" requireFreshText;

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

    # Step 1 covers the whole declared repository list in ONE pacman transaction -- unlike AUR, it
    # is not split per package: the repo IS the source, signed and mirrored by pacman, so it does
    # not share AUR's exposure to a vendor rotating a pinned checksum URL out from under a stale
    # PKGBUILD (see that step's header comment). What it IS now is `if`-guarded rather than bare,
    # so a failure can be diagnosed before it kills the script -- see the sync-database checks
    # below for what that diagnosis has to say.
    (check "packages/pacman-step-is-one-transaction-for-the-whole-list"
      (lib.hasInfix ''pacman -S --needed --noconfirm "''${assume_args[@]}" "''${pacman_pkgs[@]}"'' aurWithUserText
        && !(lib.hasInfix "for pkg in \"\${pacman_pkgs" aurWithUserText))
      "reconcileScript.text: step 1 (official-repo packages) no longer resolves the declared list in a single transaction")

    (check "packages/pacman-step-failure-is-if-guarded-not-bare"
      (lib.hasInfix ''if pacman -S --needed --noconfirm'' aurWithUserText)
      "reconcileScript.text: step 1 is not `if`-guarded, so a failing pacman kills the script before anything can name the cause")

    # ── the sync database: a cache this reconciler used to trust without ever validating it ──
    # A database days old names package file VERSIONS mirrors no longer carry, so every mirror
    # 404s on a name nothing in the output connects back to the database. These checks pin the
    # three things that keep that from being a mystery again: a policy surface, a pre-flight gate
    # that only fires when a fetch would actually happen, and a post-failure diagnosis that runs
    # on EVERY policy.

    (check "packages/sync-db-policy-defaults-to-require-fresh"
      (pkgsDefault.nixarch.packages.syncDbPolicy == "require-fresh")
      "got: ${builtins.toJSON pkgsDefault.nixarch.packages.syncDbPolicy}")

    (check "packages/sync-db-max-age-defaults-to-48h"
      (pkgsDefault.nixarch.packages.syncDbMaxAge == 172800)
      "got: ${builtins.toJSON pkgsDefault.nixarch.packages.syncDbMaxAge}")

    # THE ONE THAT MUST NEVER GO GREEN BY ACCIDENT. `pacman -Sy` followed by installing is Arch's
    # partial upgrade: new packages resolved against refreshed metadata, old libraries on disk,
    # breakage that surfaces at runtime as missing shared objects rather than here. Whatever this
    # module does about staleness, a bare `-Sy` is never it -- so the generated script is checked
    # for the literal, under every policy, not just the default one.
    (check "packages/reconcile-never-runs-a-bare-Sy"
      (lib.all (t: !(lib.hasInfix "pacman -Sy " t) && !(lib.hasInfix "pacman -Sy\n" t))
        [ requireFreshText fullUpgradeText ignoreText ])
      "reconcileScript.text contains a bare `pacman -Sy` under at least one syncDbPolicy -- that is the partial-upgrade footgun, see nixarch.packages.syncDbPolicy")

    # The gate is deliberately conditional on something actually being MISSING: `pacman -S
    # --needed` over an already-installed set contacts no mirror, and that is the steady-state
    # reconcile on every activation and every boot. A gate that fired there would fail runs that
    # were never going to fail.
    (check "packages/require-fresh-gates-only-when-a-package-is-missing"
      (lib.hasInfix "missing=$(pacman -T --" requireFreshText
        && lib.hasInfix ''if [ -n "$missing" ]; then'' requireFreshText)
      "reconcileScript.text (require-fresh): the freshness gate is not conditional on `pacman -T` reporting an unsatisfied package")

    (check "packages/require-fresh-aborts-before-installing"
      (
        let
          gateIdx = firstInfixIndex "ABORTING -- pacman's sync databases are" requireFreshText;
          installIdx = firstInfixIndex "pacman -S --needed --noconfirm" requireFreshText;
        in
        gateIdx != null && installIdx != null && gateIdx < installIdx
      )
      "reconcileScript.text (require-fresh): the staleness abort does not precede the install -- it has to run BEFORE pacman touches a mirror, not after")

    # Scoped to the abort MESSAGE, not the whole script: the script's own comments explain the same
    # thing in the same words, so an unscoped `hasInfix` would stay green with the operator-facing
    # sentences deleted. See `infixBetween`.
    (check "packages/require-fresh-abort-names-staleness-and-the-fix"
      (
        let m = staleAbortMessage; in
        lib.hasInfix "mirrors no longer carry" m
        && lib.hasInfix "404" m
        && lib.hasInfix "pacman -Syu" m
        && lib.hasInfix "partial upgrade" m
        && lib.hasInfix "syncDbMaxAge" m
      )
      "the staleness abort message does not name stale metadata, the 404 symptom, the `pacman -Syu` fix, the `-Sy` trap and the knob. got: ${builtins.toJSON staleAbortMessage}")

    (check "packages/require-fresh-threads-the-configured-max-age"
      (lib.hasInfix "-gt 3600" customMaxAgeText && !(lib.hasInfix "-gt 172800" customMaxAgeText))
      "reconcileScript.text: syncDbMaxAge = 3600 did not reach the generated comparison")

    (check "packages/full-upgrade-runs-syu-and-says-so"
      (lib.hasInfix "pacman -Syu --noconfirm" fullUpgradeText
        && lib.hasInfix "FULL SYSTEM UPGRADE" fullUpgradeText)
      "reconcileScript.text (full-upgrade): no `pacman -Syu --noconfirm`, or it does not announce itself as a full system upgrade")

    # Positive control for the two above: the default policy must NOT quietly upgrade the box.
    (check "packages/require-fresh-never-upgrades-the-host"
      (!(lib.hasInfix "pacman -Syu --noconfirm" requireFreshText))
      "reconcileScript.text (require-fresh): the default policy runs a full system upgrade, which it must never do")

    (check "packages/ignore-drops-the-gate-but-keeps-the-diagnosis"
      (!(lib.hasInfix "ABORTING -- pacman's sync databases are" ignoreText)
        && lib.hasInfix "If the errors above are 404s" ignoreText)
      "reconcileScript.text (ignore): expected no pre-flight gate but a retained post-failure diagnosis")

    # The layer that can never false-alarm: whatever the policy, a failed repository transaction
    # reports how old the databases actually are. The threshold above is a heuristic; this is not.
    (check "packages/install-failure-reports-the-database-age-on-every-policy"
      (lib.all (t: lib.hasInfix "If the errors above are 404s" t && lib.hasInfix "newest .db under" t)
        [ requireFreshText fullUpgradeText ignoreText ])
      "reconcileScript.text: a failed step-1 transaction does not report the sync-database age under every syncDbPolicy")

    (check "packages/install-failure-fails-the-unit"
      (lib.hasInfix "WARNING pacman -S FAILED" requireFreshText
        && lib.hasInfix "reconcile_failed=1" requireFreshText)
      "reconcileScript.text: a failed step-1 transaction is not tracked into the non-zero exit at step 5")

    # The age is read from pacman's own DBPath, and from the NEWEST database. A quiet repository
    # can go days without a revision, so taking the oldest would report every host as stale.
    (check "packages/database-age-comes-from-pacman-conf-dbpath"
      (lib.hasInfix "pacman-conf DBPath" requireFreshText
        && lib.hasInfix "newest_sync_db_mtime" requireFreshText)
      "reconcileScript.text: the database age is not read from pacman's own DBPath via a newest-mtime helper")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # packages-audit (modules/packages-audit.nix)
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalPackagesAudit = extraConfig: evalMod [
    ../modules/packages.nix
    ../modules/packages-audit.nix
    extraConfig
  ];

  packagesAuditOn = evalPackagesAudit {
    nixarch.packages = {
      enable = true;
      pacman = [ "base" "git" "bottom" ];
      audit.enable = true;
    };
  };
  packagesAuditOff = evalPackagesAudit { nixarch.packages.enable = true; };
  packagesAuditText = packagesAuditOn.nixarch.packages.audit.script.text;

  packagesAuditChecks = [
    (check "packages-audit/unit-and-timer-exist-when-enabled"
      (packagesAuditOn.systemd.services ? "nixarch-packages-audit"
        && packagesAuditOn.systemd.timers ? "nixarch-packages-audit")
      "service keys: ${builtins.toJSON (builtins.attrNames packagesAuditOn.systemd.services)}, timer keys: ${builtins.toJSON (builtins.attrNames packagesAuditOn.systemd.timers)}")

    (check "packages-audit/disabled-is-a-genuine-no-op"
      (!(packagesAuditOff.systemd.services ? "nixarch-packages-audit")
        && !(packagesAuditOff.systemd.timers ? "nixarch-packages-audit"))
      "service keys: ${builtins.toJSON (builtins.attrNames packagesAuditOff.systemd.services)}, timer keys: ${builtins.toJSON (builtins.attrNames packagesAuditOff.systemd.timers)}")

    # A report must never again become a dependency of system-manager.target. On a measured live
    # machine the old per-package query took 97 minutes; system-manager waits only 30 seconds for
    # target jobs, so wiring the report into multi-user.target made every activation time out.
    (check "packages-audit/service-is-not-activation-wanted"
      ((packagesAuditOn.systemd.services.nixarch-packages-audit.wantedBy or [ ]) == [ ])
      "service wantedBy: ${builtins.toJSON (packagesAuditOn.systemd.services.nixarch-packages-audit.wantedBy or null)}")

    (check "packages-audit/timer-not-activation-target-owns-scheduling"
      ((packagesAuditOn.systemd.timers.nixarch-packages-audit.wantedBy or [ ]) == [ "timers.target" ])
      "timer wantedBy: ${builtins.toJSON (packagesAuditOn.systemd.timers.nixarch-packages-audit.wantedBy or null)}")

    (check "packages-audit/timer-defers-and-repeats-the-report"
      (
        let t = packagesAuditOn.systemd.timers.nixarch-packages-audit.timerConfig or { }; in
        (t.OnActiveSec or null) == "5min"
        && (t.OnUnitActiveSec or null) == "1d"
        && (t.RandomizedDelaySec or null) == "5min"
        && (t.Unit or null) == "nixarch-packages-audit.service"
      )
      "timerConfig: ${builtins.toJSON (packagesAuditOn.systemd.timers.nixarch-packages-audit.timerConfig or null)}")

    (check "packages-audit/service-has-a-finite-runtime"
      ((packagesAuditOn.systemd.services.nixarch-packages-audit.serviceConfig.TimeoutStartSec or null) == "10min")
      "TimeoutStartSec: ${builtins.toJSON (packagesAuditOn.systemd.services.nixarch-packages-audit.serviceConfig.TimeoutStartSec or null)}")

    (check "packages-audit/service-does-not-remain-active-after-reporting"
      (!((packagesAuditOn.systemd.services.nixarch-packages-audit.serviceConfig or { }) ? RemainAfterExit))
      "serviceConfig: ${builtins.toJSON (packagesAuditOn.systemd.services.nixarch-packages-audit.serviceConfig or null)}")

    # Group membership is a database-wide index. Query it once, then select the declared group
    # rows locally; never fork one pacman process for every ordinary declared package again.
    (check "packages-audit/group-expansion-is-one-batched-query"
      (lib.hasInfix ''group_rows=$(pacman -Sgg 2>/dev/null || true)'' packagesAuditText
        && !(lib.hasInfix "members=$(pacman -Sgq" packagesAuditText))
      "audit script does not use the single-query group-index shape")

    (check "packages-audit/execstart-is-the-checked-script"
      (packagesAuditOn.systemd.services.nixarch-packages-audit.serviceConfig.ExecStart
        == "${packagesAuditOn.nixarch.packages.audit.script}")
      "ExecStart: ${builtins.toJSON (packagesAuditOn.systemd.services.nixarch-packages-audit.serviceConfig.ExecStart or null)}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # base-packages (modules/base-packages.nix) -- unconditional, no `enable` of its own (see the
  # module's own header for why), so `../modules/packages.nix` is composed alongside it purely to
  # supply the `nixarch.packages.distro` option `paru`'s placement reads -- not to enable the
  # reconciler itself, which none of these checks need running.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalBasePackages = extraConfig: evalMod [ ../modules/base-packages.nix ../modules/packages.nix extraConfig ];

  basePkgsArchDefault = evalBasePackages { }; # nixarch.packages.distro defaults to "arch"
  basePkgsCachyos = evalBasePackages { nixarch.packages.distro = "cachyos"; };
  basePkgsWithHostList = evalBasePackages {
    nixarch.packages = { pacman = [ "git" ]; aur = [ "yay" ]; };
  };

  basePackagesChecks = [
    # The four names that are the same answer on every Arch-family host -- always present,
    # regardless of `distro`.
    (check "base-packages/uniform-names-always-in-pacman"
      (builtins.all (p: lib.elem p basePkgsArchDefault.nixarch.packages.pacman)
        [ "reflector" "rebuild-detector" "arch-install-scripts" "base" "base-devel" ])
      "pacman: ${builtins.toJSON basePkgsArchDefault.nixarch.packages.pacman}")

    # THE property this module's `paru` split exists for: on the Arch floor (the default,
    # per-module-header the safe direction because it cannot abort a pacman transaction), `paru`
    # is AUR, not pacman -- a plain Arch host has no repository that carries a prebuilt one.
    (check "base-packages/paru-is-aur-on-plain-arch-floor"
      (lib.elem "paru" basePkgsArchDefault.nixarch.packages.aur
        && !(lib.elem "paru" basePkgsArchDefault.nixarch.packages.pacman))
      "pacman: ${builtins.toJSON basePkgsArchDefault.nixarch.packages.pacman}, aur: ${builtins.toJSON basePkgsArchDefault.nixarch.packages.aur}")

    # The lift: on `distro = "cachyos"`, `paru` resolves in that derivative's own repository, so
    # it moves to the plain pacman transaction and must NOT also linger in `aur` -- a name in
    # both lists would mean the AUR helper tries to build the tool a repository already ships.
    (check "base-packages/paru-lifts-to-pacman-on-cachyos"
      (lib.elem "paru" basePkgsCachyos.nixarch.packages.pacman
        && !(lib.elem "paru" basePkgsCachyos.nixarch.packages.aur))
      "pacman: ${builtins.toJSON basePkgsCachyos.nixarch.packages.pacman}, aur: ${builtins.toJSON basePkgsCachyos.nixarch.packages.aur}")

    # ── The CachyOS repository layer (2026-08-08) ────────────────────────────────────────────
    #
    # BOTH DIRECTIONS MATTER, and the absent one matters more. These six names exist ONLY in
    # CachyOS's own repositories -- zero results on archlinux.org, zero on the AUR RPC -- so on a
    # plain Arch host they are not "a package from the wrong channel", they are an unknown target,
    # and `pacman -S` aborts the ENTIRE transaction on one of those. A regression that leaked any
    # of them onto the arch floor would therefore break every OTHER declared package on that host
    # too, which is exactly the failure this module's `distro` gate exists to make impossible.
    (check "base-packages/cachyos-repo-layer-absent-on-plain-arch-floor"
      (builtins.all (p: !(lib.elem p basePkgsArchDefault.nixarch.packages.pacman))
        [
          "cachyos-keyring"
          "cachyos-mirrorlist"
          "cachyos-v3-mirrorlist"
          "cachyos-v4-mirrorlist"
          "cachyos-rate-mirrors"
          "cachyos-hooks"
        ])
      "pacman: ${builtins.toJSON basePkgsArchDefault.nixarch.packages.pacman}")

    # ... and never smuggled into `aur` as a "safe" fallback either: there is no AUR package by
    # any of these names, so an AUR helper would fail on them just as hard, only later and per
    # package instead of up front.
    (check "base-packages/cachyos-repo-layer-never-lands-in-aur"
      (builtins.all
        (p: !(lib.elem p (basePkgsArchDefault.nixarch.packages.aur
          ++ basePkgsCachyos.nixarch.packages.aur)))
        [
          "cachyos-keyring"
          "cachyos-mirrorlist"
          "cachyos-v3-mirrorlist"
          "cachyos-v4-mirrorlist"
          "cachyos-rate-mirrors"
          "cachyos-hooks"
        ])
      "arch aur: ${builtins.toJSON basePkgsArchDefault.nixarch.packages.aur}, cachyos aur: ${builtins.toJSON basePkgsCachyos.nixarch.packages.aur}")

    (check "base-packages/cachyos-repo-layer-present-on-cachyos-floor"
      (builtins.all (p: lib.elem p basePkgsCachyos.nixarch.packages.pacman)
        [
          "cachyos-keyring"
          "cachyos-mirrorlist"
          "cachyos-v3-mirrorlist"
          "cachyos-v4-mirrorlist"
          "cachyos-rate-mirrors"
          "cachyos-hooks"
        ])
      "pacman: ${builtins.toJSON basePkgsCachyos.nixarch.packages.pacman}")

    # The uniform four stay in `pacman` on the cachyos floor too -- the split is scoped to `paru`
    # alone, not a wholesale re-evaluation of the rest of this module's list.
    (check "base-packages/uniform-names-unaffected-by-distro"
      (builtins.all (p: lib.elem p basePkgsCachyos.nixarch.packages.pacman)
        [ "reflector" "rebuild-detector" "arch-install-scripts" "base" "base-devel" ])
      "pacman: ${builtins.toJSON basePkgsCachyos.nixarch.packages.pacman}")

    # Concatenates with a consumer's own lists rather than replacing them -- the same property
    # modules/desktop-backend.nix, modules/shelly.nix and modules/logrotate.nix all rely on for
    # the identical plain-`listOf` reason.
    (check "base-packages/concatenates-with-a-consumers-own-lists"
      (lib.elem "base" basePkgsWithHostList.nixarch.packages.pacman
        && lib.elem "git" basePkgsWithHostList.nixarch.packages.pacman
        && lib.elem "paru" basePkgsWithHostList.nixarch.packages.aur
        && lib.elem "yay" basePkgsWithHostList.nixarch.packages.aur)
      "pacman: ${builtins.toJSON basePkgsWithHostList.nixarch.packages.pacman}, aur: ${builtins.toJSON basePkgsWithHostList.nixarch.packages.aur}")
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
      (
        let execStart = gidsWithTty.systemd.services.devpts-gid.serviceConfig.ExecStart or [ ];
        in lib.any (l: lib.hasInfix "gid=5,mode=620,ptmxmode=666" l) execStart
      )
      "ExecStart: ${builtins.toJSON (gidsWithTty.systemd.services.devpts-gid.serviceConfig.ExecStart or null)}")

    (check "device-gids/devpts-chgrp-step-is-tolerant"
      (
        let execStart = gidsWithTty.systemd.services.devpts-gid.serviceConfig.ExecStart or [ ];
        in lib.any (l: lib.hasPrefix "-" l && lib.hasInfix "chgrp" l) execStart
      )
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
      (
        let w = gshadowEnabled.systemd.services.gshadow-sync.wantedBy or [ ];
        in lib.elem "multi-user.target" w && lib.elem "shadow.service" w
      )
      "wantedBy: ${builtins.toJSON (gshadowEnabled.systemd.services.gshadow-sync.wantedBy or null)}")

    (check "gshadow-sync/unit-ordered-before-shadow-service"
      (lib.elem "shadow.service" (gshadowEnabled.systemd.services.gshadow-sync.before or [ ]))
      "before: ${builtins.toJSON (gshadowEnabled.systemd.services.gshadow-sync.before or null)}")

    (check "gshadow-sync/unit-ordered-after-userborn-and-gid-migrate"
      (
        let a = gshadowEnabled.systemd.services.gshadow-sync.after or [ ];
        in lib.elem "userborn.service" a && lib.elem "gid-migrate.service" a
      )
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
      # `distro` stubbed here (2026-08-08) because modules/desktop-backend.nix now reads it to
      # feed `partitionAur`'s `archRepoOn` lift. Same default as the real option in
      # ../modules/packages.nix -- "arch", the floor -- so a fixture that says nothing gets the
      # answer that cannot abort a pacman transaction, exactly as a real host would.
      distro = lib.mkOption { type = lib.types.str; default = "arch"; };
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

  # brightness + wallpapers, on a SCROLL host. The compositor matters: `brightnessctl` used to
  # arrive only as a passenger on `compositors.niri`, so a niri fixture would pass while the
  # declared role stayed unresolved. Scroll is what every real host runs now, and it carries
  # neither package.
  desktopBrightnessWallpapers = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = {
      enable = true;
      compositor = "scroll";
      brightness = "brightnessctl";
      wallpapers = [ "cachyos-wallpapers" ];
    };
  };
  pacmanBrightnessWallpapers = desktopBrightnessWallpapers.nixarch.packages.pacman;

  desktopOo7 = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; keyring = "oo7"; };
  };
  pacmanOo7 = desktopOo7.nixarch.packages.pacman;

  # The input substrate. A single-choice role defaulting to null, so BOTH directions are worth
  # proving: an unfilled role must add nothing (the default every existing consumer already
  # evaluates, where a regression would silently install a daemon nobody asked for), and a filled
  # one must resolve through the table rather than through `resolve`'s bare-name fallthrough --
  # which would happen to produce the same string here, and would therefore hide a missing table
  # entry until some future role name stopped matching its package name.
  desktopInputKeyd = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; input = "keyd"; };
  };
  pacmanInputKeyd = desktopInputKeyd.nixarch.packages.pacman;

  # `duplicateFinder` -- the one role today whose package is AUR-only UPSTREAM and repo-carried on
  # a derivative, so it is the live proof that `archRepoOn`/`partitionAur` actually lift rather
  # than merely being written down. Evaluated on BOTH distro answers: testing one would leave half
  # the resolution unproven, and the two halves fail in opposite directions -- a missed lift only
  # costs a needless source build, while a WRONG lift puts an unresolvable name in the pacman list
  # and kills the whole desktop transaction.
  pacmanAppIndicators = (evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; appIndicators = true; };
  }).nixarch.packages.pacman;

  desktopDupArch = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; duplicateFinder = true; };
  };
  desktopDupCachyos = evalDesktopBackend {
    nixarch.packages = { enable = true; distro = "cachyos"; };
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; duplicateFinder = true; };
  };

  # `syntheticTyping` -- an official-repo capability, so the interesting direction is that it stays
  # out of the AUR partition and out of an unfilled host's list entirely.
  desktopTyping = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; syntheticTyping = true; };
  };

  # `inputAutomation` -- likewise official-repo, and the fixture exists for a second reason beyond
  # the partition: this capability and `syntheticTyping` above are the two that a careless edit
  # would merge, so each has to be shown reaching its own package and not the other's.
  desktopAutomation = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; inputAutomation = true; };
  };

  # `iconThemes` -- free-form names with NO table entry, so these fixtures prove two separate
  # things at once: that the pass-through reaches the reconciler at all, and that a name in
  # `archRepoOn` is still partitioned correctly when it arrives that way rather than out of a role
  # table.
  #
  # THE PAIR IS DELIBERATE, AND BOTH HALVES ARE REAL NAMES rather than one real name and a filler.
  # They are the two shapes an icon theme comes in, and a fixture carrying only one of them would
  # prove only half the partition. `char-white` is nowhere on upstream Arch and in CachyOS's own
  # repository, so it must be held out of the plain-Arch pacman list and lifted back on the
  # derivative. `breeze-icons` is an ordinary `extra` package on upstream Arch (and a `*-v3` rebuild
  # of that same package on CachyOS, which is not a different source and needs no entry anywhere),
  # so it must pass straight through on BOTH distros and must never acquire a special case just by
  # travelling next to a name that has one.
  desktopIconsArch = evalDesktopBackend {
    nixarch.packages.enable = true;
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; iconThemes = [ "char-white" "breeze-icons" ]; };
  };
  desktopIconsCachyos = evalDesktopBackend {
    nixarch.packages = { enable = true; distro = "cachyos"; };
    nixarch.desktopBackend.enable = true;
    nixdesktop.desktop = { enable = true; compositor = "niri"; iconThemes = [ "char-white" "breeze-icons" ]; };
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

    (check "desktop-backend/input-role-unfilled-installs-no-remapper"
      (!lib.elem "keyd" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/input-role-resolved-to-keyd"
      (lib.elem "keyd" pacmanInputKeyd)
      "pacman: ${builtins.toJSON pacmanInputKeyd}")

    # keyd is an official-repo package, so it must not land in the AUR partition -- an AUR name
    # in the pacman list is the failure this backend's whole `partitionAur` split exists to stop.
    (check "desktop-backend/input-role-does-not-reach-the-aur-partition"
      (!lib.elem "keyd" desktopInputKeyd.nixarch.packages.aur)
      "aur: ${builtins.toJSON desktopInputKeyd.nixarch.packages.aur}")

    # BOTH indicator libraries, never one. They ship different sonames, so a regression that
    # dropped the legacy half would look like a tidy-up and silently cost the tray for every
    # consumer still asking for the original name -- with no error anywhere, since these are
    # dlopened rather than linked.
    (check "desktop-backend/app-indicators-resolves-to-both-libraries"
      (lib.elem "libappindicator" pacmanAppIndicators
        && lib.elem "libayatana-appindicator" pacmanAppIndicators)
      "pacman: ${builtins.toJSON pacmanAppIndicators}")

    (check "desktop-backend/app-indicators-unfilled-installs-neither"
      (!lib.elem "libappindicator" pacmanDefault
        && !lib.elem "libayatana-appindicator" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/duplicate-finder-unfilled-installs-nothing"
      (!lib.elem "czkawka-gui" pacmanDefault
        && !lib.elem "czkawka-gui" desktopDefault.nixarch.packages.aur)
      "pacman: ${builtins.toJSON pacmanDefault}, aur: ${builtins.toJSON desktopDefault.nixarch.packages.aur}")

    # On the plain-Arch floor the name goes through the AUR helper, because upstream Arch packages
    # it nowhere -- and it must NOT appear in the pacman list, which is the fatal direction.
    (check "desktop-backend/duplicate-finder-is-aur-on-the-plain-arch-floor"
      (lib.elem "czkawka-gui" desktopDupArch.nixarch.packages.aur
        && !lib.elem "czkawka-gui" desktopDupArch.nixarch.packages.pacman)
      "pacman: ${builtins.toJSON desktopDupArch.nixarch.packages.pacman}, aur: ${builtins.toJSON desktopDupArch.nixarch.packages.aur}")

    # THE LIFT. On a distro whose own repository ships a prebuilt one, it moves to the pacman
    # transaction and must not linger in `aur` as well -- a name in both lists means the helper
    # rebuilds from source something the repo already provides.
    (check "desktop-backend/duplicate-finder-lifts-to-pacman-on-cachyos"
      (lib.elem "czkawka-gui" desktopDupCachyos.nixarch.packages.pacman
        && !lib.elem "czkawka-gui" desktopDupCachyos.nixarch.packages.aur)
      "pacman: ${builtins.toJSON desktopDupCachyos.nixarch.packages.pacman}, aur: ${builtins.toJSON desktopDupCachyos.nixarch.packages.aur}")

    # The lift is SCOPED to the entry that names it, not "everything AUR becomes repo on cachyos".
    # eww carries no archRepoOn, and a regression collapsing the two would put an unresolvable
    # name in the pacman list on every CachyOS desktop.
    (check "desktop-backend/archrepoon-does-not-lift-every-aur-name-on-that-distro"
      (lib.elem "eww"
        (evalDesktopBackend {
          nixarch.packages = { enable = true; distro = "cachyos"; };
          nixarch.desktopBackend.enable = true;
          nixdesktop.desktop = { enable = true; compositor = "niri"; bar = "eww"; };
        }).nixarch.packages.aur)
      "eww must stay in the AUR partition on cachyos -- it carries no archRepoOn entry")

    # Synthetic typing. Both directions, like every other capability here: an unfilled role must
    # not put a keystroke injector on a host that never asked for one, and a filled one must reach
    # the PACMAN half -- `wtype` is official-repo, and a regression routing it through the AUR
    # helper would rebuild from source something the repos already carry.
    (check "desktop-backend/synthetic-typing-unfilled-installs-nothing"
      (!lib.elem "wtype" pacmanDefault && !lib.elem "wtype" desktopDefault.nixarch.packages.aur)
      "pacman: ${builtins.toJSON pacmanDefault}, aur: ${builtins.toJSON desktopDefault.nixarch.packages.aur}")

    (check "desktop-backend/synthetic-typing-resolves-to-the-repo-package"
      (lib.elem "wtype" desktopTyping.nixarch.packages.pacman
        && !lib.elem "wtype" desktopTyping.nixarch.packages.aur)
      "pacman: ${builtins.toJSON desktopTyping.nixarch.packages.pacman}, aur: ${builtins.toJSON desktopTyping.nixarch.packages.aur}")

    # Input automation, the same two directions -- `ydotool` is official-repo too, so an AUR
    # partition here would mean rebuilding from source what `extra` already ships.
    (check "desktop-backend/input-automation-unfilled-installs-nothing"
      (!lib.elem "ydotool" pacmanDefault && !lib.elem "ydotool" desktopDefault.nixarch.packages.aur)
      "pacman: ${builtins.toJSON pacmanDefault}, aur: ${builtins.toJSON desktopDefault.nixarch.packages.aur}")

    (check "desktop-backend/input-automation-resolves-to-the-repo-package"
      (lib.elem "ydotool" desktopAutomation.nixarch.packages.pacman
        && !lib.elem "ydotool" desktopAutomation.nixarch.packages.aur)
      "pacman: ${builtins.toJSON desktopAutomation.nixarch.packages.pacman}, aur: ${builtins.toJSON desktopAutomation.nixarch.packages.aur}")

    # The two capabilities that are about keys and are not each other. Each must reach its own
    # package and neither the other's -- the assertion that catches a merge of the two roles.
    (check "desktop-backend/input-automation-and-synthetic-typing-stay-separate"
      (!lib.elem "ydotool" desktopTyping.nixarch.packages.pacman
        && !lib.elem "wtype" desktopAutomation.nixarch.packages.pacman
        && !lib.elem "keyd" desktopAutomation.nixarch.packages.pacman)
      "typing: ${builtins.toJSON desktopTyping.nixarch.packages.pacman}, automation: ${builtins.toJSON desktopAutomation.nixarch.packages.pacman}")

    # Icon themes, which reach this backend through `resolve`'s free-form path rather than a table.
    # An empty list must produce nothing at all -- the default every existing consumer evaluates.
    (check "desktop-backend/icon-themes-unfilled-installs-nothing"
      (!lib.elem "char-white" pacmanDefault && !lib.elem "char-white" desktopDefault.nixarch.packages.aur)
      "pacman: ${builtins.toJSON pacmanDefault}, aur: ${builtins.toJSON desktopDefault.nixarch.packages.aur}")

    # An ordinary theme name passes straight through to the pacman half on both distros: nothing
    # about being an icon theme routes a name anywhere special, and nothing about sharing a list
    # with a derivative-only name rubs off on it either. `breeze-icons` is in upstream `extra`, so
    # the plain-Arch floor is already correct for it and there is nothing for `archRepoOn` to lift.
    (check "desktop-backend/icon-themes-pass-through-to-the-reconciler"
      (lib.elem "breeze-icons" desktopIconsArch.nixarch.packages.pacman
        && lib.elem "breeze-icons" desktopIconsCachyos.nixarch.packages.pacman
        && !lib.elem "breeze-icons" desktopIconsArch.nixarch.packages.aur
        && !lib.elem "breeze-icons" desktopIconsCachyos.nixarch.packages.aur)
      "arch pacman: ${builtins.toJSON desktopIconsArch.nixarch.packages.pacman}")

    # THE FATAL DIRECTION for this option. `char-white` exists in no upstream Arch repository and
    # in no AUR package either, so on the plain-Arch floor it must be held OUT of the pacman list:
    # one unresolvable target there aborts the entire transaction and takes every other declared
    # package down with it, where an AUR helper handed a name it cannot find fails on that name
    # alone. This is what `aurOnly` buys for a name that is not, literally, in the AUR.
    (check "desktop-backend/cachyos-only-icon-theme-stays-out-of-the-plain-arch-pacman-list"
      (!lib.elem "char-white" desktopIconsArch.nixarch.packages.pacman
        && lib.elem "char-white" desktopIconsArch.nixarch.packages.aur)
      "pacman: ${builtins.toJSON desktopIconsArch.nixarch.packages.pacman}, aur: ${builtins.toJSON desktopIconsArch.nixarch.packages.aur}")

    # ...and the lift puts it back where it actually lives on the distro that carries it, without
    # leaving a copy in `aur` for the helper to rebuild.
    (check "desktop-backend/cachyos-only-icon-theme-lifts-to-pacman-on-cachyos"
      (lib.elem "char-white" desktopIconsCachyos.nixarch.packages.pacman
        && !lib.elem "char-white" desktopIconsCachyos.nixarch.packages.aur)
      "pacman: ${builtins.toJSON desktopIconsCachyos.nixarch.packages.pacman}, aur: ${builtins.toJSON desktopIconsCachyos.nixarch.packages.aur}")

    (check "desktop-backend/compositor-role-resolved"
      (lib.elem "niri" pacmanDefault && lib.elem "brightnessctl" pacmanDefault && lib.elem "playerctl" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    (check "desktop-backend/capability-roles-resolved"
      (lib.elem "grim" pacmanDefault && lib.elem "slurp" pacmanDefault
        && lib.elem "swayidle" pacmanDefault && lib.elem "swaylock" pacmanDefault
        && lib.elem "cliphist" pacmanDefault && lib.elem "wl-clipboard" pacmanDefault
        && lib.elem "xwayland-satellite" pacmanDefault
        && lib.elem "xdg-desktop-portal-gtk" pacmanDefault)
      "pacman: ${builtins.toJSON pacmanDefault}")

    # The GNOME portal backend must NOT come back. It implements Screenshot and ScreenCast against
    # Mutter, which is not running on the compositors this role table serves, and its `UseIn=gnome`
    # makes it a candidate for both the moment anything puts `gnome` in XDG_CURRENT_DESKTOP. See
    # lib/desktop-roles.nix's `portals` entry.
    (check "desktop-backend/no-gnome-portal-backend"
      (!(lib.elem "xdg-desktop-portal-gnome" pacmanDefault))
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
      (
        let r = roles.polkitAgents.mate-polkit;
        in lib.elem (lib.head r.packages) pacmanDefault && lib.hasPrefix "/usr/lib/mate-polkit/" r.command
      )
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

    # `engrampa`, not `xarchiver`: the table moved to the one archiver that resolves on BOTH
    # platforms (see lib/desktop-roles.nix's own paragraph on the LIBEXECDIR difference) and this
    # expectation was never updated, so the check has been failing on a table that is correct.
    # `libopenraw` is asserted for the same reason `ffmpegthumbnailer` is -- an optdepend Arch's
    # tumbler will not pull for you.
    # Both were in nixdesktop's `want` contract from the start and this table never read them, so
    # the declaration resolved to nothing. `brightnessctl` masked it for months by riding along on
    # the niri compositor entry -- retiring niri (2026-08-02) is what exposed it, on hosts that had
    # declared the role since April and would have come up with dead brightness keys on a reinstall.
    (check "desktop-backend/brightness-resolves-without-a-compositor-carrying-it"
      (lib.elem "brightnessctl" pacmanBrightnessWallpapers)
      "pacman: ${builtins.toJSON pacmanBrightnessWallpapers}")

    (check "desktop-backend/wallpapers-resolve-at-all"
      (lib.elem "cachyos-wallpapers" pacmanBrightnessWallpapers)
      "pacman: ${builtins.toJSON pacmanBrightnessWallpapers}")

    (check "desktop-backend/file-manager-extras-resolved-on-opt-in"
      (builtins.all (p: lib.elem p pacmanExtrasOptIn)
        [
          "ffmpegthumbnailer"
          "libopenraw"
          "thunar-archive-plugin"
          "engrampa"
          "thunar-media-tags-plugin"
          "thunar-vcs-plugin"
        ])
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

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # shelly (modules/shelly.nix) -- nixarch's own opinionated package, declared from inside the
  # sink rather than published into it from a domain repo's own module.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalShelly = extraConfig: evalMod [ ../modules/shelly.nix ../modules/packages.nix extraConfig ];

  shellyDefault = evalShelly { };
  shellyOn = evalShelly { nixarch.shelly.enable = true; };
  # The same concatenation property modules/desktop-backend.nix relies on (and is checked for
  # above) -- proven here for this module too rather than assumed from that one.
  shellyWithHostList = evalMod [
    ../modules/shelly.nix
    ../modules/packages.nix
    { nixarch.shelly.enable = true; nixarch.packages.pacman = [ "git" ]; }
  ];

  shellyChecks = [
    (check "shelly/disabled-by-default"
      (shellyDefault.nixarch.shelly.enable == false)
      "got: ${builtins.toJSON shellyDefault.nixarch.shelly.enable}")

    (check "shelly/disabled-contributes-nothing-to-pacman"
      (shellyDefault.nixarch.packages.pacman == [ ])
      "got: ${builtins.toJSON shellyDefault.nixarch.packages.pacman}")

    (check "shelly/enable-adds-shelly-to-pacman"
      (shellyOn.nixarch.packages.pacman == [ "shelly" ])
      "got: ${builtins.toJSON shellyOn.nixarch.packages.pacman}")

    # Shelly is the official CachyOS-repo package, not AUR -- a wrong split here would abort the
    # whole pacman transaction on `pacman -S` (one unknown target fails the batch), same failure
    # mode modules/desktop-backend.nix's own AUR split exists to avoid.
    (check "shelly/enable-adds-nothing-to-aur"
      (shellyOn.nixarch.packages.aur == [ ])
      "got: ${builtins.toJSON shellyOn.nixarch.packages.aur}")

    (check "shelly/concatenates-with-a-consumers-own-pacman-list"
      (lib.elem "shelly" shellyWithHostList.nixarch.packages.pacman
        && lib.elem "git" shellyWithHostList.nixarch.packages.pacman)
      "got: ${builtins.toJSON shellyWithHostList.nixarch.packages.pacman}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # cachyos-tools (modules/cachyos-tools.nix) -- four independently-switchable CachyOS-only
  # packages. The properties that matter are INDEPENDENCE (no option drags in another) and the
  # DISTRO GATE (none of these names exists in upstream Arch or the AUR, so leaking one onto a
  # non-CachyOS host would abort that host's whole pacman transaction, not merely install the
  # wrong thing). Both distro answers are exercised, for the same reason nixmsg's own
  # archRepoOn suite gives: testing one would leave half the resolution unproven.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalCachyosTools = extraConfig:
    evalMod [ ../modules/cachyos-tools.nix ../modules/packages.nix extraConfig ];

  cachyToolsDefault = evalCachyosTools { nixarch.packages.distro = "cachyos"; };
  cachyToolsAll = evalCachyosTools {
    nixarch.packages.distro = "cachyos";
    nixarch.cachyosTools = {
      cachyUpdate.enable = true;
      cachyosHello.enable = true;
      cachyosKernelManager.enable = true;
      cachyosPackageinstaller.enable = true;
    };
  };
  cachyToolsOnlyUpdate = evalCachyosTools {
    nixarch.packages.distro = "cachyos";
    nixarch.cachyosTools.cachyUpdate.enable = true;
  };
  # Enabled on the plain-Arch floor: the package must NOT be emitted, and the assertion must fire.
  cachyToolsWrongDistro = evalCachyosTools {
    nixarch.cachyosTools.cachyosHello.enable = true;
  };
  cachyToolsWithHostList = evalCachyosTools {
    nixarch.packages.distro = "cachyos";
    nixarch.cachyosTools.cachyUpdate.enable = true;
    nixarch.packages.pacman = [ "git" ];
  };

  cachyosToolsChecks = [
    (check "cachyos-tools/all-four-disabled-by-default"
      (cachyToolsDefault.nixarch.packages.pacman == [ ])
      "got: ${builtins.toJSON cachyToolsDefault.nixarch.packages.pacman}")

    (check "cachyos-tools/every-option-enabled-yields-every-package"
      (builtins.all (p: lib.elem p cachyToolsAll.nixarch.packages.pacman)
        [ "cachy-update" "cachyos-hello" "cachyos-kernel-manager" "cachyos-packageinstaller" ])
      "got: ${builtins.toJSON cachyToolsAll.nixarch.packages.pacman}")

    # INDEPENDENCE -- the property that makes four options meaningfully four rather than one
    # lumped toggle wearing four names. Enabling the update notifier must bring nothing else.
    (check "cachyos-tools/each-option-is-independent-of-the-others"
      (cachyToolsOnlyUpdate.nixarch.packages.pacman == [ "cachy-update" ])
      "got: ${builtins.toJSON cachyToolsOnlyUpdate.nixarch.packages.pacman}")

    # THE GATE. An enabled option on a non-CachyOS distro emits no package name -- the direction
    # that cannot abort a reconcile.
    (check "cachyos-tools/enabled-on-plain-arch-emits-no-package"
      (cachyToolsWrongDistro.nixarch.packages.pacman == [ ])
      "got: ${builtins.toJSON cachyToolsWrongDistro.nixarch.packages.pacman}")

    # ... and does not silently pretend to have worked: a suppressed package with no diagnostic
    # reads as "the option did nothing", when the truth is "this package cannot exist here".
    (check "cachyos-tools/enabled-on-plain-arch-fails-an-assertion"
      (lib.any (a: !a.assertion) cachyToolsWrongDistro.assertions)
      "assertions: ${builtins.toJSON (map (a: a.assertion) cachyToolsWrongDistro.assertions)}")

    # ... while a correctly-declared CachyOS host raises none.
    (check "cachyos-tools/no-assertion-fires-on-a-cachyos-host"
      (builtins.all (a: a.assertion) cachyToolsAll.assertions)
      "assertions: ${builtins.toJSON (map (a: a.assertion) cachyToolsAll.assertions)}")

    # None of these four is an AUR package -- there is no AUR entry by any of these names, so a
    # wrong split would fail just as hard, only later.
    (check "cachyos-tools/nothing-lands-in-aur"
      (cachyToolsAll.nixarch.packages.aur == [ ])
      "got: ${builtins.toJSON cachyToolsAll.nixarch.packages.aur}")

    (check "cachyos-tools/concatenates-with-a-consumers-own-pacman-list"
      (lib.elem "cachy-update" cachyToolsWithHostList.nixarch.packages.pacman
        && lib.elem "git" cachyToolsWithHostList.nixarch.packages.pacman)
      "got: ${builtins.toJSON cachyToolsWithHostList.nixarch.packages.pacman}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # cachyos-settings (modules/cachyos-settings.nix) -- the whole-system tuning profile, kept as a
  # deliberate base layer. Same gate, same hazard and same assertion contract as cachyos-tools
  # above; proven separately rather than inferred from that module, since the two share a shape
  # but not a line of code.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalCachyosSettings = extraConfig:
    evalMod [ ../modules/cachyos-settings.nix ../modules/packages.nix extraConfig ];

  cachySettingsDefault = evalCachyosSettings { nixarch.packages.distro = "cachyos"; };
  cachySettingsOn = evalCachyosSettings {
    nixarch.packages.distro = "cachyos";
    nixarch.cachyosSettings.enable = true;
  };
  cachySettingsWrongDistro = evalCachyosSettings {
    nixarch.cachyosSettings.enable = true;
  };

  cachyosSettingsChecks = [
    (check "cachyos-settings/disabled-by-default"
      (cachySettingsDefault.nixarch.packages.pacman == [ ])
      "got: ${builtins.toJSON cachySettingsDefault.nixarch.packages.pacman}")

    (check "cachyos-settings/enable-adds-the-package-on-a-cachyos-host"
      (cachySettingsOn.nixarch.packages.pacman == [ "cachyos-settings" ])
      "got: ${builtins.toJSON cachySettingsOn.nixarch.packages.pacman}")

    (check "cachyos-settings/enable-adds-nothing-to-aur"
      (cachySettingsOn.nixarch.packages.aur == [ ])
      "got: ${builtins.toJSON cachySettingsOn.nixarch.packages.aur}")

    (check "cachyos-settings/enabled-on-plain-arch-emits-no-package"
      (cachySettingsWrongDistro.nixarch.packages.pacman == [ ])
      "got: ${builtins.toJSON cachySettingsWrongDistro.nixarch.packages.pacman}")

    (check "cachyos-settings/enabled-on-plain-arch-fails-an-assertion"
      (lib.any (a: !a.assertion) cachySettingsWrongDistro.assertions)
      "assertions: ${builtins.toJSON (map (a: a.assertion) cachySettingsWrongDistro.assertions)}")

    (check "cachyos-settings/no-assertion-fires-on-a-cachyos-host"
      (builtins.all (a: a.assertion) cachySettingsOn.assertions)
      "assertions: ${builtins.toJSON (map (a: a.assertion) cachySettingsOn.assertions)}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # logrotate (modules/logrotate.nix) -- package + a timer enabled after the reconciler +
  # /etc/logrotate.d/* drop-ins.
  # ═══════════════════════════════════════════════════════════════════════════════════════════

  evalLogrotate = extraConfig: evalMod [ ../modules/logrotate.nix ../modules/packages.nix extraConfig ];

  logrotateDefault = evalLogrotate { };
  logrotateOn = evalLogrotate { nixarch.logrotate.enable = true; };
  logrotateWithHostList = evalMod [
    ../modules/logrotate.nix
    ../modules/packages.nix
    { nixarch.logrotate.enable = true; nixarch.packages.pacman = [ "git" ]; }
  ];
  logrotateWithDropin = evalLogrotate {
    nixarch.logrotate = {
      enable = true;
      dropins."corbet-app" = "/var/log/corbet-app/*.log { weekly }\n";
    };
  };

  timerWantsPath = "systemd/system/timers.target.wants/logrotate.timer";
  enableTimerText = logrotateOn.nixarch.logrotate.enableTimerScript.text;

  logrotateChecks = [
    (check "logrotate/disabled-by-default"
      (logrotateDefault.nixarch.logrotate.enable == false)
      "got: ${builtins.toJSON logrotateDefault.nixarch.logrotate.enable}")

    (check "logrotate/disabled-contributes-nothing-to-pacman"
      (logrotateDefault.nixarch.packages.pacman == [ ])
      "got: ${builtins.toJSON logrotateDefault.nixarch.packages.pacman}")

    (check "logrotate/disabled-renders-no-etc-entries"
      (logrotateDefault.environment.etc == { })
      "got: ${builtins.toJSON (builtins.attrNames logrotateDefault.environment.etc)}")

    (check "logrotate/enable-adds-logrotate-to-pacman"
      (logrotateOn.nixarch.packages.pacman == [ "logrotate" ])
      "got: ${builtins.toJSON logrotateOn.nixarch.packages.pacman}")

    (check "logrotate/concatenates-with-a-consumers-own-pacman-list"
      (lib.elem "logrotate" logrotateWithHostList.nixarch.packages.pacman
        && lib.elem "git" logrotateWithHostList.nixarch.packages.pacman)
      "got: ${builtins.toJSON logrotateWithHostList.nixarch.packages.pacman}")

    # THE BUG THIS MODULE EXISTS TO FIX: logrotate.timer was found live-disabled on an already
    # hand-installed box, so logs were never actually being rotated. Enabling the module has to
    # produce the state `systemctl enable logrotate.timer` produces -- but NOT by declaring a
    # `timers.target.wants` symlink into the store, which is what the checks below pin instead.
    (check "logrotate/enable-declares-no-timers-target-wants-etc-entry"
      (!(logrotateOn.environment.etc ? "${timerWantsPath}"))
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames logrotateOn.environment.etc)}")

    (check "logrotate/enable-renders-a-timer-enable-unit"
      (logrotateOn.systemd.services ? "nixarch-logrotate-enable-timer")
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames logrotateOn.systemd.services)}")

    (check "logrotate/disabled-renders-no-timer-enable-unit"
      (!(logrotateDefault.systemd.services ? "nixarch-logrotate-enable-timer"))
      "systemd.services keys: ${builtins.toJSON (builtins.attrNames logrotateDefault.systemd.services)}")

    # THE ORDERING IS THE ENTIRE FIX. The timer can only be enabled once the package that ships
    # the unit is installed, and the only thing that installs it is the reconciler -- which is a
    # unit, and therefore runs after system-manager has already activated /etc. Enabling from
    # /etc was a deadlock: the link needed the package, the package needed the reconciler, the
    # reconciler needed activation past the /etc stage, and the /etc stage died on the link.
    (check "logrotate/timer-enable-unit-runs-after-the-package-reconciler"
      (
        let u = logrotateOn.systemd.services.nixarch-logrotate-enable-timer or { }; in
        (u.after or [ ]) == [ "nixarch-packages-reconcile.service" ]
        && (u.wants or [ ]) == [ "nixarch-packages-reconcile.service" ]
      )
      "got after/wants: ${builtins.toJSON [ (logrotateOn.systemd.services.nixarch-logrotate-enable-timer.after or null) (logrotateOn.systemd.services.nixarch-logrotate-enable-timer.wants or null) ]}")

    # ...and that unit name is not a guess. modules/packages.nix owns it; if it is ever renamed,
    # the `After=`/`Wants=` above becomes a reference to nothing and the ordering silently stops
    # existing -- which is the same class of silent-wrong-answer the whole change is about.
    (check "logrotate/timer-enable-orders-after-a-unit-that-actually-exists"
      (lib.elem "nixarch-packages-reconcile"
        (builtins.attrNames (evalPackages { nixarch.packages.enable = true; }).systemd.services))
      "modules/packages.nix declares: ${builtins.toJSON (builtins.attrNames (evalPackages { nixarch.packages.enable = true; }).systemd.services)}")

    # `Wants=`, never `Requires=`: the reconcile unit only exists when nixarch.packages.enable is
    # true, and a Requires= on an undeclared unit fails the job outright on a host that manages
    # its packages some other way.
    (check "logrotate/timer-enable-does-not-hard-require-the-reconciler"
      (!((logrotateOn.systemd.services.nixarch-logrotate-enable-timer or { }) ? requires))
      "the timer-enable unit declares `requires`, which fails outright when nixarch.packages.enable is false")

    # Not RemainAfterExit, unlike the reconciler: system-manager restarts a unit only when its own
    # store path moved, so a RemainAfterExit oneshot that already succeeded would never re-assert
    # the enable. Left to go inactive, system-manager.target pulls it up again every activation --
    # which is the one property the removed `environment.etc` entry gave for free.
    (check "logrotate/timer-enable-unit-re-asserts-on-every-activation"
      ((logrotateOn.systemd.services.nixarch-logrotate-enable-timer.serviceConfig.RemainAfterExit or null) == false)
      "got: ${builtins.toJSON (logrotateOn.systemd.services.nixarch-logrotate-enable-timer.serviceConfig.RemainAfterExit or null)}")

    # Without this the unit cannot find `systemctl` at all -- system-manager injects a
    # nix-store-only PATH into everything it declares. See lib/host-path.nix.
    (check "logrotate/timer-enable-unit-carries-the-host-path"
      ((unwrap (logrotateOn.systemd.services.nixarch-logrotate-enable-timer.environment.PATH or null)) == hostPaths.hostPath)
      "got: ${builtins.toJSON (unwrap (logrotateOn.systemd.services.nixarch-logrotate-enable-timer.environment.PATH or null))}")

    # A missing vendor unit is now a named failure on the box instead of a canonicalize error
    # about a store path. Pinned as an ORDER, not a presence: the existence test has to come
    # BEFORE the enable, or it is decoration. The message itself is checked separately, scoped to
    # the message, for the same reason the staleness abort is.
    (check "logrotate/timer-enable-script-tests-for-the-vendor-unit-before-enabling"
      (
        let
          guardIdx = firstInfixIndex ''if [ ! -e "$unit" ]'' enableTimerText;
          enableIdx = firstInfixIndex "systemctl enable --now logrotate.timer" enableTimerText;
        in
        guardIdx != null && enableIdx != null && guardIdx < enableIdx
        && lib.hasInfix "unit=/usr/lib/systemd/system/logrotate.timer" enableTimerText
      )
      "the timer-enable script does not test for the vendor unit before running `systemctl enable`. got: ${builtins.toJSON enableTimerText}")

    (check "logrotate/timer-enable-failure-names-the-package-and-the-reconciler"
      (
        let m = infixBetween "does not exist" "exit 1" enableTimerText; in
        lib.hasInfix "logrotate package is not installed" m
        && lib.hasInfix "nixarch-packages-reconcile.service" m
        && lib.hasInfix "nixarch.packages.enable" m
      )
      "the missing-vendor-unit message does not name the package, the reconcile unit and the option that switches it on. got: ${builtins.toJSON (infixBetween "does not exist" "exit 1" enableTimerText)}")

    (check "logrotate/timer-enable-execstart-is-that-script"
      (logrotateOn.systemd.services.nixarch-logrotate-enable-timer.serviceConfig.ExecStart
        == "${logrotateOn.nixarch.logrotate.enableTimerScript}")
      "got: ${builtins.toJSON (logrotateOn.systemd.services.nixarch-logrotate-enable-timer.serviceConfig.ExecStart or null)}")

    (check "logrotate/enable-with-no-dropins-declares-no-dropin-entries"
      (!lib.any (n: lib.hasPrefix "logrotate.d/" n) (builtins.attrNames logrotateOn.environment.etc))
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames logrotateOn.environment.etc)}")

    (check "logrotate/dropin-renders-under-logrotate-d"
      (logrotateWithDropin.environment.etc ? "logrotate.d/corbet-app")
      "environment.etc keys: ${builtins.toJSON (builtins.attrNames logrotateWithDropin.environment.etc)}")

    (check "logrotate/dropin-string-installs-as-text"
      (logrotateWithDropin.environment.etc."logrotate.d/corbet-app".text == "/var/log/corbet-app/*.log { weekly }\n")
      "got: ${builtins.toJSON (logrotateWithDropin.environment.etc."logrotate.d/corbet-app".text or null)}")

    (check "logrotate/dropin-also-sets-replace-existing"
      (logrotateWithDropin.environment.etc."logrotate.d/corbet-app".replaceExisting == true)
      "got: ${builtins.toJSON (logrotateWithDropin.environment.etc."logrotate.d/corbet-app".replaceExisting or null)}")
  ];

  # ═══════════════════════════════════════════════════════════════════════════════════════════
  # THE DEFECT CLASS, guarded across every module rather than only the one that got it wrong.
  #
  # An `environment.etc` entry whose `source` is a plain absolute-path STRING pointing OUTSIDE the
  # store is an artefact built from live system state that nothing validates. system-manager
  # renders each entry with a bare `mkdir -p` + `ln -s "$source"` (nix/modules/default.nix,
  # `addToStore`), and `ln -s` never looks at its target: when the target is absent the derivation
  # BUILDS FINE and contains a dangling link. The failure arrives much later and somewhere else --
  # the activation engine walks the merged etc environment calling `fs::canonicalize`
  # (crates/system-manager-engine/src/activate/etc_files.rs) and dies with ENOENT on a store path,
  # a message that says nothing about the missing package. Neither Nix nor system-manager catches
  # it: eval cannot know the target host's filesystem, and the build sandbox has no /usr at all.
  # So this suite catches it. See studies/trusting-the-live-system.md.
  #
  # Store-path strings are fine (that is `"${drv}"`), Nix paths are fine (imported into the store),
  # `text` is fine. Only "a path on some machine's live filesystem, resolved at build time" is not.
  liveSourceEtcEntries = cfgs:
    lib.concatMap
      (c: lib.filter (e: e != null) (lib.mapAttrsToList
        (name: entry:
          let src = entry.source or null; in
          if lib.isString src && !(lib.hasPrefix builtins.storeDir src)
          then "${name} -> ${src}"
          else null)
        c.environment.etc))
      cfgs;

  # foreign-service.nix is otherwise not in this suite (see checks/README.md), but it is the other
  # module in the project that writes `environment.etc` from caller-supplied values, so it belongs
  # in this particular sweep: a caller handing it a live path as a STRING must land in `text`, not
  # in `source`.
  foreignServiceEtc = evalMod [
    ../modules/foreign-service.nix
    {
      nixarch.foreignServices.demo = {
        configFiles."demo.conf" = "/usr/lib/systemd/system/demo.timer";
        restartUnits = [ "demo.service" ];
      };
    }
  ];

  liveSourceOffenders = liveSourceEtcEntries [
    logrotateDefault
    logrotateOn
    logrotateWithHostList
    logrotateWithDropin
    foreignServiceEtc
  ];

  # Positive control: the sweep above must have teeth. This is the exact shape that broke a live
  # host, handed to the same function -- if it comes back empty the guard is vacuous.
  liveSourcePositiveControl = liveSourceEtcEntries [
    {
      environment.etc."systemd/system/timers.target.wants/logrotate.timer".source =
        "/usr/lib/systemd/system/logrotate.timer";
    }
  ];

  etcSourceClassChecks = [
    (check "etc-source/no-module-renders-an-etc-source-outside-the-store"
      (liveSourceOffenders == [ ])
      "offending entries: ${builtins.toJSON liveSourceOffenders}")

    (check "etc-source/the-guard-above-is-not-vacuous"
      (liveSourcePositiveControl == [ "systemd/system/timers.target.wants/logrotate.timer -> /usr/lib/systemd/system/logrotate.timer" ])
      "got: ${builtins.toJSON liveSourcePositiveControl}")

    # `or null` rather than a bare attribute read: if the module ever routes a string into `source`
    # instead, the entry has no `text` at all, and a bare read would abort the whole suite with an
    # attribute error instead of failing this one check with a legible `got:`.
    (check "etc-source/foreign-service-puts-a-string-in-text-not-source"
      ((foreignServiceEtc.environment.etc."demo.conf".text or null) == "/usr/lib/systemd/system/demo.timer"
        && !(foreignServiceEtc.environment.etc."demo.conf" ? source))
      "got: ${builtins.toJSON foreignServiceEtc.environment.etc."demo.conf"}")
  ];

  results = packagesChecks ++ packagesAuditChecks ++ basePackagesChecks ++ deviceGidsChecks ++ gshadowSyncChecks
    ++ desktopBackendChecks ++ homeDesktopChecks ++ gcrootGuardChecks ++ shellyChecks
    ++ cachyosToolsChecks ++ cachyosSettingsChecks ++ logrotateChecks ++ etcSourceClassChecks;

  failed = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n"
    (r: "  - ${r.name}: ${r.detail}")
    failed;
in
if failed != [ ]
then
  throw ''
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
      skipped =
        if nixdesktop == null
        then "desktop-backend, home-desktop (no nixdesktop checkout; run standalone for those)"
        else "none";
    }
    ''
      echo "all $passedCount nixarch eval checks passed"
      echo "skipped: $skipped"
      touch $out
    '';
}
