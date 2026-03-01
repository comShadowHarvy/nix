#!/bin/bash
# =============================================================================
# Tdarr Setup Script with Autofs SMB Mounting
# 
# A comprehensive, idempotent setup script for Tdarr transcoding nodes
# Supports: Arch Linux, Debian, Ubuntu, Fedora, SteamOS, and Bazzite
# 
# Features:
# - Auto-detects and installs Docker (preferred) or Podman
# - Configures autofs for SMB share mounting
# - Creates Docker Compose configuration with WUD (What's Up Docker)
# - Installs and configures lazydocker for management
# - Monitors container updates with WUD web UI
# - Handles SELinux, OSTree, and read-only filesystems
# =============================================================================

set -Eeo pipefail

# =============================================================================
# CONSTANTS AND CONFIGURATION
# =============================================================================

# Tdarr configuration
readonly TDARR_IMAGE="haveagitgat/tdarr_node:latest"
readonly SERVER_IP="192.168.1.210"
readonly SERVER_PORT="8266"
readonly PUID="1000"
readonly PGID="1000"
NODE_NAME="$(hostname)-node"

# Path configuration
readonly USER_HOME="$HOME"
readonly TDARR_BASE="$USER_HOME/tdarr"
readonly TDARR_MOUNTS="$TDARR_BASE/mounts"
readonly TDARR_CONFIGS="$USER_HOME/Tdarr/configs"
readonly COMPOSE_FILE="$TDARR_BASE/docker-compose.yml"
readonly LAZYDOCKER_WRAPPER="$TDARR_BASE/ld.sh"
readonly LOG_FILE="$TDARR_BASE/setup-tdarr.log"
readonly BETTERSTRAP_SMB="$USER_HOME/betterstrap/smb.sh"

# System configuration
readonly AUTOFS_MASTER_DIR="/etc/autofs/auto.master.d"
readonly AUTOFS_MASTER_FILE="$AUTOFS_MASTER_DIR/tdarr.autofs"
readonly AUTOFS_MAP="/etc/auto.tdarr"
readonly SMB_CREDS_FILE="/etc/auto.smb.210"

# SMB Share configuration
declare -A SMB_SHARES=(
    ["hass_share"]="//192.168.1.210/share|auth"
    ["hass_media"]="//192.168.1.210/media|auth"
    ["hass_config"]="//192.168.1.210/config|auth"
    ["usb_share"]="//192.168.1.47/USB-Share|guest"
    ["usb_share_2"]="//192.168.1.47/USB-Share-2|guest"
    ["rom_share"]="//192.168.1.47/ROM-Share|guest"
)

# Default credentials (can be overridden by betterstrap/smb.sh)
SMB_210_USER="me"
SMB_210_PASS="Jbean343343343"

# Script options
START_NOW=false
NO_START=false

# Terminal colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# =============================================================================
# LOGGING AND OUTPUT FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")  color="$GREEN" ;;
        "WARN")  color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        "DEBUG") color="$BLUE" ;;
        "SUCCESS") color="$CYAN" ;;
        *)       color="$NC" ;;
    esac
    
    echo -e "${color}[$timestamp] [$level]${NC} $message" | tee -a "$LOG_FILE" >&2
}

print_header() {
    echo ""
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${MAGENTA}  $*${NC}"
    echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}▶ $*${NC}"
}

# Error handler
error_handler() {
    local line_number=$1
    log "ERROR" "Script failed at line $line_number"
    log "ERROR" "Check $LOG_FILE for details"
    exit 1
}

trap 'error_handler $LINENO' ERR

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

command_exists() {
    command -v "$1" &> /dev/null
}

is_root() {
    [ "$EUID" -eq 0 ]
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -p "$prompt" -r response
    response=${response:-$default}
    
    [[ "$response" =~ ^[Yy]$ ]]
}

# =============================================================================
# DISTRIBUTION DETECTION
# =============================================================================

