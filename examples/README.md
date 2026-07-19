# examples

Minimal, working configurations showing how to use nixarch's modules across
both system and home layers.

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

## home-manager.nix

A minimal home-manager configuration showing how to use nixarch's per-user
home-manager modules:
- `nixarch.home.shell` — modern interactive shell bundle (fish + starship +
  zoxide + fzf) with automatic integration
- `nixarch.home.dev` — developer essentials: git config with sane defaults
  (main branch, rebase-on-pull, auto-setup-remote) and direnv+nix-direnv for
  per-project environments

See [`home-manager.nix`](home-manager.nix) for the full annotated config, including
how to set your git identity and layer in personal customization.

To use this as a starting point:

1. Import it into your home-manager configuration (or flake's home-manager module).
2. **Set your real git identity** — replace the example "Ada Lovelace" with your
   actual name and email.
3. Optionally layer in your own shell aliases and functions after nixarch's
   modules provide the base.
4. Apply with `home-manager switch`.

This example targets a user on Arch, CachyOS, or any NixOS-based system with
home-manager set up.
