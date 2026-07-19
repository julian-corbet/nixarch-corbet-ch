# A minimal home-manager configuration showing how to use nixarch's home-manager
# modules in a per-user setup.
#
# Usage: import this into your home-manager configuration. In your flake.nix or
# home-manager setup:
#
#   imports = [ inputs.nixarch.homeManagerModules.shell
#               inputs.nixarch.homeManagerModules.dev ];

{ lib, ... }:

{
  # ============================================================================
  # nixarch.home.shell — modern interactive shell bundle
  # ============================================================================
  #
  # This module enables a coherent, modern shell environment:
  # - fish: interactive shell (replaces bash/zsh for daily work)
  # - starship: cross-shell prompt with git info and rich styling
  # - zoxide: smarter `cd` replacement (learns frequent directories)
  # - fzf: fuzzy finder for command history, file search, etc.
  #
  # home-manager automatically wires them together: starship's prompt hook,
  # zoxide's `z`/`zi` functions, and fzf's key bindings all integrate into
  # fish without manual configuration. This module provides no personal content
  # (aliases, keybindings, functions) — those belong in your own config.

  nixarch.home.shell.enable = true;

  # ============================================================================
  # nixarch.home.dev — developer essentials: git config + direnv
  # ============================================================================
  #
  # This module configures two minimal but essential tools:
  #
  # 1. git: Sets your author identity (name/email) and sane defaults:
  #    - init.defaultBranch = "main" (future repos default to main)
  #    - pull.rebase = true (rebase instead of merge on pull)
  #    - push.autoSetupRemote = true (auto-track upstream branches)
  #
  # 2. direnv (+ nix-direnv): Per-project environment automation.
  #    When you `cd` into a project with a `.envrc` file (e.g., containing
  #    `layout uv` or `source .venv/bin/activate`), direnv auto-loads it.
  #    This pairs with the system ai-workstation profile's python+uv to
  #    enable a seamless per-repo virtual environment workflow.

  nixarch.home.dev.enable = true;

  # Git identity: CHANGE THESE to your real name and email.
  # This example uses a deliberately fake identity (Ada Lovelace, a historical
  # figure from 1815–1852) to show the structure — do not commit code with
  # this identity!
  nixarch.home.dev.git.userName = "Ada Lovelace";
  nixarch.home.dev.git.userEmail = "ada@example.com";

  # ============================================================================
  # Optional: layer in your own personal shell customization
  # ============================================================================
  #
  # After nixarch's modules enable the shell tools, you can layer on your
  # own aliases, keybindings, or functions without fighting mkDefault
  # precedence. Example (uncomment to use):
  #
  # programs.fish.shellAliases = {
  #   ll = "ls -lh";
  #   rebuild = "home-manager switch";
  # };
  #
  # programs.fish.interactiveShellInit = ''
  #   # Your fish initialization code here
  # '';
}