detect_distribution() {
    print_section "Detecting Linux distribution..."
    
    if [ ! -f /etc/os-release ]; then
        log "ERROR" "Cannot detect distribution: /etc/os-release not found"
        exit 1
    fi
    
    source /etc/os-release
    
    # Detect distribution
    case "$ID" in
        arch|cachyos|endeavouros|garuda)
            DISTRO="arch"
            PKG_MANAGER="pacman"
            ;;
        manjaro)
            DISTRO="arch"
            PKG_MANAGER="pacman"
            ;;
        steamos)
            DISTRO="steamos"
            PKG_MANAGER="pacman"
            ;;
        debian)
            DISTRO="debian"
            PKG_MANAGER="apt"
            ;;
        ubuntu)
            DISTRO="ubuntu"
            PKG_MANAGER="apt"
            ;;
        fedora)
            DISTRO="fedora"
            PKG_MANAGER="dnf"
            ;;
        bazzite*)
            DISTRO="bazzite"
            PKG_MANAGER="rpm-ostree"
            ;;
        *)
            # Check ID_LIKE
            if [[ "$ID_LIKE" == *"arch"* ]]; then
                DISTRO="arch"
                PKG_MANAGER="pacman"
            elif [[ "$ID_LIKE" == *"debian"* ]] || [[ "$ID_LIKE" == *"ubuntu"* ]]; then
                DISTRO="debian"
                PKG_MANAGER="apt"
            elif [[ "$ID_LIKE" == *"fedora"* ]]; then
                # Check if it's OSTree-based
                if command_exists rpm-ostree; then
                    DISTRO="bazzite"
                    PKG_MANAGER="rpm-ostree"
                else
                    DISTRO="fedora"
                    PKG_MANAGER="dnf"
                fi
            else
                log "ERROR" "Unsupported distribution: $ID"
                exit 1
            fi
            ;;
    esac
    
    # Detect OSTree
    if command_exists rpm-ostree && rpm-ostree status &>/dev/null; then
        IS_OSTREE=true
    else
        IS_OSTREE=false
    fi
    
    # Detect SELinux
    if command_exists getenforce && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        IS_SELINUX=true
        SELINUX_CONTEXT=",context=system_u:object_r:container_file_t:s0"
    else
        IS_SELINUX=false
        SELINUX_CONTEXT=""
    fi
    
    # Check for read-only filesystem (SteamOS)
    if [ "$DISTRO" = "steamos" ] && grep -q " / .*\<ro[\,\ ]" /proc/mounts 2>/dev/null; then
        IS_READONLY_FS=true
    else
        IS_READONLY_FS=false
    fi
    
    log "INFO" "Distribution: $DISTRO ($ID $VERSION_ID)"
    log "INFO" "Package Manager: $PKG_MANAGER"
    [ "$IS_OSTREE" = true ] && log "INFO" "OSTree detected"
    [ "$IS_SELINUX" = true ] && log "INFO" "SELinux enforcing detected"
    [ "$IS_READONLY_FS" = true ] && log "WARN" "Read-only filesystem detected"
    
    export DISTRO PKG_MANAGER IS_OSTREE IS_SELINUX SELINUX_CONTEXT IS_READONLY_FS
}

# =============================================================================
# CONTAINER ENGINE DETECTION AND INSTALLATION
# =============================================================================

detect_container_engine() {
    print_section "Detecting container engine..."
    
    # Check if Docker is already installed
    if command_exists docker && docker info &>/dev/null 2>&1; then
        ENGINE="docker"
        log "INFO" "Docker already installed and running"
        
        # Check for compose
        if docker compose version &>/dev/null 2>&1; then
            COMPOSE_CMD="docker compose"
        elif command_exists docker-compose; then
            COMPOSE_CMD="docker-compose"
        else
            log "WARN" "Docker Compose not found, will install"
            COMPOSE_CMD=""
        fi
        
    # Check if Podman is already installed
    elif command_exists podman; then
        ENGINE="podman"
        log "INFO" "Podman already installed"
        
        if command_exists podman-compose; then
            COMPOSE_CMD="podman-compose"
        else
            log "WARN" "podman-compose not found, will install"
            COMPOSE_CMD=""
        fi
    else
        ENGINE=""
        COMPOSE_CMD=""
        log "INFO" "No container engine detected, will install Docker"
    fi
    
    export ENGINE COMPOSE_CMD
}

install_docker_arch() {
    print_section "Installing Docker on Arch Linux..."
    
    if [ "$IS_READONLY_FS" = true ]; then
        log "WARN" "Read-only filesystem detected (SteamOS)"
        if prompt_yes_no "Disable read-only mode to install Docker?" "n"; then
            sudo steamos-readonly disable
            IS_READONLY_FS=false
        else
            log "INFO" "Falling back to Podman installation"
            install_podman_arch
            return
        fi
    fi
    
    sudo pacman -Sy --needed --noconfirm docker docker-compose
    ENGINE="docker"
    
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    else
        COMPOSE_CMD="docker-compose"
    fi
    
    log "SUCCESS" "Docker installed successfully"
}

