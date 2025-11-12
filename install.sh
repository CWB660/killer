#!/bin/bash

################################################################################
# Killer.sh Installation Script
# 
# This script installs killer.sh to make it globally available on your system.
# It supports both local and remote installation:
#   - Local: ./install.sh
#   - Remote: curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/ufn-killer/main/install.sh | bash
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# GitHub repository information
GITHUB_USER="${GITHUB_USER:-YOUR_USERNAME}"
GITHUB_REPO="${GITHUB_REPO:-ufn-killer}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
GITHUB_RAW_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# Get script directory (empty if piped from curl)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# Installation directories
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BIN_DIR="${INSTALL_PREFIX}/bin"
LIB_DIR="${INSTALL_PREFIX}/lib/killer"

# Temporary directory for downloads
TMP_DIR=""

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT

check_dependencies() {
    local missing_deps=()
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v tar &> /dev/null; then
        missing_deps+=("tar")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install them first"
        exit 1
    fi
}

check_permissions() {
    if [ ! -w "$INSTALL_PREFIX" ]; then
        log_error "Cannot write to $INSTALL_PREFIX"
        log_info "Please run with sudo: curl -fsSL ... | sudo bash"
        log_info "Or install to user directory: curl -fsSL ... | INSTALL_PREFIX=~/.local bash"
        exit 1
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    local description="${3:-file}"
    
    log_info "Downloading $description..."
    if ! curl -fsSL "$url" -o "$output"; then
        log_error "Failed to download $description from $url"
        return 1
    fi
    return 0
}

download_repository() {
    log_info "Downloading killer.sh from GitHub..."
    
    # Create temporary directory
    TMP_DIR=$(mktemp -d)
    log_info "Using temporary directory: $TMP_DIR"
    
    # Download the repository archive
    local archive_url="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"
    local archive_file="$TMP_DIR/repo.tar.gz"
    
    if ! download_file "$archive_url" "$archive_file" "repository archive"; then
        log_error "Failed to download repository"
        log_info "Please check:"
        log_info "  1. Repository URL: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
        log_info "  2. Branch name: ${GITHUB_BRANCH}"
        log_info "  3. Repository is public"
        exit 1
    fi
    
    # Extract the archive
    log_info "Extracting files..."
    if ! tar -xzf "$archive_file" -C "$TMP_DIR"; then
        log_error "Failed to extract archive"
        exit 1
    fi
    
    # Find the extracted directory (GitHub archives create a folder with repo-branch name)
    local extracted_dir="$TMP_DIR/${GITHUB_REPO}-${GITHUB_BRANCH}"
    if [ ! -d "$extracted_dir" ]; then
        log_error "Extracted directory not found: $extracted_dir"
        exit 1
    fi
    
    # Set SCRIPT_DIR to the extracted directory
    SCRIPT_DIR="$extracted_dir"
    log_success "Repository downloaded successfully"
}

setup_config() {
    # Determine the actual user (not root if using sudo)
    local actual_user="${SUDO_USER:-$USER}"
    local actual_home
    
    if [ -n "$SUDO_USER" ]; then
        actual_home=$(eval echo ~$SUDO_USER)
    else
        actual_home="$HOME"
    fi
    
    local env_file="$actual_home/.killer.env"
    
    log_info "Setting up killer.sh configuration..."
    echo ""
    
    # Check if already configured
    if [ -f "$env_file" ]; then
        log_info "Configuration file already exists: $env_file"
        read -p "Would you like to reconfigure? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Skipping configuration"
            return
        fi
    fi
    
    # Ask for API key
    echo -e "${YELLOW}Enter your GLM Coding API key:${NC}"
    read -r api_key
    if [ -z "$api_key" ]; then
        log_warn "No API key provided. You can configure it later by running: killer setup"
        return
    fi
    
    # Ask for model (with default)
    echo ""
    echo -e "${YELLOW}Enter default model (press Enter for 'glm-4.6'):${NC}"
    read -r model
    model="${model:-glm-4.6}"
    
    # Ask for API base URL (with default)
    echo ""
    echo -e "${YELLOW}Enter API base URL (press Enter for 'https://open.bigmodel.cn/api/coding/paas/v4'):${NC}"
    read -r api_base
    api_base="${api_base:-https://open.bigmodel.cn/api/coding/paas/v4}"
    
    # Ask for max iterations (with default)
    echo ""
    echo -e "${YELLOW}Enter maximum iterations (press Enter for '25'):${NC}"
    read -r max_iterations
    max_iterations="${max_iterations:-25}"
    
    # Save to .env file
    echo ""
    log_info "Saving configuration to $env_file..."
    cat > "$env_file" << EOF
# Killer.sh Configuration
# Generated on $(date)

# GLM Coding API Configuration
GLM_CODING_API_KEY=$api_key
GLM_CODING_MODEL=$model
GLM_CODING_API_BASE=$api_base
MAX_ITERATIONS=$max_iterations
EOF
    
    # Create user data directory
    local data_dir="$actual_home/.killer"
    if [ ! -d "$data_dir" ]; then
        mkdir -p "$data_dir/tmp"
        if [ -n "$SUDO_USER" ]; then
            chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$data_dir"
        fi
    fi
    
    # Set proper ownership if running as sudo
    if [ -n "$SUDO_USER" ]; then
        chown "$SUDO_USER:$(id -gn $SUDO_USER)" "$env_file"
    fi
    
    chmod 600 "$env_file"  # Secure the file
    log_success "Configuration saved!"
    log_info "Config file: $env_file"
    echo ""
}

