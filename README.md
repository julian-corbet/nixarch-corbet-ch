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
- **`desktop-backend`** — the Arch resolution layer for [nixdesktop][nixdesktop]:
  turns platform-neutral desktop *roles* into real pacman packages. The only
  place in the project that knows a desktop package name.

### Scope

nixarch's job is **making an Arch box Nix-manageable** — paving the way for
system-manager and home-manager to work on a distro neither was built for, and
declaring the package set they sit on top of. Everything here should be some
part of that.

That is a boundary as much as a mission. Domains that merely *run on* such a
box belong in their own modules, not this one — a Wayland desktop
([nixdesktop][nixdesktop]) is a different domain that happened to start life
here, and its modules moved out once that was clear. What stays is what a
consumer needs regardless of what they then run: package convergence, the
system/user layer plumbing, and the Arch-specific quirks that otherwise cost
each user the same afternoon.

## Status

**Pre-alpha, system and home-manager layers both real.** This repository is being extracted
from machines that actually run this way daily — one module at a time — not
a toy demo or marketing page. As of this writing:

- Working modules have landed across both layers:
  - **System layer:** `packages` (declarative Arch/AUR access — the core USP),
    `device-gids` (stable device group ids, with optional devpts lockstep),
    `gshadow-sync` (heals `/etc/gshadow` after `userborn` writes `/etc/group`),
    `foreign-service` (declarative config over pacman systemd units),
    `gcroot-guard` (catches the activated-but-unregistered generation),
    `desktop-backend` (resolves nixdesktop roles into Arch packages),
    `shelly` (nixarch's own opinionated package: a graphical pacman/AUR front-end),
    and `cachyos-tools` (CachyOS's own update notifier, welcome app, kernel GUI and
    package installer, four independent `enable`s, distro-gated).
  - **Home-manager layer:** `shell` (fish, starship, zoxide, fzf bundle),
    `dev` (git config and direnv/nix-direnv integration), and `desktop`
    (Arch spawn commands for nixdesktop's session components).
- Each module is real, working code with documented options. Not speculative;
  the patterns run daily in production.
- Home-manager modules are lean and config-only; packages source from the
  system layer.
- Still **not built**: integration test suite or end-to-end example machine config.

What's landed is usable today on its own (see Usage below). What's missing is
the integration, testing, and documentation needed to make the entire stack
consumable as a single drop-in base for a new machine.

## Usage

These are plain `system-manager` modules (and `gshadow-sync` is also a plain
NixOS module — see below). Import them as regular nixpkgs modules: add nixarch
to your system-manager flake as an input, then reference them in your
configuration.

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

### gcroot-guard

Catches a silent, data-loss-class failure in `system-manager switch` on a
Determinate-installer box.

Applying a config is two steps, and only the first is loud. `activate` writes
the units and starts things — the machine is now *running* that generation.
`register` then adds it to the system-manager profile, which is what makes it a
garbage-collection **root**. But `register` shells out to `nix-env`, and
`nix-env` is on the invoking user's PATH, not root's under plain `sudo`. So
step 2 dies after step 1 has already succeeded.

Nothing looks wrong. The box comes up, everything works — and the store paths
the running system depends on have no GC root, so the next
`nix-collect-garbage` is entitled to delete the currently-running system out
from under itself.

```nix
{
  imports = [ inputs.nixarch.systemManagerModules.gcroot-guard ];

  nixarch.gcrootGuard.enable = true;
}
```

This adds a boot-and-switch oneshot that fails loudly when the running
generation is unrooted, and installs `nixarch-register` — the same registration
with the PATH that `sudo` does not provide, so the fix is one command rather
than a remembered incantation.

The check works by asking about **itself**: the script is a store path inside
the generation being checked, so `nix-store --query --roots "$0"` reports that
generation's profile link if it was registered, and nothing at all if it was
not. That self-reference is what lets it work without the module knowing its
own output hash, which would be circular.

It cannot be an assertion: whether registration succeeded is a fact about the
machine *after* activation, not about the configuration. A correct config fails
this way exactly as readily as a wrong one.

Set `failLoudly = false` to log without marking the unit failed — though the
default is `true` deliberately, since the entire character of this bug is that
it is silent and everything appears fine.

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

### ai-workstation profile (removed)

Dissolved 2026-07-27. It bundled two unrelated things behind one enable flag:
GPU vendor toolchains, and a persona's dev tooling (`python`/`uv`, editors).

Neither is nixarch's job. This project makes an Arch box Nix-manageable; a
machine *class* — "an ML workstation" — is a composition on top of that, and
the profile sat directly under a Scope section saying exactly that.

Where it went:

| Piece | Now lives in |
|---|---|
| GPU vendor toolchains (CUDA / ROCm) | [nixgpu][nixgpu]'s `toolchain` module, which exports a `systemManagerModules` class so this hub can install it |
| `python`/`uv`, editors | [nixdev][nixdev] — language toolchains and the operator's toolbox |

The GPU package names — the profile's own header called them *"the one
genuinely hard-to-get-right bit and the main reason this profile exists"* —
carried over unchanged and are now asserted by a test in nixgpu.

### desktop-backend

The Arch half of [nixdesktop][nixdesktop]. nixdesktop declares *what* a Wayland
session needs as roles — a file manager, a polkit agent, a bar — and names no
package and no binary path, so it stays distro-agnostic. This module answers
*with what*, for Arch: it reads the `nixdesktop.want` attrset that nixdesktop's
profile publishes, resolves each role through
[`lib/desktop-roles.nix`](lib/desktop-roles.nix), and feeds the result into
`nixarch.packages.pacman`. It adds no mechanism of its own.

```nix
{
  imports = [
    inputs.nixdesktop.systemManagerModules.desktop  # declares the roles
    inputs.nixarch.systemManagerModules.desktop-backend  # resolves them for Arch
    inputs.nixarch.systemManagerModules.packages         # installs them
  ];

  nixarch.packages.enable = true;
  nixarch.desktopBackend.enable = true;

  nixdesktop.desktop = {
    enable = true;
    compositor = "niri";  # no default: nixdesktop prefers no compositor, so name one
  };
}
```

That alone resolves to a working niri desktop — compositor, bar, notifier,
launcher, terminal, file manager, polkit agent, keyring, portals, idle/lock,
clipboard and screenshot tooling.

Role resolution falls through to the role name itself when a role is not in the
tables, which is why `fileManager`, `launcher` and `terminal` can be free-form:
on Arch the role name is usually already the package name, so an unlisted choice
still works without waiting on this table to grow.

nixdesktop's three opt-in capability roles — `fileManagerExtras`, `gvfsBackends`
and `theming`, all `false` by default — are where the two backends diverge most,
and they are the clearest demonstration of why a per-platform catalogue beats a
shared name list:

- **`gvfsBackends` has no nixpkgs equivalent at all.** Arch splits SMB, NFS, MTP
  and gphoto2 into four separate packages, each with its own `gvfsd-*` daemon and
  `.mount` file, none of them pulled in by `gvfs` itself; without them `smb://`
  and friends simply fail to resolve while the local disk browses fine. nixpkgs
  builds one gvfs with all four compiled in, so the same role is a documented
  no-op there. Four names here, zero there.
- **`theming` is spelled differently.** `adw-gtk-theme` here is `adw-gtk3` in
  nixpkgs (no `adw-gtk-theme` attribute exists); `qt6ct` here is
  `qt6Packages.qt6ct` there. Only `nwg-look` is the same word on both.
- **`fileManagerExtras` needs a package here that must *not* be added there, and
  picks a different archiver.** Arch's `tumbler` ships the ffmpeg thumbnailer
  plugin, but that `.so` has a `DT_NEEDED` on a library only the separate
  `ffmpegthumbnailer` package provides — so without it video files silently never
  get a thumbnail; nixpkgs takes it as a buildInput of tumbler, where a second
  package would install nothing but noise. And `thunar-archive-plugin` dispatches
  only to archivers with a `.tap` wrapper under the LIBEXECDIR compiled into it,
  which here is a shared directory that `xarchiver`'s own tap lands in, and on
  NixOS is the plugin's own store path — reachable only by the taps it bundles.

Getting one of those names wrong is not a local failure: `pacman -S` aborts the
entire transaction on a single unknown target, which is also why
[`lib/desktop-roles.nix`](lib/desktop-roles.nix) partitions AUR names out before
publishing anything.

The user-layer companion, `homeManagerModules.desktop`, turns the same role
names into the commands that spawn them, so absolute paths like
`/usr/lib/mate-polkit/polkit-mate-authentication-agent-1` stay out of personal
config:

```nix
{
  imports = [
    inputs.nixdesktop.homeModules.niri
    inputs.nixarch.homeManagerModules.desktop
  ];

  nixdesktop.niri.enable = true;
  nixarch.home.desktop = {
    enable = true;
    polkitAgent = "mate-polkit";     # must match the system layer
    keyring = "gnome-keyring";
  };
}
```

Both halves read the same tables from the same file, so the package that gets
installed and the binary that gets spawned cannot drift apart. The role is
stated twice because system-manager and home-manager are separate evaluations
with no shared config tree — an honest cost, and a much smaller one than
duplicating a path.

One role is not a spawn command on Arch at all: `keyring = "oo7"` installs the
`extra/oo7` package, which ships its own user unit bound to `default.target` — a
target the user manager reaches at startup, strictly before a compositor pulls in
`graphical-session.target`. The vendor daemon therefore owns
`org.freedesktop.secrets` before anything nixdesktop rendered could start, so a
second unit loses the name race every time and sits permanently failed. The user
layer routes that role through nixdesktop's own
`session.keyring.oo7.renderDaemon = false` instead, which keeps oo7 the selected
provider — its credential-based unlock stays configurable — while rendering no
daemon of its own. Note also that Arch's `oo7` declares a hard `Conflicts With:
gnome-keyring`, so swapping providers means removing the outgoing one first.

### shelly

Shelly, a graphical package manager — a GTK4 front-end for pacman and the AUR (search,
install, remove, browse dependencies), sitting alongside the `pacman`/paru CLIs. Official
CachyOS repo, not AUR.

Unlike every other package that ends up in `nixarch.packages.pacman`/`.aur`, which arrives
from a domain repo (nixgpu, nixdev, ...) publishing into that sink from outside, Shelly is a
package nixarch itself owns — a tool for managing the Arch package set, which is nixarch's own
subject matter. It is declared the same way `desktop-backend` is: a small module inside this
repo that publishes into the sink from the inside.

```nix
{
  imports = [
    inputs.nixarch.systemManagerModules.packages
    inputs.nixarch.systemManagerModules.shelly
  ];

  nixarch.packages.enable = true;
  nixarch.shelly.enable = true;
}
```

**Caution:** this is a second, imperative package manager on a host whose installed set
`nixarch.packages` otherwise reconciles declaratively. Anything installed through Shelly's GUI
is invisible to that declaration and will read as undeclared drift the moment
`pruneUndeclared`/`pruneOrphans` is turned on — deliberate, not an oversight; the declared
lists remain the source of truth for what a box is supposed to have.

### cachyos-tools

CachyOS ships operator tooling of its own that has nothing to do with any domain: an update
notifier and applier (`cachy-update`, which also brings a tray applet and a systemd *user*
timer), a welcome/onboarding app (`cachyos-hello`), a kernel GUI (`cachyos-kernel-manager`)
and a curated graphical package installer (`cachyos-packageinstaller`, binary `cachyos-pi`).
Four independent `enable` options, all off by default:

```nix
{
  imports = [
    inputs.nixarch.systemManagerModules.packages
    inputs.nixarch.systemManagerModules.cachyos-tools
  ];

  nixarch.packages.enable = true;
  nixarch.packages.distro = "cachyos";
  nixarch.cachyosTools.cachyUpdate.enable = true;
}
```

**Distro-gated, and that is a correctness requirement rather than a nicety.** None of these
four names exists in upstream Arch or in the AUR — they live only in CachyOS's own
repositories. `pacman -S` aborts the *entire* transaction on a single unknown target, so one
of these names on a plain Arch host would fail every other declared package alongside it.
Each definition is therefore gated on `nixarch.packages.distro == "cachyos"`, and an
enabled-but-wrong-distro host gets an assertion rather than a silent no-op.

**Caution:** `cachy-update` and `cachyos-packageinstaller` are both, like Shelly above, an
imperative path to pacman on a box whose package set is otherwise reconciled from Nix. That
is workable — a GUI installer is a fine way to *evaluate* a package before committing to a
declaration — but only while the declaration actually follows.

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
  that imports every module this flake exports (`systemManagerModules` and
  `homeManagerModules`) and can bootstrap a complete workstation from fresh
  Arch in a single apply.
- Additional `system-manager` modules extracted from real use as they mature.

Once these land, nixarch will be usable as a true drop-in base layer for new
Arch/CachyOS machines.

## Repository layout

| Path | Purpose |
|---|---|
| `flake.nix` | Flake entry point; exports `systemManagerModules` (device-gids, gshadow-sync, packages, base-packages, foreign-service, logrotate, gcroot-guard, desktop-backend, shelly, cachyos-tools), `homeManagerModules` (shell, dev, desktop), and `nixosModules` (gshadow-sync). |
| `lib/` | Pure data shared across module classes — `desktop-roles.nix` (Arch resolution tables for nixdesktop roles) and `host-path.nix` (the host PATH every unit driving pacman/nix needs). |
| `experiments/` | Throwaway trials — see [`experiments/README.md`](experiments/README.md). |
| `studies/` | Written-up findings — see [`studies/README.md`](studies/README.md). |
| `site/` | The project page (`nixarch.corbet.ch`), vendored from the shared `design-corbet-ch` project-pages base. |

## Related projects

nixarch is one of several small, independently-usable open-source projects
sharing a common design system: a NixOS distro build (**nixnas**), a generic
RAM/memory-tuning NixOS module (**nixram**), tiny sub-1GB NixOS VPS profiles
(**nixvps**), cross-machine native Wayland app forwarding
([nixremote](https://github.com/julian-corbet/nixremote-corbet-ch)), and the
safe-adoption pattern for declarative shell config, across fish, bash and zsh
([nixsh](https://github.com/julian-corbet/nixsh-corbet-ch)). nixarch's own
niche is the non-NixOS, Arch-family side of the same "declarative machines"
idea: access to rolling Arch breadth, tidied by Nix's reproducible layers.

Closest sibling: **[nixdesktop][nixdesktop]** — a declarative, CPU-rendered
Wayland desktop (niri, bar, notifier, locker), which grew inside nixarch before
moving out. The two are designed to pair: nixdesktop declares desktop roles and
generates config, `desktop-backend` here resolves those roles into Arch
packages. Either works without the other.

[nixdesktop]: https://github.com/julian-corbet/nixdesktop-corbet-ch
[nixgpu]: https://github.com/julian-corbet/nixgpu-corbet-ch
[nixdev]: https://github.com/julian-corbet/nixdev-corbet-ch

## License

[MIT License](LICENSE) © 2026 Julian Corbet
