# checks/

Eval-level regression checks for nixarch's system-manager modules. `nixarch` is the substrate
under two real desktops (see the root README's Vision), so a change here that silently breaks a
module deserves to fail loudly before it ever reaches `system-manager switch`.

## What this is, and isn't

**Is:** every check builds a real `lib.evalModules` tree around the module(s) under test and
inspects what lands in `config` — units, package lists, gid maps. Pure evaluation, no build, no
VM, no store realisation of anything but a trivial pass/fail marker derivation at the end.

**Isn't:** a test that pacman actually converges, that `grpconv` actually heals `/etc/gshadow`, or
that a system-manager generation actually gets rooted. Those are facts about a *running* box, not
about a configuration, and no amount of evaluation can answer them — see the header comments on
`modules/gcroot-guard.nix` for what was instead verified directly against a live CachyOS machine.

## The stub pattern

None of nixarch's modules are NixOS modules with a real option tree to evaluate against — they're
system-manager modules, and only system-manager itself provides `systemd.services`,
`environment.systemPackages`, and `users.groups`. Building a real system-manager evaluation here
would mean adding `numtide/system-manager` as a flake input just to run checks, for a project
whose `flake.nix` deliberately has [one input](../flake.nix) and says so.

Instead, `default.nix` declares the same three options as bare, opaque `attrsOf attrs` /
`listOf package` stubs and evaluates the real module against those. This is the exact trick
`experiments/desktop-backend-eval.nix` and `experiments/gcroot-guard-eval.nix` already used ad
hoc; this file is the permanent version, covering every module those two didn't. One consequence
worth knowing if you add a check: because the stub is opaque (not a submodule), a value wrapped in
`lib.mkForce` — `environment.PATH`, most notably — comes back through `config` still wrapped.
`unwrap` undoes that.

## Coverage

- **`packages`** — declared `pacman`/`aur` lists round-trip through the option surface, including
  concatenation across two modules touching the same list; `pruneUndeclared` defaults off (the
  one safety property worth a dedicated check: it runs `pacman -Rns` on a real box, and pacman
  cannot distinguish "genuinely undeclared" from "declared by a list you forgot to write"); the
  reconcile unit exists only when enabled and carries the host-tools PATH override without which
  `pacman`/`runuser` don't resolve at all.
- **`device-gids`** — a gid map renders into `users.groups.<name>.gid`; the `tty` entry alone
  arms the devpts remount unit; an empty map, and a populated map with the module disabled, are
  both genuine no-ops (no unit, no group declarations).
- **`gshadow-sync`** — enabling the module produces the `gshadow-sync` unit with its documented
  ordering (`after` userborn/gid-migrate, `before` shadow.service, `wantedBy` both
  multi-user.target and shadow.service) and is *not* `RemainAfterExit`; disabled contributes
  nothing.
- **`desktop-backend`** — nixdesktop's roles resolve to real Arch packages (file manager, polkit
  agent, compositor, capabilities), and — the regression this suite most wants to catch — the
  **defaults pull in zero KDE packages**. The old profile defaulted the polkit agent to
  `polkit-kde-agent`, so an unopinionated consumer silently got a KDE Frameworks stack reinstalled
  on every activation. A positive-control check proves `polkit-kde-agent`/`qt6ct` *can* appear on
  an explicit opt-in, so the "never by default" assertion isn't vacuously true. Also checks that
  the system layer (package) and user layer (`home/desktop.nix`'s spawn command) agree on the
  same binary, since `lib/desktop-roles.nix` is the only thing keeping those two from drifting
  apart.
- **`gcroot-guard`** — the check unit's PATH actually reaches `nix-store` (without it the check
  can't even run — the same PATH gap the module exists to catch); `failLoudly` flips the
  `ExecStart` `"-"` prefix; disabled ships no unit and no `nixarch-register` wrapper.

**Not covered yet:** `modules/foreign-service.nix` and the `ai-workstation` profile. Both are
real, shipped modules; they just didn't make this first pass. Worth a follow-up in the same
shape — `foreign-service.nix` in particular has a subtle `restartTriggers` cross-reference into
`environment.etc.<dest>.source` that would benefit from the same treatment.

## Running

Needs a `nixdesktop` checkout for the `desktop-backend` section — defaults to a sibling clone
(`../../nixdesktop`, i.e. `github/nixdesktop` next to `github/nixarch`), which is how these two
repos are normally worked on together. Override with `--arg nixdesktop <path>` if yours lives
elsewhere.

```console
$ nix-instantiate --eval --strict -A eval-checks.passedCount checks
"43"
```

A failing check throws before that derivation attribute even exists, with every failing check's
name and a `got: ...` detail — not just the first one:

```
error: nixarch eval-checks FAILED (1/43):
  - packages/prune-undeclared-defaults-off: got: true
```

## Not wired into `flake.nix`

Deliberately. `flake.nix`'s own header explains why `nixdesktop` isn't a flake input: the
`desktop-backend` section here needs it in the same evaluation, and adding it as an input would
force every consumer of nixarch — the many who use it without a desktop at all — to fetch it on
every evaluation. The `nixdesktop` sibling-checkout default above is a filesystem path outside
this flake's own source tree, which a real flake evaluation (`nix flake check`, `nix build
.#checks.<system>.eval-checks`) resolves against a copied, sandboxed store path, not your working
tree — so wiring `checks` into `flake.nix` as written would break the moment anyone without that
exact sibling layout ran `nix flake check`, or would need `nixdesktop` promoted to a real flake
input either way, undoing that documented design decision. Run it directly with
`nix-instantiate`, the same way `experiments/*.nix` already are.
