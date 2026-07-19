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
# PRUNING IS OPT-IN AND DANGEROUS: `pruneUndeclared` actually removes
# packages (`pacman -Rns`) that are explicitly installed but not in your
# declared lists. pacman has no concept of "this was here before your
# declaration existed" — a package you depend on but simply forgot to list
# looks identical, to this reconciler, to genuine drift. It defaults off.
# `keep` is the safety floor under it: groups/names that are never removed
# even with pruning on, defaulting to the two groups a running Arch system
# cannot lose.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.packages;

  reconcile = pkgs.writeShellScript "nixarch-packages-reconcile" ''
    set -eu

    pacman_pkgs=(${lib.escapeShellArgs cfg.pacman})
    aur_pkgs=(${lib.escapeShellArgs cfg.aur})
    keep_list=(${lib.escapeShellArgs cfg.keep})

    # --- 1. official-repo packages -----------------------------------------
    if [ ''${#pacman_pkgs[@]} -gt 0 ]; then
      echo "nixarch-packages: pacman -S --needed -> ''${pacman_pkgs[*]}"
      pacman -S --needed --noconfirm "''${pacman_pkgs[@]}"
    fi

    # --- 2. AUR packages -----------------------------------------------------
    # makepkg (and every AUR helper built on it) refuses to run as root, so this
    # step MUST drop to a real user. That user in turn needs passwordless sudo
    # for the helper's internal `pacman -U` of the built package — that sudoers
    # entry is part of the same one-time manual bootstrap as the helper itself,
    # not something this module can set up (it would need to already run as
    # root-with-opinions about sudoers, which is out of scope here).
    if [ ''${#aur_pkgs[@]} -gt 0 ]; then
      ${if cfg.aurUser == null then ''
        echo "nixarch-packages: WARNING nixarch.packages.aur is non-empty but nixarch.packages.aurUser is null — skipping AUR reconcile. Set aurUser to a non-root account with a bootstrapped AUR helper and passwordless sudo."
      '' else ''
        echo "nixarch-packages: ${lib.escapeShellArg cfg.aurHelper} -S --needed (as ${lib.escapeShellArg cfg.aurUser}) -> ''${aur_pkgs[*]}"
        runuser -u ${lib.escapeShellArg cfg.aurUser} -- ${lib.escapeShellArg cfg.aurHelper} -S --needed --noconfirm "''${aur_pkgs[@]}"
      ''}
    fi

    # --- 3. prune undeclared (opt-in, dangerous) ------------------------------
    # pacman has no notion of "installed before this declaration existed" — a
    # package you rely on but simply forgot to declare is indistinguishable,
    # from here, from genuine drift. Only enable this once `pacman` + `aur` +
    # `keep` together actually describe the box you want.
    ${lib.optionalString cfg.pruneUndeclared ''
      installed=$(pacman -Qqe | LC_ALL=C sort -u)

      # Expand `keep` groups to their member packages; anything that is not a
      # known group (a plain package name, most likely) is kept as-is.
      keep_expanded=""
      for k in "''${keep_list[@]}"; do
        grp=$(pacman -Sqg "$k" 2>/dev/null || true)
        if [ -n "$grp" ]; then
          keep_expanded="$keep_expanded
$grp"
        else
          keep_expanded="$keep_expanded
$k"
        fi
      done

      declared=$(printf '%s\n' "''${pacman_pkgs[@]}" "''${aur_pkgs[@]}" "$keep_expanded" | LC_ALL=C sort -u)
      remove=$(comm -23 <(printf '%s\n' "$installed") <(printf '%s\n' "$declared") | sed '/^$/d')

      if [ -z "$remove" ]; then
        echo "nixarch-packages: pruneUndeclared — nothing to remove"
      else
        mapfile -t remove_arr <<< "$remove"
        echo "nixarch-packages: pruneUndeclared removing -> ''${remove_arr[*]}"
        pacman -Rns --noconfirm "''${remove_arr[@]}"
      fi
    ''}
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

    keep = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "base" "base-devel" ];
      description = ''
        Package groups or exact names that are NEVER removed even when
        `pruneUndeclared` is on — the safety floor. Entries are expanded as
        pacman groups first (`pacman -Sqg`); anything that isn't a known
        group is kept as a literal package name.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.nixarch-packages-reconcile = {
      description = "nixarch: converge the installed Arch/AUR package set to the declared list";
      # multi-user.target (not sysinit) so system-manager (re)runs this on a live
      # `switch`, not only at boot — sysinit is already past by the time `switch`
      # runs, same reasoning as the other oneshots in this project.
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${reconcile}";
      };
    };
  };
}
