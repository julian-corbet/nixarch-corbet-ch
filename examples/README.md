# examples

Minimal, working configurations showing how to use nixarch's `system-manager`
modules.

## system-manager.nix

A bare-minimum system-manager configuration importing both nixarch modules:
- `gshadow-sync` — heals `/etc/gshadow` inconsistencies
- `device-gids` — pins shared device groups (render, video, input, tty) to
  stable gids across reboots

See [`system-manager.nix`](system-manager.nix) for the full annotated config.

To use this as a starting point:

1. Adapt the gid numbers and group names to your needs (the example uses
   500–503).
2. Import it into your system-manager configuration — either directly or as
   a base to be extended.
3. Apply with `system-manager switch`.

This example targets an Arch or CachyOS system with `system-manager` already
set up. For installation and setup instructions, see the
[`system-manager` documentation](https://github.com/numtide/system-manager).
