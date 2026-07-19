# modules/foreign-service.nix — declaratively manage the CONFIG of a service
# whose binary and systemd unit are owned by pacman (foreign to Nix), while
# still getting an automatic re-apply when that config changes.
#
# THE SPLIT this module encodes:
#   - pacman owns the BINARY and the systemd UNIT — imperative, foreign,
#     completely out of scope here. This module never installs a package
#     and never declares a service's [Unit]/[Service] definition.
#   - Nix owns the CONFIG as a declarative `environment.etc` entry (system-
#     manager's equivalent of NixOS's `environment.etc`) — a file, generated
#     from your Nix expression, that replaces whatever pacman or a human
#     hand-wrote at that path.
#   - A BRIDGE oneshot is the missing piece between those two worlds:
#     system-manager restarts units it owns whose *own* store path moved,
#     but it has no NixOS-style "a file I wrote changed, so restart the
#     things that read it" wiring for units it does NOT own. This module
#     builds that bridge explicitly, per foreign service, keyed on the
#     content of the config files you hand it.
#
# This module supplies NONE of the payload. It has no opinion on what
# service you're managing, what its config should say, or which units it
# owns — all of that is `nixarch.foreignServices.<name>.*`, entirely yours.
# An empty attrset is a complete no-op.
#
# ── GOTCHA (a): system-manager can SILENTLY SKIP an /etc entry ──────────────
# If the destination path already exists on disk and the entry does not set
# `replaceExisting = true`, system-manager silently declines to write it —
# no error, no warning, just a no-op module. This is exactly the trap that
# turns a "working" config change into nothing happening on the box. Every
# entry this module generates sets `replaceExisting = true` unconditionally
# for that reason; you never need to (and should not have to) remember it
# per file.
#
# Writing the file is ALSO not the same as applying it: cron-style daemons
# read their config at their own pace (some only at start-up, some never
# again without a signal/restart), so a changed file can sit on disk, inert,
# while the running process still enforces the old values — and nothing
# reports that disagreement. That is what the reapply bridge below is for:
# it re-asserts the change against the live daemon (restart, reload command,
# or a custom re-assertion script) every time the config's content changes,
# rather than assuming a write is enough.
#
# ── GOTCHA (b): pacman-owned + pacman-BACKUP files need real takeover ───────
# Some pacman packages ship their config as a "backup" file (tracked in the
# package's .PKGINFO backup list) specifically so pacman never silently
# overwrites local edits. `replaceExisting = true` is what lets Nix take
# over that file anyway: system-manager renames the existing file aside
# (typically to a `.system-manager-backup` sibling) before writing its own,
# so a later `pacman -Syu` still leaves its usual `.pacnew` next to the
# now-Nix-owned file instead of silently clobbering it. Without
# `replaceExisting`, taking over a pacman-backup path is not just skipped —
# it is exactly the silent-skip failure mode in gotcha (a).
#
# ── GOTCHA (c): numeric-prefix ordering can be load-bearing ─────────────────
# Many daemons read an entire drop-in DIRECTORY (`*.conf` glob) in filename
# order and let later files win over earlier ones — vendor defaults often
# ship under a low numeric prefix specifically so local overrides can sort
# after them. If your `configFiles` destinations land in such a directory,
# the prefix you choose is part of the contract, not cosmetic: too low and
# the vendor default silently wins; a prefix collision with something else
# in that directory is a real correctness bug, not a style nit. This module
# does not — and cannot — know your target daemon's read order; picking
# prefixes that actually sort after whatever else populates that directory
# on the box is entirely on the caller.
#
# ── GOTCHA: the reapply bridge runs under a nix-store-only PATH ─────────────
# system-manager injects a minimal, nix-store-only PATH (coreutils,
# findutils, grep, sed, systemd-minimal — no `/usr/bin`) into every unit it
# declares. A `reapply` command that itself shells out to further host
# tools by bare name (rather than an absolute path) can fail to find them
# under that PATH — and some such tools still exit 0 while having silently
# applied nothing, so the unit reports SUCCESS for a no-op. The bridge unit
# below overrides its PATH to include the normal host locations so `reapply`
# commands (and anything they shell out to) resolve the same way they would
# from an interactive root shell.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.foreignServices;

  # A configFiles value is either a literal string (installed as `text`) or
  # a Nix path / store path (installed as `source`) — same two shapes
  # system-manager's own `environment.etc.<name>` accepts.
  mkEtcEntry = src:
    { replaceExisting = true; } // (
      if builtins.isPath src
      then { source = src; }
      else { text = src; }
    );

  etcEntriesFor = svc: lib.mapAttrs (_: mkEtcEntry) svc.configFiles;

  # Keys the bridge's restartTriggers on the STORE PATH of each generated
  # /etc entry (not on the raw text/path the caller supplied): system-
  # manager's engine restarts a unit whose OWN store path moved, and
  # `restartTriggers` is exactly the mechanism that lets an unrelated file's
  # store path move THIS unit's rendered store path in lockstep — so it
  # restarts on precisely the diff the engine already knows how to detect.
  restartTriggersFor = svc:
    map (dest: config.environment.etc.${dest}.source) (builtins.attrNames svc.configFiles);

  scriptBodyFor = name: svc:
    let
      lines =
        map (u: "systemctl restart ${lib.escapeShellArg u}") svc.restartUnits
        ++ lib.optional (svc.reapply != null) svc.reapply;
    in
    if lines == [ ]
    then ''
      echo "nixarch-foreign-${name}-reapply: WARNING neither restartUnits nor reapply is set" >&2
      echo "nixarch-foreign-${name}-reapply: configFiles were installed but nothing re-applies them" >&2
    ''
    else lib.concatStringsSep "\n" lines;

  scriptFor = name: svc:
    pkgs.writeShellScript "nixarch-foreign-${name}-reapply" ''
      set -eu
      ${scriptBodyFor name svc}
    '';
