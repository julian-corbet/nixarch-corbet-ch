# profiles/ai-workstation.nix — an OPT-IN system-manager profile for
# nixarch's target persona: an AI-engineer / data-scientist workstation on
# Arch/CachyOS.
#
# This is a PROFILE, not a new mechanism: it composes `nixarch.packages`
# (modules/packages.nix — the declarative-packages reconciler that is
# nixarch's headline feature) and turns a handful of high-level toggles
# into curated `pacman`/`aur` lists. Nothing here is required — every
# option defaults to off or to a conservative choice, and every list this
# module produces is set with `mkDefault`, so a consuming configuration can
# override any of it (add to it, replace it, or drop entries) without a
# `mkForce` fight.
#
# HONESTY UP FRONT: the package lists below are a SENSIBLE STARTING POINT,
# not gospel. They are generic Arch/AUR package names for the ML/DS
# ecosystem as it exists at the time this module was written — not a
# pinned, tested, or version-locked stack. Arch ships whatever is current
# in the repos/AUR at update time; CUDA/ROCm/framework compatibility drifts
# constantly (a CUDA bump can outrun a framework's supported range, an AUR
# package can go stale or orphaned). Pinning specific versions, holding
# packages back, or swapping a listed package for an alternative is the
# user's call, made with `extraPacman`/`extraAur` or by overriding
# `nixarch.packages.pacman`/`.aur` directly — this module does not attempt
# to track compatibility for you.
{ lib, config, ... }:
let
  cfg = config.nixarch.aiWorkstation;
in
{
  options.nixarch.aiWorkstation = {
    enable = lib.mkEnableOption
      "AI/DS workstation package + tooling profile (curated, optional package sets over nixarch.packages)";

    gpu = lib.mkOption {
      type = lib.types.enum [ "none" "nvidia" "amd" ];
      default = "none";
      description = ''
        GPU stack to pull in. `"nvidia"` adds the CUDA/cuDNN toolchain
        packages; `"amd"` adds the ROCm toolchain packages. `"none"`
        (default) adds neither — CPU-only, or a GPU stack managed some
        other way (e.g. a container image, or a fleet-specific module).
      '';
    };

    python = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Include Python + uv + JupyterLab + the common scientific stack
        (numpy/pandas/matplotlib/scikit-learn/...). On by default since it
        is the lowest-risk, near-universally-wanted layer for this
        persona; set to `false` for a leaner base.
      '';
    };

    ml = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Include heavier ML framework packages (PyTorch, etc.). Off by
        default: these are large downloads, and which framework/build
        (CPU vs CUDA vs ROCm variant) is wanted is genuinely
        project-specific — opt in once you know what you need.
      '';
    };

    editors = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Dev editors/IDEs to include, as pacman/AUR package names (e.g.
        `"code"`, `"zed"`, `"neovim"`). Empty by default — deliberately not
        opinionated about editor choice; the user picks.
      '';
    };

    extraPacman = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Escape hatch: extra official-repo packages appended to the
        computed `nixarch.packages.pacman` list, for anything this
        profile's toggles don't cover.
      '';
    };

    extraAur = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Escape hatch: extra AUR packages appended to the computed
        `nixarch.packages.aur` list, for anything this profile's toggles
        don't cover. Requires `nixarch.packages.aurUser` to be set (see
        modules/packages.nix) or these are skipped with a warning at
        reconcile time, same as any other AUR entry.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixarch.packages.enable = lib.mkDefault true;

    nixarch.packages.pacman = lib.mkDefault (
      lib.optionals cfg.python [
        "python"
        "uv"
        "python-pipx"
        "jupyterlab"
        "python-numpy"
        "python-pandas"
        "python-matplotlib"
        "python-scipy"
        "python-scikit-learn"
      ]
      ++ lib.optionals (cfg.gpu == "nvidia") [
        "cuda"
        "cudnn"
        "nvidia-utils"
        "nvidia-settings"
      ]
      ++ lib.optionals (cfg.gpu == "amd") [
        "rocm-hip-sdk"
        "rocm-opencl-sdk"
        "rocm-smi-lib"
      ]
      ++ cfg.editors
      ++ cfg.extraPacman
    );

    nixarch.packages.aur = lib.mkDefault (
      lib.optionals cfg.ml (
        if cfg.gpu == "nvidia" then [ "python-pytorch-cuda" ]
        else if cfg.gpu == "amd" then [ "python-pytorch-rocm" ]
        else [ "python-pytorch" ]
      )
      ++ cfg.extraAur
    );
  };
}
