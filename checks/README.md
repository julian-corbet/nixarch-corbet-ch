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

Instead, `default.nix` declares the same handful of options as bare, opaque `attrsOf attrs` /
`listOf package` stubs and evaluates the real module against those. This is the exact trick
`experiments/desktop-backend-eval.nix` and `experiments/gcroot-guard-eval.nix` already used ad
hoc; this file is the permanent version, covering every module those two didn't. One consequence
worth knowing if you add a check: because the stub is opaque (not a submodule), a value wrapped in
`lib.mkForce` — `environment.PATH`, most notably — comes back through `config` still wrapped.
`unwrap` undoes that.

`home/desktop.nix` gets the mirror treatment (`homeManagerSurfaceStub`): home-manager's surface,
as far as anything in this pairing touches it, is `systemd.user.services` plus assertions. What is
*not* stubbed there is nixdesktop's own `home/session.nix` — that one is imported for real,
because every property worth asserting about the user layer (which unit gets rendered, with which
process shape) is produced by **its** provider dispatch from the values `home/desktop.nix` hands
it. Stubbing it would only prove that this module writes the options it writes.

## Coverage

- **`packages`** — declared `pacman`/`aur` lists round-trip through the option surface, including
  concatenation across two modules touching the same list; `pruneUndeclared` defaults off (the
  one safety property worth a dedicated check: it runs `pacman -Rns` on a real box, and pacman
  cannot distinguish "genuinely undeclared" from "declared by a list you forgot to write"); the
  reconcile unit exists only when enabled and carries the host-tools PATH override without which
  `pacman`/`runuser` don't resolve at all. The AUR-isolation step (a batch `paru` failure falls
  back to one invocation per package, so a single stale AUR checksum can't take the rest of the
  declared set down with it) gets a static-text pass over the actual generated reconcile script,
  via `pkgs.writeShellScript`'s own `.text` passthru — the module exposes the derivation itself as
  `nixarch.packages.reconcileScript` for exactly this. That proves the SHAPE of the control flow
  (batch attempt `if`-guarded not bare, a reachable per-package fallback loop, a tracked failure
  turning into a non-zero exit) without building or running anything; it does not prove paru
  itself behaves this way on a real box — see "Is/Isn't" above. That side was checked by hand:
  render the script, run it under stubbed `pacman`/`paru`/`runuser` with one package made to fail,
  confirm the others still install and the process exits non-zero.

  The same static-text treatment covers the **sync-database policy** (`syncDbPolicy`), which
  selects between three quite different scripts at eval time. Pinned: the default is
  `"require-fresh"` and never upgrades the host; `"full-upgrade"` really does render
  `pacman -Syu --noconfirm` and announces itself; **no policy renders a bare `pacman -Sy`**, which
  is the partial-upgrade footgun and the reflex fix this module deliberately does not offer; the
  freshness gate is conditional on `pacman -T` reporting something actually missing, and lands
  *before* the install rather than after it (an order, checked with offsets, not just presence);
  the configured `syncDbMaxAge` reaches the generated comparison; and a failed transaction reports
  the database age under every policy, so the mystery 404 stays named. Assertions about what a
  *message* says are scoped to that message via `infixBetween` — these scripts carry their own
  reasoning as comments, and an unscoped `hasInfix` stays green after the operator-facing sentence
  is deleted because the comment above it still says the words. The runtime side was checked the
  same way as the AUR step: render the script, run it under a stubbed `pacman` with a deliberately
  old sync directory, confirm it aborts *before* `pacman -S` on a stale database with something to
  fetch, stays quiet on a stale database with nothing to fetch, and names the database age when a
  stubbed 404 comes back.
- **`base-packages`** — `reflector`, `rebuild-detector`, `arch-install-scripts`, `base` and
  `base-devel` land in `pacman` regardless of `nixarch.packages.distro` (the same answer on every
  Arch-family host); `paru` is the one name that splits on it — `aur` on the default `"arch"`
  floor (a plain Arch host has no repository that carries a prebuilt one), lifted to `pacman` only
  on `distro = "cachyos"`, and never present in both lists at once on either setting. Also proves
  the list concatenates with a consumer's own `pacman`/`aur` entries, the same property
  `desktop-backend`/`shelly`/`logrotate` are each checked for.
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
  apart. The three opt-in capability roles (`fileManagerExtras`, `gvfsBackends`, `theming`) get
  the same off-by-default-plus-positive-control pair, and the theming one additionally pins the
  **Arch** spellings — `adw-gtk-theme`, not nixpkgs' `adw-gtk3` — because one unknown target
  aborts the entire pacman transaction, so a name copied across from the NixOS table would take
  the whole desktop down rather than just itself.
- **`home-desktop`** — the user layer's provider dispatch. `gnome-keyring` renders a keyring unit
  with the table's own command; `oo7` renders **none**, because the pacman `oo7` package already
  ships a `--user` unit bound to `default.target` (reached before any compositor pulls in
  `graphical-session.target`), so a second one loses the `org.freedesktop.secrets` name race every
  time and sits permanently failed. Separate checks pin that oo7 nevertheless remains the
  *selected* provider — the state that keeps its credential-based unlock reachable — and that it
  never travels through nixdesktop's generic `command` escape hatch, which would render that
  duplicate unit *and* give a `Type=simple` daemon gnome-keyring's `forking` shape.