in
{
  options.nixarch.foreignServices = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        configFiles = lib.mkOption {
          type = lib.types.attrsOf (lib.types.either lib.types.path lib.types.str);
          default = { };
          example = {
            "myservice.conf" = "option = value\n";
            "systemd/system/myservice.service.d/10-override.conf" = ''
              [Service]
              Restart=always
            '';
          };
          description = ''
            Map of `/etc`-relative destination path -> source content. A
            string value is installed as `text`; a Nix path is installed as
            `source`. Every entry is always installed with
            `replaceExisting = true` (see gotchas (a) and (b) in the module
            header) — this module never installs a bare, takeover-less
            `environment.etc` entry.

            When a destination lands inside a drop-in directory that a
            foreign daemon reads in filename order (`*.conf` glob), the
            numeric prefix you choose is part of the contract: it must sort
            after whatever vendor defaults already populate that directory
            for your override to actually win (gotcha (c)).
          '';
        };

        restartUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "myservice.service" ];
          description = ''
            Foreign, pacman-owned systemd units to `systemctl restart`
            whenever any file in `configFiles` changes. Use this when a
            plain unit restart is how the daemon picks up its new config —
            for a daemon whose own re-apply entry point is not "restart the
            unit" (a dedicated reload subcommand, a `start`-not-`restart`
            distinction, etc.), use `reapply` instead or in addition.
          '';
        };

        reapply = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/usr/bin/myservice-tool start";
          description = ''
            Optional shell command run whenever any file in `configFiles`
            changes, after any `restartUnits` restarts. Use this when
            restarting the foreign unit is not the correct (or not the
            only) re-apply step — e.g. the daemon has its own re-apply
            subcommand distinct from a unit restart, or there is a stateful
            fact (a limit, a quota, a mode) that needs re-asserting rather
            than just re-reading a file. Prefer an absolute path for the
            command itself and for anything it shells out to internally —
            see the PATH gotcha in the module header.

            At least one of `restartUnits` or `reapply` should be set, or
            `configFiles` are installed declaratively but nothing ever
            re-applies them against the live foreign service.
          '';
        };
      };
    });
    default = { };
    description = ''
      Declaratively manage the CONFIG of pacman-owned ("foreign") services:
      one `environment.etc` entry per file in `configFiles` (always with
      `replaceExisting = true`), plus one bridge oneshot per named entry
      that restarts `restartUnits` and/or runs `reapply` whenever the
      content of any `configFiles` entry changes. Supplies no configs, no
      unit names, no packages — entirely data-driven per attribute name.
      An empty attrset is a no-op.
    '';
  };

  config = {
    environment.etc = lib.foldl' (acc: svc: acc // etcEntriesFor svc) { } (lib.attrValues cfg);

    systemd.services = lib.mapAttrs'
      (name: svc: lib.nameValuePair "nixarch-foreign-${name}-reapply" {
        description = "nixarch foreign-service bridge: reapply '${name}' against its pacman-owned unit(s)";
        # multi-user.target (not sysinit) so system-manager (re)runs this on a live
        # `switch`, not only at boot — sysinit is already long past by then, so a
        # sysinit-wanted unit would silently never fire on activation. On a live
        # system-manager machine this target is remapped to `system-manager.target`.
        wantedBy = [ "multi-user.target" ];
        # See "restartTriggersFor" above: this is what makes THIS unit's own
        # rendered store path move whenever any configFiles entry's content
        # changes, which is the diff system-manager's engine restarts on.
        restartTriggers = restartTriggersFor svc;
        # See the PATH gotcha in the module header: without this, `reapply`
        # commands (and anything they shell out to internally) resolve against
        # a nix-store-only PATH with no `/usr/bin`, and can silently do nothing
        # while still reporting success.
        environment.PATH = lib.mkForce "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${scriptFor name svc}";
        };
      })
      cfg;
  };
}
