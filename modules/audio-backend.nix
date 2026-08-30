# The Arch/CachyOS system-layer backend for NixAudio.
#
# NixAudio publishes WHAT the local graph requires as `nixaudio.want`. This module answers WITH
# WHAT on the host platform: pacman/AUR package names and the ABI-correct command prefix for its
# Nix-built JackTrip transport. Import it alongside NixAudio's system-manager module and
# nixarch's package reconciler. There is no flake dependency between the two repositories.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixarch.audioBackend;
  roles = import ../lib/audio-roles.nix { inherit lib; };
  want = config.nixaudio.want or { };
  split = roles.partitionAur (roles.packagesFor want);
in
{
  options.nixarch.audioBackend = {
    enable = lib.mkEnableOption ''
      resolving NixAudio's declared roles into Arch/CachyOS packages and command paths.

      Requires NixAudio's system-manager module in the same evaluation (it declares
      `nixaudio.want`) and `nixarch.packages` to install the resolved packages
    '';
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      nixarch.packages.pacman = split.repo;
      nixarch.packages.aur = split.aur;
    }

    # The transport binary is Nix-built and its RUNPATH names Nix's real libjack2. Arch's pw-jack
    # is deliberately a no-op for library redirection because Arch replaces libjack in /usr/lib;
    # it therefore cannot redirect this binary. Use nixpkgs' pw-jack, ABI-matched to the Nix
    # binary it wraps. This adds no second PipeWire daemon: the shim's libjack speaks the PipeWire
    # protocol to the distro server already running in the user session. Proven live at 48 kHz /
    # 128 frames before this responsibility moved here; this module preserves that exact bridge.
    (lib.mkIf ((config.nixaudio.fabric.enable or false) && want != { }) {
      nixaudio.fabric.transport.command = [
        "${pkgs.pipewire.jack}/bin/pw-jack"
        "${config.nixaudio.fabric.transport.package}/bin/jacktrip"
      ];
    })
  ]);
}
