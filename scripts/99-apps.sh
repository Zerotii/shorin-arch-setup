#!/bin/bash

# ==============================================================================
# 99-apps.sh - Common Applications (FZF Menu + Split Repo/AUR + Retry Logic)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/00-utils.sh"

check_root

# Ensure FZF is installed
if ! command -v fzf &> /dev/null; then
    log "Installing dependency: fzf..."
    pacman -S --noconfirm fzf >/dev/null 2>&1
fi

trap 'echo -e "\n   ${H_YELLOW}>>> Operation cancelled by user (Ctrl+C). Skipping...${NC}"' INT

# ------------------------------------------------------------------------------
# 0. Identify Target User & Helper
# ------------------------------------------------------------------------------
section "Phase 5" "Common Applications"

log "Identifying target user..."
DETECTED_USER=$(awk -F: '$3 == 1000 {print $1}' /etc/passwd)

if [ -n "$DETECTED_USER" ]; then
    TARGET_USER="$DETECTED_USER"
else
    read -p "   Please enter the target username: " TARGET_USER
fi
HOME_DIR="/home/$TARGET_USER"
info_kv "Target" "$TARGET_USER"

# Helper function for user commands
as_user() {
  runuser -u "$TARGET_USER" -- "$@"
}

# ------------------------------------------------------------------------------
# 1. List Selection & User Prompt
# ------------------------------------------------------------------------------
if [ "$DESKTOP_ENV" == "kde" ]; then
    LIST_FILENAME="kde-common-applist.txt"
else
    LIST_FILENAME="common-applist.txt"
fi
LIST_FILE="$PARENT_DIR/$LIST_FILENAME"

REPO_APPS=()
AUR_APPS=()
FLATPAK_APPS=()
FAILED_PACKAGES=()
SUCCESSFUL_PACKAGES=()

if [ ! -f "$LIST_FILE" ]; then
    warn "File $LIST_FILENAME not found. Skipping."
    trap - INT
    exit 0
fi

if ! grep -q -vE "^\s*#|^\s*$" "$LIST_FILE"; then
    warn "App list is empty. Skipping."
    trap - INT
    exit 0
fi

echo ""
echo -e "   Selected List: ${BOLD}$LIST_FILENAME${NC}"
echo -e "   ${H_YELLOW}>>> Do you want to install common applications?${NC}"
echo -e "   ${H_CYAN}    [ENTER] = Select packages${NC}"
echo -e "   ${H_CYAN}    [N]     = Skip installation${NC}"
echo -e "   ${H_YELLOW}    [Timeout 60s] = Auto-install ALL default packages (No FZF)${NC}"
echo ""

read -t 60 -p "   Please select [Y/n]: " choice
READ_STATUS=$?

SELECTED_RAW=""

# Case 1: Timeout (Auto Install ALL)
if [ $READ_STATUS -ne 0 ]; then
    echo "" 
    warn "Timeout reached (60s). Auto-installing ALL applications from list..."
    SELECTED_RAW=$(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | sed -E 's/[[:space:]]+#/\t#/')

# Case 2: User Input
else
    choice=${choice:-Y}
    if [[ "$choice" =~ ^[nN]$ ]]; then
        warn "User skipped application installation."
        trap - INT
        exit 0
    else
        clear
        echo -e "\n  Loading application list..."
        
        SELECTED_RAW=$(grep -vE "^\s*#|^\s*$" "$LIST_FILE" | \
            sed -E 's/[[:space:]]+#/\t#/' | \
            fzf --multi \
                --layout=reverse \
                --border \
                --margin=1,2 \
                --prompt="Search App > " \
                --pointer=">>" \
                --marker="* " \
                --delimiter=$'\t' \
                --with-nth=1 \
                --bind 'load:select-all' \
                --bind 'ctrl-a:select-all,ctrl-d:deselect-all' \
                --info=inline \
                --header="[TAB] TOGGLE | [ENTER] INSTALL | [CTRL-D] DE-ALL | [CTRL-A] SE-ALL" \
                --preview "echo {} | cut -f2 -d$'\t' | sed 's/^# //'" \
                --preview-window=right:45%:wrap:border-left \
                --color=dark \
                --color=fg+:white,bg+:black \
                --color=hl:blue,hl+:blue:bold \
                --color=header:yellow:bold \
                --color=info:magenta \
                --color=prompt:cyan,pointer:cyan:bold,marker:green:bold \
                --color=spinner:yellow)
        
        clear
        
        if [ -z "$SELECTED_RAW" ]; then
            log "Skipping application installation (User cancelled selection)."
            trap - INT
            exit 0
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 2. Categorize Selection & Strip Prefixes
# ------------------------------------------------------------------------------
log "Processing selection..."

