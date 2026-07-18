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

**Pre-alpha scaffold.** This repository is being extracted from a private
fleet configuration, one module at a time. As of this writing:

- There is **no installable module set** and no documented usage.
- `flake.nix` exports empty `lib`, `nixosModules`, and `homeManagerModules`
  attrsets, explicitly marked as placeholders — it evaluates cleanly
  (`nix flake check` passes) but does not do anything yet.
- The project page in `site/` describes the vision honestly as
  not-yet-consumable; it is not a marketing page for a finished tool.

The pattern behind nixarch runs daily on real Arch/CachyOS machines today.
What's missing is the generalization and extraction work needed to make
it usable by anyone else, which is what this repository tracks.

## Roadmap

Planned, not yet built:

- **system-manager base module** — a minimal, documented configuration
  covering system services and files, safe to apply on an unmodified
  Arch/CachyOS install.
- **home-manager base module** — a user-layer module extracted from real
  daily-driver dotfiles and packages, generalized away from any one
  machine's specifics.
- **CachyOS data patterns** — a documented, data-driven way to express
  v3/znver repository selection and kernel/scheduler choice.
- Worked, runnable examples once the above land.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point; currently empty placeholder outputs only. |
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