- **`gcroot-guard`** — the check unit's PATH actually reaches `nix-store` (without it the check
  can't even run — the same PATH gap the module exists to catch); `failLoudly` flips the
  `ExecStart` `"-"` prefix; disabled ships no unit and no `nixarch-register` wrapper.
- **`shelly`** — off by default and contributes nothing to `pacman` until enabled; enabling adds
  exactly `"shelly"` to `pacman` and nothing to `aur` (it is the official CachyOS-repo package,
  not an AUR one); concatenates with a consumer's own `pacman` list rather than replacing it, the
  same property `desktop-backend` relies on.
- **`logrotate`** — off by default, contributing nothing to `pacman` and rendering no
  `environment.etc` entries at all; enabling adds exactly `"logrotate"` to `pacman` and
  concatenates with a consumer's own list. `dropins` entries render under `logrotate.d/<name>`
  (string values as `text`, also with `replaceExisting = true`), and enabling with no `dropins`
  declared adds none — this module ships no default rotation policy. This is also the first module
  in this suite to exercise `environment.etc`, so the stub gained that option (opaque
  `attrsOf attrs`, same shape as `systemd.services`/`users.groups`) to support it.

  The property this suite most wants to catch is now a **negative**: enabling must NOT render an
  `environment.etc."systemd/system/timers.target.wants/logrotate.timer"` entry. It used to, and
  that entry deadlocked activation on any host without logrotate already installed — see
  `studies/trusting-the-live-system.md`. What is checked instead is the replacement: a
  `nixarch-logrotate-enable-timer` oneshot exists when enabled and not when disabled; it is ordered
  `After=`/`Wants=` the package reconciler and does not hard-`Requires=` it; that reconcile unit
  name is cross-checked against the unit `modules/packages.nix` actually declares, so a rename over
  there fails here rather than silently turning the ordering into a reference to nothing; the unit
  is *not* `RemainAfterExit`, so it re-asserts the enable every activation; it carries the host
  PATH, without which `systemctl` does not resolve; and its script tests for the vendor unit
  **before** enabling (an order, not a presence) and explains a missing one by naming the package,
  the reconcile unit and `nixarch.packages.enable`. The module exposes
  `nixarch.logrotate.enableTimerScript` for that static-text pass, the same way `packages` exposes
  `reconcileScript`.
- **`etc-source`** — the defect class above, guarded across every module rather than only the one
  that got it wrong. An `environment.etc` entry whose `source` is a plain absolute-path **string**
  pointing outside the store is an artefact built from live system state that nothing validates:
  system-manager renders it with a bare `ln -s`, which succeeds against a nonexistent target, and
  the resulting dangling link fails much later inside the activation engine's `fs::canonicalize`
  with a message naming a store path rather than the missing package. Neither Nix nor
  system-manager catches it — eval cannot know the target host's filesystem, and the build sandbox
  has no `/usr` at all — so this sweep does, over every evaluated config in the suite. A positive
  control feeds it the exact shape that broke a live host, so the sweep cannot pass by being
  vacuous. `foreign-service.nix` is pulled into this one sweep (it is otherwise not covered) because
  it is the other module that writes `environment.etc` from caller-supplied values: a string handed
  to it must land in `text`, never in `source`.

**Not covered yet:** `modules/foreign-service.nix` beyond the `etc-source` sweep above, and the
`ai-workstation` profile. Both are real, shipped modules; they just didn't make this first pass.
Worth a follow-up in the same shape — `foreign-service.nix` in particular has a subtle
`restartTriggers` cross-reference into `environment.etc.<dest>.source` that would benefit from the
same treatment.

## Running

Needs a `nixdesktop` checkout for the `desktop-backend` and `home-desktop` sections — defaults to
a sibling clone (`../../nixdesktop`, i.e. `github/nixdesktop` next to `github/nixarch`), which is
how these two repos are normally worked on together. Override with `--arg nixdesktop <path>` if
yours lives elsewhere.

```console
$ nix-instantiate --eval --strict -A eval-checks.passedCount checks
"167"
```

A failing check throws before that derivation attribute even exists, with every failing check's
name and a `got: ...` detail — not just the first one:

```
error: nixarch eval-checks FAILED (1/167):
  - packages/prune-undeclared-defaults-off: got: true
```

## `nix flake check` runs a subset

`flake.nix` wires this suite in as `checks.<system>.eval-checks`, passing `nixdesktop = null` — so
`nix flake check` runs everything except the `desktop-backend` and `home-desktop` sections, and the
result derivation records what it skipped rather than hiding it.

That split is not laziness. `flake.nix`'s own header explains why `nixdesktop` isn't a flake input:
those two sections need it in the same evaluation, and adding it as an input would force every
consumer of nixarch — the many who use it without a desktop at all — to fetch it on every
evaluation. The `nixdesktop` sibling-checkout default above is a filesystem path outside this
flake's own source tree, which a real flake evaluation resolves against a copied, sandboxed store
path rather than your working tree, so it cannot be reached from `nix flake check` at all. Run the
standalone `nix-instantiate` invocation above to cover those two.