while IFS= read -r line; do
    raw_pkg=$(echo "$line" | cut -f1 -d$'\t' | xargs)
    [[ -z "$raw_pkg" ]] && continue

    if [[ "$raw_pkg" == flatpak:* ]]; then
        clean_name="${raw_pkg#flatpak:}"
        FLATPAK_APPS+=("$clean_name")
    elif [[ "$raw_pkg" == AUR:* ]]; then
        clean_name="${raw_pkg#AUR:}"
        AUR_APPS+=("$clean_name")
    else
        REPO_APPS+=("$raw_pkg")
    fi
done <<< "$SELECTED_RAW"

info_kv "Scheduled" "Repo: ${#REPO_APPS[@]}" "AUR: ${#AUR_APPS[@]}" "Flatpak: ${#FLATPAK_APPS[@]}"

# ------------------------------------------------------------------------------
# [SETUP] GLOBAL SUDO CONFIGURATION
# ------------------------------------------------------------------------------
if [ ${#REPO_APPS[@]} -gt 0 ] || [ ${#AUR_APPS[@]} -gt 0 ]; then
    log "Configuring temporary NOPASSWD for installation..."
    SUDO_TEMP_FILE="/etc/sudoers.d/99_shorin_installer_apps"
    echo "$TARGET_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDO_TEMP_FILE"
    chmod 440 "$SUDO_TEMP_FILE"
fi

# ------------------------------------------------------------------------------
# 3. Install Applications
# ------------------------------------------------------------------------------

# --- A. Install Repo Apps (BATCH MODE) ---
if [ ${#REPO_APPS[@]} -gt 0 ]; then
    section "Step 1/3" "Official Repository Packages (Batch)"
    
    REPO_QUEUE=()
    for pkg in "${REPO_APPS[@]}"; do
        if pacman -Qi "$pkg" &>/dev/null; then
            log "Skipping '$pkg' (Already installed)."
        else
            REPO_QUEUE+=("$pkg")
        fi
    done

    if [ ${#REPO_QUEUE[@]} -gt 0 ]; then
        BATCH_LIST="${REPO_QUEUE[*]}"
        info_kv "Installing" "${#REPO_QUEUE[@]} packages via Pacman/Yay"
        
        if ! exe as_user yay -Syu --noconfirm --needed --answerdiff=None --answerclean=None $BATCH_LIST; then
            error "Batch installation failed. Some repo packages might be missing."
            for pkg in "${REPO_QUEUE[@]}"; do
                FAILED_PACKAGES+=("repo:$pkg:安装失败")
            done
        else
            success "Repo batch installation completed."
            for pkg in "${REPO_QUEUE[@]}"; do
                SUCCESSFUL_PACKAGES+=("repo:$pkg:安装成功")
            done
        fi
    else
        log "All Repo packages are already installed."
    fi
fi

# --- B. Install AUR Apps (INDIVIDUAL MODE + RETRY) ---
if [ ${#AUR_APPS[@]} -gt 0 ]; then
    section "Step 2/3" "AUR Packages (Sequential + Retry)"
    
    for app in "${AUR_APPS[@]}"; do
        if pacman -Qi "$app" &>/dev/null; then
            log "Skipping '$app' (Already installed)."
            continue
        fi


        log "Installing AUR: $app ..."
        install_success=false
        max_retries=2
        
        for (( i=0; i<=max_retries; i++ )); do
            if [ $i -gt 0 ]; then
                warn "Retry $i/$max_retries for '$app' in 3 seconds..."
                sleep 3
            fi
            
            if as_user yay -S --noconfirm --needed --answerdiff=None --answerclean=None "$app"; then
                install_success=true
                success "Installed $app"
                SUCCESSFUL_PACKAGES+=("aur:$app:安装成功")
                break
            else
                warn "Attempt $((i+1)) failed for $app"
            fi
        done

        if [ "$install_success" = false ]; then
            error "Failed to install $app after $((max_retries+1)) attempts."
            FAILED_PACKAGES+=("aur:$app:安装失败，已尝试$((max_retries+1))次")
        fi
    done
fi

# --- C. Install Flatpak Apps (INDIVIDUAL MODE) ---
if [ ${#FLATPAK_APPS[@]} -gt 0 ]; then
    section "Step 3/3" "Flatpak Packages (Individual)"
    
    for app in "${FLATPAK_APPS[@]}"; do
        if flatpak info "$app" &>/dev/null; then
            log "Skipping '$app' (Already installed)."
            continue
        fi

        log "Installing Flatpak: $app ..."
        if ! exe flatpak install -y flathub "$app"; then
            error "Failed to install: $app"
            FAILED_PACKAGES+=("flatpak:$app:安装失败")
        else
            success "Installed $app"
            SUCCESSFUL_PACKAGES+=("flatpak:$app:安装成功")
        fi
    done
fi

# ------------------------------------------------------------------------------
# 4. Environment & Additional Configs (Virt/Wine/Steam)
# ------------------------------------------------------------------------------
section "Post-Install" "System & App Tweaks"

# --- [NEW] Virtualization Configuration (Virt-Manager) ---
if pacman -Qi virt-manager &>/dev/null; then
  info_kv "Config" "Virt-Manager detected"
  
  # 1. 安装完整依赖
  # iptables-nft 和 dnsmasq 是默认 NAT 网络必须的
  log "Installing QEMU/KVM dependencies..."
  pacman -S --noconfirm --needed qemu-full virt-manager swtpm dnsmasq 

  # 2. 添加用户组 (需要重新登录生效)
  log "Adding $TARGET_USER to libvirt group..."
  usermod -a -G libvirt "$TARGET_USER"
  # 同时添加 kvm 和 input 组以防万一
  usermod -a -G kvm,input "$TARGET_USER"

  # 3. 开启服务
  log "Enabling libvirtd service..."
  systemctl enable --now libvirtd

  # 4. [修复] 强制设置 virt-manager 默认连接为 QEMU/KVM
  # 解决第一次打开显示 LXC 或无法连接的问题
  log "Setting default URI to qemu:///system..."
  
  # 编译 glib schemas (防止 gsettings 报错)
  glib-compile-schemas /usr/share/glib-2.0/schemas/

  # 强制写入 Dconf 配置
  # uris: 连接列表
  # autoconnect: 自动连接的列表
  as_user gsettings set org.virt-manager.virt-manager.connections uris "['qemu:///system']"
  as_user gsettings set org.virt-manager.virt-manager.connections autoconnect "['qemu:///system']"

  # 5. 配置网络 (Default NAT)
  log "Starting default network..."
  sleep 3
  virsh net-start default >/dev/null 2>&1 || warn "Default network might be already active."
  virsh net-autostart default >/dev/null 2>&1 || true
  
  success "Virtualization (KVM) configured."
fi

# --- [NEW] Wine Configuration & Fonts ---
if pacman -Qi wine &>/dev/null; then
  info_kv "Config" "Wine detected"
  
  # 1. 安装 Gecko 和 Mono
  log "Ensuring Wine Gecko/Mono are installed..."
  pacman -S --noconfirm --needed wine wine-gecko wine-mono

  # 2. 初始化 Wine (使用 wineboot -u 在后台运行，不弹窗)
  WINE_PREFIX="$HOME_DIR/.wine"
  if [ ! -d "$WINE_PREFIX" ]; then
    log "Initializing wine prefix (This may take a minute)..."
    # WINEDLLOVERRIDES prohibits popups
    as_user env WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -u
    # Wait for completion
    as_user wineserver -w
  else
    log "Wine prefix already exists."
  fi

  # 3. 复制字体
  FONT_SRC="$SCRIPT_DIR/resources/windows-sim-fonts"
  FONT_DEST="$WINE_PREFIX/drive_c/windows/Fonts"

  if [ -d "$FONT_SRC" ]; then
    log "Copying Windows fonts from resources..."
    
    # 1. 确保目标目录存在 (以用户身份创建)
    if [ ! -d "$FONT_DEST" ]; then
        as_user mkdir -p "$FONT_DEST"
    fi

    # 2. 执行复制 (关键修改：直接以目标用户身份复制，而不是 Root 复制后再 Chown)
    # 使用 cp -rT 确保目录内容合并，而不是把源目录本身拷进去
    # 注意：这里假设 as_user 能够接受命令参数。如果 as_user 只是简单的 su/sudo 封装：
    if sudo -u "$TARGET_USER" cp -rf "$FONT_SRC"/. "$FONT_DEST/"; then
        success "Fonts copied successfully."
    else
        error "Failed to copy fonts."
    fi

    # 3. 强制刷新 Wine 字体缓存 (非常重要！)
    # 字体文件放进去了，但 Wine 不一定会立刻重修构建 fntdata.dat
    # 杀死 wineserver 会强制 Wine 下次启动时重新扫描系统和本地配置
    log "Refreshing Wine font cache..."
    if command -v wineserver &> /dev/null; then
        # 必须以目标用户身份执行 wineserver -k
        as_user env WINEPREFIX="$WINE_PREFIX" wineserver -k
    fi
    
    success "Wine fonts installed and cache refresh triggered."
  else
    warn "Resources font directory not found at: $FONT_SRC"
  fi
fi

# --- Steam Locale Fix ---
STEAM_desktop_modified=false
NATIVE_DESKTOP="/usr/share/applications/steam.desktop"
if [ -f "$NATIVE_DESKTOP" ]; then
    log "Checking Native Steam..."
    if ! grep -q "env LANG=zh_CN.UTF-8" "$NATIVE_DESKTOP"; then
        exe sed -i 's|^Exec=/usr/bin/steam|Exec=env LANG=zh_CN.UTF-8 /usr/bin/steam|' "$NATIVE_DESKTOP"
        exe sed -i 's|^Exec=steam|Exec=env LANG=zh_CN.UTF-8 steam|' "$NATIVE_DESKTOP"
        success "Patched Native Steam .desktop."
        STEAM_desktop_modified=true
    else
        log "Native Steam already patched."
    fi
fi

if flatpak list | grep -q "com.valvesoftware.Steam"; then
    log "Checking Flatpak Steam..."
    exe flatpak override --env=LANG=zh_CN.UTF-8 com.valvesoftware.Steam
    success "Applied Flatpak Steam override."
    STEAM_desktop_modified=true
fi

# ------------------------------------------------------------------------------
# [FIX] CLEANUP GLOBAL SUDO CONFIGURATION
# ------------------------------------------------------------------------------
if [ -f "$SUDO_TEMP_FILE" ]; then
    log "Revoking temporary NOPASSWD..."
    rm -f "$SUDO_TEMP_FILE"
fi

# ------------------------------------------------------------------------------
# 5. Generate Detailed Installation Report
# ------------------------------------------------------------------------------
DOCS_DIR="$HOME_DIR/Documents"
REPORT_FILE="$DOCS_DIR/软件安装报告.txt"

if [ ! -d "$DOCS_DIR" ]; then as_user mkdir -p "$DOCS_DIR"; fi

echo -e "\n========================================================" > "$REPORT_FILE"
echo -e " 软件安装详细报告 - $(date)" >> "$REPORT_FILE"
echo -e "========================================================" >> "$REPORT_FILE"

# 生成成功安装的软件列表
if [ ${#SUCCESSFUL_PACKAGES[@]} -gt 0 ]; then
    echo -e "\n✅ 成功安装的软件：" >> "$REPORT_FILE"
    echo -e "--------------------------------------------------------" >> "$REPORT_FILE"
    for pkg in "${SUCCESSFUL_PACKAGES[@]}"; do
        echo -e "   $pkg" >> "$REPORT_FILE"
    done
else
    echo -e "\n✅ 成功安装的软件：无" >> "$REPORT_FILE"
fi

# 生成安装失败的软件列表
if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
    echo -e "\n❌ 安装失败的软件：" >> "$REPORT_FILE"
    echo -e "--------------------------------------------------------" >> "$REPORT_FILE"
    for pkg in "${FAILED_PACKAGES[@]}"; do
        echo -e "   $pkg" >> "$REPORT_FILE"
    done
else
    echo -e "\n❌ 安装失败的软件：无" >> "$REPORT_FILE"
fi

# 生成统计信息
TOTAL_PACKAGES=$(( ${#SUCCESSFUL_PACKAGES[@]} + ${#FAILED_PACKAGES[@]} ))
SUCCESS_RATE=0
if [ $TOTAL_PACKAGES -gt 0 ]; then
    SUCCESS_RATE=$(( ${#SUCCESSFUL_PACKAGES[@]} * 100 / TOTAL_PACKAGES ))
fi

echo -e "\n📊 统计信息：" >> "$REPORT_FILE"
echo -e "--------------------------------------------------------" >> "$REPORT_FILE"
echo -e "   总软件数：$TOTAL_PACKAGES" >> "$REPORT_FILE"
echo -e "   成功安装：${#SUCCESSFUL_PACKAGES[@]}" >> "$REPORT_FILE"
echo -e "   安装失败：${#FAILED_PACKAGES[@]}" >> "$REPORT_FILE"
echo -e "   成功率：$SUCCESS_RATE%" >> "$REPORT_FILE"
echo -e "========================================================" >> "$REPORT_FILE"

chown "$TARGET_USER:$TARGET_USER" "$REPORT_FILE"

echo ""
info "详细安装报告已生成："
echo -e "   ${BOLD}$REPORT_FILE${NC}"

if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
    warn "部分应用安装失败，请查看报告了解详情。"
else
    success "所有应用安装成功！"
fi

# Reset Trap
trap - INT

log "Module 99-apps completed."