# lib/host-path.nix — the host's own PATH, for units that must call host tools.
#
# THE PROBLEM THIS NAMES ONCE. system-manager injects a nix-store-only PATH into every systemd
# unit it declares. That is the right default for a NixOS-shaped world, where everything a unit
# needs is a store path. It is exactly wrong for the units nixarch writes, whose entire job is to
# drive the HOST's own tooling: `pacman`, `runuser`, `groupmod`, `nix-store`. None of those live
# in the store, so they simply do not resolve, and the unit fails with a bare "command not found"
# that gives no hint the PATH was replaced underneath it.
#
# Worse, it cannot be fixed the obvious ways. Both `Environment=PATH=` in serviceConfig and
# system-manager's own `path` option are silently DROPPED in favour of the injected baseline —
# no error, no warning, the value just does not appear. `lib.mkForce` on `environment.PATH` is
# the one thing that actually wins.
#
# This was open-coded in three separate places before it lived here. That is the real argument
# for a lib entry: not reuse for its own sake, but that the next person writing a
# host-tool-driving unit should not have to rediscover the workaround, and a fix or addition
# lands once instead of drifting between copies.
{ lib }:
rec {
  # The standard Arch root PATH, as /etc/profile would set it.
  systemPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin";

  # Nix's own tooling. NOT on root's PATH under plain `sudo` on a Determinate-installer box --
  # the installer puts it on the invoking USER's PATH only. Any unit shelling out to nix-store,
  # nix-env or nix needs this explicitly; assuming it is present is the same class of bug as
  # assuming pacman is.
  nixPath = "/nix/var/nix/profiles/default/bin";

  # Host tools only. The common case: pacman, coreutils, groupmod.
  hostPath = systemPath;

  # Host tools plus Nix's CLI, for units that inspect or manipulate the store.
  hostPathWithNix = "${nixPath}:${systemPath}";

  # Drop into a systemd unit definition. `lib.mkForce` is load-bearing -- see the header.
  #
  #   systemd.services.foo = lib.recursiveUpdate (roles.forceHostPath { }) { ... };
  #
  # Most callers just want the attribute, so the plain strings above are usually clearer; this
  # helper exists for the case where a unit is assembled programmatically.
  forceHostPath = { withNix ? false }: {
    environment.PATH = lib.mkForce (if withNix then hostPathWithNix else hostPath);
  };
}
