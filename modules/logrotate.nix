# modules/logrotate.nix — logrotate: package, timer, and a place to declare config.
#
# WHY ITS OWN MODULE, NOT modules/base-packages.nix. base-packages.nix's own header draws the
# line for what belongs there: reflector, rebuild-detector and arch-install-scripts are bare
# names with no config surface of their own — installing the package IS the whole declaration.
# logrotate is not that shape. It needs CONFIG (per-caller drop-ins under /etc/logrotate.d/) and
# a systemd TIMER that has to actually be enabled for the package to do anything at all. An
# option surface with a submodule-shaped map belongs in its own file, the same way
# modules/foreign-service.nix and modules/device-gids.nix each get one instead of folding into
# packages.nix.
#
# WHY THE TIMER GETS ENABLED HERE, UNLIKE modules/base-packages.nix's reflector. reflector's
# timer is deliberately left unwired there because firing it rewrites /etc/pacman.d/mirrorlist, a
# file this repo does not own and has no declared opinion on the contents of — enabling that
# timer would be silently taking a side on state nothing here declares. logrotate.timer rewrites
# nothing anyone else owns: it only reads /etc/logrotate.conf (pacman's own, untouched by this
# module) plus whatever this module or another package drops into /etc/logrotate.d/, and running
# it is simply the intended behaviour of having the package installed at all. Verified live on
# the Elitebook: the package was already installed by hand (`Install Reason: Explicitly
# installed`), but `logrotate.timer` was DISABLED — meaning logs on this box were never actually
# being rotated. That is a bug this module fixes, not a design choice to leave alone.
#
# CONFIG SURFACE: DROP-INS ONLY, NOT /etc/logrotate.conf. Arch's own logrotate.conf already ends
# with `include /etc/logrotate.d` (verified live), so an override belongs in a same-named file
# under that directory, not by taking over the main conf. Taking over logrotate.conf would also
# hit the `replaceExisting` trap harder than a drop-in does: that file ships WITH the package and
# already exists on every host before this module ever runs, so a future edit that forgot
# `replaceExisting = true` would silently never apply (system-manager's `environment.etc.<x>`
# defaults `replaceExisting` to false and skips writing to an occupied path with no error — see
# modules/foreign-service.nix's header, gotcha (a), for the same trap on the same mechanism). A
# drop-in is written to a path that does not already exist for any name this module doesn't
# already know about, so the trap is far less likely to bite there — but this module still sets
# `replaceExisting = true` unconditionally on every entry it generates anyway, on the same "never
# make the caller remember it" reasoning foreign-service.nix gives for doing so: nixarch hosts
# already have OTHER packages' drop-ins living in /etc/logrotate.d/ (bootlog, cups, libvirtd,
# samba, snapper — confirmed live on the Elitebook), so a chosen drop-in name could collide with
# one of those on some future host.
#
# HOW THE TIMER GETS ENABLED. `systemctl enable logrotate.timer` (never run on either host) would
# create a symlink at /etc/systemd/system/timers.target.wants/logrotate.timer pointing at the
# unit file the package ships. This module creates that exact symlink itself, declaratively, via
# `environment.etc` — the same idiom hosts/archlxc/default.nix's own `/etc/localtime` entry uses
# for a foreign, non-store path: `source` is a plain absolute-path STRING, not a Nix path literal,
# so system-manager symlinks straight to the vendor unit already on disk instead of importing a
# frozen copy into the store. Confirmed against this box's OTHER already-enabled foreign timers
# (cachyos-rate-mirrors.timer, fstrim.timer, snapper-*.timer, all live in
# /etc/systemd/system/timers.target.wants/) that this is exactly the shape a real `systemctl
# enable` produces here. `replaceExisting = true`: a host that had this enabled by hand before
# adopting this module would already occupy this exact path, and an occupied, unclaimed path is
# gotcha (a) again.
#
# NO DEFAULT ROTATION POLICY. This module ships no drop-in of its own — `dropins` defaults to
# `{ }`, a pure no-op beyond installing the package and enabling the timer. What log files get
# rotated, on what schedule, is an operator decision this module has no business making up.
{ lib, config, ... }:
let
  cfg = config.nixarch.logrotate;

  # Same two-shape acceptance as modules/foreign-service.nix's `configFiles`: a string is literal
  # config content (`text`), a Nix path is a file to install as-is (`source`). `replaceExisting`
  # is unconditional on every entry — see the module header for why.
  mkDropinEntry = src:
    { replaceExisting = true; } // (
      if builtins.isPath src
      then { source = src; }
      else { text = src; }
    );

  dropinEntries = lib.mapAttrs'
    (name: src: lib.nameValuePair "logrotate.d/${name}" (mkDropinEntry src))
    cfg.dropins;
in
{
  options.nixarch.logrotate = {
    enable = lib.mkEnableOption ''
      logrotate: installs the package, enables `logrotate.timer` (disabled by default on a bare
      Arch/CachyOS install — see the module header for why that is a bug to fix, not a choice to
      leave alone), and offers `dropins` for declaring `/etc/logrotate.d/*` config.

      Requires `nixarch.packages.enable` to actually install anything — this module only adds
      the name to `nixarch.packages.pacman`; the reconciler in modules/packages.nix does the rest.
    '';

    dropins = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.path lib.types.str);
      default = { };
      example = {
        "corbet-app" = ''
          /var/log/corbet-app/*.log {
            weekly
            rotate 4
            compress
            missingok
            notifempty
          }
        '';
      };
      description = ''
        Map of drop-in NAME (no path, no extension implied) -> config content, installed at
        `/etc/logrotate.d/<name>` via `environment.etc`. A string value is installed as `text`; a
        Nix path is installed as `source`. Every entry is always installed with
        `replaceExisting = true` (see the module header).

        Empty by default: this module ships no rotation policy of its own — see the module
        header's "NO DEFAULT ROTATION POLICY".
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixarch.packages.pacman = [ "logrotate" ];

    environment.etc = dropinEntries // {
      "systemd/system/timers.target.wants/logrotate.timer" = {
        replaceExisting = true;
        source = "/usr/lib/systemd/system/logrotate.timer";
      };
    };
  };
}
