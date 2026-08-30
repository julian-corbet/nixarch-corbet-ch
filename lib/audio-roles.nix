# Arch/CachyOS resolution for NixAudio's semantic `nixaudio.want` contract. Pure data, shared by
# the system-manager backend and its eval checks.
#
# THIS FILE IS THE ONLY PLACE THAT KNOWS ARCH AUDIO PACKAGE NAMES. NixAudio publishes provider,
# protocol, diagnostic and firmware roles; this table answers how the host platform supplies them.
{ lib }:
let
  resolve = kind: table: name:
    table.${name} or (throw "nixarch audio backend: unsupported ${kind} role `${name}`");
in
rec {
  graphs = {
    # `pipewire-audio` supplies the profile/codec payload that is part of PipeWire itself on NixOS.
    pipewire = [ "pipewire" "pipewire-audio" ];
  };

  sessionPolicies = {
    wireplumber = [ "wireplumber" ];
  };

  clientProtocols = {
    alsa = [ "pipewire-alsa" ];
    # The distro package keeps jack2 (and an autostartable jackd) off a PipeWire host. It is not the
    # shim used for the Nix-built transport; modules/audio-backend.nix supplies that separately.
    jack = [ "pipewire-jack" ];
    pulse = [ "pipewire-pulse" ];
  };

  diagnostics = {
    alsa = [ "alsa-utils" ];
  };

  firmware = {
    "intel-sof" = [ "sof-firmware" ];
  };

  # No current audio role is AUR-only. Keep the partition explicit so adding one cannot put an
  # unresolvable target in the pacman transaction.
  aurOnly = [ ];

  packagesFor = want:
    if want == { } then [ ] else
    lib.unique (
      resolve "graph" graphs want.graph
      ++ resolve "session policy" sessionPolicies want.sessionPolicy
      ++ lib.concatMap (resolve "client protocol" clientProtocols) (want.clientProtocols or [ ])
      ++ lib.concatMap (resolve "diagnostic" diagnostics) (want.diagnostics or [ ])
      ++ lib.concatMap (resolve "firmware" firmware) (want.firmware or [ ])
    );

  partitionAur = packages: {
    repo = lib.filter (p: !(lib.elem p aurOnly)) packages;
    aur = lib.filter (p: lib.elem p aurOnly) packages;
  };
}
