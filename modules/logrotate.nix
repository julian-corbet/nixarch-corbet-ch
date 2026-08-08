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
# HOW THE TIMER GETS ENABLED, AND WHY NOT THROUGH `environment.etc`. `systemctl enable
# logrotate.timer` creates a symlink at /etc/systemd/system/timers.target.wants/logrotate.timer
# pointing at the unit file the package ships in /usr/lib/systemd/system/. Declaring that symlink
# through `environment.etc`, with `source` as a plain absolute-path STRING so system-manager links
# straight to the vendor unit instead of importing a frozen copy into the store, LOOKS like the
# declarative way to say it — and is the idiom a host's own `/etc/localtime` entry legitimately
# uses. It is wrong here, and the way it is wrong is worth the paragraphs.
#
# system-manager renders every `environment.etc` entry into its own small derivation
# (`nix/modules/default.nix`, `addToStore`) whose entire body is `mkdir -p` plus `ln -s "$source"`.
# `ln -s` does not look at its target. So on a host where logrotate is NOT installed, that
# derivation builds SUCCESSFULLY and contains a DANGLING symlink: no error, no warning, an
# artefact that looks fine right up until something dereferences it. Something does — the
# activation engine walks the merged etc environment and calls `fs::canonicalize` on every entry
# it finds (`crates/system-manager-engine/src/activate/etc_files.rs`), which follows symlinks and
# fails with ENOENT. Activation dies with
#
#   Error during activation: Failed to get the canonical path of
#   /nix/store/…-systemd-system-timers.target.wants-logrotate.timer-etc-link/systemd/system/timers.target.wants/logrotate.timer
#   — No such file or directory
#
# which names a store path and says nothing whatsoever about a missing package. Reproduced by
# building that exact derivation against a deliberately absent unit; see
# studies/trusting-the-live-system.md for the transcript.
#
# THE DEADLOCK, which is why "make it loud" was not a sufficient fix. system-manager activates
# /etc BEFORE it starts any unit, and the package reconciler in modules/packages.nix is a unit. On
# a host without logrotate the loop closes: the /etc link needs the package, the package needs the
# reconciler, the reconciler needs activation to get past the /etc stage, and the /etc stage dies
# on the link. Such a host cannot install logrotate through nixarch at all — the loop has to be
# cut by hand with a `pacman -S logrotate` before activation will ever complete again. That
# happened on a real container host.
#
# AND NEITHER EVAL NOR BUILD CAN CHECK IT. An eval-time `builtins.pathExists` reads the filesystem
# of whatever machine EVALUATES the flake, which is not necessarily the machine being activated —
# modules/packages.nix's `distro` option rejects exactly that probe for exactly that reason, and
# an impure probe that answers for the wrong host is the same silent-wrong-answer defect wearing a
# different hat. A build-time check is worse: the build sandbox has no /usr at all, so it would
# fail on every host including the ones where the unit is present.
#
# SO THE ENABLE IS EXPRESSED WHERE THE FACT IT DEPENDS ON IS ACTUALLY TRUE: on the target box,
# after the reconciler has run. `nixarch-logrotate-enable-timer` is a oneshot ordered `After=` (and
# `Wants=`) the package reconciler, running `systemctl enable --now logrotate.timer` under the host
# PATH. That is the same shape modules/foreign-service.nix already uses to drive pacman-owned
# units — a bridge oneshot, not a store artefact pretending to be one. It removes the deadlock
# outright rather than reporting it: activation no longer depends on the package existing, the
# reconciler installs it, and the timer is enabled in the SAME activation. If the vendor unit is
# still absent when the oneshot runs, it exits non-zero naming the package and the reconciler, so
# `systemctl --failed` carries a sentence about logrotate instead of a store path about nothing.
#
# WHAT THAT GIVES UP, stated plainly. An `environment.etc` entry is removed by system-manager when
# the declaration goes away; a `systemctl enable` is not. Setting `enable = false` stops nixarch
# asserting the timer, it does not disable it — `systemctl disable logrotate.timer` is a manual
# step. The unit is deliberately NOT `RemainAfterExit`, so it runs again on every activation and
# keeps re-asserting the enable; that per-activation re-assertion is the one property the etc entry
# gave for free, and `systemctl enable` is idempotent enough to reproduce it for the price of one
# process start.
#
# NO DEFAULT ROTATION POLICY. This module ships no drop-in of its own — `dropins` defaults to
# `{ }`, a pure no-op beyond installing the package and enabling the timer. What log files get
# rotated, on what schedule, is an operator decision this module has no business making up.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.logrotate;
  hostPaths = import ../lib/host-path.nix { inherit lib; };

  # The vendor unit `systemctl enable` will link to. Named once here because the enable script
  # both checks for it and reports it.
  vendorTimer = "/usr/lib/systemd/system/logrotate.timer";

  # modules/packages.nix names its reconcile unit; this module has to order after it by name.
  # checks/default.nix pins that the two agree, so a rename over there fails the suite rather
  # than silently turning this `After=`/`Wants=` into a reference to nothing.
  reconcileUnit = "nixarch-packages-reconcile.service";

  enableTimerScript = pkgs.writeShellScript "nixarch-logrotate-enable-timer" ''
    set -eu

    unit=${lib.escapeShellArg vendorTimer}

    if [ ! -e "$unit" ]; then
      echo "nixarch-logrotate: ${vendorTimer} does not exist -- the logrotate package is not installed on this host, so there is no timer to enable." >&2
      echo "nixarch-logrotate: nixarch.logrotate.enable puts \"logrotate\" into nixarch.packages.pacman, and this unit runs After=${reconcileUnit}, so reaching here means that reconcile did not run or did not install it. Check \`systemctl status ${reconcileUnit}\` and that nixarch.packages.enable is true." >&2
      exit 1
    fi

    systemctl enable --now logrotate.timer
  '';

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

      The timer is enabled by a oneshot ordered after that reconciler, not by a declared
      `/etc/systemd/system/timers.target.wants/` symlink — see the module header for the
      dangling-link deadlock that rules the declarative form out. One consequence is worth
      knowing before you rely on it: setting this back to `false` stops nixarch asserting the
      timer, it does not run `systemctl disable`.
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

  # Computed, read-only, for the same reason modules/packages.nix exposes `reconcileScript`:
  # there is otherwise no way to inspect the generated script without building it, and
  # checks/default.nix wants to assert real properties of the script this module actually ships
  # (that it enables the timer; that a missing vendor unit produces a sentence naming the package
  # and the reconciler rather than a store path). `pkgs.writeShellScript`'s own `.text` passthru is
  # readable at eval time with no store realisation. NOT a stable interface.
  #
  # No `default`, and defined unconditionally below: `readOnly` permits exactly one definition, and
  # a default plus a `mkIf`-guarded definition counts as two.
  options.nixarch.logrotate.enableTimerScript = lib.mkOption {
    type = lib.types.package;
    readOnly = true;
    description = "The generated timer-enable script (same derivation `ExecStart` runs). Exposed for checks/default.nix's static-text assertions; not a stable interface.";
  };

  config = lib.mkMerge [
    { nixarch.logrotate.enableTimerScript = enableTimerScript; }

    (lib.mkIf cfg.enable {
    nixarch.packages.pacman = [ "logrotate" ];

    # Drop-ins only. Every value here becomes `text` (a string) or `source` (a Nix path imported
    # into the store) — never a bare absolute-path string pointing at a live file, which is the
    # shape the module header dissects at length.
    environment.etc = dropinEntries;

    systemd.services.nixarch-logrotate-enable-timer = {
      description = "nixarch: enable logrotate.timer (the pacman-owned unit) once the package is installed";
      # multi-user.target (not sysinit) so system-manager (re)runs this on a live `switch`, not
      # only at boot — the same reasoning every other oneshot in this project carries.
      wantedBy = [ "multi-user.target" ];
      # THE ORDERING IS THE FIX. `Wants=` rather than `Requires=`: the reconcile unit only exists
      # when `nixarch.packages.enable` is true, and a `Requires=` on a unit that is not declared
      # at all would fail the job instead of degrading to "the package had better already be
      # there", which is what a host managing its packages some other way actually wants.
      after = [ reconcileUnit ];
      wants = [ reconcileUnit ];
      # system-manager injects a nix-store-only PATH (no /usr/bin) into every unit it declares, so
      # `systemctl` would not resolve on a real box. See lib/host-path.nix for why mkForce is the
      # only thing that wins here.
      environment.PATH = lib.mkForce hostPaths.hostPath;
      serviceConfig = {
        Type = "oneshot";
        # NOT RemainAfterExit, unlike the reconciler. system-manager restarts a unit only when
        # its own store path moved, so a RemainAfterExit oneshot that already succeeded would
        # never run again and the enable would stop being re-asserted after a hand `systemctl
        # disable`. Left to go inactive, `system-manager.target` pulls it back up on every
        # activation, which is what the removed `environment.etc` entry used to give for free.
        RemainAfterExit = false;
        ExecStart = "${enableTimerScript}";
      };
    };
    })
  ];
}
