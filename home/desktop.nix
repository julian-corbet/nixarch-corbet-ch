# home/desktop.nix — the USER-layer half of the Arch backend for nixdesktop.
#
# Closes the seam that would otherwise leak absolute binary paths into every consumer's personal
# config. nixdesktop's home/session.nix starts a polkit agent and a keyring daemon by COMMAND
# (`session.polkitAgent.command` / `session.keyring.command`), because those invocations are
# platform-specific and nixdesktop refuses to know about platforms. Somebody has to supply the
# string. Before this module that somebody was the consumer, hand-writing
# "/usr/lib/mate-polkit/polkit-mate-authentication-agent-1" into a values file.
#
# So: state the same role you gave the system layer, get the right command for Arch. The tables
# are shared with modules/desktop-backend.nix (lib/desktop-roles.nix), so the package that gets
# installed and the binary that gets spawned cannot drift apart.
#
# WHY THE ROLE IS STATED TWICE (once here, once in nixdesktop.desktop). system-manager and
# home-manager are separate evaluations with no shared config tree, so this module genuinely
# cannot see what the system layer chose. Collapsing that duplication needs a mechanism above
# both — a flake-level value threaded into each — which is a consumer-side pattern, not
# something either module can impose. Stating a role name twice is the honest cost; hardcoding
# a path twice was not.
{ lib, config, ... }:
let
  cfg = config.nixarch.home.desktop;
  roles = import ../lib/desktop-roles.nix { inherit lib; };
in
{
  options.nixarch.home.desktop = {
    enable = lib.mkEnableOption
      "Arch-specific spawn commands for nixdesktop's session components (requires nixdesktop's home/session.nix in the same home-manager evaluation)";

    polkitAgent = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum (lib.attrNames roles.polkitAgents));
      default = null;
      description = ''
        Polkit agent role — must match what the system layer installs
        (`nixdesktop.desktop.polkitAgent`). Sets nixdesktop's
        `session.polkitAgent.command` to this agent's Arch binary path.

        Null means no agent is spawned, which under niri means privileged GUI prompts never
        appear at all — silently, with nothing logged, since niri does not process XDG autostart.
      '';
    };

    keyring = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum (lib.attrNames roles.keyrings));
      default = null;
      description = ''
        Secret-service role — must match `nixdesktop.desktop.keyring`. Sets nixdesktop's
        `session.keyring.command`. Set exactly one provider: two daemons racing for
        `org.freedesktop.secrets` presents as applications intermittently losing stored secrets.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Targets nixdesktop's `session` module: a spawn-at-startup-style line runs once at session
    # start and cannot fire into an already-running session, so switching configuration would
    # silently fail to start anything until the next login. systemd user services don't have that
    # problem, which is why these command strings go there.
    #
    # `enable` is set here as well as `command`. The session module ships every
    # component off by default, so naming a command without enabling it would
    # produce a role that resolves correctly and then never runs — the exact
    # silent-nothing failure this whole change exists to remove.
    nixdesktop.session = {
      polkitAgent = lib.mkIf (cfg.polkitAgent != null) {
        enable = true;
        command = roles.polkitAgents.${cfg.polkitAgent}.command;
      };
      keyring = lib.mkIf (cfg.keyring != null) {
        enable = true;
        command = roles.keyrings.${cfg.keyring}.command;
      };
    };
  };
}