install_podman_arch() {
    print_section "Installing Podman on Arch Linux..."
    
    sudo pacman -Sy --needed --noconfirm podman podman-compose
    ENGINE="podman"
    COMPOSE_CMD="podman-compose"
    
    log "SUCCESS" "Podman installed successfully"
}

install_docker_debian() {
    print_section "Installing Docker on Debian/Ubuntu..."
    
    # Install prerequisites
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    
    # Add Docker's official GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/$ID/gpg | \
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    
    # Add Docker repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    
    ENGINE="docker"
    COMPOSE_CMD="docker compose"
    
    log "SUCCESS" "Docker installed successfully"
}

install_podman_debian() {
    print_section "Installing Podman on Debian/Ubuntu..."
    
    sudo apt-get update
    sudo apt-get install -y podman
    
    # Try to install podman-compose
    if apt-cache show podman-compose &>/dev/null; then
        sudo apt-get install -y podman-compose
    else
        log "WARN" "podman-compose not available in repos, will install via pip"
        sudo apt-get install -y python3-pip
        sudo pip3 install podman-compose
    fi
    
    ENGINE="podman"
    COMPOSE_CMD="podman-compose"
    
    log "SUCCESS" "Podman installed successfully"
}

install_docker_fedora() {
    print_section "Installing Docker on Fedora..."
    
    if [ "$IS_OSTREE" = true ]; then
        log "WARN" "OSTree system detected, attempting to layer Docker with rpm-ostree"
        sudo rpm-ostree install -y moby-engine docker-compose
        log "WARN" "A reboot is required to apply rpm-ostree changes"
        log "WARN" "After reboot, re-run this script with --no-start, then start manually"
        exit 0
    else
        sudo dnf install -y moby-engine docker-compose-plugin
        ENGINE="docker"
        COMPOSE_CMD="docker compose"
        log "SUCCESS" "Docker installed successfully"
    fi
}

install_podman_fedora() {
    print_section "Installing Podman on Fedora..."
    
    if [ "$IS_OSTREE" = true ]; then
        # Podman is usually pre-installed on Bazzite
        if ! command_exists podman; then
            sudo rpm-ostree install -y podman
            log "WARN" "A reboot is required to apply rpm-ostree changes"
            exit 0
        fi
    else
        sudo dnf install -y podman
    fi
    
    # Install podman-compose
    if dnf list podman-compose &>/dev/null 2>&1; then
        if [ "$IS_OSTREE" = false ]; then
            sudo dnf install -y podman-compose
        else
            log "WARN" "Installing podman-compose via pip for OSTree system"
            pip3 install --user podman-compose
        fi
    else
        pip3 install --user podman-compose
    fi
    
    ENGINE="podman"
    COMPOSE_CMD="podman-compose"
    
    log "SUCCESS" "Podman installed successfully"
}

install_container_engine() {
    if [ -n "$ENGINE" ] && [ -n "$COMPOSE_CMD" ]; then
        log "INFO" "Container engine already configured: $ENGINE with $COMPOSE_CMD"
        return
    fi
    
    # Determine which engine to install
    if [ -z "$ENGINE" ]; then
        # No engine installed, prefer Docker
        case "$DISTRO" in
            arch|steamos)
                install_docker_arch || install_podman_arch
                ;;
            debian|ubuntu)
                install_docker_debian || install_podman_debian
                ;;
            fedora|bazzite)
                if [ "$IS_OSTREE" = true ]; then
                    # For OSTree, prefer Podman (usually pre-installed)
                    if command_exists podman; then
                        install_podman_fedora
                    else
                        install_docker_fedora
                    fi
                else
                    install_docker_fedora || install_podman_fedora
                fi
                ;;
        esac
    elif [ -z "$COMPOSE_CMD" ]; then
        # Engine installed but compose missing
        case "$ENGINE" in
            docker)
                case "$DISTRO" in
                    arch|steamos)
                        sudo pacman -Sy --needed --noconfirm docker-compose
                        ;;
                    debian|ubuntu)
                        sudo apt-get install -y docker-compose-plugin
                        ;;
                    fedora|bazzite)
                        if [ "$IS_OSTREE" = false ]; then
                            sudo dnf install -y docker-compose-plugin
                        fi
                        ;;
                esac
                
                if docker compose version &>/dev/null 2>&1; then
                    COMPOSE_CMD="docker compose"
                else
                    COMPOSE_CMD="docker-compose"
                fi
                ;;
            podman)
                pip3 install --user podman-compose
                COMPOSE_CMD="podman-compose"
                ;;
        esac
    fi
    
    log "INFO" "Container engine: $ENGINE"
    log "INFO" "Compose command: $COMPOSE_CMD"
}

