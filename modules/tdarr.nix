{ config, pkgs, lib, ... }:

let
  cfg = config.services.tdarr;
in
{
  options.services.tdarr = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Tdarr declarative service (autofs, docker, systemd unit, compose).";
    };

    tdarrBase = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/tdarr";
      description = "Base path for Tdarr data on the host.";
    };

    tdarrImage = lib.mkOption {
      type = lib.types.str;
      default = "haveagitgat/tdarr_node:latest";
    };

    serverIP = lib.mkOption { type = lib.types.str; default = "192.168.1.210"; };
    serverPort = lib.mkOption { type = lib.types.int; default = 8266; };
    puid = lib.mkOption { type = lib.types.int; default = 1000; };
    pgid = lib.mkOption { type = lib.types.int; default = 1000; };

    smbCreds = lib.mkOption {
      type = lib.types.attrs;
      default = { user = "me"; pass = "changeme"; };
      description = "Credentials used for authenticated SMB shares.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure required packages are present
    environment.systemPackages = with pkgs; [ docker autofs docker-compose lazydocker ];

    # Create directories used by Tdarr
    systemd.tmpfiles.rules = lib.mkForce (lib.concatLists (lib.mapAttrsToList (name: _:
      [ "d ${cfg.tdarrBase} 0755 root root -",
        "d ${cfg.tdarrBase}/mounts 0755 root root -",
        "d ${cfg.tdarrBase}/mounts/hass_share 0755 root root -",
        "d ${cfg.tdarrBase}/configs 0755 root root -",
        "d ${cfg.tdarrBase}/wud 0755 root root -"
      ]) {}));

    # Write SMB credentials file for autofs maps
    environment.etc."auto.smb.210".text = ''
username=${cfg.smbCreds.user}
password=${cfg.smbCreds.pass}
'';

    # Simple autofs map tailored for the typical Tdarr shares
    environment.etc."auto.tdarr".text = ''
# Tdarr SMB shares autofs map
hass_share  -fstype=cifs,vers=3.1.1,credentials=/etc/auto.smb.210,uid=${toString cfg.puid},gid=${toString cfg.pgid},iocharset=utf8,soft,actimeo=1 ://${cfg.serverIP}/share
hass_media  -fstype=cifs,vers=3.1.1,credentials=/etc/auto.smb.210,uid=${toString cfg.puid},gid=${toString cfg.pgid},iocharset=utf8,soft,actimeo=1 ://${cfg.serverIP}/media
hass_config -fstype=cifs,vers=3.1.1,credentials=/etc/auto.smb.210,uid=${toString cfg.puid},gid=${toString cfg.pgid},iocharset=utf8,soft,actimeo=1 ://${cfg.serverIP}/config
# Example guest shares (adjust as needed)
usb_share   -fstype=cifs,vers=3.1.1,guest,uid=${toString cfg.puid},gid=${toString cfg.pgid},iocharset=utf8,soft,actimeo=1 ://192.168.1.47/USB-Share
usb_share_2 -fstype=cifs,vers=3.1.1,guest,uid=${toString cfg.puid},gid=${toString cfg.pgid},iocharset=utf8,soft,actimeo=1 ://192.168.1.47/USB-Share-2
rom_share   -fstype=cifs,vers=3.1.1,guest,uid=${toString cfg.puid},gid=${toString cfg.pgid},iocharset=utf8,soft,actimeo=1 ://192.168.1.47/ROM-Share
'';

    # Add autofs master entry so mounts occur under tdarr base
    environment.etc."auto.master.d/tdarr.autofs".text = ''
# Tdarr autofs configuration
${cfg.tdarrBase}/mounts /etc/auto.tdarr --timeout=120,--ghost
'';

    # Place the docker-compose file under the tdarr base path
    environment.etc."tdarr/docker-compose.yml".text = ''
version: '3.8'

services:
  tdarr-node:
    image: ${cfg.tdarrImage}
    container_name: tdarr-node
    network_mode: host
    restart: unless-stopped
    environment:
      - serverIP=${cfg.serverIP}
      - serverPort=${toString cfg.serverPort}
      - nodeName=${lib.escapeShellArg (config.networking.hostName or "tdarr-node")}
      - PUID=${toString cfg.puid}
      - PGID=${toString cfg.pgid}
    volumes:
      - ${cfg.tdarrBase}/mounts/hass_share:/share:rw
      - ${cfg.tdarrBase}/mounts/hass_share/trans:/tmp:rw
      - ${cfg.tdarrBase}/configs:/app/configs:rw
    labels:
      - "wud.tag.include=^\\d+\\.\\d+\\.\\d+$"
      - "wud.watch=true"

  wud:
    image: fmartinou/whats-up-docker:latest
    container_name: wud
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${cfg.tdarrBase}/wud:/store
'';

    # Ensure autofs service is available via package and enabled
    systemd.services.autofs = {
      description = "autofs (automount)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.autofs}/sbin/automount -f -v";
        Type = "simple";
      };
    };

    # Enable docker declaratively
    virtualisation.docker.enable = true;

    # Systemd service to start Tdarr containers using docker-compose
    systemd.services."tdarr-node" = {
      description = "Tdarr Node (docker-compose)";
      wants = [ "autofs.service" "docker.service" ];
      after = [ "autofs.service" "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.docker}/bin/docker compose -f /etc/tdarr/docker-compose.yml up -d";
        ExecStop = "${pkgs.docker}/bin/docker compose -f /etc/tdarr/docker-compose.yml down";
      };
    };
  };
}
