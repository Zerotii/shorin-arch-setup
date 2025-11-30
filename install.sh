#!/bin/bash

# ==============================================================================
# shorin-arch-setup Installer
# ==============================================================================

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"
STATE_FILE="$BASE_DIR/.install_progress"

source "$SCRIPTS_DIR/00-utils.sh"

check_root

# Make scripts executable
chmod +x "$SCRIPTS_DIR"/*.sh

clear
echo -e "${BLUE}"
cat << "EOF"
   _____ __  ______  ____  _____   __
  / ___// / / / __ \/ __ \/  _/ | / /
  \__ \/ /_/ / / / / /_/ // //  |/ / 
 ___/ / __  / /_/ / _, _// // /|  /  
/____/_/ /_/\____/_/ |_/___/_/ |_/   
                                     
   Arch Linux Setup Script by Shorin
EOF
echo -e "${NC}"
log "Welcome to the automated setup script."
log "Installation logs will be output to this console."
echo "----------------------------------------------------"

MODULES=(
    "01-base.sh"
    "02-musthave.sh"
    "03-user.sh"
    "04-niri-setup.sh"
    "05-apps.sh"
)

# Create state file if not exists
if [ ! -f "$STATE_FILE" ]; then
    touch "$STATE_FILE"
fi

for module in "${MODULES[@]}"; do
    script_path="$SCRIPTS_DIR/$module"
    
    if [ ! -f "$script_path" ]; then
        warn "Module not found: $module"
        continue
    fi

    # Check if module is already completed
    if grep -q "^${module}$" "$STATE_FILE"; then
        echo -e "${YELLOW}[CHECKPOINT]${NC} Module '${module}' is marked as COMPLETED."
        read -p "Do you want to SKIP it? [Y/n] " skip_choice
        skip_choice=${skip_choice:-Y} # Default to Yes
        
        if [[ "$skip_choice" =~ ^[Yy]$ ]]; then
            log "Skipping $module..."
            continue
        else
            log "Re-running $module..."
            # Remove from state file temporarily in case it fails this time
            sed -i "/^${module}$/d" "$STATE_FILE"
        fi
    fi

    # Execute Module
    log "Executing module: $module"
    bash "$script_path"
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        # Record success
        echo "$module" >> "$STATE_FILE"
    else
        error "Module $module failed (Exit Code: $exit_code)."
        error "Fix the issue and re-run ./install.sh to resume."
        exit 1
    fi
done

echo "----------------------------------------------------"
success "All selected modules executed successfully!"

# ==============================================================================
# Finalization & Reboot
# ==============================================================================

echo "----------------------------------------------------"
success "All selected modules executed successfully!"

# Cleanup the state file so the next run starts fresh
if [ -f "$STATE_FILE" ]; then
    rm "$STATE_FILE"
fi

echo -e "${GREEN}Installation Complete! The system needs to reboot to apply changes.${NC}"
echo -e "${YELLOW}System will REBOOT automatically in 10 seconds...${NC}"

# Wait for 10 seconds. If no input, default to 'Y' (Reboot)
read -t 10 -p "Reboot now? [Y/n] " choice
choice=${choice:-Y}

if [[ "$choice" =~ ^[Yy]$ ]]; then
    log "Rebooting system..."
    reboot
else
    log "Reboot skipped. Please remember to reboot manually!"
fi
# Optional: Clean up state file on full success?
# rm "$STATE_FILE" 
# I suggest keeping it unless you want to force full reinstall next time.