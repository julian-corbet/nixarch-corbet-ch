# modules/gcroot-guard.nix — catch the activated-but-never-registered system-manager generation.
#
# ── THE TRAP, EXACTLY ───────────────────────────────────────────────────────────────────────────
# Applying a system-manager config is two steps, and only the first one is loud:
#
#   1. `activate` — writes the units, links /etc, starts things. The box is now RUNNING this
#      generation.
#   2. `register` — adds the generation to the system-manager profile, which is what makes it a
#      garbage-collection ROOT.
#
# `register` shells out to `nix-env`. On a Determinate-installer box, `nix-env` is on the invoking
# USER's PATH but NOT on root's under plain `sudo`. So under `sudo system-manager switch`, step 2
# dies with a bare "While running nix-env: No such file or directory" — after step 1 has already
# succeeded. The box comes up fine. Everything works. Nothing looks wrong.
#
# But the running system's store paths now have NO gc root. The next `nix-collect-garbage` is
# entitled to delete the store paths of the system that is currently running — the unit scripts,
# the wrappers, the whole generation — out from under a live machine.
#
# The fix at the source is to register with an explicit PATH:
#   sudo env PATH=/nix/var/nix/profiles/default/bin:$PATH <engine> register --store-path <path>
# and `nixarch-register` (installed by this module) is that command, so nobody has to remember it.
#
# ── WHY A RUNTIME CHECK AND NOT AN ASSERTION ────────────────────────────────────────────────────
# This cannot be caught at evaluation time. Whether registration succeeded is a fact about the
# machine after activation, not about the configuration — a correct config fails this way just as
# readily as a wrong one. So it has to be observed on the box, after the fact.
#
# ── HOW THE CHECK KNOWS ─────────────────────────────────────────────────────────────────────────
# The check script is itself a store path inside the generation being checked, so it can ask about
# its own rootedness: `nix-store --query --roots "$0"`. Nix reports INDIRECT roots, so a script in
# a registered generation lists that generation's profile link. A script in an unregistered one
# lists nothing at all.
#
# That self-reference is what makes this reliable without the module needing to know its own
# output hash (which it cannot — that would be circular). Verified on a live CachyOS box: a unit's
# ExecStart path reported both `system-manager-42-link` and `system-manager-current` as roots,
# while previously-activated-but-unregistered `-system-manager` paths in the same store reported
# zero.
{ lib, pkgs, config, ... }:
let
  cfg = config.nixarch.gcrootGuard;
  paths = import ../lib/host-path.nix { inherit lib; };

  check = pkgs.writeShellScript "nixarch-gcroot-guard" ''
    set -u

    # "$0" is this script's own store path. See the header: this is the whole trick.
    self="$0"

    if ! command -v nix-store >/dev/null 2>&1; then
      echo "nixarch-gcroot-guard: nix-store not found on PATH -- cannot verify." >&2
      echo "  This is itself the PATH problem this module exists for. PATH=$PATH" >&2
      exit 1
    fi

    # stderr is discarded deliberately: on a box with many auto-roots, nix-store emits a
    # "cannot read potential root" line per unreadable entry when not running as root. Those are
    # noise, not failures -- the roots we care about (profile links) are world-readable.
    roots="$(nix-store --query --roots "$self" 2>/dev/null || true)"

    if [ -n "$roots" ]; then
      echo "nixarch-gcroot-guard: OK -- this generation is a GC root."
      echo "$roots" | sed 's/^/  /'
      exit 0
    fi

    cat >&2 <<EOF
    nixarch-gcroot-guard: THIS RUNNING GENERATION IS NOT A GARBAGE-COLLECTION ROOT.

    The system was activated but never registered, so nothing protects the store paths this
    machine is currently running from. A `nix-collect-garbage` now would delete them out from
    under the live system.

    Almost certainly cause: `register` shells out to nix-env, which is not on root's PATH under
    plain sudo, so it failed silently after `activate` had already succeeded.

    Fix (safe to run now, it only adds the root):
      sudo nixarch-register

    Verify:
      readlink -f /nix/var/nix/gcroots/system-manager-current

    Until then, DO NOT run nix-collect-garbage or `nix store gc` on this machine.
    EOF
    exit 1
  '';

  register = pkgs.writeShellApplication {
    name = "nixarch-register";
    runtimeInputs = [ ];
    text = ''
      # Register the CURRENT system-manager generation as a GC root, with the PATH that
      # `system-manager switch` fails to provide under sudo. See modules/gcroot-guard.nix.
      set -euo pipefail

      export PATH="${paths.hostPathWithNix}:''${PATH:-}"

      if [ "$(id -u)" -ne 0 ]; then
        echo "nixarch-register: must run as root (it writes to /nix/var/nix/profiles)." >&2
        exit 1
      fi

      store_path="''${1:-}"
      if [ -z "$store_path" ]; then
        # Default to whatever is currently activated. /run/system-manager/sw points at the PATH
        # derivation rather than the toplevel, so resolve the toplevel from the profile instead,
        # and fall back to the existing gcroot.
        store_path="$(readlink -f /nix/var/nix/profiles/system-manager-profiles/system-manager 2>/dev/null || true)"
      fi
      if [ -z "$store_path" ]; then
        store_path="$(readlink -f /nix/var/nix/gcroots/system-manager-current 2>/dev/null || true)"
      fi
      if [ -z "$store_path" ]; then
        echo "nixarch-register: could not determine the current generation's store path." >&2
        echo "  Pass it explicitly: nixarch-register /nix/store/...-system-manager" >&2
        exit 1
      fi

      echo "nixarch-register: rooting $store_path"
      nix-store --add-root /nix/var/nix/gcroots/system-manager-current --indirect --realise "$store_path" >/dev/null
      echo "nixarch-register: done. system-manager-current -> $(readlink -f /nix/var/nix/gcroots/system-manager-current)"
    '';
  };
in
{
  options.nixarch.gcrootGuard = {
    enable = lib.mkEnableOption ''
      a boot-time check that the running system-manager generation is actually a GC root, plus
      the `nixarch-register` wrapper that fixes it when it is not
    '';

    failLoudly = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the check unit should FAIL (leaving a red unit in `systemctl --failed`) when the
        generation is unrooted, rather than only logging.

        Defaults to true on purpose. The entire character of this bug is that it is silent and
        that everything appears to work, right up until a routine garbage collection deletes the
        running system. A log line nobody reads is not a meaningful improvement on that; a failed
        unit is something a human or a monitor actually notices.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ register ];

    systemd.services.nixarch-gcroot-guard = {
      description = "nixarch: verify the running system-manager generation is a GC root";
      # multi-user.target, not sysinit: this must also re-run on a live `system-manager switch`,
      # and sysinit is long past by then. Same reasoning as the other oneshots in this project.
      wantedBy = [ "multi-user.target" ];

      # The check shells out to nix-store, which is precisely the binary that is missing from the
      # PATH system-manager injects -- the same gap that causes the bug being detected.
      environment.PATH = lib.mkForce paths.hostPathWithNix;

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart =
          if cfg.failLoudly
          then "${check}"
          # `-` prefix: systemd records the failure but does not mark the unit failed.
          else "-${check}";
      };
    };
  };
}
