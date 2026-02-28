#!/usr/bin/env bash
set -euo pipefail

# enable-tdarr-nixos.sh
# Copies the tdarr NixOS module into /etc/nixos, creates a small activation
# file that enables `services.tdarr` with provided SMB creds, adds that
# activation file to `/etc/nixos/configuration.nix` imports, and runs
# `nixos-rebuild switch`.
#
# Usage: sudo ./scripts/enable-tdarr-nixos.sh [--repo PATH] [--user USER] [--pass PASS]

REPO_PATH="$(pwd)"
SMB_USER="me"
SMB_PASS="changeme"

usage() {
  cat <<EOF
Usage: sudo $0 [--repo PATH] [--user USER] [--pass PASS] [--no-rebuild]

Options:
  --repo PATH    Path to this repository (default: current directory)
  --user USER    SMB username (default: me)
  --pass PASS    SMB password (default: changeme)
  --no-rebuild   Don't run nixos-rebuild automatically
  -h, --help     Show this help
EOF
  exit 1
}

NO_REBUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_PATH="$2"; shift 2;;
    --user) SMB_USER="$2"; shift 2;;
    --pass) SMB_PASS="$2"; shift 2;;
    --no-rebuild) NO_REBUILD=1; shift;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root (sudo)." >&2
  exit 2
fi

NIXOS_DIR=/etc/nixos
MODULE_SRC="$REPO_PATH/modules/tdarr.nix"
MODULE_DST="$NIXOS_DIR/tdarr-module.nix"
ACTIVATE_DST="$NIXOS_DIR/tdarr-activate.nix"
BACKUP_SUFFIX=".tdarr-backup-$(date +%Y%m%d%H%M%S)"

if [ ! -f "$MODULE_SRC" ]; then
  echo "Module not found in repo: $MODULE_SRC" >&2
  exit 3
fi

echo "Backing up existing configuration.nix to configuration.nix$BACKUP_SUFFIX"
cp -a "$NIXOS_DIR/configuration.nix" "$NIXOS_DIR/configuration.nix$BACKUP_SUFFIX"

echo "Copying module to $MODULE_DST"
cp -a "$MODULE_SRC" "$MODULE_DST"

cat > "$ACTIVATE_DST" <<EOF
{ config, pkgs, ... }:
{
  imports = [ ./tdarr-module.nix ];

  services.tdarr.enable = true;
  services.tdarr.smbCreds = { user = "${SMB_USER}"; pass = "${SMB_PASS}"; };

  # You may override other options here, for example:
  # services.tdarr.tdarrBase = "/var/lib/tdarr";
}
EOF

echo "Created activation file: $ACTIVATE_DST"

# Safely add import to configuration.nix if not already present
CONF="$NIXOS_DIR/configuration.nix"
if grep -q "tdarr-activate.nix" "$CONF"; then
  echo "configuration.nix already imports tdarr-activate.nix; skipping edit."
else
  echo "Injecting import into $CONF"
  awk '
  BEGIN{added=0}
  /imports[ \t]*=[ \t]*\[/ && !added {
    print; 
    # print lines until closing bracket and insert our import before the closing bracket
    while(getline){
      if(/\]/){
        print "  ./tdarr-activate.nix";
        print;
        added=1; break;
      } else print
    }
    next
  }
  { print }
  END{ if(!added){ print "\nimports = [ ./tdarr-activate.nix ];" > "/dev/stderr" }}' "$CONF" > "$CONF.tmp" || true

  # If awk failed to add (no imports array), append an imports line at end
  if ! grep -q "tdarr-activate.nix" "$CONF.tmp"; then
    echo "No imports array found; appending imports line to $CONF.tmp"
    cat "$CONF.tmp" > "$CONF.tmp2"
    echo "\nimports = [ ./tdarr-activate.nix ];" >> "$CONF.tmp2"
    mv "$CONF.tmp2" "$CONF.tmp"
  fi

  mv "$CONF.tmp" "$CONF"
  chmod --reference="$NIXOS_DIR/configuration.nix$BACKUP_SUFFIX" "$CONF" || true
  echo "Updated $CONF (original backed up as configuration.nix$BACKUP_SUFFIX)"
fi

if [ "$NO_REBUILD" -eq 0 ]; then
  echo "Running nixos-rebuild switch..."
  nixos-rebuild switch || { echo "nixos-rebuild failed; check /var/log/nixos/*" >&2; exit 4; }
  echo "nixos-rebuild completed."
else
  echo "Skipping nixos-rebuild ( --no-rebuild ). You must run: nixos-rebuild switch" 
fi

echo "Done."
