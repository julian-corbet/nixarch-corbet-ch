# nixarch

Arch/AUR's rolling breadth, Nix's declarative config. Reproducible, software-rich workstations for ML engineers and data scientists.

## Vision

**nixarch** merges Arch/AUR's rolling package access (nearly all software,
lands faster than nixpkgs) with Nix's declarative system and user layers,
enabling reproducible workstations without switching to NixOS. Prototype
AI-engineer machines: access to nearly everything, tidied and reproducible.

The goal is a reusable base layer built on real, working modules across both
system and user layers:

- **`packages`** — the core USP. Declarative access to Arch's entire rolling
  AUR breadth. Declare packages once, get them reproducibly across machines
  via Nix without abandoning Arch's "nearly everything" package culture.
- **System layer via `system-manager`** — services, system files, and
  foundational modules (`device-gids`, `gshadow-sync`, `foreign-service`)
  solving Arch/userborn quirks and declaring pacman services as data.
- **User layer via `home-manager`** — shell environment (`shell` module:
  fish, starship, zoxide, fzf) and development tools (`dev` module: git
  config and direnv/nix-direnv). Lean and config-only; packages come from
  the system layer.
- **`ai-workstation` profile** — a curated starter combining the modules for
  ML and data-science workflows: GPU support, dev toolchains, scientific
  stacks, CUDA/ROCm. Starting points, not dogma.

## Status

**Pre-alpha, system and home-manager layers both real.** This repository is being extracted
from machines that actually run this way daily — one module at a time — not
a toy demo or marketing page. As of this writing:

- **Seven working modules** have landed:
  - **System layer:** `packages` (declarative Arch/AUR access — the core USP),
    `device-gids` (stable device group ids, with optional devpts lockstep),
    `gshadow-sync` (heals `/etc/gshadow` after `userborn` writes `/etc/group`),
    `foreign-service` (declarative config over pacman systemd units), and
    `ai-workstation` profile (starter config for ML/data-science workflows).
  - **Home-manager layer:** `shell` (fish, starship, zoxide, fzf bundle) and
    `dev` (git config and direnv/nix-direnv integration).
- Each module is real, working code with documented options. Not speculative;
  the patterns run daily in production.
- The `ai-workstation` profile's package lists and home-manager modules are
  starting points, not gospel. Home-manager modules are lean and config-only;
  packages source from the system layer.
- Still **not built**: integration test suite or end-to-end example machine config.

What's landed is usable today on its own (see Usage below). What's missing is
the integration, testing, and documentation needed to make the entire stack
consumable as a single drop-in base for a new machine.

## Usage

The five modules are plain `system-manager` modules (and `gshadow-sync` is
also a plain NixOS module — see below). Import them as regular nixpkgs
modules: add nixarch to your system-manager flake as an input, then reference
them in your configuration.

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

### packages

Declarative access to Arch/AUR packages. Declare package lists once, apply
reproducibly across machines via Nix without switching distros.

```nix
{
  imports = [ inputs.nixarch.systemManagerModules.packages ];
  
  nixarch.packages.enable = true;
  
  # Official repos and AUR both work; nixarch handles the fetch.
  # Package lists are starting points, not fixed.
  nixarch.packages.core = [
    "vim"
    "git"
    "tmux"
  ];
  
  nixarch.packages.development = [
    "rustup"
    "python"
    "just"
  ];
  
  # AUR packages also supported (example; adjust for your AUR helper)
  nixarch.packages.aur = [
    "paru-bin"  # or your chosen AUR helper
  ];
}
```

### foreign-service

Declarative configuration over pacman-managed systemd units. Treat distro
services as data: configure options, enable/disable, set dependencies.

```nix
{
  imports = [ inputs.nixarch.systemManagerModules.foreign-service ];
  
  nixarch.foreignServices."bluetooth" = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
    requiredBy = [ ];
  };
  
  nixarch.foreignServices."pipewire" = {
    enable = true;
    wantedBy = [ "multi-user.target" ];
  };
}
```

### ai-workstation profile

A curated starter combining all modules for ML/data-science workflows. GPU
support, dev toolchains, scientific stacks, CUDA/ROCm.

```nix
{
  imports = [
    inputs.nixarch.systemManagerModules.device-gids
    inputs.nixarch.systemManagerModules.gshadow-sync
    inputs.nixarch.systemManagerModules.packages
    inputs.nixarch.profiles.ai-workstation
  ];
  
  # Customize the profile's package lists (they are starting points)
  nixarch.packages.development = [ "cuda" "pytorch" ];
  nixarch.deviceGids = {
    render = 500;
    video = 501;
    input = 502;
  };
}
```

### shell (home-manager)

A declarative shell environment bundle: fish, starship prompt, zoxide, and fzf.

```nix
{
  imports = [ inputs.nixarch.homeManagerModules.shell ];
  
  nixarch.shell.enable = true;
  
  # Customize prompt colors and symbols (optional; sensible defaults included)
  nixarch.shell.starship.preset = "nerd-font-symbols";
}
```

### dev (home-manager)

Declarative git configuration and direnv/nix-direnv integration for reproducible
development environments.

```nix
{
  imports = [ inputs.nixarch.homeManagerModules.dev ];
  
  nixarch.dev.enable = true;
  
  # Git identity (example values; use your own)
  nixarch.dev.git.identity = {
    name = "Example User";
    email = "user@example.com";
  };
  
  # Signing configuration (optional)
  nixarch.dev.git.signing = {
    enable = true;
    format = "openpgp";
    key = "XXXXXXXXXXXXXXXX";
  };
  
  # direnv/nix-direnv is automatically configured when enabled
}
```

### Full example

See [`examples/system-manager.nix`](examples/system-manager.nix) for a minimal,
annotated configuration showing modules in action.

### NixOS portability

`gshadow-sync` is also exported under `nixarch.nixosModules.gshadow-sync`.
NixOS realises users with the same userborn and has the same `/etc/gshadow`
blind spot, so the module carries over as-is — only the import path differs,
not the logic or configuration.

## Roadmap

Planned, not yet built:

- **Integration test suite** — behavior-driven tests for each module in
  isolation and in combination, run against fresh Arch/CachyOS installs.
- **End-to-end example machine config** — a worked, runnable configuration
  that imports all seven modules (system and home-manager) and can bootstrap
  a complete workstation from fresh Arch in a single apply.
- Additional `system-manager` modules extracted from real use as they mature.

Once these land, nixarch will be usable as a true drop-in base layer for new
Arch/CachyOS machines.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point; exports `systemManagerModules` (device-gids, gshadow-sync, packages, foreign-service) and `homeManagerModules` (shell, dev); also profiles (ai-workstation) and lib utilities. |
| `experiments/` | Throwaway trials — see [`experiments/README.md`](experiments/README.md). |
| `studies/` | Written-up findings — see [`studies/README.md`](studies/README.md). |
| `site/` | The project page (`nixarch.corbet.ch`), vendored from the shared `design-corbet-ch` project-pages base. |

## Related projects

nixarch is one of several small, independently-usable open-source projects
sharing a common design system. Related projects include a NixOS distro build
(**nixnas**) and a generic RAM/memory-tuning NixOS module (**nixram**) —
nixarch's own niche is the non-NixOS, Arch-family side of the same "declarative
machines" idea: access to rolling Arch breadth, tidied by Nix's reproducible
layers.

## License

[MIT License](LICENSE) © 2026 Julian Corbet