# =============================================================================
# PACKAGE INSTALLATION
# =============================================================================

install_base_packages() {
    print_section "Installing base packages..."
    
    case "$DISTRO" in
        arch|steamos)
            if [ "$IS_READONLY_FS" = true ]; then
                if ! prompt_yes_no "Read-only filesystem. Disable to install packages?" "n"; then
                    log "ERROR" "Cannot proceed without installing packages"
                    exit 1
                fi
                sudo steamos-readonly disable
            fi
            
            # Install cifs-utils from official repos
            sudo pacman -Sy --needed --noconfirm cifs-utils
            
            # Install autofs from AUR if not already installed
            if ! command_exists automount && ! pacman -Q autofs &>/dev/null; then
                log "INFO" "Installing autofs from AUR..."
                if command_exists yay; then
                    yay -S --needed --noconfirm autofs
                elif command_exists paru; then
                    paru -S --needed --noconfirm autofs
                else
                    log "WARN" "No AUR helper found (yay/paru). Please install autofs manually:"
                    log "WARN" "  yay -S autofs   OR   paru -S autofs"
                    log "WARN" "Then re-run this script."
                    exit 1
                fi
            else
                log "INFO" "autofs already installed"
            fi
            ;;
        debian|ubuntu)
            sudo apt-get update
            sudo apt-get install -y autofs cifs-utils
            ;;
        fedora)
            sudo dnf install -y autofs cifs-utils
            ;;
        bazzite)
            if [ "$IS_OSTREE" = true ]; then
                sudo rpm-ostree install -y autofs cifs-utils
                log "WARN" "OSTree layering applied, reboot required"
            else
                sudo dnf install -y autofs cifs-utils
            fi
            ;;
    esac
    
    log "SUCCESS" "Base packages installed"
}

install_lazydocker() {
    print_section "Installing lazydocker..."
    
    if command_exists lazydocker; then
        log "INFO" "lazydocker already installed"
        return
    fi
    
    case "$DISTRO" in
        arch|steamos)
            if sudo pacman -Sy --needed --noconfirm lazydocker 2>/dev/null; then
                log "SUCCESS" "lazydocker installed from repository"
                return
            fi
            ;;
        debian|ubuntu)
            if apt-cache show lazydocker &>/dev/null && \
                sudo apt-get install -y lazydocker 2>/dev/null; then
                log "SUCCESS" "lazydocker installed from repository"
                return
            fi
            ;;
        fedora|bazzite)
            if [ "$IS_OSTREE" = false ] && \
                sudo dnf install -y lazydocker 2>/dev/null; then
                log "SUCCESS" "lazydocker installed from repository"
                return
            fi
            ;;
    esac
    
    # Fallback: install from upstream
    log "INFO" "Installing lazydocker from upstream..."
    curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | \
        sudo bash
    
    if command_exists lazydocker; then
        log "SUCCESS" "lazydocker installed from upstream"
    else
        log "WARN" "Failed to install lazydocker, skipping"
    fi
}

# =============================================================================
# SERVICE CONFIGURATION
# =============================================================================

enable_services() {
    print_section "Enabling services..."
    
    # Enable autofs
    sudo systemctl enable --now autofs
    log "INFO" "autofs service enabled and started"
    
    # Enable Docker if using Docker
    if [ "$ENGINE" = "docker" ]; then
        sudo systemctl enable --now docker
        log "INFO" "Docker service enabled and started"
        
        # Add user to docker group
        if ! groups "$USER" | grep -q '\<docker\>'; then
            sudo usermod -aG docker "$USER"
            log "WARN" "Added $USER to docker group - re-login required for rootless access"
            log "INFO" "Attempting to apply group change in current session..."
            # Try to apply group change
            if ! newgrp docker &>/dev/null; then
                log "WARN" "Could not apply group change in current session"
            fi
        fi
    fi
    
    # Enable Podman socket if using Podman
    if [ "$ENGINE" = "podman" ]; then
        if systemctl --user list-unit-files | grep -q podman.socket; then
            systemctl --user enable --now podman.socket 2>/dev/null || true
            log "INFO" "Podman socket enabled"
        fi
    fi
}

# =============================================================================
# CREDENTIAL MANAGEMENT
# =============================================================================

