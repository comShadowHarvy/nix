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
  xdg.configFile."nvim".source = ./nvim;
}
