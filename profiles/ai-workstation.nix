# profiles/ai-workstation.nix — an OPT-IN system-manager profile for
# nixarch's target persona: an AI-engineer / data-scientist workstation on
# Arch/CachyOS.
#
# This is a PROFILE, not a new mechanism: it composes `nixarch.packages`
# (modules/packages.nix — the declarative-packages reconciler that is
# nixarch's headline feature) and turns a couple of high-level toggles into
# curated `pacman` lists. Every option defaults to off or to a conservative
# choice, and every list is `mkDefault`, so a consuming configuration can
# override anything without a `mkForce` fight.
#
# LEAN BY DESIGN — "when in doubt, leave it out". This profile installs a
# minimal, uncontroversial SYSTEM base only: fresh Python + uv, plus your
# GPU toolchain if you ask for one. It deliberately does NOT install the
# scientific stack (numpy/pandas/jupyter/...) or ML frameworks (PyTorch/...)
# at the system level, because the modern AI/DS workflow keeps those in
# PER-PROJECT uv/venv environments (reproducible per repo, not one global
# version fighting every project). System packages here are just the floor
# under that: a current interpreter, a fast env/package manager, and the
# GPU driver/runtime that genuinely IS a system concern.
#
# Anything beyond this base is the user's call — add it with `extraPacman`
# (or `editors`), or override `nixarch.packages.pacman`/`.aur` directly. If
# something turns out to be near-universally wanted for this persona, it can
# earn its way in via a PR rather than being guessed at up front. The GPU
# package names are the one genuinely hard-to-get-right bit and the main
# reason this profile exists; the rest stays out of your way.
{ lib, config, ... }:
let
  cfg = config.nixarch.aiWorkstation;
in
{
  options.nixarch.aiWorkstation = {
    enable = lib.mkEnableOption
      "AI/DS workstation base profile (lean, opt-in package sets over nixarch.packages)";

    gpu = lib.mkOption {
      type = lib.types.enum [ "none" "nvidia" "amd" ];
      default = "none";
      description = ''
        GPU stack to pull in — the one curated, hard-to-name-correctly bit.
        `"nvidia"` adds the CUDA/cuDNN toolchain; `"amd"` adds the ROCm
        toolchain. `"none"` (default) adds neither — CPU-only, or a GPU
        stack managed some other way (a container image, a fleet module).
      '';
    };

    python = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Include a lean Python base at the SYSTEM level: just `python` + `uv`.
        On by default because it is tiny, uncontroversial, and the entry
        point for the per-project uv/venv workflow this profile assumes.
        It deliberately does NOT pull the scientific stack or any ML
        framework — those belong in per-project environments, not system
        packages. Set `false` for no system Python at all.
      '';
    };

    editors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Dev editors/IDEs to include, as pacman package names (e.g. `"code"`,
        `"zed"`, `"neovim"`). Empty by default — deliberately not
        opinionated about editor choice.
      '';
    };

    extraPacman = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Escape hatch: extra official-repo packages appended to the computed
        `nixarch.packages.pacman` list — the intended place to add whatever
        this lean profile deliberately leaves out.
      '';
    };

    extraAur = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Escape hatch: extra AUR packages appended to `nixarch.packages.aur`.
        Requires `nixarch.packages.aurUser` to be set (see
        modules/packages.nix) or these are skipped with a warning at
        reconcile time, same as any other AUR entry.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixarch.packages.enable = lib.mkDefault true;

    nixarch.packages.pacman = lib.mkDefault (
      lib.optionals cfg.python [ "python" "uv" ]
      ++ lib.optionals (cfg.gpu == "nvidia") [ "cuda" "cudnn" "nvidia-utils" "nvidia-settings" ]
      ++ lib.optionals (cfg.gpu == "amd") [ "rocm-hip-sdk" "rocm-opencl-sdk" "rocm-smi-lib" ]
      ++ cfg.editors
      ++ cfg.extraPacman
    );

    nixarch.packages.aur = lib.mkDefault cfg.extraAur;
  };
}