setup_smb_credentials() {
    print_section "Setting up SMB credentials..."
    
    # Check if betterstrap smb.sh exists and can provide credentials
    if [ -f "$BETTERSTRAP_SMB" ]; then
        log "INFO" "Found betterstrap/smb.sh, checking for credentials..."
        # Try to extract credentials from smb.sh
        if grep -q "username=me" "$BETTERSTRAP_SMB"; then
            local extracted_user=$(grep -oP '(?<=username=)[^,]+' "$BETTERSTRAP_SMB" | head -1)
            local extracted_pass=$(grep -oP '(?<=password=)[^,]+' "$BETTERSTRAP_SMB" | head -1)
            
            if [ -n "$extracted_user" ] && [ -n "$extracted_pass" ]; then
                SMB_210_USER="$extracted_user"
                SMB_210_PASS="$extracted_pass"
                log "INFO" "Using credentials from betterstrap/smb.sh"
            fi
        fi
    fi
    
    # Create credentials file
    sudo tee "$SMB_CREDS_FILE" > /dev/null << EOF
username=$SMB_210_USER
password=$SMB_210_PASS
EOF
    
    sudo chown root:root "$SMB_CREDS_FILE"
    sudo chmod 600 "$SMB_CREDS_FILE"
    
    log "SUCCESS" "SMB credentials configured at $SMB_CREDS_FILE"
}

# =============================================================================
# DIRECTORY SETUP
# =============================================================================

setup_directories() {
    print_section "Setting up directories..."
    
    # Create mount directories
    mkdir -p "$TDARR_MOUNTS"/{hass_share,hass_media,hass_config,usb_share,usb_share_2,rom_share}
    log "INFO" "Created mount directories in $TDARR_MOUNTS"
    
    # Create Tdarr config directory
    mkdir -p "$TDARR_CONFIGS"
    log "INFO" "Created Tdarr config directory at $TDARR_CONFIGS"
    
    # Create WUD data directory
    mkdir -p "$TDARR_BASE/wud"
    log "INFO" "Created WUD data directory at $TDARR_BASE/wud"
    
    # Ensure ownership
    chown -R "$USER":"$USER" "$TDARR_BASE" "$TDARR_CONFIGS" 2>/dev/null || true
    
    log "SUCCESS" "Directory structure created"
}

# =============================================================================
# AUTOFS CONFIGURATION
# =============================================================================

configure_autofs() {
    print_section "Configuring autofs for SMB shares..."
    
    # Create auto.master.d directory if it doesn't exist
    sudo mkdir -p "$AUTOFS_MASTER_DIR"
    
    # Create master file
    sudo tee "$AUTOFS_MASTER_FILE" > /dev/null << EOF
# Tdarr autofs configuration
# Mount SMB shares to ~/tdarr/mounts
$TDARR_MOUNTS /etc/auto.tdarr --timeout=120,--ghost
EOF
    
    log "INFO" "Created autofs master file at $AUTOFS_MASTER_FILE"
    
    # Create autofs map file
    sudo tee "$AUTOFS_MAP" > /dev/null << 'EOFMAP'
# Tdarr SMB shares autofs map
# Format: <mount_name> <options> :<server>/<share>

# 192.168.1.210 shares (authenticated)
hass_share  -fstype=cifs,vers=3.1.1,credentials=/etc/auto.smb.210,uid=1000,gid=1000,iocharset=utf8,soft,actimeo=1SELINUX_CONTEXT ://192.168.1.210/share
hass_media  -fstype=cifs,vers=3.1.1,credentials=/etc/auto.smb.210,uid=1000,gid=1000,iocharset=utf8,soft,actimeo=1SELINUX_CONTEXT ://192.168.1.210/media
hass_config -fstype=cifs,vers=3.1.1,credentials=/etc/auto.smb.210,uid=1000,gid=1000,iocharset=utf8,soft,actimeo=1SELINUX_CONTEXT ://192.168.1.210/config

# 192.168.1.47 shares (guest access)
usb_share   -fstype=cifs,vers=3.1.1,guest,uid=1000,gid=1000,iocharset=utf8,soft,actimeo=1SELINUX_CONTEXT ://192.168.1.47/USB-Share
usb_share_2 -fstype=cifs,vers=3.1.1,guest,uid=1000,gid=1000,iocharset=utf8,soft,actimeo=1SELINUX_CONTEXT ://192.168.1.47/USB-Share-2
rom_share   -fstype=cifs,vers=3.1.1,guest,uid=1000,gid=1000,iocharset=utf8,soft,actimeo=1SELINUX_CONTEXT ://192.168.1.47/ROM-Share
EOFMAP
    
    # Replace SELINUX_CONTEXT placeholder
    if [ "$IS_SELINUX" = true ]; then
        sudo sed -i "s/SELINUX_CONTEXT/$SELINUX_CONTEXT/g" "$AUTOFS_MAP"
        log "INFO" "Added SELinux context for container access"
    else
        sudo sed -i "s/SELINUX_CONTEXT//g" "$AUTOFS_MAP"
    fi
    
    log "INFO" "Created autofs map at $AUTOFS_MAP"
    
    # Restart autofs to apply changes
    sudo systemctl restart autofs
    sleep 2
    
    log "SUCCESS" "Autofs configured and restarted"
}

