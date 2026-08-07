# modules/base-packages.nix — the pacman packages every nixarch host wants, unconditionally.
#
# WHY THIS IS NIXARCH'S OWN PACKAGE SET, NOT A DOMAIN REPO'S. Same reasoning as
# modules/shelly.nix: everything else that ends up in `nixarch.packages.pacman`/`.aur` arrives
# from OUTSIDE this repo, a domain module (nixgpu, nixdev, this project's own desktop-backend.nix)
# publishing into that sink from its own tree. These three tools manage the Arch host itself
# (mirrors, rebuild detection, chroot/provisioning) — nixarch's own subject matter, not any
# domain's — so, like Shelly, they are declared HERE and published into the sink from the inside.
#
# WHY UNCONDITIONAL, UNLIKE SHELLY. Shelly is a taste choice — a GUI package manager some hosts
# want and others don't — so it gets its own `nixarch.shelly.enable` gate; a host opts in by
# naming it. These three are not a choice: every nixarch host benefits from ranked mirrors,
# rebuild detection after a library bump, and the chroot tools needed to recover one. There is no
# meaningful "off" state for a nixarch host, so this module carries no `enable` option of its
# own — unlike EVERY other module in this repo that touches `nixarch.packages.pacman`, all of
# which gate themselves (shelly.enable; desktop-backend.enable plus nixdesktop's own `want`).
# Importing this module IS the opt-in, the same way `nixarch.packages.enable` itself is: whether
# anything actually gets installed still depends on that master switch, exactly as
# desktop-backend.nix's own config comment already establishes ("Resolving roles into a list a
# consumer inspects without installing anything is a legitimate use anyway; leave
# `packages.enable` to them.") — this module just never adds a SECOND, redundant gate on top.
#
# All three verified live as official Arch repo packages (`pacman -Si`, `Repository : extra`),
# so none needs `nixarch.packages.aur`.
{
  config.nixarch.packages.pacman = [
    # Ranks pacman mirrors by speed and rewrites the mirrorlist. Every host benefits from mirrors
    # that are actually fast for it, not just alphabetically or geographically first.
    "reflector"

    # `checkrebuild` — finds installed packages that need rebuilding after a library bump (a
    # soname change landing before every reverse-dependent has been rebuilt against it). Detection
    # only; it does not rebuild anything itself.
    "rebuild-detector"

    # `arch-chroot`, `genfstab`, `pacstrap`. Verified installed today on the container host
    # (corbet-archlxc) and ABSENT on the Elitebook laptop — so this is not currently a uniform
    # fact about the fleet, only a uniform declaration. Its use is provisioning and disaster
    # recovery (building/chrooting into a new or broken install), not daily operation, which is
    # why a host going without it day-to-day was never a problem worth noticing before now.
    "arch-install-scripts"
  ];
}
