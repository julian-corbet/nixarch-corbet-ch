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
      # Extraction is in progress: this repo does not yet ship any
      # system-manager or home-manager modules. These attrsets are
      # intentionally empty placeholders — real content lands here
      # module by module as it is pulled out of the private fleet
      # configuration it started life in. See the Roadmap in README.md.
      lib = { };
      nixosModules = { };
      homeManagerModules = { };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
