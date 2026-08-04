# modules/packages.nix — declarative Arch/AUR package management. This is
# nixarch's headline feature: the installed package set lives as Nix
# declarations, and the machine CONVERGES to it on every system-manager
# activation (and at boot).
#
# HONESTY UP FRONT: pacman is not a transactional, declarative package
# manager the way the Nix store is. There is no atomic rollback, no
# content-addressed store, no "diff and apply in one transaction" primitive
# to build on. What this module gives you is a *convergence reconciler*:
# the DESIRED set is declared here in Nix, and a oneshot systemd service
# nudges the live Arch install toward that set every time system-manager
# activates. The declaration is declarative; the underlying tool it drives
# is not — don't expect Nix-store guarantees (atomicity, instant rollback,
# bit-for-bit reproducibility) from pacman/AUR installs just because the
# wish-list is now Nix syntax. What you DO get: your package set is
# versioned, reviewable, and reproduces itself on a fresh box instead of
# living only in your fingers' shell history.
#
# BOOTSTRAP, ONE TIME, BY HAND: an AUR helper (paru/yay) is itself built
# from the AUR — chicken-and-egg. This module deliberately does not
# bootstrap one; `aurHelper` just names a binary that MUST already be on
# the box before `aur` is non-empty. Install it once, manually, the normal
# AUR way, then hand this module the rest of the declarative work.
#
# THE SAME CIRCULARITY APPLIES TO THE PACKAGE SOURCE ITSELF, and it is worth
# stating because it looks at first like something this module should manage.
# The keyring, the mirrorlist and the pacman hooks are what make `pacman`
# able to fetch and verify anything. This module RUNS pacman. So they cannot
# be declared here in any meaningful sense: the mechanism that would install
# them is the mechanism that requires them to already exist. On plain Arch
# that is `archlinux-keyring` + `pacman-mirrorlist`; on a derivative it is
# that distro's own (CachyOS: `cachyos-keyring`, `cachyos-mirrorlist` and the
# v3/v4 microarchitecture variants, `cachyos-hooks`).
#
# They are a PRECONDITION, alongside nix and an AUR helper — not a package
# list. What this module can do about them is refuse to delete them, which is
# what `keep` is for; see its description.
#
# The distinction generalises: a distro also ships packages that CONFIGURE the
# system rather than install software (on CachyOS, `cachyos-settings` ships
# sysctls, systemd drop-ins, udev rules and a zram-generator config). Declaring
# those changes nothing — they are already installed, and what matters is
# knowing which knobs they pre-set so an explicit declaration is deliberate
# rather than an accidental inheritance. That is documentation, not a package
# list; see studies/ for a worked example.
#
# PRUNING IS OPT-IN AND DANGEROUS: `pruneUndeclared` actually removes
# packages (`pacman -Rns`) that are explicitly installed but not in your
# declared lists. pacman has no concept of "this was here before your
# declaration existed" — a package you depend on but simply forgot to list
# looks identical, to this reconciler, to genuine drift. It defaults off.
# `keep` is the safety floor under it: groups/names that are never removed
# even with pruning on, defaulting to the two groups a running Arch system
# cannot lose.
#
# A SEPARATE, ALSO-DANGEROUS KNOB: `pruneOrphans`. `pruneUndeclared` diffs against
# `pacman -Qqe` — EXPLICITLY installed packages — because that is the only install reason a
# declaration can meaningfully claim credit for. A genuine pacman orphan (`pacman -Qdtq`:
# installed as someone else's DEPENDENCY, and now required by nothing) is invisible to that diff
# no matter what `pruneUndeclared` is set to: it was never explicit, so it was never
# "undeclared" in the sense that option checks. Naming the same package in `pacman` does not fix
# this either — the reconcile above runs `pacman -S --needed`, and `--needed` skips a package
# that is already installed WITHOUT promoting its install reason from dependency to explicit, so
# a package that predates its own declaration can sit as a permanent "orphan" even while
# genuinely declared (verified live: a host that declared a language toolchain nixdev had
# already pulled in earlier as a build dependency stayed orphaned across reconciles until the
# declaration was dropped, because `--needed` never touched its reason bit). `pruneOrphans` is
# the dedicated sweep for the genuine case: `pacman -Rns` on the live `pacman -Qdtq` set,
# filtered through the same `keep`/`effectiveKeep` floor as `pruneUndeclared`. Off by default,
# for the same reason `pruneUndeclared` is: an orphan you rely on but happen to have installed
# only as a dependency (a library pulled in once by something you later removed by hand, say)
# looks identical to genuine drift.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.packages;
  hostPaths = import ../lib/host-path.nix { inherit lib; };

  # NON-OVERRIDABLE. Union'd into the prune keep-set regardless of what a consumer puts in
  # `keep`, because `keep` is a plain listOf: a consumer who SETS it replaces the default
  # outright rather than adding to it. That is the wrong failure mode for this particular
  # content -- the hazard being guarded against is someone forgetting, and "you lose the
  # protection at the exact moment you start customising" is the shape of guard that fails
  # precisely when it is needed. Verified: a config setting `keep = [ "cachyos-keyring" ]`
  # evaluates to exactly that one entry, with the default gone.
  #
  # These three are members of NEITHER `base` nor `base-devel` (checked on a real box), so
  # nothing else in the floor covers them. Pruning them means `pacman -Rns pacman`: the
  # reconciler deleting the tool it runs, on a machine that then cannot reinstall it.
  archCriticalKeep = [ "pacman" "archlinux-keyring" "pacman-mirrorlist" ];

  # The same guarantee, one distro layer down. A derivative serves its own repos from its own
  # mirrorlists, signed by its own keyring, so the set above does not cover it — and because
  # these packages are the PRECONDITION for fetching anything, a prune that removes them leaves
  # a machine that cannot reinstall them. That is the one failure this module must never cause.
  #
  # ADDITIVE, not a replacement. Verified by reading /etc/pacman.conf on a live CachyOS box:
  # `[core]`, `[extra]` and `[multilib]` all `Include = /etc/pacman.d/mirrorlist` — Arch's own,
  # shipped by `pacman-mirrorlist` — while only the `[cachyos*]` repos use the CachyOS lists. A
  # derivative therefore needs BOTH keyrings and BOTH mirrorlists, not just its own three.
  #
  # Deliberately narrow: only what pacman needs to FETCH AND VERIFY. `cachyos-settings`
  # (sysctls, udev rules, a zram-generator config) and `cachyos-rate-mirrors` (ranks mirrors)
  # are not preconditions — removing them changes how the system behaves, not whether the
  # package manager works, and the header above already explains why declaring that class of
  # package is documentation rather than a package list.
  distroCriticalKeep = {
    arch = [ ];
    cachyos = [
      "cachyos-keyring"
      "cachyos-mirrorlist"
      # The microarchitecture repos ([cachyos-v3], [cachyos-core-v3], ...) carry their own
      # mirrorlists, and a v3/v4 box resolves most of its packages through them.
      "cachyos-v3-mirrorlist"
      "cachyos-v4-mirrorlist"
      "cachyos-hooks"
    ];
  };

  criticalKeep =
    archCriticalKeep
    ++ distroCriticalKeep.${cfg.distro}
    ++ cfg.extraCriticalKeep;

  # One package per DERIVATIVE (never "arch" itself -- see the runtime check below for why that
  # direction can't be detected) whose mere presence is strong evidence the box actually runs
  # that derivative, regardless of what `distro` is set to. `cachyos-keyring` is not something a
  # plain Arch box acquires by accident -- getting it onto a box means the CachyOS repos are
  # already configured, which for `criticalKeep`'s purposes IS the fact that matters, no matter
  # what /etc/os-release (or a stale `distro` declaration) claims.
  distroSignature = {
    cachyos = "cachyos-keyring";
  };

  reconcile = pkgs.writeShellScript "nixarch-packages-reconcile" ''
    set -eu

    pacman_pkgs=(${lib.escapeShellArgs cfg.pacman})
    aur_pkgs=(${lib.escapeShellArgs cfg.aur})
    keep_list=(${lib.escapeShellArgs (lib.unique (criticalKeep ++ cfg.keep))})

    # Shared by both prune paths below (steps 3 and 4): expand `keep` entries as pacman
    # groups first (`pacman -Sqg`) — the way `keep`'s own option doc says it works — falling
    # back to the literal name for anything that is not a known group.
    expand_keep() {
      local k grp
      for k in "''${keep_list[@]}"; do
        grp=$(pacman -Sqg "$k" 2>/dev/null || true)
        if [ -n "$grp" ]; then
          printf '%s\n' "$grp"
        else
          printf '%s\n' "$k"
        fi
      done
    }

    # Virtual-package dependency overrides, shared by BOTH transactions below.
    # Empty-array expansion under `set -u` is safe on bash >= 4.4; every
    # Arch-family box this module targets is well past that.
    assume_args=(${lib.escapeShellArgs (lib.concatMap (p: [ "--assume-installed" p ]) cfg.assumeInstalled)})

    # --- 0. distro mismatch detector (always runs -- NOT gated behind either prune flag) -----
    # `distro` is DECLARED, never probed at eval time -- that option's own doc already explains
    # why: this module is evaluated wherever the flake is built, not necessarily the machine it
    # targets, so eval-time detection would as often as not read the WRONG host's identity. This
    # is the runtime complement, and it has to be: it runs ON the real box, where the live pacman
    # database is the actual box's, not eval's guess. A `distro` left at the wrong value costs a
    # box its own keyring/mirrorlist protection under `criticalKeep` -- silently, until someone
    # turns `pruneUndeclared`/`pruneOrphans` on and finds out the hard way. This check exists so
    # that finding-out happens in a log line instead, and happens BEFORE either flag is ever
    # turned on, which is why it is unconditional rather than folded into steps 3/4 below.
    #
    # Deliberately WARN, never fail the unit: one signature package being present is strong
    # evidence, not proof, and "converge packages" should not stop because a heuristic fired.
    #
    # Only checks the DERIVATIVE direction (a box that is secretly cachyos but declares "arch"),
    # never the reverse: "arch" is the fallback with an empty critical-keep list, so there is no
    # signature package whose ABSENCE would mean anything -- a plain Arch box is what you get by
    # not opting into a derivative, not a state with its own fingerprint to check for.
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList
      (name: signaturePkg: ''
        if [ ${lib.escapeShellArg cfg.distro} != ${lib.escapeShellArg name} ] \
          && pacman -Qq ${lib.escapeShellArg signaturePkg} >/dev/null 2>&1; then
          echo "nixarch-packages: WARNING ${lib.escapeShellArg signaturePkg} is installed but nixarch.packages.distro = ${lib.escapeShellArg cfg.distro}, not ${lib.escapeShellArg name} -- this host's ${lib.escapeShellArg name} keyring/mirrorlist floor is likely NOT protected by criticalKeep right now. Check nixarch.packages.distro." >&2
        fi
      '')
      distroSignature)}

    # --- 1. official-repo packages -----------------------------------------
    if [ ''${#pacman_pkgs[@]} -gt 0 ]; then
      echo "nixarch-packages: pacman -S --needed -> ''${pacman_pkgs[*]}"
      pacman -S --needed --noconfirm "''${assume_args[@]}" "''${pacman_pkgs[@]}"
    fi

    # --- 2. AUR packages -----------------------------------------------------
    # makepkg (and every AUR helper built on it) refuses to run as root, so this
    # step MUST drop to a real user. That user in turn needs passwordless sudo
    # for the helper's internal `pacman -U` of the built package — that sudoers
    # entry is part of the same one-time manual bootstrap as the helper itself,
    # not something this module can set up (it would need to already run as
    # root-with-opinions about sudoers, which is out of scope here).
    #
    # ISOLATED PER PACKAGE ON BATCH FAILURE, not a bare command trusted to
    # succeed. An AUR PKGBUILD can pin its checksums against a versioned vendor
    # URL that the vendor rotates off its CDN on its own schedule (zoom's:
    # `https://zoom.us/client/<ver>/zoom_x86_64.pkg.tar.xz`) — the package goes
    # stale with zero action on this module's or this host's part, between one
    # activation and the next. Official-repo packages in step 1 don't share
    # this exposure (the repo IS the source, signed and mirrored by pacman
    # itself), which is why only this step gets the isolation below.
    #
    # A bare `paru -S pkg1 .. pkgN` resolves and commits the whole batch as one
    # transaction: one package's checksum failure fails the command, and under
    # `set -eu` a failed command kills the script outright — taking every OTHER
    # declared AUR package down with it, including ones with nothing to do with
    # the one that actually failed (on a real host: `sway-scroll`, the
    # compositor, and `evdi-dkms`, the DisplayLink kernel driver, both silently
    # never installed because `zoom`, alphabetically last, 404'd first).
    #
    # So: try the batch, and ONLY on failure fall back to one invocation per
    # package to find out which one(s) actually failed. `if cmd; then .. else
    # .. fi` is what keeps this compatible with `set -e` — a bare failing
    # command in that position kills the script the same as an unguarded one,
    # but a command tested by `if`/`while` does not, by `set -e`'s own carve-out
    # (POSIX 2.14.3 / bash's `set -e` manual: a command's failure is ignored
    # when it is part of the test in an `if`, `while`, `until`, or a `&&`/`||`
    # list — see the `assumeInstalled` doc above for the same bash-version-floor
    # reasoning applied elsewhere in this script).
    #
    # COST: the happy path (nothing fails) still costs exactly the one `paru`
    # invocation it always did — the fallback loop only runs at all once the
    # batch has ALREADY failed. Paid only then: on a 16-package list, up to 15
    # extra `paru` process starts (config load, sync-db read, an AUR RPC lookup
    # per package instead of one batched lookup) versus the single batch
    # attempt — real, but bounded, one-time-per-failed-activation, and every
    # invocation for a package the batch already got installed is a fast
    # `--needed` no-op rather than a rebuild. The alternative of always going
    # one-by-one would pay a strict superset of this cost on EVERY run,
    # including the common case where nothing is wrong; this only pays it when
    # something already is.
    if [ ''${#aur_pkgs[@]} -gt 0 ]; then
      ${if cfg.aurUser == null then ''
        echo "nixarch-packages: WARNING nixarch.packages.aur is non-empty but nixarch.packages.aurUser is null — skipping AUR reconcile. Set aurUser to a non-root account with a bootstrapped AUR helper and passwordless sudo."
      '' else ''
        echo "nixarch-packages: ${lib.escapeShellArg cfg.aurHelper} -S --needed (as ${lib.escapeShellArg cfg.aurUser}) -> ''${aur_pkgs[*]}"
        if runuser -u ${lib.escapeShellArg cfg.aurUser} -- ${lib.escapeShellArg cfg.aurHelper} -S --needed --noconfirm "''${assume_args[@]}" "''${aur_pkgs[@]}"; then
          echo "nixarch-packages: AUR batch install succeeded -> ''${aur_pkgs[*]}"
        else
          echo "nixarch-packages: WARNING AUR batch install failed -- falling back to one ${lib.escapeShellArg cfg.aurHelper} invocation per package to isolate which one(s) actually failed" >&2
          failed_aur=()
          for pkg in "''${aur_pkgs[@]}"; do
            if runuser -u ${lib.escapeShellArg cfg.aurUser} -- ${lib.escapeShellArg cfg.aurHelper} -S --needed --noconfirm "''${assume_args[@]}" "$pkg"; then
              echo "nixarch-packages: AUR package installed -> $pkg"
            else
              echo "nixarch-packages: WARNING AUR package FAILED -> $pkg" >&2
              failed_aur+=("$pkg")
            fi
          done
          if [ ''${#failed_aur[@]} -gt 0 ]; then
            echo "nixarch-packages: AUR reconcile finished with FAILURES (isolated -- every other declared AUR package still converged) -> ''${failed_aur[*]}" >&2
            reconcile_failed=1
          fi
        fi
      ''}
    fi

    # --- 3. prune undeclared (opt-in, dangerous) ------------------------------
    # pacman has no notion of "installed before this declaration existed" — a
    # package you rely on but simply forgot to declare is indistinguishable,
    # from here, from genuine drift. Only enable this once `pacman` + `aur` +
    # `keep` together actually describe the box you want.
    ${lib.optionalString cfg.pruneUndeclared ''
      installed=$(pacman -Qqe | LC_ALL=C sort -u)
      declared=$(printf '%s\n' "''${pacman_pkgs[@]}" "''${aur_pkgs[@]}" "$(expand_keep)" | LC_ALL=C sort -u)
      remove=$(comm -23 <(printf '%s\n' "$installed") <(printf '%s\n' "$declared") | sed '/^$/d')

      if [ -z "$remove" ]; then
        echo "nixarch-packages: pruneUndeclared — nothing to remove"
      else
        mapfile -t remove_arr <<< "$remove"
        echo "nixarch-packages: pruneUndeclared removing -> ''${remove_arr[*]}"
        pacman -Rns --noconfirm "''${remove_arr[@]}"
      fi
    ''}

    # --- 4. prune orphans (opt-in, dangerous, SEPARATE from step 3) ----------
    # `pacman -Qdtq`: installed as a DEPENDENCY, required by nothing installed. Structurally
    # invisible to step 3 above (which only ever looks at `-Qqe`, explicit installs), and not
    # fixed by declaring the package in `pacman` either — see the module header for why
    # `--needed` can leave a genuinely-declared package's install reason stuck on "dependency"
    # forever. This is the dedicated sweep for that case.
    #
    # Runs AFTER step 3 on purpose: pruning an undeclared explicit package can itself strand
    # its own dependencies as fresh orphans in the same activation, and a single reconcile
    # should converge as far as it can in one run rather than needing two activations to settle.
    #
    # ITERATES TO A FIXED POINT rather than a single `pacman -Rns $(pacman -Qdtq)` pass. One
    # pacman invocation with `-s` already closes the dependency graph *reachable from the
    # targets you hand it* — passing this round's full orphan list gets you that closure in one
    # transaction. But that is not the same guarantee as "no orphans remain": pacman's orphan
    # accounting can shift on axes a single recursive removal does not chase (a virtual package
    # a removed orphan alone satisfied, a group membership, a DB inconsistency from an earlier
    # partial upgrade) — which is exactly why the standard Arch community idiom for this exact
    # command is "run it again until nothing is left" rather than trusting one pass. Iterating
    # is the more thorough answer; it is also the more dangerous one, which is why every round
    # re-applies the full `keep`/`effectiveKeep` floor (nothing gets a free pass just because it
    # showed up two rounds in) and the loop is hard-capped rather than open-ended: a keep-list
    # that is wrong should fail fast and loud on round one, not get more of the box removed out
    # from under it round after round until someone happens to look at the log.
    ${lib.optionalString cfg.pruneOrphans ''
      orphan_round=0
      while :; do
        orphan_round=$((orphan_round + 1))
        if [ "$orphan_round" -gt ${toString cfg.orphanSweepMaxRounds} ]; then
          echo "nixarch-packages: pruneOrphans — hit the ${toString cfg.orphanSweepMaxRounds}-round safety cap without converging (pacman -Qdtq still non-empty after filtering \`keep\`). Stopping rather than looping forever -- investigate by hand." >&2
          break
        fi

        orphans=$(pacman -Qdtq 2>/dev/null | LC_ALL=C sort -u || true)
        if [ -z "$orphans" ]; then
          echo "nixarch-packages: pruneOrphans — round $orphan_round: pacman -Qdtq is empty, converged"
          break
        fi

        keep_expanded=$(expand_keep | LC_ALL=C sort -u)
        to_remove=$(comm -23 <(printf '%s\n' "$orphans") <(printf '%s\n' "$keep_expanded") | sed '/^$/d')

        if [ -z "$to_remove" ]; then
          echo "nixarch-packages: pruneOrphans — round $orphan_round: remaining orphans are all keep-listed, converged"
          break
        fi

        mapfile -t remove_arr <<< "$to_remove"
        echo "nixarch-packages: pruneOrphans — round $orphan_round removing -> ''${remove_arr[*]}"
        pacman -Rns --noconfirm "''${remove_arr[@]}"
      done
    ''}

    # --- 5. surface a partial AUR failure (step 2) as a failed unit ----------
    # Step 2 above ISOLATES a failing AUR package so the rest of the declared
    # set still converges — but isolating the failure must not also HIDE it.
    # A reconcile that silently reports success while one package never
    # installed is worse than no isolation at all: nothing short of reading
    # the journal by hand would ever reveal that `zoom` is still missing. This
    # runs LAST, after both prune steps, on purpose — pruning is independent
    # of whether every AUR package installed (it diffs the DECLARED lists
    # against what pacman thinks is installed, not against step 2's outcome)
    # and a single reconcile should still converge everything it safely can in
    # one run rather than stopping short over one unrelated package. Only once
    # that is done does this exit non-zero, which is what actually makes the
    # failure visible: `RemainAfterExit` on a oneshot means the unit's status
    # reflects the LAST `ExecStart` exit code, so this is what turns "check
    # `systemctl --failed`" (or anything watching systemd unit state) into a
    # real signal instead of something only a full journal read would catch.
    if [ "''${reconcile_failed:-0}" -eq 1 ]; then
      echo "nixarch-packages: reconcile finished with package failures (see WARNING lines above) -- exiting non-zero so the unit shows failed rather than reporting a clean converge that didn't happen" >&2
      exit 1
    fi
  '';
in
{
  options.nixarch.packages = {
    enable = lib.mkEnableOption
      "declarative Arch package management (converge the installed set to a declared list)";

    pacman = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Official-repo packages to ensure installed (`pacman -S --needed`).";
    };

    aur = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "AUR packages to ensure installed, via an AUR helper (see `aurHelper`/`aurUser`).";
    };

    assumeInstalled = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "evdi=1.15.0" ];
      description = ''
        Dependencies to satisfy with a VIRTUAL package instead of a real one,
        as `name=version` (pacman's `--assume-installed`). Applied to both the
        `pacman` and the `aur` transaction.

        This exists for the case where a dependency is genuinely present but
        cannot be a package *here*: the canonical one is a container whose
        kernel belongs to the host. A DisplayLink dock needs the `evdi` kernel
        module, so its userspace package depends on `evdi` — but inside an LXC
        that module is loaded by the HOST, and the guest has neither kernel
        headers nor `CAP_SYS_MODULE`. Without this, pacman resolves the
        dependency the only way it knows and drags a DKMS package into a
        container that can neither build nor load it.

        ⚠ This is a DEPENDENCY OVERRIDE, so it is only ever correct when you
        know the dependency is satisfied by something outside pacman's view.
        A wrong entry here does not fail loudly — it installs a package whose
        requirements are not actually met, and the breakage surfaces at
        runtime instead.

        Scope note: this applies to the whole reconcile transaction, not to one
        package. pacman has no per-package form of the flag, so a virtual entry
        declared for one package is visible to every other package resolved in
        the same run. Keep the list minimal for that reason.
      '';
    };

    aurHelper = lib.mkOption {
      type = lib.types.str;
      default = "paru";
      description = ''
        AUR helper binary (e.g. `paru`, `yay`). MUST already be installed on
        the box — bootstrapping an AUR helper is itself an AUR build, a
        documented one-time manual step done before this module can help
        (chicken-and-egg: nothing can declaratively install the tool that
        would install it).
      '';
    };

    aurUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Non-root user the AUR helper runs as. REQUIRED for `aur` to do
        anything: makepkg (and every helper built on it) refuses to run as
        root, so the AUR reconcile step drops to this user via `runuser`.
        That user needs passwordless sudo for the helper's internal
        `pacman -U` install step — set up as part of the one-time AUR-helper
        bootstrap, not by this module. If left `null`, a non-empty `aur`
        list is skipped with a loud warning rather than silently failing.
      '';
    };

    pruneUndeclared = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        DANGEROUS: also REMOVE explicitly-installed packages that are not in
        `pacman` ∪ `aur` ∪ `keep` (via `pacman -Rns`). Off by default —
        pacman is not transactional, and a wrong or incomplete list here can
        uninstall things you actually need with no atomic undo.
      '';
    };

    pruneOrphans = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        DANGEROUS, and SEPARATE from `pruneUndeclared`: also REMOVE genuine pacman orphans —
        `pacman -Qdtq`, packages installed as a DEPENDENCY and now required by nothing — via
        `pacman -Rns`, filtered through the same `keep`/`effectiveKeep` floor. Off by default,
        for the same reason `pruneUndeclared` is.

        `pruneUndeclared` cannot substitute for this: it diffs against `pacman -Qqe` (explicit
        installs only), so a dependency-reason orphan is invisible to it no matter how that
        option is set. See the module header for the full reasoning, including why simply
        naming a package in `pacman` does not reliably fix its install reason either.

        Iterates to a fixed point, capped at `orphanSweepMaxRounds` — see that option and the
        `reconcile` script's own comment for why a single pass is not trusted to be enough.
      '';
    };

    orphanSweepMaxRounds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = ''
        Safety cap on `pruneOrphans`'s convergence loop. Each round re-queries
        `pacman -Qdtq`, filters it through `keep`/`effectiveKeep`, and removes what is left;
        the loop stops as soon as a round removes nothing. Ordinary convergence takes one or
        two rounds. Hitting the cap means `pacman -Qdtq` is still non-empty after
        `orphanSweepMaxRounds` rounds of real removals — logged loudly and left for a human,
        rather than continuing to remove packages indefinitely on a keep-list that may be
        wrong.
      '';
    };

    distro = lib.mkOption {
      type = lib.types.enum (lib.attrNames distroCriticalKeep);
      default = "arch";
      example = "cachyos";
      description = ''
        Which Arch-family distribution this host runs. Selects the package-manager
        floor that prune can never remove, on top of the Arch one.

        Declared, never detected. This module is evaluated wherever the flake is
        built, which is not necessarily the machine it targets, so probing
        `/etc/os-release` would read the wrong host's identity — and the failure
        would be silent: a wrong answer here removes protection rather than
        raising an error.

        An `enum` rather than a free string on purpose. A typo in a free-form
        value would resolve to "no extra floor" and prune the keyring, which is
        precisely the outcome this option exists to prevent; a typo in an enum
        fails evaluation. For a derivative not listed here, leave this at `arch`
        and use `extraCriticalKeep` — then send a patch adding it.
      '';
    };

    extraCriticalKeep = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "endeavouros-keyring" "endeavouros-mirrorlist" ];
      description = ''
        Additional names union'd into the non-overridable floor, for an
        Arch derivative `distro` does not model yet.

        Separate from `keep` because it inherits `keep`'s one weakness in
        reverse: `keep` is a plain `listOf`, so setting it REPLACES the default,
        and anything expressed there is lost the moment a consumer customises.
        Entries here survive that, exactly as the built-in floor does.

        Use it only for package-manager preconditions — a keyring, a mirrorlist,
        a pacman hook. Ordinary "do not remove this" belongs in `keep`.
      '';
    };

    keep = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "base" "base-devel" ];
      description = ''
        Package groups or exact names that are NEVER removed even when
        `pruneUndeclared` or `pruneOrphans` is on — the safety floor. Entries are expanded as
        pacman groups first (`pacman -Sqg`); anything that isn't a known
        group is kept as a literal package name.

        SETTING THIS REPLACES THE DEFAULT, it does not add to it — a plain
        `listOf` works that way. So treat this as "the whole floor I want",
        not "extras on top".

        The one exception is deliberate: the package-manager floor is union'd in
        unconditionally and cannot be removed from here, because a guard you lose
        the moment you start customising is a guard that fails exactly when it is
        needed. See `criticalKeep` at the top of this file, and read
        `effectiveKeep` to see what prune will actually apply.

        DERIVATIVE DISTROS ARE HANDLED BY `distro`, NOT HERE. Set
        `distro = "cachyos"` and the derivative's keyring, mirrorlists and pacman
        hooks join the floor on the same non-overridable terms — never add them to
        `keep` itself: a floor expressed in a plain `listOf` disappears the moment
        a host sets that list for some unrelated reason, and the packages in
        question are the PRECONDITION for fetching anything — lose them and the
        machine cannot reinstall them.

        Note that a derivative ADDS to the Arch floor rather than replacing it.
        On CachyOS, `[core]`, `[extra]` and `[multilib]` still resolve through
        Arch's own `/etc/pacman.d/mirrorlist`; only the `[cachyos*]` repos use the
        CachyOS lists. Both keyrings and both mirrorlists are load-bearing.
      '';
    };
  };

  # Computed, read-only: what prune will ACTUALLY refuse to remove. Exposed because `keep` alone
  # does not tell you -- the package-manager set is union'd in by this module and survives any
  # override. A consumer debugging "why was X removed / kept" should read this, not `keep`.
  #
  # No `default`, and defined unconditionally below: `readOnly` permits exactly one definition,
  # and a default plus a `mkIf`-guarded definition counts as two.
  options.nixarch.packages.effectiveKeep = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = "The keep-set prune actually applies: `keep` plus the non-removable package-manager floor.";
  };

  # Computed, read-only, same shape as `effectiveKeep` above and for the same reason: exposed
  # because there is otherwise no way to inspect the generated reconcile script without building
  # it. This is what lets checks/default.nix assert real, static properties of the actual script
  # this module ships -- e.g. that an AUR batch failure falls back to per-package installs, and
  # that a partial failure exits non-zero -- via `pkgs.writeShellScript`'s own `.text` passthru
  # (the literal string handed to it, readable at eval time, no store realisation required). NOT a
  # stable interface: nothing outside the check suite should depend on this option's presence or
  # the script's exact shape, only on the module's declared config/systemd surface.
  options.nixarch.packages.reconcileScript = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The generated reconcile script (same derivation `ExecStart` runs). Exposed for checks/default.nix's static-text assertions; not a stable interface.";
  };

  config = lib.mkMerge [
    { nixarch.packages.effectiveKeep = lib.unique (criticalKeep ++ cfg.keep); }
    { nixarch.packages.reconcileScript = reconcile; }

    (lib.mkIf cfg.enable {
    systemd.services.nixarch-packages-reconcile = {
      description = "nixarch: converge the installed Arch/AUR package set to the declared list";
      # multi-user.target (not sysinit) so system-manager (re)runs this on a live
      # `switch`, not only at boot — sysinit is already past by the time `switch`
      # runs, same reasoning as the other oneshots in this project.
      wantedBy = [ "multi-user.target" ];
      # system-manager injects a nix-store-only PATH (no /usr/bin) into every unit
      # it declares, so `pacman`/`runuser` (and the coreutils the prune step uses)
      # would not resolve on a real box. Force the normal host PATH; see
      # lib/host-path.nix for why mkForce is the only thing that wins here.
      environment.PATH = lib.mkForce hostPaths.hostPath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${reconcile}";
      };
    };
    })
  ];
}
