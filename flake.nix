{
  description = "nixarch — declarative Arch/CachyOS workstations, managed the Nix way (pre-alpha scaffold)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # v5 only -- nixpkgs' own "noctalia-shell"/"noctalia-qs" packages are the old Qt/QML v4
    # (github:noctalia-dev/noctalia's own team-recommended rewrite, native C++, no Qt at all).
    # No nixpkgs package exists for v5 yet, hence pulling their own flake directly.
    noctalia = {
      url = "github:noctalia-dev/noctalia";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, noctalia }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      # Extraction is in progress. The first two real modules have landed
      # under system-manager: a device-gid registry and a gshadow/group
      # hygiene fix. Everything else here is still an intentionally empty
      # placeholder — real content lands module by module as it is
      # generalized out of the private configuration it started life in.
      # See the Roadmap in README.md.
      lib = { };
      systemManagerModules = {
        gshadow-sync = ./modules/gshadow-sync.nix;
        device-gids = ./modules/device-gids.nix;
        packages = ./modules/packages.nix;
        foreign-service = ./modules/foreign-service.nix;
        ai-workstation = ./profiles/ai-workstation.nix;
        niri-desktop = ./profiles/niri-desktop.nix;
      };
      nixosModules = {
        # NixOS realises users with the same userborn as system-manager and
        # has the same /etc/gshadow blind spot, so this module carries over
        # as-is — no NixOS-specific fork needed.
        gshadow-sync = ./modules/gshadow-sync.nix;
      };
      homeManagerModules = {
        shell = ./home/shell.nix;
        dev = ./home/dev.nix;
        niri = ./home/niri.nix;
        waybar = ./home/waybar.nix;
        # Composed: noctalia-dev/noctalia's own upstream home-manager module (package + settings/
        # customPalettes/systemd plumbing, unmodified) plus home/noctalia.nix, which supplies
        # exactly what the upstream module doesn't -- the EGL-vendor-ICD fix a nix-built GPU/EGL
        # client needs on a non-NixOS host, and startup wiring via niri's own spawn-sh-at-startup.
        noctalia = { ... }: {
          imports = [ noctalia.homeModules.default ./home/noctalia.nix ];
        };
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
