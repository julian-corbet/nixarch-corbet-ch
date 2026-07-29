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
#
# ── Defaulting from nixid.posix.groups, never the reverse ───────────────────
# `nixarch.deviceGids` is the MECHANISM (pin + migrate + the tty/devpts
# lockstep above); nixid's `posix.groups` (modules/posix.nix) is the TABLE — a
# plain name-to-gid map, fleet-wide, for exactly the reason its own header
# gives: two machines that let the same group name auto-allocate
# independently end up with different gid numbers, and anything using
# AUTH_SYS (NFS's numeric-only security flavor) then grants or denies access
# based on WHICH machine asked, not what the caller actually is. Before this
# default existed, that table had to be restated by hand in every host's
# `nixarch.deviceGids`, which is exactly the kind of copy this repo's sibling
# `nixid` was built to make impossible — a fleet where render/video/input/tty
# happen to sit at gids 400-416 on three machines only because someone typed
# 400-416 three times, with nothing asserting the three typings still agree.
#
# So: read `config.nixid.posix.groups` defensively (`or { }`) and let it
# become the DEFAULT for `nixarch.deviceGids`. Defensively, because this
# repo takes nixid as neither a flake input nor an import — a host that has
# never heard of nixid still evaluates this module fine, `cfg` is just
# `{ }`, and the whole module stays the no-op its header already promises.
# A host that HAS composed nixid's posix module into its own configuration
# (system-manager's module system is the same `lib.evalModules` nixid's pure
# option declarations were written against — see that module's own header:
# no `pkgs`, no `systemd.services`, nothing NixOS-specific to be reachable
# from) gets the fleet table for free. Either way, an explicitly-declared
# `nixarch.deviceGids` on any one host still wins outright — a plain option
# `default` is exactly the priority a hand-typed value already overrides, so
# a host carving its own numbering (or one with no sibling module at all)
# is completely unaffected. Direction stays one-way: nixid must never learn
# this module, or a group name, or a gid — only ever be read from.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.deviceGids;
  ttyCfg = config.nixarch.ttyDevpts;
  enabled = config.nixarch.deviceGidsEnable;

  # See the header block above for why this is read defensively rather than
  # imported: `or { }` resolves to the empty map both when nixid was never
  # composed into this configuration at all, and when it was but declared no
  # groups — the module cannot and need not tell those two cases apart.
  nixidGroups = config.nixid.posix.groups or { };

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
      # Defaults from nixid's fleet-wide `posix.groups` table when that module has been
      # composed into this configuration (read defensively; see the header block above for
      # why this is a default and never an import). Set this explicitly to override it, carve
      # your own numbering with no sibling module at all, or opt out with `{ }`.
      default = nixidGroups;
      defaultText = lib.literalExpression "config.nixid.posix.groups or { }";
      example = { render = 500; video = 501; };
      description = ''
        Map of group name -> gid to pin and, if the group already exists under
        a different gid, migrate to via `groupmod`. Include an entry for
        `tty` to also enable the devpts lockstep below. An empty map makes
        this module a no-op.

        Defaults to `config.nixid.posix.groups` (nixid's fleet-wide POSIX
        group registry) when that module is present, so a fleet-wide gid
        table only needs to be declared once, in nixid, rather than restated
        per host here. Set this explicitly to pin a different map, or to
        override any one entry the default supplies.
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
