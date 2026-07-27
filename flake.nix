{
  description = "nixarch — declarative Arch/CachyOS workstations, managed the Nix way (pre-alpha scaffold)";

  # ONE INPUT. The desktop modules that used to live here moved to nixdesktop, and the noctalia
  # flake they needed went with them -- a QML shell has no business in the closure of a project
  # about Arch package management. nixdesktop is deliberately NOT an input either: the desktop
  # backend below reads an option that nixdesktop's profile declares, which means a consumer
  # imports both flakes anyway, and adding it here would only force a fetch on every evaluation
  # for the many consumers who use nixarch without a desktop at all.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

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
        foreign-service = ./modules/foreign-service.nix;

        # Detects the activated-but-never-registered generation -- the failure where `activate`
        # succeeds, `register` dies on a missing nix-env, and the running system quietly has no
        # GC root. Ships `nixarch-register` to fix it.
        gcroot-guard = ./modules/gcroot-guard.nix;

        ai-workstation = ./profiles/ai-workstation.nix;

        # The Arch half of nixdesktop: resolves the roles nixdesktop declares into real pacman
        # packages. Import alongside nixdesktop.systemManagerModules.niri-desktop, which
        # declares the `nixdesktop.want` option this reads.
        desktop-backend = ./modules/desktop-backend.nix;
      };
      nixosModules = {
        # NixOS realises users with the same userborn as system-manager and
        # has the same /etc/gshadow blind spot, so this module carries over
        # as-is — no NixOS-specific fork needed.
        gshadow-sync = ./modules/gshadow-sync.nix;

        # Only entry in this class, so it is trivially the default.
        default = self.nixosModules.gshadow-sync;
      };
      homeManagerModules = {
        shell = ./home/shell.nix;
        dev = ./home/dev.nix;

        # User-layer half of the desktop backend: turns a nixdesktop role name into the Arch
        # command that spawns it, so absolute binary paths stay out of consumers' personal
        # config. Shares its tables with modules/desktop-backend.nix via lib/desktop-roles.nix.
        desktop = ./home/desktop.nix;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
