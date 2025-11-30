#!/bin/bash

# ==============================================================================
# 05-apps.sh - Common Applications Installation (Yay & Flatpak)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

check_root

log ">>> Starting Phase 5: Common Applications Setup"

# ------------------------------------------------------------------------------
# 0. Identify Target User
# ------------------------------------------------------------------------------
log "Step 0/4: Identify User"

DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)

if [ -n "$DETECTED_USER" ]; then
    TARGET_USER="$DETECTED_USER"
    log "-> Automatically detected target user: $TARGET_USER"
else
    read -p "Please enter the target username: " TARGET_USER
fi

HOME_DIR="/home/$TARGET_USER"

# ------------------------------------------------------------------------------
# 1. User Confirmation
# ------------------------------------------------------------------------------
echo -e "${YELLOW}------------------------------------------------------------${NC}"
echo -e "This script will install applications from ${BLUE}common-applist.txt${NC}."
echo -e "Format: lines starting with 'flatpak:' use Flatpak, others use Yay."
echo -e "${YELLOW}------------------------------------------------------------${NC}"
read -p "Do you want to install common applications? [Y/n] " choice
choice=${choice:-Y}

if [[ ! "$choice" =~ ^[Yy]$ ]]; then
    log "Skipping application installation."
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Parse App List
# ------------------------------------------------------------------------------
log "Step 2/4: Parsing common-applist.txt..."

LIST_FILE="$PARENT_DIR/common-applist.txt"
YAY_APPS=()
FLATPAK_APPS=()
FAILED_PACKAGES=() # Initialize failure tracking

if [ -f "$LIST_FILE" ]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | tr -d '\r' | xargs)
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        
        if [[ "$line" == flatpak:* ]]; then
            app_id="${line#flatpak:}"
            FLATPAK_APPS+=("$app_id")
        else
            YAY_APPS+=("$line")
        fi
    done < "$LIST_FILE"
    
    log "-> Found ${#YAY_APPS[@]} Yay packages and ${#FLATPAK_APPS[@]} Flatpak packages."
else
    warn "common-applist.txt not found. Skipping installation."
fi

# ------------------------------------------------------------------------------
# 3. Install Applications
# ------------------------------------------------------------------------------

# --- A. Install Yay Apps ---
if [ ${#YAY_APPS[@]} -gt 0 ]; then
    log "Step 3a/4: Installing Yay packages..."
    
    SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_apps"
    echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDO_TEMP_FILE"
    chmod 440 "$SUDO_TEMP_FILE"
    
    BATCH_LIST="${YAY_APPS[*]}"
    log "-> Attempting batch install..."
    
    if runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
        success "Yay packages installed."
    else
        warn "Batch install failed. Retrying one-by-one..."
        for pkg in "${YAY_APPS[@]}"; do
            if ! runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$pkg"; then
                warn "Failed to install '$pkg'. Retrying (Attempt 2/2)..."
                if ! runuser -u "$TARGET_USER" -- yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$pkg"; then
                    error "Failed to install: $pkg"
                    FAILED_PACKAGES+=("yay:$pkg")
                fi
            fi
        done
    fi
    
    rm -f "$SUDO_TEMP_FILE"
fi

# --- B. Install Flatpak Apps (With Retry) ---
if [ ${#FLATPAK_APPS[@]} -gt 0 ]; then
    log "Step 3b/4: Installing Flatpak packages..."
    
    for app in "${FLATPAK_APPS[@]}"; do
        log "-> Installing Flatpak: $app..."
        # Attempt 1
        if flatpak install -y flathub "$app"; then
            success "Installed: $app"
        else
            warn "Flatpak install failed for '$app'. Network issue? Waiting 3s to Retry..."
            sleep 3
            # Attempt 2
            if flatpak install -y flathub "$app"; then
                success "Installed: $app (on retry)"
            else
                error "Failed to install Flatpak: $app"
                FAILED_PACKAGES+=("flatpak:$app")
            fi
        fi
    done
fi

# ------------------------------------------------------------------------------
# 3.5 Generate Failure Report (Append to existing)
# ------------------------------------------------------------------------------
if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
    DOCS_DIR="$HOME_DIR/Documents"
    REPORT_FILE="$DOCS_DIR/安装失败的软件.txt"
    
    if [ ! -d "$DOCS_DIR" ]; then runuser -u "$TARGET_USER" -- mkdir -p "$DOCS_DIR"; fi
    
    # Append header and list
    echo -e "\n--- Phase 5 (Common Apps) Failures ---" >> "$REPORT_FILE"
    printf "%s\n" "${FAILED_PACKAGES[@]}" >> "$REPORT_FILE"
    
    # Ensure ownership is correct
    chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"
    
    echo -e "${RED}[ATTENTION] Some common applications failed to install.${NC}"
    echo -e "${YELLOW}Added to failure report at: $REPORT_FILE${NC}"
else
    success "All selected common applications installed successfully."
fi

# ------------------------------------------------------------------------------
# 4. Steam Locale Fix
# ------------------------------------------------------------------------------
log "Step 4/4: Applying Steam Chinese Locale Fix..."

STEAM_desktop_modified=false

# Method 1: Fix Native Steam
NATIVE_DESKTOP="/usr/share/applications/steam.desktop"
if [ -f "$NATIVE_DESKTOP" ]; then
    log "-> Detected Native Steam. Patching .desktop file..."
    if ! grep -q "env LANG=zh_CN.UTF-8" "$NATIVE_DESKTOP"; then
        sed -i 's|^Exec=/usr/bin/steam|Exec=env LANG=zh_CN.UTF-8 /usr/bin/steam|' "$NATIVE_DESKTOP"
        sed -i 's|^Exec=steam|Exec=env LANG=zh_CN.UTF-8 steam|' "$NATIVE_DESKTOP"
        success "Native Steam .desktop patched."
        STEAM_desktop_modified=true
    else
        log "-> Native Steam already patched."
    fi
fi

# Method 2: Fix Flatpak Steam
if echo "${FLATPAK_APPS[@]}" | grep -q "com.valvesoftware.Steam" || flatpak list | grep -q "com.valvesoftware.Steam"; then
    log "-> Detected Flatpak Steam. Applying environment override..."
    flatpak override --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam
    success "Flatpak Steam override applied."
    STEAM_desktop_modified=true
fi

if [ "$STEAM_desktop_modified" = false ]; then
    log "-> Steam not installed or found. Skipping fix."
fi

log ">>> Phase 5 completed."