install_killer() {
    log_info "Installing killer.sh..."
    
    # Verify required files exist
    if [ ! -f "$SCRIPT_DIR/killer.sh" ]; then
        log_error "killer.sh not found in $SCRIPT_DIR"
        exit 1
    fi
    
    # Create directories
    log_info "Creating directories..."
    mkdir -p "$BIN_DIR"
    mkdir -p "$LIB_DIR"
    
    # Copy files
    log_info "Copying files..."
    cp "$SCRIPT_DIR/killer.sh" "$LIB_DIR/killer.sh"
    chmod +x "$LIB_DIR/killer.sh"
    
    # Copy prompts and tools (remove old directories first to ensure clean install)
    if [ -d "$SCRIPT_DIR/prompts" ]; then
        # Remove old prompts directory if exists
        if [ -d "$LIB_DIR/prompts" ]; then
            log_info "Removing old prompts directory..."
            rm -rf "$LIB_DIR/prompts"
        fi
        log_info "Copying prompts..."
        cp -r "$SCRIPT_DIR/prompts" "$LIB_DIR/"
    fi
    
    if [ -d "$SCRIPT_DIR/tools" ]; then
        # Remove old tools directory if exists
        if [ -d "$LIB_DIR/tools" ]; then
            log_info "Removing old tools directory..."
            rm -rf "$LIB_DIR/tools"
        fi
        log_info "Copying tools..."
        cp -r "$SCRIPT_DIR/tools" "$LIB_DIR/"
        # Make sure all setup.sh scripts are executable
        find "$LIB_DIR/tools" -name "setup.sh" -exec chmod +x {} \;
    fi
    
    # Create wrapper script in bin directory
    log_info "Creating wrapper script..."
    cat > "$BIN_DIR/killer" << 'EOF'
#!/bin/bash

# Killer.sh wrapper script
# This script sets the correct paths and executes killer.sh

# Determine installation directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KILLER_LIB_DIR="$(dirname "$SCRIPT_DIR")/lib/killer"

# Export environment variables for killer.sh to find its resources
export KILLER_INSTALL_DIR="$KILLER_LIB_DIR"

# Execute the actual killer.sh script
exec "$KILLER_LIB_DIR/killer.sh" "$@"
EOF
    
    chmod +x "$BIN_DIR/killer"
    
    log_success "Installation completed!"
    echo ""
    log_info "killer.sh is now available as 'killer' command"
    log_info "Installation location: $LIB_DIR"
    log_info "Executable location: $BIN_DIR/killer"
    echo ""
    
    # Check if bin directory is in PATH
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        log_warn "$BIN_DIR is not in your PATH"
        echo ""
        log_info "Add it to your PATH by adding this line to your shell rc file:"
        log_info "  export PATH=\"$BIN_DIR:\$PATH\""
        echo ""
        
        # Detect shell and provide specific instructions
        if [ -n "$BASH_VERSION" ]; then
            log_info "For bash, add to ~/.bashrc or ~/.bash_profile:"
        elif [ -n "$ZSH_VERSION" ]; then
            log_info "For zsh, add to ~/.zshrc:"
        else
            log_info "Add to your shell configuration file:"
        fi
        echo "  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc"
        echo "  source ~/.bashrc"
        echo ""
    else
        log_info "Try it out: killer --help"
    fi
}

main() {
    echo "=================================="
    echo "  Killer.sh Installation"
    echo "=================================="
    echo ""
    
    log_info "Installation prefix: $INSTALL_PREFIX"
    log_info "Binary directory: $BIN_DIR"
    log_info "Library directory: $LIB_DIR"
    echo ""
    
    # Check dependencies
    check_dependencies
    
    # Check if we have write permissions
    check_permissions
    
    # Check if already installed
    if [ -f "$BIN_DIR/killer" ]; then
        log_warn "killer is already installed at $BIN_DIR/killer"
        echo ""
        read -p "Do you want to reinstall? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
        log_info "Removing old installation..."
        rm -rf "$LIB_DIR"
        rm -f "$BIN_DIR/killer"
    fi
    
    # Download repository if running remotely (SCRIPT_DIR is empty or doesn't contain killer.sh)
    if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/killer.sh" ]; then
        log_info "Remote installation detected"
        download_repository
    else
        log_info "Local installation detected"
    fi
    
    # Install
    install_killer
    
    # Setup configuration
    echo ""
    if [ -t 0 ]; then
        # Only prompt if running interactively
        read -p "Would you like to configure killer.sh now? [Y/n] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            setup_config
        else
            log_info "You can configure killer.sh later by running: killer setup"
        fi
    else
        log_info "Non-interactive mode detected. Skipping configuration."
        log_info "You can configure killer.sh later by running: killer setup"
    fi
    
    echo ""
    log_success "Installation complete!"
}

main "$@"

