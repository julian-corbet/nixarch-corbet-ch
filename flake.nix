{
  description = "nixarch — declarative Arch/CachyOS workstations, managed the Nix way (pre-alpha scaffold)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
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
      };
      nixosModules = {
        # NixOS realises users with the same userborn as system-manager and
        # has the same /etc/gshadow blind spot, so this module carries over
        # as-is — no NixOS-specific fork needed.
        gshadow-sync = ./modules/gshadow-sync.nix;
      };
      homeManagerModules = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
