# Trusting the live system: two artefacts nothing validated

Two defects found in production on the same day, in two unrelated modules, with the same shape:
**something built out of live system state, where the "input is missing" case produces a wrong
answer instead of an error.** One built an artefact that was structurally fine and semantically
dangling. The other trusted a cache it had never once looked at. Both failed late, far from the
cause, with a message that pointed somewhere else.

Nix is very good at making the parts it owns total: a missing attribute is an eval error, a missing
input is a build error. Neither defect was in a part Nix owns. Everything below is about the seam
where a declaration reaches for something on the other side of the store boundary.

---

## Case 1 — an enable link built from a unit that was not installed

`modules/logrotate.nix` enabled `logrotate.timer` the way `systemctl enable` does: a symlink at
`/etc/systemd/system/timers.target.wants/logrotate.timer` pointing at the vendor unit in
`/usr/lib/systemd/system/`. It declared that symlink through system-manager's `environment.etc`,
with `source` as a plain absolute-path **string** rather than a Nix path, precisely so
system-manager would link to the file already on disk instead of importing a frozen copy into the
store. That is a legitimate idiom — a host's own `/etc/localtime` entry uses it.

### What actually happens when the target is absent

system-manager renders every `environment.etc` entry into a small derivation of its own
(`nix/modules/default.nix`, `addToStore`). The entire build is:

```sh
mkdir -p "$out/$(dirname "$target")"
ln -s "$source" "$out/$target"
```

`ln -s` does not look at its target. Built against a unit that does not exist, this derivation
**succeeds** and its output is a dangling symlink. Reproduced verbatim:

```console
$ find /nix/store/…-definitely-not-installed.timer-etc-link -mindepth 1 -printf '%y %p -> %l\n'
d …/systemd
d …/systemd/system
d …/systemd/system/timers.target.wants
l …/systemd/system/timers.target.wants/definitely-not-installed.timer -> /usr/lib/systemd/system/definitely-not-installed.timer

$ readlink -e …/timers.target.wants/definitely-not-installed.timer
(nothing; exit 1)
```

The link is present, has a plausible size, and `ls -l` shows it. It is only wrong when
dereferenced. Something dereferences it: `buildEnv` merges these per-entry derivations into one
`etc-static-env`, and the activation engine then walks that env calling `fs::canonicalize` on every
entry (`crates/system-manager-engine/src/activate/etc_files.rs`). `canonicalize` follows symlinks.

```
Error during activation: Failed to get the canonical path of
/nix/store/…-systemd-system-timers.target.wants-logrotate.timer-etc-link/systemd/system/timers.target.wants/logrotate.timer
— No such file or directory
```

That message names a store path and a directory nobody asked about. It does not contain the words
`logrotate`, `pacman`, or `package` in any load-bearing position. The distance between the message
and the cause is the whole defect.

### The deadlock, which is what made it unfixable from the host

system-manager's activation order is fixed: pre-activation assertions, then **/etc**, then
sysinit-reactivation, userborn, tmpfiles, then **services**. The package reconciler is a service.

| Needs | Provided by | Which needs |
|---|---|---|
| the `/etc` link to resolve | the `logrotate` package | the package reconciler |
| the package reconciler to run | activation reaching the services stage | activation getting past `/etc` |
| activation getting past `/etc` | the `/etc` link resolving | *(back to the top)* |

The host could not install logrotate through nixarch at all. The loop was cut by hand with one
`pacman -S logrotate`. A container host without logrotate could never have converged on its own.

### What was rejected, and why

| Option | Why not |
|---|---|
| `builtins.pathExists` at eval, assert or render nothing | Reads the filesystem of whatever machine **evaluates** the flake, which is not necessarily the machine being activated. `nixarch.packages.distro` already refuses exactly this probe for exactly this reason. An impure probe answering for the wrong host is the same silent-wrong-answer defect wearing a different hat. |
| A build-time existence check | Worse. The build sandbox has no `/usr` at all, so the check fails on every host, including the ones where the unit is present. |
| Ship our own copy of the timer (and service) unit into the store | Takes ownership of a file pacman owns, and silently shadows the vendor unit forever — a later `pacman -Syu` that changes it would have no effect. The module's whole premise is that pacman owns the binary and the unit. |
| Make the reconciler run before `/etc` activation | Not ours. That is system-manager's engine, and the ordering is deliberate there. |
| A `system-manager.preActivationAssertions` entry naming the deadlock | Genuinely better than the canonicalize error — it runs **on the target box, before `/etc`**, so it can say the right sentence. But it only renames the deadlock. Activation still aborts, the reconciler still never runs, the host still cannot install logrotate on its own. |

### What was done

Express the enable **where the fact it depends on is true**: on the box, after the reconciler. A
oneshot `nixarch-logrotate-enable-timer`, ordered `After=`/`Wants=` `nixarch-packages-reconcile`,
running `systemctl enable --now logrotate.timer` under the host PATH. No store artefact stands in
for a live file, so there is nothing to dangle, and `/etc` activation no longer depends on a
package. The reconciler installs logrotate and the timer is enabled **in the same activation**.

This is not a new mechanism: `modules/foreign-service.nix` already drives pacman-owned units from a
bridge oneshot for the same reason. The `environment.etc` route was the outlier.

Two costs, both accepted and both written down where the option is declared:

- `enable = false` stops nixarch **asserting** the timer; it does not run `systemctl disable`. An
  `environment.etc` entry would have been removed on removal. This one is not.
