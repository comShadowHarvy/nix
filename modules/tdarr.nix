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

    smbShares = lib.mkOption {
      type = lib.types.attrs;
      default = {
        hass_share = { path = "//192.168.1.210/share"; auth = "auth"; };
        hass_media = { path = "//192.168.1.210/media"; auth = "auth"; };
        hass_config = { path = "//192.168.1.210/config"; auth = "auth"; };
        usb_share = { path = "//192.168.1.47/USB-Share"; auth = "guest"; };
      };
      description = "Map of SMB shares to mount via autofs. Each value is an attrset with 'path' and 'auth' (auth|guest).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure required packages are present
    environment.systemPackages = with pkgs; [ docker autofs docker-compose lazydocker ];

    # Create tmpfiles rules to ensure `tdarr` directories exist (including mounts)
    systemd.tmpfiles.rules = lib.mkForce (
      let
        shareNames = lib.attrNames cfg.smbShares;
        shareDirs = builtins.map (name: "d ${cfg.tdarrBase}/mounts/${name} 0755 root root -") shareNames;
      in lib.concatLists [ [
        "d ${cfg.tdarrBase} 0755 root root -",
        "d ${cfg.tdarrBase}/mounts 0755 root root -",
        "d ${cfg.tdarrBase}/configs 0755 root root -",
        "d ${cfg.tdarrBase}/wud 0755 root root -"
      ] shareDirs ]);

    # Write SMB credentials file for autofs maps
    environment.etc."auto.smb.210".text = ''
username=${cfg.smbCreds.user}
password=${cfg.smbCreds.pass}
'';

    # Generate autofs map from `smbShares` option
    environment.etc."auto.tdarr".text = let
      shareNames = lib.attrNames cfg.smbShares;
      mkLine = name: let
        share = builtins.getAttr name cfg.smbShares;
        authPart = if share.auth == "auth" then "credentials=/etc/auto.smb.210," else "guest,";
      in "${name} -fstype=cifs,vers=3.1.1,${authPart}uid=${toString cfg.puid},gid=${toString cfg.pgid},iocharset=utf8,soft,actimeo=1 :${share.path}";
    in lib.concatStringsSep "\n" (builtins.map mkLine shareNames);

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
