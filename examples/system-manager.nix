# A minimal system-manager configuration showing both nixarch modules in action.
#
# Usage: import this into your system-manager flake alongside nixarch as a
# flake input, then reference the modules:
#
#   imports = [
#     inputs.nixarch.systemManagerModules.gshadow-sync
#     inputs.nixarch.systemManagerModules.device-gids
#   ];

{ config, lib, ... }:

{
  # Import the two nixarch system-manager modules.
  # In your own flake.nix, add nixarch as an input:
  #   nixarch.url = "github:user/nixarch";
  # Then reference them here or in a configuration file:
  #   imports = [ inputs.nixarch.systemManagerModules.gshadow-sync
  #               inputs.nixarch.systemManagerModules.device-gids ];

  # ============================================================================
  # gshadow-sync: heal /etc/gshadow after userborn writes /etc/group
  # ============================================================================
  #
  # Why: userborn (system-manager's tool for realising users and groups)
  # writes /etc/passwd, /etc/group, and /etc/shadow but NOT /etc/gshadow.
  # Arch's daily shadow.service runs grpck to check consistency and fails
  # when gshadow is missing entries, leaving a permanently-red unit.
  #
  # This module runs grpconv (from shadow-suite) to regenerate /etc/gshadow
  # from /etc/group, idempotently, healing the gap.
  #
  # Enable with a single boolean:
  nixarch.gshadowSync.enable = true;

  # ============================================================================
  # device-gids: pin shared device groups to stable gids
  # ============================================================================
  #
  # Why: groups like 'render', 'video', and 'input' are often assigned
  # arbitrary gids by the distro. This module lets you declare a canonical
  # gid for each one and keeps them stable across reboots and re-configurations.
  #
  # Includes automatic migration: if the group already exists at a different
  # gid, groupmod renumbers it to match the declaration.
  #
  # The example below pins four common device groups to gids 500–503.
  # Adapt these values to your own numbering scheme.

  nixarch.deviceGidsEnable = true;

  # Map each group name to its canonical gid.
  # Common device groups: render, video, input, audio, tty, dialout, uucp, lp.
  # Include 'tty' if you want the devpts lockstep (see below).
  nixarch.deviceGids = {
    render = 500;  # DRI devices
    video = 501;   # GPU, framebuffer
    input = 502;   # Input devices (tablet, joystick, etc.)
    tty = 503;     # Pseudo-terminals; including this also remounts /dev/pts
  };

  # When 'tty' is included in deviceGids above, this module also manages the
  # /dev/pts mount to keep it in lockstep. These options configure the
  # remount parameters:
  #
  # - mode: permissions on /dev/pts itself (e.g. "620" = rw for owner+gid, r for others)
  # - ptmxmode: permissions on /dev/ptmx (e.g. "666" = world-rw)
  #
  # These are Arch defaults; change only if you have a specific reason.
  nixarch.ttyDevpts.mode = "620";
  nixarch.ttyDevpts.ptmxmode = "666";

  # ============================================================================
  # Optional: declare additional system groups that you want managed
  # ============================================================================
  #
  # system-manager's users.groups and users.users let you declare groups and
  # users alongside the nixarch modules. Example:
  #
  # users.groups.mygroup = { gid = 2000; };
  # users.users.myuser = {
  #   uid = 1000;
  #   group = "mygroup";
  #   home = "/home/myuser";
  #   shell = pkgs.bash;
  # };
}
