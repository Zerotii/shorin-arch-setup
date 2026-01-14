#!/bin/bash

# Test script to verify application download links without actual installation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# Color definitions
NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'

# Log functions
log() {
    echo -e "   ${BLUE}>>>${NC} $1"
}

success() {
    echo -e "   ${GREEN}✓${NC} $1"
}

error() {
    echo -e "   ${RED}✗${NC} $1"
}

warn() {
    echo -e "   ${YELLOW}⚠${NC} $1"
}

info() {
    echo -e "   ${CYAN}i${NC} $1"
}

# Test official repo packages
test_repo_packages() {
    log "Testing official repository packages..."
    local repo_apps=("$@")
    
    for app in "${repo_apps[@]}"; do
        log "Checking $app..."
        if pacman -Si "$app" >/dev/null 2>&1; then
            success "$app: Found in official repository"
        else
            error "$app: Not found in official repository"
        fi
    done
}

# Test AUR packages
test_aur_packages() {
    log "Testing AUR packages..."
    local aur_apps=("$@")
    
    for app in "${aur_apps[@]}"; do
        log "Checking $app..."
        if curl -sf "https://aur.archlinux.org/packages/$app" >/dev/null 2>&1; then
            success "$app: Found in AUR"
        else
            error "$app: Not found in AUR"
        fi
    done
}

# Test Flatpak packages
test_flatpak_packages() {
    log "Testing Flatpak packages..."
    local flatpak_apps=("$@")
    
    for app in "${flatpak_apps[@]}"; do
        log "Checking $app..."
        if curl -sf "https://flathub.org/api/v1/apps/$app" >/dev/null 2>&1; then
            success "$app: Found in Flathub"
        else
            error "$app: Not found in Flathub"
        fi
    done
}

# Main function
main() {
    echo -e "\n${WHITE}=== Testing Application Download Links ===${NC}"
    
    # Read apps from common-applist.txt
    LIST_FILE="$PARENT_DIR/common-applist.txt"
    
    if [ ! -f "$LIST_FILE" ]; then
        error "common-applist.txt not found!"
        exit 1
    fi
    
    local repo_apps=()
    local aur_apps=()
    local flatpak_apps=()
    
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^\s*#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # Extract package name
        raw_pkg=$(echo "$line" | cut -d'#' -f1 | xargs)
        [[ -z "$raw_pkg" ]] && continue
        
        if [[ "$raw_pkg" == flatpak:* ]]; then
            clean_name="${raw_pkg#flatpak:}"
            flatpak_apps+=("$clean_name")
        elif [[ "$raw_pkg" == AUR:* ]]; then
            clean_name="${raw_pkg#AUR:}"
            aur_apps+=("$clean_name")
        else
            repo_apps+=("$raw_pkg")
        fi
    done < "$LIST_FILE"
    
    # Test each category
    if [ ${#repo_apps[@]} -gt 0 ]; then
        echo -e "\n${PURPLE}--- Official Repository Packages ---${NC}"
        test_repo_packages "${repo_apps[@]}"
    fi
    
    if [ ${#aur_apps[@]} -gt 0 ]; then
        echo -e "\n${PURPLE}--- AUR Packages ---${NC}"
        test_aur_packages "${aur_apps[@]}"
    fi
    
    if [ ${#flatpak_apps[@]} -gt 0 ]; then
        echo -e "\n${PURPLE}--- Flatpak Packages ---${NC}"
        test_flatpak_packages "${flatpak_apps[@]}"
    fi
    
    echo -e "\n${WHITE}=== Test Complete ===${NC}"
}

# Run main
main