# =============================================================================
# MOUNT VALIDATION
# =============================================================================

validate_mounts() {
    print_section "Validating SMB mounts..."
    
    local failed_mounts=()
    local successful_mounts=()
    
    for share_name in "${!SMB_SHARES[@]}"; do
        local mount_path="$TDARR_MOUNTS/$share_name"
        
        log "INFO" "Testing mount: $share_name"
        
        # Trigger autofs mount by accessing the directory
        if timeout 10 ls -la "$mount_path" &>/dev/null; then
            # Check if actually mounted
            if mountpoint -q "$mount_path" 2>/dev/null; then
                successful_mounts+=("$share_name")
                log "SUCCESS" "✓ $share_name mounted successfully"
            else
                failed_mounts+=("$share_name")
                log "WARN" "✗ $share_name directory accessible but not mounted"
            fi
        else
            failed_mounts+=("$share_name")
            log "WARN" "✗ $share_name failed to mount"
        fi
    done
    
    # Summary
    echo ""
    log "INFO" "Mount validation complete:"
    log "INFO" "  Successful: ${#successful_mounts[@]}"
    log "INFO" "  Failed: ${#failed_mounts[@]}"
    
    if [ ${#failed_mounts[@]} -gt 0 ]; then
        log "WARN" "Failed mounts: ${failed_mounts[*]}"
        log "WARN" "Check network connectivity and SMB server availability"
        log "WARN" "You can continue, but Tdarr may not have access to all shares"
        
        if [ ${#successful_mounts[@]} -eq 0 ]; then
            log "ERROR" "No mounts succeeded. Cannot continue."
            
            if prompt_yes_no "Roll back autofs configuration?" "y"; then
                sudo rm -f "$AUTOFS_MASTER_FILE" "$AUTOFS_MAP"
                sudo systemctl restart autofs
                log "INFO" "Autofs configuration rolled back"
            fi
            exit 1
        fi
    else
        log "SUCCESS" "All mounts validated successfully!"
    fi
    
    # Ensure trans directory exists in hass_share
    if [[ " ${successful_mounts[*]} " =~ " hass_share " ]]; then
        mkdir -p "$TDARR_MOUNTS/hass_share/trans" 2>/dev/null || true
        log "INFO" "Ensured trans directory exists in hass_share"
    fi
}

# =============================================================================
# DOCKER COMPOSE GENERATION
# =============================================================================

generate_compose_file() {
    print_section "Generating Docker Compose file..."
    
    cat > "$COMPOSE_FILE" << EOF
version: '3.8'

services:
  tdarr-node:
    image: $TDARR_IMAGE
    container_name: tdarr-node
    network_mode: host
    restart: unless-stopped
    environment:
      - serverIP=$SERVER_IP
      - serverPort=$SERVER_PORT
      - nodeName=$NODE_NAME
      - PUID=$PUID
      - PGID=$PGID
    volumes:
      # Media files - mounted as /share to match server paths
      - $TDARR_MOUNTS/hass_share:/share:rw
      # Transcode temp directory - on shared storage so server can access
      - $TDARR_MOUNTS/hass_share/trans:/tmp:rw
      # Node configuration
      - $TDARR_CONFIGS:/app/configs:rw
    labels:
      - "wud.tag.include=^\\\\d+\\\\.\\\\d+\\\\.\\\\d+$"
      - "wud.watch=true"

  wud:
    image: fmartinou/whats-up-docker:latest
    container_name: wud
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - WUD_LOG_LEVEL=info
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - $TDARR_BASE/wud:/store
EOF
    
    log "SUCCESS" "Docker Compose file created at $COMPOSE_FILE"
    log "INFO" "Node name: $NODE_NAME"
    log "INFO" "Server: $SERVER_IP:$SERVER_PORT"
}

# =============================================================================
# LAZYDOCKER WRAPPER
# =============================================================================

create_lazydocker_wrapper() {
    print_section "Creating lazydocker wrapper..."
    
    cat > "$LAZYDOCKER_WRAPPER" << EOF
#!/bin/bash
# Lazydocker wrapper for Tdarr management

export COMPOSE_FILE="$COMPOSE_FILE"

if ! command -v lazydocker &> /dev/null; then
    echo "Error: lazydocker is not installed"
    echo "Install with: curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash"
    exit 1
fi

exec lazydocker
EOF
    
    chmod +x "$LAZYDOCKER_WRAPPER"
    log "SUCCESS" "Lazydocker wrapper created at $LAZYDOCKER_WRAPPER"
}

# =============================================================================
# CONTAINER STARTUP
# =============================================================================

start_tdarr_container() {
    print_section "Starting Tdarr container..."
    
    # Ensure mounts are accessible
    timeout 5 ls "$TDARR_MOUNTS/hass_share" &>/dev/null || {
        log "WARN" "hass_share not accessible, attempting to trigger mount..."
        sleep 3
    }
    
    # Pull image
    log "INFO" "Pulling Tdarr image: $TDARR_IMAGE"
    if [ "$ENGINE" = "docker" ]; then
        docker pull "$TDARR_IMAGE"
    else
        podman pull "$TDARR_IMAGE"
    fi
    
    # Start with compose
    log "INFO" "Starting Tdarr with: $COMPOSE_CMD"
    cd "$TDARR_BASE"
    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d
    
    # Wait for container to start
    sleep 5
    
    # Check status
    if [ "$ENGINE" = "docker" ]; then
        if docker ps --format '{{.Names}}' | grep -q "^tdarr-node$"; then
            log "SUCCESS" "Tdarr container started successfully!"
        else
            log "ERROR" "Tdarr container failed to start"
            docker logs tdarr-node --tail 20
            exit 1
        fi
    else
        if podman ps --format '{{.Names}}' | grep -q "^tdarr-node$"; then
            log "SUCCESS" "Tdarr container started successfully!"
        else
            log "ERROR" "Tdarr container failed to start"
            podman logs tdarr-node --tail 20
            exit 1
        fi
    fi
}

# =============================================================================
# SUMMARY AND DOCUMENTATION
# =============================================================================

print_summary() {
    print_header "SETUP COMPLETE!"
    
    echo -e "${GREEN}✓${NC} Distribution: ${CYAN}$DISTRO${NC}"
    echo -e "${GREEN}✓${NC} Container Engine: ${CYAN}$ENGINE${NC}"
    echo -e "${GREEN}✓${NC} Compose Command: ${CYAN}$COMPOSE_CMD${NC}"
    [ "$IS_SELINUX" = true ] && echo -e "${YELLOW}⚠${NC} SELinux: ${CYAN}Enforcing${NC}"
    [ "$IS_OSTREE" = true ] && echo -e "${YELLOW}⚠${NC} OSTree: ${CYAN}Detected${NC}"
    echo ""
    
    echo -e "${CYAN}📁 Paths Created:${NC}"
    echo -e "   Mounts:       ${YELLOW}$TDARR_MOUNTS${NC}"
    echo -e "   Configs:      ${YELLOW}$TDARR_CONFIGS${NC}"
    echo -e "   Compose File: ${YELLOW}$COMPOSE_FILE${NC}"
    echo -e "   Lazy Wrapper: ${YELLOW}$LAZYDOCKER_WRAPPER${NC}"
    echo -e "   Log File:     ${YELLOW}$LOG_FILE${NC}"
    echo ""
    
    echo -e "${CYAN}🔧 Container Management:${NC}"
    echo -e "   Start:   ${YELLOW}$COMPOSE_CMD -f $COMPOSE_FILE up -d${NC}"
    echo -e "   Stop:    ${YELLOW}$COMPOSE_CMD -f $COMPOSE_FILE down${NC}"
    echo -e "   Logs:    ${YELLOW}$COMPOSE_CMD -f $COMPOSE_FILE logs -f${NC}"
    echo -e "   Restart: ${YELLOW}$COMPOSE_CMD -f $COMPOSE_FILE restart${NC}"
    echo ""
    
    if command_exists lazydocker; then
        echo -e "${CYAN}🐳 Lazydocker (TUI Management):${NC}"
        echo -e "   ${YELLOW}$LAZYDOCKER_WRAPPER${NC}"
        echo -e "   or: ${YELLOW}cd $TDARR_BASE && lazydocker${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}📊 Tdarr Configuration:${NC}"
    echo -e "   Server:    ${YELLOW}$SERVER_IP:$SERVER_PORT${NC}"
    echo -e "   Node Name: ${YELLOW}$NODE_NAME${NC}"
    echo -e "   Share:     ${YELLOW}/share${NC} (inside container)"
    echo -e "              ↳ ${YELLOW}$TDARR_MOUNTS/hass_share${NC} (host)"
    echo ""
    
    if ! groups "$USER" | grep -q '\<docker\>' && [ "$ENGINE" = "docker" ]; then
        echo -e "${YELLOW}⚠ IMPORTANT:${NC} You were added to the docker group."
        echo -e "  You need to ${RED}log out and log back in${NC} for this to take effect."
        echo -e "  Or run: ${YELLOW}newgrp docker${NC}"
        echo ""
    fi
    
    echo -e "${CYAN}🔔 What's Up Docker (WUD) - Update Monitor:${NC}"
    echo -e "   Web UI:    ${YELLOW}http://localhost:3000${NC}"
    echo -e "   Purpose:   Monitor Tdarr container for image updates"
    echo ""
    
    echo -e "${CYAN}🌐 Next Steps:${NC}"
    echo -e "   1. Check that Tdarr node appears in server UI:"
    echo -e "      ${YELLOW}http://$SERVER_IP:8265${NC}"
    echo -e "   2. Look for node: ${YELLOW}$NODE_NAME${NC}"
    echo -e "   3. Verify mounts: ${YELLOW}ls $TDARR_MOUNTS/hass_share${NC}"
    echo -e "   4. Monitor updates at: ${YELLOW}http://localhost:3000${NC}"
    echo ""
    
    log "SUCCESS" "Setup completed successfully!"
}

# =============================================================================
# COMMAND LINE ARGUMENT PARSING
# =============================================================================

show_help() {
    cat << EOF
Tdarr Setup Script - Multi-distribution Tdarr node installer

USAGE:
    $0 [OPTIONS]

OPTIONS:
    --up, --start-now       Start Tdarr container immediately after setup
    --no-start              Complete setup but don't start the container
    --help, -h              Show this help message

DESCRIPTION:
    This script sets up a Tdarr transcoding node with:
    - Docker or Podman container runtime
    - Autofs-based SMB share mounting
    - Lazydocker for easy management
    - Support for Arch, Debian, Ubuntu, Fedora, SteamOS, and Bazzite

EXAMPLES:
    $0                      # Interactive setup with prompt to start
    $0 --start-now          # Setup and start immediately
    $0 --no-start           # Setup only, don't start container

EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --up|--start-now)
                START_NOW=true
                shift
                ;;
            --no-start)
                NO_START=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                echo "Unknown option: $1"
                show_help
                ;;
        esac
    done
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    parse_args "$@"
    
    # Initialize log file
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Tdarr Setup Log ===" > "$LOG_FILE"
    echo "Started: $(date)" >> "$LOG_FILE"
    
    print_header "Tdarr Setup Script"
    log "INFO" "Starting Tdarr setup..."
    
    # Check if running as root (should not be)
    if is_root; then
        log "ERROR" "This script should not be run as root"
        log "ERROR" "Run as a normal user - sudo will be used when needed"
        exit 1
    fi
    
    # Detection phase
    detect_distribution
    detect_container_engine
    
    # Installation phase
    install_base_packages
    install_container_engine
    install_lazydocker
    
    # Configuration phase
    enable_services
    setup_smb_credentials
    setup_directories
    configure_autofs
    
    # Validation phase
    validate_mounts
    
    # Generation phase
    generate_compose_file
    create_lazydocker_wrapper
    
    # Startup phase
    if [ "$NO_START" = true ]; then
        log "INFO" "Skipping container startup (--no-start specified)"
    elif [ "$START_NOW" = true ]; then
        start_tdarr_container
    else
        echo ""
        if prompt_yes_no "Start Tdarr container now?" "y"; then
            start_tdarr_container
        else
            log "INFO" "Container not started. Start manually with:"
            log "INFO" "  $COMPOSE_CMD -f $COMPOSE_FILE up -d"
        fi
    fi
    
    # Summary
    print_summary
    
    echo "Completed: $(date)" >> "$LOG_FILE"
}

# Run main function
main "$@"
