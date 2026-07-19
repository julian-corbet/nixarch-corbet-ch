# home/dev.nix — a LEAN home-manager module for nixarch's target persona:
# the developer/AI-engineer USER layer (as opposed to profiles/ai-workstation.nix,
# which is the SYSTEM layer — python+uv, GPU toolchain).
#
# Two concerns, deliberately kept together because they're both "make my git
# checkouts behave sanely" and both tiny:
#
#   1. git CONFIG — sane, uncontroversial defaults (main branch, rebase-on-pull,
#      autoSetupRemote). Your IDENTITY (name/email) is NOT one of those
#      defaults: `git.userName`/`git.userEmail` default to `null` and this
#      module writes nothing for them until you set them. This module writes
#      your git config, it does not invent your identity.
#
#   2. direnv (+ nix-direnv) — the per-project env ENABLER. It doesn't
#      install anything itself; it's what makes a project's `.envrc` (e.g.
#      `layout uv` / `source .venv/bin/activate`) auto-activate on `cd`,
#      which is what turns the system profile's system-level python+uv floor
#      (profiles/ai-workstation.nix) into the real per-repo uv/venv workflow
#      that profile assumes downstream.
#
# LEAN BY DESIGN — no shell integration choices, no extra programs, no
# opinions beyond these two. Everything is `mkDefault`, so a consuming
# home-manager config can override any of it without a `mkForce` fight.
{ lib, config, ... }:
let
  cfg = config.nixarch.home.dev;
in
{
  options.nixarch.home.dev = {
    enable = lib.mkEnableOption "developer home layer: git config + direnv";

    git = {
      userName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Ada Lovelace";
        description = ''
          Git author/committer name. REQUIRED to be set by YOU — there is
          intentionally no default. This module writes your git CONFIG, it
          does not invent your identity.
        '';
      };

      userEmail = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "ada@example.com";
        description = ''
          Git author/committer email — same deal as `userName`: you supply
          it, no default.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs.git = {
      enable = lib.mkDefault true;
      userName = lib.mkIf (cfg.git.userName != null) cfg.git.userName;
      userEmail = lib.mkIf (cfg.git.userEmail != null) cfg.git.userEmail;
      extraConfig = lib.mkDefault {
        init.defaultBranch = "main";
        pull.rebase = true;
        push.autoSetupRemote = true;
      };
    };

    # The per-project env workflow: pairs with the system ai-workstation
    # profile's python+uv — project-local uv/venv envs (an `.envrc` with
    # `layout uv` or similar) auto-activate via direnv on `cd`.
    programs.direnv = {
      enable = lib.mkDefault true;
      nix-direnv.enable = lib.mkDefault true;
    };
  };
}
