{
  description = "nixarch — declarative Arch/CachyOS workstations, managed the Nix way (pre-alpha scaffold)";

  # TWO INPUTS. nixdesktop is deliberately NOT an input: the desktop backend below reads an
  # option that nixdesktop's profile declares, which means a consumer imports both flakes anyway,
  # and adding it here would only force a fetch on every evaluation for the many consumers who use
  # nixarch without a desktop at all.
  #
  # nixhost IS an input, for exactly one thing: `lib.probeFact`/`lib.collectProbes`
  # (github:julian-corbet/nixhost-corbet-ch, `lib/facts.nix`) -- the shared, plain-function fix for
  # the cross-namespace defensive-read defect class (a bare `config.nixfoo.bar or fallback` cannot
  # tell "nixfoo not composed here" from "nixfoo composed but `bar` moved/renamed/rejected" -- see
  # nixhost's own `lib/facts.nix` header). `device-gids.nix`'s own `config.nixiam.posix.groups`
  # read is exactly this shape, so it takes `probeFact` closed over as a plain function argument
  # (below), never `_module.args` -- so a consumer importing `systemManagerModules.device-gids`
  # sees an ordinary module function and never needs to know `probeFact` exists.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nixhost = {
    url = "github:julian-corbet/nixhost-corbet-ch";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixhost }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      # Modules land here as they are generalized out of private configuration into a reusable,
      # public shape; see README.md for the roadmap and current module list.
      lib = { };
      systemManagerModules = {
        gshadow-sync = ./modules/gshadow-sync.nix;
        # `probeFact` closed over here, before the module system ever sees the result -- see the
        # input comment above. The exported value is a plain module function taking the usual
        # `{ config, lib, pkgs, ... }`; nothing about consuming it changes.
        device-gids = import ./modules/device-gids.nix { inherit (nixhost.lib) probeFact; };
        packages = ./modules/packages.nix;
        foreign-service = ./modules/foreign-service.nix;

        # Detects the activated-but-never-registered generation -- the failure where `activate`
        # succeeds, `register` dies on a missing nix-env, and the running system quietly has no
        # GC root. Ships `nixarch-register` to fix it.
        gcroot-guard = ./modules/gcroot-guard.nix;


        # The Arch half of nixdesktop: resolves the roles nixdesktop declares into real pacman
        # packages. Import alongside nixdesktop.systemManagerModules.desktop, which
        # declares the `nixdesktop.want` option this reads.
        desktop-backend = ./modules/desktop-backend.nix;
      };
      nixosModules = {
        # NixOS realises users with the same userborn as system-manager and
        # has the same /etc/gshadow blind spot, so this module carries over
        # as-is — no NixOS-specific fork needed.
        gshadow-sync = ./modules/gshadow-sync.nix;

        # Same reasoning as the systemManagerModules entry above: pin+migrate
        # (users.groups + groupmod) and the devpts remount are plain module-
        # system options NixOS realises identically to system-manager — no
        # NixOS-specific fork needed. `probeFact` closed over here too, same
        # as the systemManagerModules entry.
        device-gids = import ./modules/device-gids.nix { inherit (nixhost.lib) probeFact; };

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

      # The eval-time regression net in ./checks. It was written, committed and NOT reachable
      # from any flake output, so `nix flake check` walked the module classes and the formatter
      # and reported success without evaluating a single one of its assertions. A suite nothing
      # runs is worse than no suite: it reads as coverage while providing none, and it silently
      # stopped being true the moment a module changed under it.
      #
      # `nixpkgs` is passed explicitly rather than left to its `<nixpkgs>` default, which would
      # resolve through NIX_PATH — an impurity that makes the result depend on the invoking
      # machine's channels rather than this flake's lock.
      # `nixdesktop = null` because nixarch does not take it as an input (see the input comment
      # above, and R4): the two desktop-backend checks need a nixdesktop checkout, so they run
      # only in the standalone invocation. The suite reports what it skipped rather than hiding it.
      checks = forAllSystems (system:
        import ./checks {
          nixpkgs = nixpkgs.outPath;
          inherit system;
          nixdesktop = null;
          # Unlike nixdesktop above, nixhost genuinely IS a flake input (see the input comment) --
          # so `nix flake check` gets the real, locked `nixhost.lib.probeFact` here, not a stub.
          probeFact = nixhost.lib.probeFact;
        });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
