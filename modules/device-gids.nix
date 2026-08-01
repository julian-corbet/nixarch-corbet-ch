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
# per-user/cross-host choice, supplied entirely via `nixarch.deviceGids`. With
# an empty map it is a complete no-op.
#
# ── Defaulting from nixiam.posix.groups, never the reverse ───────────────────
# `nixarch.deviceGids` is the MECHANISM (pin + migrate + the tty/devpts
# lockstep above); nixiam's `posix.groups` (modules/posix.nix) is the TABLE — a
# plain name-to-gid map, cross-host, for exactly the reason its own header
# gives: two machines that let the same group name auto-allocate
# independently end up with different gid numbers, and anything using
# AUTH_SYS (NFS's numeric-only security flavor) then grants or denies access
# based on WHICH machine asked, not what the caller actually is. Defaulting
# from that table here means the cross-host numbering is declared exactly
# once, in nixiam, rather than restated by hand in every host's
# `nixarch.deviceGids` with nothing asserting the copies still agree.
#
# So: read `config.nixiam.posix.groups` through `lib.probeFact`
# (github:julian-corbet/nixhost-corbet-ch, `lib/facts.nix`) and let the
# resolved value become the DEFAULT for `nixarch.deviceGids`. This repo
# takes nixiam as neither a flake input nor an import — a bare
# `config.nixiam.posix.groups or { }` cannot tell "nixiam was never composed
# here" (legitimate, silent) from "nixiam IS composed, but `posix.groups`
# moved, was renamed, or its value was rejected by its own type" (a defect,
# and a bare `or` hides it exactly as silently as the first case) — see
# nixhost's own `lib/facts.nix` header for the full defect class and the two
# evaluation traps a naive fix falls into. `probeFact` answers which of the
# two happened: `state == "absent"` for a host that has never heard of
# nixiam (still evaluates this module fine, exactly the no-op its header
# already promises), `state == "unresolved"` for the composed-but-broken
# case (falls back to `{ }` the same as absent, but ALSO renders a warning —
# see `groupsProbe`'s use in `config` below), `state == "resolved"` for the
# healthy case this module was built for. A host that HAS composed nixiam's
# posix module (system-manager's module system is the same `lib.evalModules`
# nixiam's pure option declarations were written against) gets the
# cross-host table for free. Either way, an explicitly-declared
# `nixarch.deviceGids` on any one host still wins outright — a plain option
# `default` is exactly the priority a hand-typed value already overrides, so
# a host carving its own numbering (or one with no sibling module at all)
# is completely unaffected. Direction stays one-way: nixiam must never learn
# this module, or a group name, or a gid — only ever be read from.
{ probeFact }:
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.deviceGids;
  ttyCfg = config.nixarch.ttyDevpts;
  enabled = config.nixarch.deviceGidsEnable;

  # See the header block above for why this goes through `probeFact` rather than a bare `or`:
  # `state == "absent"` and `state == "unresolved"` both resolve `value` to `fallback` (`{ }`) --
  # deliberately indistinguishable to `nixiamGroups` itself, since either way the safe behavior
  # here is "no default to offer" -- but `groupsProbe.warnings` (spliced into `config.warnings`
  # below) is what tells the two apart for whoever reads the build output.
  groupsProbe = probeFact {
    inherit config;
    # `deviceGroups`, not `groups`: nixiam split the two because they need opposite number
    # policies. This module is the device half -- names the platform already knows (`video`,
    # `render`, `input`, `wheel`), which must stay below a distro's dynamic-allocation floor or the
    # pinning is undone on the next package install. Shared groups this fleet hands out live in
    # `groups` and use the high band.
    namespace = "nixiam.posix";
    path = "deviceGroups";
    fallback = { };
  };
  nixiamGroups = groupsProbe.value;

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
      # The default is NOT `nixiamGroups` here -- see `config`, below, for why. A bare
      # `default = nixiamGroups;` on this OPTION declaration would be a single implicit
      # definition of the whole attrset at the module system's lowest priority: the instant a
      # host wrote so much as `nixarch.deviceGids.render = 500;` to pin ONE group, that plain
      # (unwrapped, normal-priority) definition would outrank and wholly REPLACE this default --
      # not merge with it -- silently dropping every other nixiam-derived entry (`video`,
      # `input`, ...) from the pinned/migrated set, with no error. `attrsOf` merges per-KEY only
      # among definitions that survive the OPTION-level priority filter first; a lower-priority
      # definition that loses that filter contributes nothing at all, regardless of which keys it
      # was missing. Proved live with `nix-instantiate` against this exact shape before writing
      # this comment -- this was not a hypothetical, see `nixaudio.fabric.peers` for a case where
      # the equivalent gap actually shipped and one fleet host's audio peers silently collapsed to
      # the one hand-written entry for weeks.
      default = { };
      defaultText = lib.literalExpression "config.nixiam.posix.groups or { }";
      example = { render = 500; video = 501; };
      description = ''
        Map of group name -> gid to pin and, if the group already exists under
        a different gid, migrate to via `groupmod`. Include an entry for
        `tty` to also enable the devpts lockstep below. An empty map makes
        this module a no-op.

        Defaults to `config.nixiam.posix.groups` (nixiam's cross-host POSIX
        group registry) when that module is present, so a cross-host gid
        table only needs to be declared once, in nixiam, rather than restated
        per host here. Set this explicitly to pin a different map, or to
        override any one entry the default supplies -- literally true now (see
        `config`'s per-key `lib.mkDefault`, below): overriding `render` alone
        leaves `video`/`input`/every other nixiam-derived entry intact.
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

  config = lib.mkMerge [
    # Populates the default here, on the `config` side, per-key -- NOT as the option's own
    # `default =` (see that option's own comment for why a bare option-level default of this
    # shape is the exact bug this repo was asked to sweep for). `lib.mapAttrs` wraps EACH
    # group's gid in its own `lib.mkDefault`, so each becomes its own independent, per-key
    # definition of `deviceGids` rather than one definition covering the whole attrset: a host
    # writing `nixarch.deviceGids.render = 500;` now only ever competes with (and wins against)
    # THIS key's own `mkDefault`, leaving every other nixiam-derived entry untouched. Unconditional
    # (not gated on `enabled`) to match the option's previous behavior -- `deviceGids` is DATA,
    # resolved the same way regardless of whether the pin/migrate mechanism is switched on; the
    # mechanism's own "complete no-op when disabled" promise is kept below, by gating the actual
    # side effects (not this value) on `enabled`.
    { nixarch.deviceGids = lib.mapAttrs (_: lib.mkDefault) nixiamGroups; }

    # The probe's warning is gated on `enabled` ALONE, deliberately never on `groupNames != [ ]`
    # too: state "absent" and state "unresolved" both resolve `nixiamGroups` to the SAME fallback
    # (`{ }`), so gating the warning on the resolved map being non-empty would hide it in exactly
    # the case it exists to report -- a host that leans on the nixiam default (no explicit
    # `nixarch.deviceGids` of its own), where nixiam turns out to be composed but broken, ends up
    # with `groupNames == [ ]` from the fallback and would silently never see the warning render.
    # Gating on `enabled` alone keeps the module's own "complete no-op when disabled" promise
    # intact (a host that never turns this mechanism on sees zero effect from it, warnings
    # included) while making the warning visible in every case where it might matter.
    (lib.mkIf enabled {
      warnings = groupsProbe.warnings;
    })
    (lib.mkIf (enabled && groupNames != [ ]) {
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
    })
  ];
}
