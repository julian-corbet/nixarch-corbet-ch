# The gshadow gap: why userborn needs a healer

## The problem

On Arch/CachyOS, `userborn` (the system-manager tool that realises users and
groups) writes three files:

- `/etc/passwd` — user accounts
- `/etc/group` — group memberships
- `/etc/shadow` — password hashes

It does *not* write `/etc/gshadow` — the shadow-suite group password file.

Every group userborn creates lands in `/etc/group` with no corresponding line
in `/etc/gshadow`. This gaps the group password and administrator fields that
gshadow tracks, a state the shadow-suite considers an inconsistency.

Arch ships a daily hygiene check: `shadow.service` runs `pwck -qr && grpck -r`
(check users and groups). The `grpck` step finds these missing gshadow lines
and exits non-zero. The service then fails.

More problematically: a check you have learned to ignore becomes useless as a
warning signal. A genuine `/etc/passwd`/`/etc/shadow` mismatch — a real
problem that deserves attention — can then silently pass unnoticed.

## Why userborn doesn't write gshadow

userborn is a thin userborn, not a full account-management tool. It writes
only what NixOS does: passwd, group, and shadow (user password hashes). It has
no opinion on group passwords or group administrators — concepts that rarely
matter on a single-user or small-team system.

The gap is not unique to userborn-declared groups, either. Any group added
outside of Nix's view (installed by a package, added by hand) can be missing a
gshadow line too. This is a general Arch system-hygiene issue, not a userborn
bug.

## The solution: grpconv

The shadow-suite includes `grpconv`, a tool that regenerates `/etc/gshadow`
from `/etc/group`. It:

- Preserves any existing gshadow lines (including their group-password and
  group-administrator fields)
- Writes `name:!::` for missing entries (no password, no admins — the safe
  default, and what a group without a gshadow line effectively means anyway)
- Leaves the file unchanged if already consistent

This is idempotent: running it twice is identical to running it once. A group
that already has a matching gshadow line is not rewritten.

The `gshadow-sync` module wraps grpconv as a oneshot systemd service that:

1. Diffs `/etc/group` and `/etc/gshadow` before doing anything
2. Exits silently if they already agree
3. Saves a backup of the old gshadow to `gshadow.pre-gshadow-sync` (one time only)
4. Runs `grpconv` and reports what was added or removed

## Why this stays scope-limited

`gshadow-sync` **does not** run `pwconv` (which would regenerate `/etc/shadow`
from `/etc/passwd`). The reason:

`/etc/shadow` holds real password hashes. A `/etc/passwd`/`/etc/shadow`
mismatch is a genuine problem that deserves human investigation, not a silent
repair. Leave the data as-is; let grpck flag it, and let that flag mean
something.

`/etc/gshadow`, by contrast, holds group passwords — a feature rarely used on
modern systems. A missing gshadow line is not a signal of data loss; it is
Arch's definition of "no group password". Regenerating it from group is safe
and follows the distro's intent.

## Scope

This module targets Arch/CachyOS systems managed via `system-manager`. It is
also exported under nixosModules because NixOS uses the same userborn and
carries the same blind spot — the logic is identical, only the import path
changes.

A converged system (where gshadow already matches group) sees no writes. The
service becomes a no-op, and the daily check runs green.

## See also

- [`../modules/gshadow-sync.nix`](../modules/gshadow-sync.nix) — the module
  implementation with full details on when it runs and what it checks.
- [`../examples/`](../examples/) — working configuration examples showing both
  `gshadow-sync` and `device-gids` in use.
