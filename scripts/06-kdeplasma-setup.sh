#!/bin/bash

# ==============================================================================
# 06-kdeplasma-setup.sh - KDE Plasma Setup (Visual Enhanced + Logic Refactored)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

DEBUG=${DEBUG:-0}
CN_MIRROR=${CN_MIRROR:-0}

check_root

section "Phase 6" "KDE Plasma Environment"

# ------------------------------------------------------------------------------
# 0. Identify Target User
# ------------------------------------------------------------------------------
log "Identifying user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
if [ -n "$DETECTED_USER" ]; then TARGET_USER="$DETECTED_USER"; else read -p "Target user: " TARGET_USER; fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# ------------------------------------------------------------------------------
# 1. Install KDE Plasma Base
# ------------------------------------------------------------------------------
section "Step 1/5" "Plasma Core"

log "Installing KDE Plasma Meta & Apps..."
KDE_PKGS="plasma-meta konsole dolphin kate firefox qt6-multimedia-ffmpeg pipewire-jack sddm"
exe pacman -Syu --noconfirm --needed $KDE_PKGS
success "KDE Plasma installed."

# ------------------------------------------------------------------------------
# 2. Software Store & Network (Smart Mirror Selection)
# ------------------------------------------------------------------------------
section "Step 2/5" "Software Store & Network"

log "Configuring Discover & Flatpak..."

exe pacman -Syu --noconfirm --needed flatpak flatpak-kcm
exe flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# --- Network Detection Logic ---
CURRENT_TZ=$(readlink -f /etc/localtime)
IS_CN_ENV=false

if [[ "$CURRENT_TZ" == *"Shanghai"* ]]; then
    IS_CN_ENV=true
    info_kv "Region" "China (Timezone)"
elif [ "$CN_MIRROR" == "1" ]; then
    IS_CN_ENV=true
    info_kv "Region" "China (Manual Env)"
elif [ "$DEBUG" == "1" ]; then
    IS_CN_ENV=true
    warn "DEBUG MODE: Forcing China Environment"
fi

# --- Mirror Configuration ---
if [ "$IS_CN_ENV" = true ]; then
    log "Enabling China Optimizations..."
    
    # Use utility function
    select_flathub_mirror

    exe flatpak remote-modify --no-p2p flathub
    
    success "Optimizations Enabled."
else
    log "Using Global Official Sources."
fi

# NOPASSWD for yay
SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_temp"
echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDO_TEMP_FILE"
chmod 440 "$SUDO_TEMP_FILE"

# ------------------------------------------------------------------------------
# 3. Install Dependencies (Logic: Batch -> Verify -> AUR -> Recovery)
# ------------------------------------------------------------------------------
section "Step 3/5" "KDE Dependencies"

LIST_FILE="$PARENT_DIR/kde-applist.txt"
UNDO_SCRIPT="$PARENT_DIR/undochange.sh"

# --- Critical Failure Handler ---
critical_failure_handler() {
    local failed_pkg="$1"
    
    echo ""
    echo -e "\033[0;31m################################################################\033[0m"
    echo -e "\033[0;31m#                                                              #\033[0m"
    echo -e "\033[0;31m#   CRITICAL INSTALLATION FAILURE DETECTED                     #\033[0m"
    echo -e "\033[0;31m#   Package: $failed_pkg                                       #\033[0m"
    echo -e "\033[0;31m#   Status: Package not found after install attempt.           #\033[0m"
    echo -e "\033[0;31m#                                                              #\033[0m"
    echo -e "\033[0;31m#   Would you like to restore snapshot (undo changes)?         #\033[0m"
    echo -e "\033[0;31m################################################################\033[0m"
    echo ""

    while true; do
        read -p "Execute System Recovery? [y/n]: " -r choice
        case "$choice" in 
            [yY][eE][sS]|[yY]) 
                if [ -f "$UNDO_SCRIPT" ]; then
                    warn "Executing recovery script: $UNDO_SCRIPT"
                    bash "$UNDO_SCRIPT"
                    exit 1
                else
                    error "Recovery script not found at: $UNDO_SCRIPT"
                    exit 1
                fi
                ;;
            [nN][oO]|[nN])
                warn "User chose NOT to recover. System might be in a broken state."
                error "Installation aborted due to failure in: $failed_pkg"
                exit 1
                ;;
            *)
                echo -e "\033[1;33mInvalid input. Please enter 'y' to recover or 'n' to abort.\033[0m"
                ;;
        esac
    done
}

