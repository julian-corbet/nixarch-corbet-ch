# The Arch/CachyOS user-layer backend for NixAudio.
#
# Home Manager owns the user unit, while the running PipeWire and its command-line clients come
# from the host distribution. Supply those platform paths here rather than making NixAudio name a
# distro or assume a global PATH. Import alongside NixAudio's Home Manager module.
{ lib, config, pkgs, ... }:
let
  cfg = config.nixarch.home.audio;
in
{
  options.nixarch.home.audio.enable = lib.mkEnableOption
    "Arch/CachyOS command paths for NixAudio's Home Manager projection";

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      # The daemon and guard invoke clients of the RUNNING graph. On this platform those clients
      # are the distro's, including in a lingering session whose inherited PATH may be incomplete.
      nixaudio.daemon.toolPath = [ "/usr/bin" ];
      nixaudio.guard.toolPath = [ "/usr/bin" ];
    }

    # Same ABI boundary as the system-manager backend. This definition is repeated because the
    # system and Home Manager trees are separate evaluations; both must remain valid when used as
    # the sole projection for a host.
    (lib.mkIf (config.nixaudio.fabric.enable or false) {
      nixaudio.fabric.transport.command = [
        "${pkgs.pipewire.jack}/bin/pw-jack"
        "${config.nixaudio.fabric.transport.package}/bin/jacktrip"
      ];
    })
  ]);
}
