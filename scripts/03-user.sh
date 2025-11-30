#!/bin/bash

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-utils.sh"

check_root

log ">>> Starting Phase 3: User Creation & Configuration"

# ------------------------------------------------------------------------------
# 1. User Detection / Creation Logic
# ------------------------------------------------------------------------------
log "Step 1/3: User Account Setup"

# Attempt to detect existing user with UID 1000 (The first standard user)
EXISTING_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)
MY_USERNAME=""
SKIP_CREATION=false

if [ -n "$EXISTING_USER" ]; then
    log "-> Detected existing user with UID 1000: '$EXISTING_USER'"
    success "Using existing user: $EXISTING_USER"
    MY_USERNAME="$EXISTING_USER"
    SKIP_CREATION=true
else
    # No UID 1000 found, enter creation wizard
    log "-> No standard user found. Starting user creation wizard..."
    
    while true; do
        echo -e "${YELLOW}----------------------------------------${NC}"
        read -p "Please enter the new username: " INPUT_USER
        
        if [[ -z "$INPUT_USER" ]]; then
            warn "Username cannot be empty. Please try again."
            continue
        fi

        # "Regret" option: Confirmation
        read -p "You entered '$INPUT_USER'. Is this correct? [y/N]: " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            MY_USERNAME="$INPUT_USER"
            break
        else
            log "Cancelled. Please re-enter the username."
        fi
    done
fi

# ------------------------------------------------------------------------------
# 2. Create User & Sudo (Only if user didn't exist)
# ------------------------------------------------------------------------------
if [ "$SKIP_CREATION" = true ]; then
    log "Step 2/3: Skipped user creation (User already exists)."
else
    log "Step 2/3: Creating user '$MY_USERNAME' and configuring sudo..."
    
    # 1. Create User
    if id "$MY_USERNAME" &>/dev/null; then
        warn "User '$MY_USERNAME' already exists (but not UID 1000?). Skipping add."
    else
        useradd -m -g wheel "$MY_USERNAME"
        success "User '$MY_USERNAME' created."
        
        log "-> Setting password for '$MY_USERNAME'..."
        passwd "$MY_USERNAME"
    fi

    # 2. Configure Sudoers
    log "-> Configuring Sudo privileges..."
    if grep -q "^# %wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
        sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        success "Enabled sudo access for %wheel group."
    elif grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
        success "Sudo access for %wheel group is already enabled."
    else
        echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
        success "Appended wheel config to /etc/sudoers."
    fi
fi

# ------------------------------------------------------------------------------
# 3. Generate User Directories (xdg-user-dirs)
# ------------------------------------------------------------------------------
log "Step 3/3: Generating user directories (Downloads, Music, etc.)..."

# Install the package first if missing (Safety check)
pacman -S --noconfirm --needed xdg-user-dirs > /dev/null 2>&1

# Run update as the target user
if runuser -u "$MY_USERNAME" -- xdg-user-dirs-update; then
    success "User directories generated for '$MY_USERNAME' in /home/$MY_USERNAME/"
else
    warn "Failed to generate directories (This is normal if running in chroot or minimal environment)."
    warn "They will be created automatically when $MY_USERNAME logs in."
fi

log ">>> Phase 3 completed."