# --- Verification Function ---
verify_installation() {
    local pkg="$1"
    # 使用 pacman -Q 检查包是否存在
    if pacman -Q "$pkg" &>/dev/null; then
        return 0 # 已安装
    else
        return 1 # 未安装
    fi
}

if [ -f "$LIST_FILE" ]; then
    mapfile -t PACKAGE_ARRAY < <(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | tr -d '\r')
    
    if [ ${#PACKAGE_ARRAY[@]} -gt 0 ]; then
        BATCH_LIST=()
        AUR_LIST=()

        # 1. Parse List & Separate
        for pkg in "${PACKAGE_ARRAY[@]}"; do
            # 兼容旧列表习惯
            [ "$pkg" == "imagemagic" ] && pkg="imagemagick"

            if [[ "$pkg" == "AUR:"* ]]; then
                clean_pkg="${pkg#AUR:}"
                AUR_LIST+=("$clean_pkg")
            elif [[ "$pkg" == *"-git" ]]; then
                # 兼容旧逻辑：如果没写 AUR: 但带了 -git，也视为 AUR
                AUR_LIST+=("$pkg")
            else
                BATCH_LIST+=("$pkg")
            fi
        done

        # 2. Phase 1: Batch Install (Repo Packages)
        if [ ${#BATCH_LIST[@]} -gt 0 ]; then
            log "Phase 1: Batch Installing Repository Packages..."
            
            # 尝试安装
            exe runuser -u "$TARGET_USER" -- yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "${BATCH_LIST[@]}"
            
            # --- Verification Loop ---
            log "Verifying batch installation..."
            for pkg in "${BATCH_LIST[@]}"; do
                if ! verify_installation "$pkg"; then
                    warn "Verification failed for '$pkg'. Retrying individually..."
                    # 失败重试：单独安装这一个
                    exe runuser -u "$TARGET_USER" -- yay -Syu --noconfirm --needed "$pkg"
                    
                    # 二次核查
                    if ! verify_installation "$pkg"; then
                        critical_failure_handler "$pkg (Repo)"
                    else
                        success "Verified: $pkg"
                    fi
                fi
            done
            success "Batch phase verified."
        fi

        # 3. Phase 2: Sequential Install (AUR Packages)
        if [ ${#AUR_LIST[@]} -gt 0 ]; then
            log "Phase 2: Installing AUR Packages (Sequential)..."
            log "Hint: Use Ctrl+C to skip a specific package download step."

            for aur_pkg in "${AUR_LIST[@]}"; do
                log "Installing '$aur_pkg'..."
                
                # Try 1
                runuser -u "$TARGET_USER" -- yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "$aur_pkg"
                EXIT_CODE=$?

                # Ctrl+C 跳过处理
                if [ $EXIT_CODE -eq 130 ]; then
                    warn "Skipped '$aur_pkg' by user request (Ctrl+C)."
                    continue
                fi

                # --- Verification ---
                if ! verify_installation "$aur_pkg"; then
                    warn "Verification failed for '$aur_pkg'. Retrying once..."
                    
                    # Retry 1
                    runuser -u "$TARGET_USER" -- yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None "$aur_pkg"
                    RETRY_CODE=$?

                    if [ $RETRY_CODE -eq 130 ]; then
                         warn "Skipped '$aur_pkg' on retry by user request (Ctrl+C)."
                         continue
                    fi

                    # 二次核查
                    if ! verify_installation "$aur_pkg"; then
                        critical_failure_handler "$aur_pkg (AUR)"
                    else
                         success "Verified: $aur_pkg"
                    fi
                else
                    success "Verified: $aur_pkg"
                fi
            done
        fi
        
    fi
else
    warn "kde-applist.txt not found."
fi

# ------------------------------------------------------------------------------
# 4. Dotfiles Deployment
# ------------------------------------------------------------------------------
section "Step 4/5" "KDE Config Deployment"

DOTFILES_SOURCE="$PARENT_DIR/kde-dotfiles"

if [ -d "$DOTFILES_SOURCE" ]; then
    log "Deploying KDE configurations..."
    
    # 1. Backup Existing .config
    BACKUP_NAME="config_backup_kde_$(date +%s).tar.gz"
    if [ -d "$HOME_DIR/.config" ]; then
        log "Backing up ~/.config to $BACKUP_NAME..."
        exe runuser -u "$TARGET_USER" -- tar -czf "$HOME_DIR/$BACKUP_NAME" -C "$HOME_DIR" .config
    fi
    
    # 2. Explicitly Copy .config and .local
    
    # --- Process .config ---
    if [ -d "$DOTFILES_SOURCE/.config" ]; then
        log "Merging .config..."
        if [ ! -d "$HOME_DIR/.config" ]; then mkdir -p "$HOME_DIR/.config"; fi
        
        exe cp -rf "$DOTFILES_SOURCE/.config/"* "$HOME_DIR/.config/" 2>/dev/null || true
        exe cp -rf "$DOTFILES_SOURCE/.config/." "$HOME_DIR/.config/" 2>/dev/null || true
        
        log "Fixing permissions for .config..."
        exe chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config"
    fi

    # --- Process .local ---
    if [ -d "$DOTFILES_SOURCE/.local" ]; then
        log "Merging .local..."
        if [ ! -d "$HOME_DIR/.local" ]; then mkdir -p "$HOME_DIR/.local"; fi
        
        exe cp -rf "$DOTFILES_SOURCE/.local/"* "$HOME_DIR/.local/" 2>/dev/null || true
        exe cp -rf "$DOTFILES_SOURCE/.local/." "$HOME_DIR/.local/" 2>/dev/null || true
        
        log "Fixing permissions for .local..."
        exe chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.local"
    fi
    
    success "KDE Dotfiles applied and permissions fixed."
else
    warn "Folder 'kde-dotfiles' not found in repo. Skipping config."
fi

# ------------------------------------------------------------------------------
# 4.5 Deploy Resource Files (README)
# ------------------------------------------------------------------------------
log "Deploying desktop resources..."

SOURCE_README="$PARENT_DIR/resources/KDE-README.txt"
DESKTOP_DIR="$HOME_DIR/Desktop"

if [ ! -d "$DESKTOP_DIR" ]; then
    exe runuser -u "$TARGET_USER" -- mkdir -p "$DESKTOP_DIR"
fi

if [ -f "$SOURCE_README" ]; then
    log "Copying KDE-README.txt..."
    exe cp "$SOURCE_README" "$DESKTOP_DIR/"
    exe chown "$TARGET_USER:$TARGET_USER" "$DESKTOP_DIR/KDE-README.txt"
    success "Readme deployed."
else
    warn "resources/KDE-README.txt not found."
fi

# ------------------------------------------------------------------------------
# 5. Enable SDDM (FIXED THEME)
# ------------------------------------------------------------------------------
section "Step 5/5" "Enable Display Manager"

log "Configuring SDDM Theme to Breeze..."
exe mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/theme.conf <<EOF
[Theme]
Current=breeze
EOF
log "Theme set to 'breeze'."

log "Enabling SDDM..."
exe systemctl enable sddm
success "SDDM enabled. Will start on reboot."

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
section "Cleanup" "Restoring State"
rm -f "$SUDO_TEMP_FILE"
success "Done."

log "Module 06 completed."