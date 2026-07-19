# modules/device-gids.nix — pin shared device groups (render, video, input, ...)
# to a caller-supplied gid map, and keep them there across reboots. Three parts:
#
#   1. Declaration — pin every group named in `nixarch.deviceGids` to its gid.
#      Correct for a fresh account, but not sufficient on its own: userborn (how
#      system-manager realises `users.groups`) does NOT renumber an EXISTING
#      group from a declaration, it only creates missing ones at the declared
#      gid. A box that already has e.g. `video` at some other gid stays there.
#
#   2. gid-migrate.service — an idempotent `groupmod` oneshot that renumbers any
#      pre-existing group to the gid the caller asked for, skipping groups that
#      are already correct and refusing to clobber a gid that's already taken
#      by something else.
#
#   3. The tty <-> devpts lockstep. Arch's systemd bakes the tty group's gid
#      into /dev/pts at COMPILE time, so renumbering the `tty` group alone does
#      not change the live gid of /dev/pts — a remount service is needed to
#      make the pseudo-terminal mount track the gid you actually chose.
#
# This module has no opinion on WHAT the gid numbers should be — that's a
# per-user/per-fleet choice, supplied entirely via `nixarch.deviceGids`. With
# an empty map it is a complete no-op.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.deviceGids;
  ttyCfg = config.nixarch.ttyDevpts;
  enabled = config.nixarch.deviceGidsEnable;

  groupNames = builtins.attrNames cfg;
  migratePairs = lib.concatStringsSep " " (map (n: "${n}:${toString cfg.${n}}") groupNames);
  migrate = pkgs.writeShellScript "gid-migrate" ''
    set -u
    for pair in ${migratePairs}; do
      name=''${pair%%:*}; new=''${pair##*:}
      cur=$(${pkgs.gawk}/bin/awk -F: -v n="$name" '$1==n{print $3}' /etc/group)
      [ -z "$cur" ] && continue
      [ "$cur" = "$new" ] && continue
      if ${pkgs.gawk}/bin/awk -F: -v g="$new" 'BEGIN{e=1} $3==g{e=0} END{exit e}' /etc/group; then
        echo "gid-migrate: $name wants $new but it is taken; skip"; continue; fi
      ${pkgs.shadow}/bin/groupmod -g "$new" "$name" && echo "gid-migrate: $name $cur -> $new"
    done
  '';

  ttyGid = cfg.tty or null;
in
{
  options.nixarch = {
    deviceGidsEnable = lib.mkEnableOption
      "pinning + migrating the groups listed in nixarch.deviceGids to their canonical gids";

    deviceGids = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = { };
      example = { render = 500; video = 501; };
      description = ''
        Map of group name -> gid to pin and, if the group already exists under
        a different gid, migrate to via `groupmod`. Include an entry for
        `tty` to also enable the devpts lockstep below. An empty map makes
        this module a no-op.
      '';
    };

    ttyDevpts = {
      mode = lib.mkOption {
        type = lib.types.str;
        default = "620";
        description = "Mode to apply to the /dev/pts mount when the tty gid is remounted.";
      };
      ptmxmode = lib.mkOption {
        type = lib.types.str;
        default = "666";
        description = "ptmxmode to apply to the /dev/pts mount when the tty gid is remounted.";
      };
    };
  };

  config = lib.mkIf (enabled && groupNames != [ ]) {
    # Declaration (correct for fresh accounts).
    users.groups = lib.genAttrs groupNames (n: { gid = lib.mkForce cfg.${n}; });

    # Migration (renumbers pre-existing groups; idempotent no-op once converged).
    systemd.services.gid-migrate = {
      description = "Migrate existing device groups to the gids in nixarch.deviceGids";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${migrate}"; };
    };

    # devpts lockstep — only when the caller pinned `tty`, since without it there is no
    # canonical tty gid to remount to.
    systemd.services.devpts-gid = lib.mkIf (ttyGid != null) {
      description = "Pin /dev/pts to the configured tty gid";
      # multi-user.target (not sysinit) so system-manager (re)starts it on a live ACTIVATION,
      # not only at boot — sysinit is already passed when you `switch`, so a sysinit-wanted
      # unit would silently not fire.
      wantedBy = [ "multi-user.target" ];
      before = [ "systemd-user-sessions.service" ];
      after = [ "systemd-remount-fs.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "${pkgs.util-linux}/bin/mount -o remount,gid=${toString ttyGid},mode=${ttyCfg.mode},ptmxmode=${ttyCfg.ptmxmode} devpts /dev/pts"
          "-${pkgs.coreutils}/bin/chgrp ${toString ttyGid} /dev/ptmx"
        ];
      };
    };
  };
}
