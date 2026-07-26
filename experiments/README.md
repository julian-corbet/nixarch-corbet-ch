# experiments

Throwaway trials: spikes, one-off scripts, things tried and abandoned or
not yet worth writing up. Nothing here is guaranteed to work, be
maintained, or survive the next cleanup pass.

If something in here turns out to matter, distill the actual finding into
[`../studies/`](../studies/README.md) and let the experiment stay
disposable (or delete it).

See the main [README](../README.md) for the project itself.

| File | What |
|---|---|
| `desktop-backend-eval.nix` | Confirms nixdesktop roles resolve into Arch package names, and that the system and user halves of the backend agree on which binary a role means. Needs a nixdesktop checkout (defaults to a sibling clone). |
