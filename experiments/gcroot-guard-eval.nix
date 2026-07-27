# Throwaway eval check for modules/gcroot-guard.nix -- NOT part of the module surface. Confirms
# the unit renders with the PATH that makes it able to run at all, and that `failLoudly` actually
# changes the ExecStart prefix. Safe to delete; nothing imports this file.
#
#   nix-instantiate --eval --strict experiments/gcroot-guard-eval.nix -A ok
#
# NOT covered here, and worth being honest about: whether the check SCRIPT reaches the right
# verdict. That is a runtime property of a real box (does this generation have a gc root?) and no
# amount of evaluation can answer it. It was instead verified directly against a live CachyOS
# machine, both directions: a script inside the current generation reported 3 roots, while a
# stray previously-activated `-system-manager` path in the same store reported none.
{ nixpkgs ? <nixpkgs> }:
let
  pkgs = import nixpkgs { };
  lib = pkgs.lib;
  paths = import ../lib/host-path.nix { inherit lib; };

  evalWith = failLoudly: lib.evalModules {
    modules = [
      ../modules/gcroot-guard.nix

      # Stubs for the surface system-manager provides and a bare evalModules does not. Only the
      # shape matters here, not the semantics.
      ({ lib, ... }: {
        options = {
          systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
          environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
        };
      })

      { _module.args.pkgs = pkgs; }
      { nixarch.gcrootGuard = { enable = true; inherit failLoudly; }; }
    ];
  };

  loud = (evalWith true).config.systemd.services.nixarch-gcroot-guard;
  quiet = (evalWith false).config.systemd.services.nixarch-gcroot-guard;

  off = lib.evalModules {
    modules = [
      ../modules/gcroot-guard.nix
      ({ lib, ... }: {
        options = {
          systemd.services = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
          environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
        };
      })
      { _module.args.pkgs = pkgs; }
      { nixarch.gcrootGuard.enable = false; }
    ];
  };
in
rec {
  # `systemd.services` is stubbed as `attrsOf attrs`, which treats each service as an OPAQUE
  # attrset -- so the module system never merges the `lib.mkForce` inside it, and the value comes
  # back as a raw override wrapper instead of a string. Real system-manager declares these as
  # submodules and resolves it properly. Unwrap here rather than build an elaborate stub.
  unwrap = v: if lib.isAttrs v && (v._type or null) == "override" then v.content else v;

  execStart = unwrap loud.serviceConfig.ExecStart;
  loudPath = unwrap loud.environment.PATH;

  # The unit must carry a PATH containing Nix's own bin dir. Without it the check cannot run
  # nix-store -- which is the very gap this module exists to catch, so getting it wrong here
  # would be quietly self-defeating.
  pathHasNix = lib.hasInfix paths.nixPath loudPath;
  pathHasHostTools = lib.hasInfix "/usr/bin" loudPath;

  # failLoudly = false prefixes ExecStart with "-", which tells systemd to record the non-zero
  # exit without marking the unit failed.
  loudFails = !(lib.hasPrefix "-" execStart);
  quietTolerates = lib.hasPrefix "-" (unwrap quiet.serviceConfig.ExecStart);

  # Disabled must contribute nothing at all -- importing the module should never be the thing
  # that adds a unit.
  disabledIsInert = off.config.systemd.services == { } && off.config.environment.systemPackages == [ ];

  # The wrapper is installed so the error message's suggested fix actually exists on the box.
  shipsRegister = lib.length (evalWith true).config.environment.systemPackages == 1;

  ok = pathHasNix && pathHasHostTools && loudFails && quietTolerates
    && disabledIsInert && shipsRegister;
}
