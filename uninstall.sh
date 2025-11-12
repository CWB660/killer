#!/bin/bash

################################################################################
# Killer.sh Uninstallation Script
# 
# This script removes killer.sh from your system.
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Installation directories
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BIN_DIR="${INSTALL_PREFIX}/bin"
LIB_DIR="${INSTALL_PREFIX}/lib/killer"

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

check_permissions() {
    if [ ! -w "$INSTALL_PREFIX" ]; then
        log_error "Cannot write to $INSTALL_PREFIX"
        log_info "Please run with sudo: sudo ./uninstall.sh"
        log_info "Or if installed to user directory: INSTALL_PREFIX=~/.local ./uninstall.sh"
        exit 1
    fi
}

clean_user_data() {
    # Determine the actual user (not root if using sudo)
    local actual_user="${SUDO_USER:-$USER}"
    local actual_home
    
    if [ -n "$SUDO_USER" ]; then
        actual_home=$(eval echo ~$SUDO_USER)
    else
        actual_home="$HOME"
    fi
    
    local has_data=false
    
    echo ""
    log_info "Checking user data for: $actual_user"
    
    # Check for config file
    if [ -f "$actual_home/.killer.env" ]; then
        has_data=true
        log_info "Found configuration file: $actual_home/.killer.env"
    fi
    
    # Check for temp directory
    if [ -d "$actual_home/.killer" ]; then
        has_data=true
        log_info "Found user data directory: $actual_home/.killer"
    fi
    
    if [ "$has_data" = true ]; then
        echo ""
        read -p "Do you want to remove user configuration and data? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if [ -f "$actual_home/.killer.env" ]; then
                log_info "Removing configuration: $actual_home/.killer.env"
                rm -f "$actual_home/.killer.env"
            fi
            if [ -d "$actual_home/.killer" ]; then
                log_info "Removing user data: $actual_home/.killer"
                rm -rf "$actual_home/.killer"
            fi
            log_success "User data removed"
        else
            log_info "User data preserved"
        fi
    fi
}

uninstall_killer() {
    local found=false
    
    # Remove library directory
    if [ -d "$LIB_DIR" ]; then
        log_info "Removing library directory: $LIB_DIR"
        rm -rf "$LIB_DIR"
        found=true
    fi
    
    # Remove executable
    if [ -f "$BIN_DIR/killer" ]; then
        log_info "Removing executable: $BIN_DIR/killer"
        rm -f "$BIN_DIR/killer"
        found=true
    fi
    
    if [ "$found" = true ]; then
        log_success "killer.sh has been uninstalled successfully!"
        
        # Ask about user data
        clean_user_data
    else
        log_warn "killer.sh installation not found at $INSTALL_PREFIX"
        echo ""
        log_info "If you installed to a custom location, specify it:"
        log_info "  INSTALL_PREFIX=~/.local ./uninstall.sh"
    fi
}

main() {
    echo "=================================="
    echo "  Killer.sh Uninstallation"
    echo "=================================="
    echo ""
    
    log_info "Installation prefix: $INSTALL_PREFIX"
    log_info "Binary directory: $BIN_DIR"
    log_info "Library directory: $LIB_DIR"
    echo ""
    
    # Check if installed
    if [ ! -f "$BIN_DIR/killer" ] && [ ! -d "$LIB_DIR" ]; then
        log_warn "killer.sh is not installed at $INSTALL_PREFIX"
        exit 0
    fi
    
    # Confirm uninstallation
    read -p "Are you sure you want to uninstall killer.sh? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Uninstallation cancelled"
        exit 0
    fi
    
    # Check permissions
    check_permissions
    
    # Uninstall
    uninstall_killer
}

main "$@"

