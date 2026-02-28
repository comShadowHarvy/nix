#!/usr/bin/env bash
# Run this once from your ~/nixos-config folder
# It assumes you are running as root or via sudo

CONFIG_DIR="/etc/nixos"
REPO_DIR="$HOME/nixos-config"

# Force link the files from your repo to /etc/nixos
sudo ln -sf "$REPO_DIR/configuration.nix" "$CONFIG_DIR/configuration.nix"
sudo ln -sf "$REPO_DIR/hardware-configuration.nix" "$CONFIG_DIR/hardware-configuration.nix"
sudo ln -sf "$REPO_DIR/flake.nix" "$CONFIG_DIR/flake.nix"
sudo ln -sf "$REPO_DIR/flake.lock" "$CONFIG_DIR/flake.lock"

echo "Symlinks created. You can now manage everything from $REPO_DIR"
