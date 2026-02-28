{ pkgs, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;
    
    # This pulls in the necessary dependencies for LazyVim
    extraPackages = with pkgs; [
      lua-language-server
      nil # Nix LSP
      ripgrep
      fd
    ];
  };

  # Link your LazyVim config folder
  # Create a directory in your repo: ~/nixos-config/nvim/
  # Then point Home Manager to it:
  xdg.configFile."nvim".source = ./nvim;
}