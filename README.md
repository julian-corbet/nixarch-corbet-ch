# nixarch

Declarative Arch/CachyOS workstations, managed the Nix way.

## Vision

`system-manager` is young, and almost nobody has published a serious,
real-world configuration built on it for an Arch-family distro. **nixarch**
aims to be a worked, opinionated base extracted from machines that
actually run this way daily — not a toy demo.

The goal is a reusable base layer for running Arch-family desktops and
laptops under Nix control *without* switching to NixOS:

- **`system-manager`** as the system layer — services and system files,
  declared and applied on top of an otherwise ordinary Arch/CachyOS
  install.
- **`home-manager`** as the user layer — dotfiles and user packages,
  declared the same way you would on NixOS, on a distro that isn't.
- **CachyOS-specific concerns expressed as data** — v3/znver-optimized
  repository selection, kernel and scheduler choice, and similar
  distro-specific decisions, driven by configuration rather than
  hardcoded into the modules.

The distro keeps its own package manager, its own kernel, its own driver
story. Nix only owns the declarative layers on top.

## Status

**Pre-alpha.** This repository is being extracted from a private
configuration, one module at a time. As of this writing:

- Two real `system-manager` modules have landed: `gshadow-sync` (heals
  `/etc/gshadow` after `userborn` writes `/etc/group`) and `device-gids`
  (pins and migrates shared device groups to caller-chosen gids, with the
  Arch tty/devpts lockstep that goes with it). See Usage below.
- Everything else is still **not built**: no `home-manager` base module,
  no CachyOS data patterns, no worked end-to-end example machine config.
- The project page in `site/` describes the vision honestly as
  not-yet-consumable as a whole; it is not a marketing page for a
  finished tool.

The pattern behind nixarch runs daily on real Arch/CachyOS machines today.
What's missing is the generalization and extraction work needed to make
it usable by anyone else, which is what this repository tracks.

## Usage

The two landed modules are plain `system-manager` modules (and, for
`gshadow-sync`, a plain NixOS module too — see below). Both are imported as
regular nixpkgs modules; add nixarch to your system-manager flake as an input,
then reference them in your configuration.

### gshadow-sync

Heals `/etc/gshadow` inconsistencies that arise when `userborn` writes
`/etc/group` but not `/etc/gshadow`. See [`studies/gshadow-under-userborn.md`](studies/gshadow-under-userborn.md)
for the full rationale.

Add to your system-manager configuration:

```nix
{
  imports = [ inputs.nixarch.systemManagerModules.gshadow-sync ];
  
  nixarch.gshadowSync.enable = true;
}
```

That's all — once enabled, it runs idempotently on every boot and when you
call `system-manager switch`, plus it hooks into `shadow.service` to re-heal
before the daily check.

### device-gids

Pins shared device groups (render, video, input, tty, etc.) to stable,
caller-chosen gids. Automatically migrates pre-existing groups via `groupmod`
if they land at a different gid, and includes an optional devpts lockstep
to keep `/dev/pts` in sync when remumbering `tty`.

Add to your system-manager configuration:

```nix
{
  imports = [ inputs.nixarch.systemManagerModules.device-gids ];
  
  nixarch.deviceGidsEnable = true;
  
  # Map group name to its canonical gid.
  # Including "tty" also enables the /dev/pts remount service.
  nixarch.deviceGids = {
    render = 500;  # DRI devices
    video = 501;   # GPU, framebuffer
    input = 502;   # Input devices
    tty = 503;     # Pseudo-terminals (triggers devpts lockstep)
  };
  
  # Optional: customize devpts mount modes (defaults shown).
  # Only used if "tty" is in deviceGids above.
  nixarch.ttyDevpts.mode = "620";
  nixarch.ttyDevpts.ptmxmode = "666";
}
```

The module has no opinion on the actual gid numbers — those are entirely
your choice. An empty `deviceGids` map makes it a no-op.

### Full example

See [`examples/system-manager.nix`](examples/system-manager.nix) for a minimal,
annotated configuration showing both modules in action.

### NixOS portability

`gshadow-sync` is also exported under `nixarch.nixosModules.gshadow-sync`.
NixOS realises users with the same userborn and has the same `/etc/gshadow`
blind spot, so the module carries over as-is — only the import path differs,
not the logic or configuration.

## Roadmap

Planned, not yet built:

- **home-manager base module** — a user-layer module extracted from real
  daily-driver dotfiles and packages, generalized away from any one
  machine's specifics.
- **CachyOS data patterns** — a documented, data-driven way to express
  v3/znver repository selection and kernel/scheduler choice.
- Additional `system-manager` modules beyond the two landed so far.
- Worked, runnable examples once the above land.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point; exports the two landed `system-manager` modules (see Usage) plus still-empty `lib`/`homeManagerModules` placeholders. |
| `experiments/` | Throwaway trials — see [`experiments/README.md`](experiments/README.md). |
| `studies/` | Written-up findings — see [`studies/README.md`](studies/README.md). |
| `site/` | The project page (`nixarch.corbet.ch`), vendored from the shared `design-corbet-ch` project-pages base. |

## Part of the corbet.ch project family

nixarch is one of several small, independently-usable open-source
projects that share a common design system and house conventions.
Related sibling projects manage a NixOS distro build (**nixnas**) and a
generic RAM/memory-tuning NixOS module (**nixram**) — nixarch's own
niche is the non-NixOS, Arch-family side of the same "declarative
machines" idea.

## License

[MIT License](LICENSE) © 2026 Julian Corbet