- The unit is deliberately **not** `RemainAfterExit`. system-manager restarts a unit only when its
  own store path moved, so a RemainAfterExit oneshot that succeeded once would never re-assert.
  Left to go inactive, `system-manager.target` pulls it back up every activation — which is the one
  property the `/etc` entry gave for free, bought back for one process start.

---

## Case 2 — a converger that trusted a cache it never validated

`modules/packages.nix` ran `pacman -S --needed --noconfirm …` on every activation and never
refreshed, or so much as looked at, the sync databases. On a host whose databases were four to
seven days old, every mirror answered 404:

```
error: failed retrieving file 'openai-codex-0.146.0-1.1-x86_64_v3.pkg.tar.zst' … The requested URL returned error: 404
error: failed to commit transaction (unexpected error)
```

pacman resolves a name to a **file with an exact version in it**, and mirrors keep only the current
build. A database days old therefore names files that no longer exist anywhere. Nothing in that
output mentions the database. It reads like a broken mirror, or a bad package. It is neither.

### Why the obvious fix is a footgun

`pacman -Sy` followed by installing is Arch's textbook **partial upgrade**: the new package is
resolved against refreshed metadata while the libraries on disk are the old ones, and the mismatch
surfaces later as a missing shared object rather than as an error at install time. The only refresh
that is not a partial upgrade is `pacman -Syu` — but a full system upgrade on every activation is a
far larger and more surprising action than "converge the declared list", and on a workstation it
can carry a kernel, a Mesa or a libc bump.

So there is no single right answer, which makes it a policy, not a default.

### What was done

`nixarch.packages.syncDbPolicy`, three values, plus two layers of defence.

**Layer 1 — a pre-flight gate, scoped to the runs that can actually fail.** Under the default
`"require-fresh"`, the reconciler asks whether any declared package is genuinely missing
(`pacman -T`, which understands `provides` as a `pacman -Qq` diff would not). If the whole declared
set is already installed, `pacman -S --needed` contacts no mirror at all and the database's age
cannot matter — nothing is checked and nothing fails. That is the steady-state reconcile on every
activation and every boot, and keeping it quiet is the point: **a gate that fires on runs that were
never going to fail gets switched off.** Only when something must actually be fetched is the
newest database's age compared against `syncDbMaxAge`, and a stale one aborts before pacman touches
a mirror, naming staleness, the 404 symptom, `pacman -Syu` as the fix, and `-Sy` as the trap.

**Layer 2 — a post-failure diagnosis, on every policy including `"ignore"`.** The threshold above
is a heuristic; a package rebuilt an hour ago already invalidates an hour-old database, so no age
makes a 404 impossible. So step 1 is `if`-guarded, and a failed transaction always reports how old
the databases actually are alongside the sentence "if the errors above are 404s, that is the cause
and not the mirrors". This layer cannot false-alarm, and it is what guarantees the mystery is gone
regardless of how the threshold is tuned.

`"full-upgrade"` runs `pacman -Syu --noconfirm` itself and announces in the journal that it is a
full system upgrade. `"ignore"` drops layer 1 and keeps layer 2. **No policy offers a bare `-Sy`**:
it is strictly worse than `full-upgrade` in every situation where it would appear to help, and
`checks/default.nix` asserts the literal never appears in the generated script under any policy.

### Two details worth keeping

**The mtime is the right signal, and it is not the download time.** pacman stamps each downloaded
`.db` with the *remote* file's `Last-Modified` — that is how `-Sy` decides whether to re-fetch. So
the mtime measures how old the database's **content** is, which is exactly what decides whether the
versions it names still exist on a mirror. Measured live: `extra.db` carried an mtime hours old
while the local package database directory had been written minutes earlier.

**Newest across repositories, not oldest.** A quiet repository can legitimately go days without a
revision; taking its mtime would report every host as stale. `[extra]` and its derivative
equivalents move several times a day.

`syncDbMaxAge` defaults to 48 hours. Long enough that a box which is simply not upgraded daily
converges without complaint; short enough to catch the week-old database that produced this.

---

## What generalises

1. **An artefact built from live system state must be built by something that runs on that
   system, at a point where the state is guaranteed.** Not by eval (which runs on the wrong
   machine), not by a build (which runs in a sandbox with no `/usr`), and not by a stage that runs
   before the thing that establishes the state.
2. **Check whether the primitive you are leaning on is total.** `ln -s` succeeds on a nonexistent
   target. `pacman -S` resolves happily against week-old metadata. Both are correct primitives
   doing what they are documented to do; both hand back a plausible artefact for an input that is
   not there. Look for that property explicitly before building on one.
3. **A guard belongs where the failure would otherwise be silent, and its message belongs at the
   distance of the cause.** The canonicalize error was loud and useless because it fired three
   layers away from the missing package. The 404 was loud and useless because it named a file.
4. **Scope a gate to the runs that can actually fail.** A correctness gate that fires on the common
   healthy path is a gate that gets deleted. Ask what makes the failure possible at all — here,
   "does anything actually have to be fetched" — and gate on that, not on the risky condition in
   isolation.
5. **Where an unsafe repair is the obvious one, make the choice explicit rather than picking
   silently.** `-Sy` is what a reflex would have added. Offering the safe form as a named policy,
   refusing to offer the unsafe one, and asserting its absence in the check suite is the version
   that survives the next person in a hurry.
6. **A text assertion over a generated script is satisfied by that script's own comments.** These
   modules carry their reasoning inline, and a comment explaining a message uses the same words as
   the message. `checks/default.nix` grew an `infixBetween` helper for this: an assertion about
   what a *message* says is scoped to that message, or it stays green after the message is deleted.
   Two such checks were caught being toothless by mutation-testing them, not by review.
