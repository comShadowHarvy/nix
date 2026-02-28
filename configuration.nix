{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Networking & SSH
  networking.hostName = "my-server";
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Users
  users.users.me = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" ];
    openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBGxYRLhWEXRZerFJ5/d+IgiAnMj+URVflaiprsY7gZ1 jimbob343@gmail.com" ];
  };

  # Docker
  virtualisation.docker.enable = true;

  # Remote Access (Guacamole / NoVNC substitute)
  services.guacamole-server.enable = true;
  services.guacamole-client = {
    enable = true;
    settings = {
      guacd-port = 4822;
      guacd-hostname = "127.0.0.1";
    };
  };

  # System Packages
  environment.systemPackages = with pkgs; [
    git
    neovim
    docker-compose
    htop
  ];

  # System state version
  system.stateVersion = "25.11"; # Match your current NixOS version
}