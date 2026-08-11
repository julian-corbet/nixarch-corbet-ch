# modules/packages-audit.nix — reports what is on this machine that the declaration does not
# explain, and what exists more than once. REPORTS ONLY: it never installs, removes, or fails.
#
# WHY THIS IS SEPARATE FROM THE RECONCILE. The reconcile converges the DECLARED set: it installs
# what is named and prunes orphaned dependencies. Two whole classes of drift are structurally
# invisible to it, and both were found by hand on live machines rather than by any build:
#
#   1. AN EXPLICITLY-INSTALLED PACKAGE NOBODY DECLARED. `pacman -Qdtq` -- what pruneOrphans walks
#      -- lists orphaned DEPENDENCIES. A package someone installed on purpose is not an orphan and
#      is never questioned, so undeclared software accumulates silently and forever. Found this
#      way on 2026-08-11: `brightnessctl` and `cachyos-wallpapers` (both declared as nixdesktop
#      ROLES that no Arch role table read, so the declaration resolved to nothing), `kanshi`
#      (deliberately retired the night before; the package outlived its declaration), and two
#      leftovers from a broken AUR build.
#
#   2. THE SAME COMMAND IN TWO PLACES AT ONCE. Which one runs is decided by PATH order, silently,
#      and the loser can be the NEWER one. Live on the same box the same day: `sops` 3.13.1 from a
#      hand-run `nix profile install` sitting ahead of the distro's 3.13.3, and `tpm2-tools` 5.8
#      from nixpkgs beside 5.7 from pacman -- that one from a SINGLE module option that declares
#      the package on both planes at once, so the config was self-consistent and still produced a
#      duplicate.
#
# Neither is a build-time question. Both are about what is actually on the disk, which is why this
# runs on the machine at activation rather than being a check in a flake.
#
# WARN-ONLY, ON PURPOSE, FOR NOW. Nobody knows how big this is on a machine that has never been
# audited, and a first run that BLOCKS activation on a decade of accumulated drift is a report
# nobody can act on -- it just gets disabled. It reports, every activation, until the number is
# small enough that turning it into an error is a decision rather than a demolition.
#
# IT DOES NOT DECIDE ANYTHING. Every line it prints is a question for a human: declare it, or
# remove it. This module has no opinion about which, because the answer depends on whether the
# thing is wanted -- and that is not a fact any package database contains.
{ config, lib, pkgs, ... }:
let
  cfg = config.nixarch.packages;
  hostPaths = import ../lib/host-path.nix { inherit lib; };

  # The prefixes a command can live in on an Arch host that also has nix. Ordered as PATH orders
  # them, because that is what decides which copy of a duplicate actually runs.
  #
  # `%h` is not available here and the user is not known at eval time, so the per-user prefixes are
  # discovered at RUN time from the passwd database rather than being baked in -- a machine with
  # two humans on it has two profiles to check, and hardcoding one operator's name would quietly
  # audit half the box.
  audit = pkgs.writeShellScript "nixarch-packages-audit" ''
    set -uo pipefail

    declared=${lib.escapeShellArg (lib.concatStringsSep "\n" (lib.unique (cfg.pacman ++ cfg.aur)))}

    # Groups (base, base-devel) expand to their members; a declared group means every package in
    # it is declared. Without this every member of base-devel reads as undeclared.
    expanded=$(
      printf '%s\n' "$declared" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        members=$(pacman -Sgq "$p" 2>/dev/null)
        if [ -n "$members" ]; then printf '%s\n' "$members"; else printf '%s\n' "$p"; fi
      done | sort -u
    )

    undeclared=$(comm -13 <(printf '%s\n' "$expanded") <(pacman -Qeq | sort -u))

    if [ -n "$undeclared" ]; then
      echo "nixarch-packages-audit: INSTALLED BUT NOT DECLARED -- each is either something to declare or something to remove:" >&2
      printf '%s\n' "$undeclared" | while IFS= read -r p; do
        [ -n "$p" ] || continue
        echo "  $p -- $(pacman -Qi "$p" 2>/dev/null | sed -n 's/^Description *: //p')" >&2
      done
    fi

    # ── duplicates across the substrate boundary ──────────────────────────────────────────────
    # Only bin dirs that EXIST are walked, so this is silent about planes a host does not have,
    # and `/run/current-system` is skipped when it is a symlink to /run/system-manager -- on these
    # hosts it is, and counting one tree under two names reported ~150 phantom duplicates the
    # first time this was done by hand.
    dirs=""
    for d in /usr/local/bin /usr/bin /run/system-manager/sw/bin /nix/var/nix/profiles/default/bin; do
      [ -d "$d" ] && dirs="$dirs $d"
    done
    if [ -d /run/current-system/sw/bin ] && [ "$(readlink -f /run/current-system)" != "$(readlink -f /run/system-manager)" ]; then
      dirs="$dirs /run/current-system/sw/bin"
    fi
    while IFS=: read -r user _ uid _ _ home _; do
      [ "$uid" -ge 1000 ] 2>/dev/null || continue
      for d in "$home/.nix-profile/bin" "/etc/profiles/per-user/$user/bin" "$home/.local/bin"; do
        [ -d "$d" ] && dirs="$dirs $d"
      done
    done < /etc/passwd

    dupes=$(
      for d in $dirs; do
        find -L "$d" -maxdepth 1 -type f -executable -printf '%f\t%h\n' 2>/dev/null
      done | sort | awk -F'\t' '
        { if ($1 == prev) { locs = locs " | " $2; n++ } else { if (n > 1) print prev "\t" locs; prev = $1; locs = $2; n = 1 } }
        END { if (n > 1) print prev "\t" locs }'
    )

    if [ -n "$dupes" ]; then
      count=$(printf '%s\n' "$dupes" | wc -l)
      echo "nixarch-packages-audit: $count COMMAND(S) EXIST IN MORE THAN ONE PLACE -- PATH order decides which runs, silently:" >&2
      printf '%s\n' "$dupes" | sed 's/^/  /' >&2
    fi

    if [ -z "$undeclared" ] && [ -z "$dupes" ]; then
      echo "nixarch-packages-audit: clean -- nothing undeclared, nothing duplicated"
    fi

    # ALWAYS ZERO. See this module's header: reporting is the whole job today.
    exit 0
  '';
in
{
  options.nixarch.packages.audit.enable = lib.mkEnableOption ''
    reporting installed-but-undeclared packages and duplicated commands after each reconcile.

    Reports only -- it installs nothing, removes nothing, and cannot fail an activation. See the
    module header for the two classes of drift it exists to surface and why neither is visible to
    the reconcile itself or to any build-time check.
  '';

  config = lib.mkIf (cfg.enable && cfg.audit.enable) {
    systemd.services.nixarch-packages-audit = {
      description = "nixarch: report undeclared packages and duplicated commands (reports only)";
      wantedBy = [ "multi-user.target" ];
      # AFTER the reconcile, so it describes the converged machine rather than the one that was
      # there a moment ago. `after` only -- not `requires`: a reconcile that fails on one broken
      # AUR package is exactly when an operator most wants to know what else is adrift, and a
      # report that refuses to run when something is wrong is a report that runs when it is least
      # needed.
      after = [ "nixarch-packages-reconcile.service" ];
      environment.PATH = lib.mkForce hostPaths.hostPath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${audit}";
      };
    };
  };
}
