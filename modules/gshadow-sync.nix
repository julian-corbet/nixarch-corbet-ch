# modules/gshadow-sync.nix — keep /etc/gshadow in lockstep with /etc/group.
#
# WHY: userborn (how system-manager realises `users.groups`) writes /etc/passwd,
# /etc/group and /etc/shadow, but NOT /etc/gshadow. Every group it creates
# therefore lands in /etc/group with no matching /etc/gshadow line. Arch ships
# a daily hygiene check, shadow.service (`pwck -qr || r=1; grpck -r && exit
# $r`), and `grpck` calls that an inconsistency and exits non-zero. The box
# then carries a permanently-red unit — which is worse than cosmetic: a check
# you have learned to ignore cannot warn you about a REAL passwd/shadow
# problem later.
#
# The gap is not exclusive to groups system-manager itself declares — any
# group that predates gshadow accounting on the box (or is added by a package
# outside Nix's view) can be missing a line too, so this is general Arch
# hygiene rather than only a userborn artefact.
#
# WHAT: an idempotent oneshot running `grpconv` — the shadow-suite tool that
# regenerates /etc/gshadow from /etc/group, preserving the group-password and
# group-administrator fields of entries that already exist and writing
# `name:!::` (no password, no admins — the safe default, and what a group
# without a gshadow line effectively means anyway) for the missing ones.
# Guarded: it diffs the two files first and exits without touching anything
# when they already agree, so a converged box never rewrites /etc/gshadow.
#
# SCOPE: gshadow only, deliberately. /etc/shadow holds real password hashes —
# a passwd/shadow divergence is a genuine event that deserves human eyes, not
# a silent auto-repair. There is no pwconv here on purpose.
#
# NixOS portability: NixOS realises users with the same userborn and has the
# same blind spot, so this module carries over as-is under `nixosModules` —
# only the import path differs, not the logic.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.gshadowSync;

  sync = pkgs.writeShellScript "gshadow-sync" ''
    set -u
    group=/etc/group
    gshadow=/etc/gshadow

    if [ ! -f "$group" ]; then
      echo "gshadow-sync: $group is missing — refusing to run"
      exit 1
    fi

    if [ -f "$gshadow" ]; then
      # Names in /etc/group with no /etc/gshadow line, and gshadow lines with no group.
      missing=$(${pkgs.gawk}/bin/awk -F: 'NR==FNR{s[$1]=1;next} !($1 in s){print $1}' "$gshadow" "$group")
      stale=$(${pkgs.gawk}/bin/awk -F: 'NR==FNR{s[$1]=1;next} !($1 in s){print $1}' "$group" "$gshadow")

      if [ -z "$missing" ] && [ -z "$stale" ]; then
        echo "gshadow-sync: /etc/gshadow already agrees with /etc/group — nothing to do"
        exit 0
      fi

      [ -n "$missing" ] && echo "gshadow-sync: adding:   $(echo $missing | tr '\n' ' ')"
      [ -n "$stale" ]   && echo "gshadow-sync: dropping: $(echo $stale | tr '\n' ' ')"

      # One-time safety copy of the file grpconv is about to regenerate.
      if [ ! -f "$gshadow.pre-gshadow-sync" ]; then
        ${pkgs.coreutils}/bin/cp -a "$gshadow" "$gshadow.pre-gshadow-sync"
      fi
    else
      echo "gshadow-sync: /etc/gshadow does not exist — grpconv will create it"
    fi

    ${pkgs.shadow}/bin/grpconv
    echo "gshadow-sync: grpconv done"
  '';
in
{
  options.nixarch.gshadowSync.enable = lib.mkEnableOption
    "the gshadow-sync oneshot that heals /etc/gshadow after userborn writes /etc/group";

  config = lib.mkIf cfg.enable {
    systemd.services.gshadow-sync = {
      description = "Sync /etc/gshadow with /etc/group (userborn writes group but not gshadow)";
      # Two pull-ins on purpose:
      #   multi-user.target — every boot, and a live `system-manager switch` (sysinit is long
      #                       past by then, so a sysinit-wanted unit would silently not fire —
      #                       same reasoning as the devpts service in modules/device-gids.nix).
      #   shadow.service    — re-heals immediately before the daily check, so a group created
      #                       between boots cannot leave the check red for a day.
      wantedBy = [ "multi-user.target" "shadow.service" ];
      after = [ "userborn.service" "gid-migrate.service" ];
      before = [ "shadow.service" ];
      serviceConfig = {
        Type = "oneshot";
        # NOT RemainAfterExit: the unit must be startable again for the shadow.service pull-in
        # above to actually re-run it each day.
        ExecStart = "${sync}";
      };
    };
  };
}
