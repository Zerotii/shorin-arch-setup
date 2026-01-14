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
            test_results+=("repo:$app:测试通过:在官方仓库中找到:pacman -Si $app")
        else
            error "$app: Not found in official repository"
            test_results+=("repo:$app:测试失败:在官方仓库中未找到:pacman -Si $app")
        fi
    done
}

# Test AUR packages
test_aur_packages() {
    log "Testing AUR packages..."
    local aur_apps=("$@")
    local url=""
    local status=""
    
    for app in "${aur_apps[@]}"; do
        url="https://aur.archlinux.org/packages/$app"
        log "Checking $app at $url..."
        
        # Get HTTP status code
        status=$(curl -s -o /dev/null -w "%{http_code}" "$url")
        
        if [ "$status" -eq 200 ]; then
            success "$app: Found in AUR (HTTP $status)"
            test_results+=("aur:$app:测试通过:在AUR中找到 (HTTP $status):$url")
        else
            error "$app: Not found in AUR (HTTP $status)"
            test_results+=("aur:$app:测试失败:在AUR中未找到 (HTTP $status):$url")
        fi
    done
}

# Test Flatpak packages
test_flatpak_packages() {
    log "Testing Flatpak packages..."
    local flatpak_apps=("$@")
    local url=""
    local status=""
    
    for app in "${flatpak_apps[@]}"; do
        url="https://flathub.org/api/v1/apps/$app"
        log "Checking $app at $url..."
        
        # Get HTTP status code
        status=$(curl -s -o /dev/null -w "%{http_code}" "$url")
        
        if [ "$status" -eq 200 ]; then
            success "$app: Found in Flathub (HTTP $status)"
            test_results+=("flatpak:$app:测试通过:在Flathub中找到 (HTTP $status):$url")
        else
            error "$app: Not found in Flathub (HTTP $status)"
            test_results+=("flatpak:$app:测试失败:在Flathub中未找到 (HTTP $status):$url")
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
    local test_results=()
    
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
    
    # Generate test report
    REPORT_DIR="$PARENT_DIR/test-reports"
    REPORT_FILE="$REPORT_DIR/软件下载链接测试报告.txt"
    
    if [ ! -d "$REPORT_DIR" ]; then
        mkdir -p "$REPORT_DIR"
    fi
    
    echo -e "\n========================================================" > "$REPORT_FILE"
    echo -e " 软件下载链接测试报告 - $(date)" >> "$REPORT_FILE"
    echo -e "========================================================" >> "$REPORT_FILE"
    
    # 统计测试结果
    local passed=0
    local failed=0
    local passed_results=()
    local failed_results=()
    
    for result in "${test_results[@]}"; do
        if [[ "$result" == *":测试通过:"* ]]; then
            ((passed++))
            passed_results+=("$result")
        else
            ((failed++))
            failed_results+=("$result")
        fi
    done
    
    # 生成通过测试的软件列表
    echo -e "\n✅ 测试通过的软件：" >> "$REPORT_FILE"
    echo -e "--------------------------------------------------------" >> "$REPORT_FILE"
    
    if [ ${#passed_results[@]} -gt 0 ]; then
        for result in "${passed_results[@]}"; do
            # 提取类型（前两个字符）
            type=$(echo "$result" | cut -d':' -f1)
            # 提取应用名称（第二个字段）
            app=$(echo "$result" | cut -d':' -f2)
            # 提取状态（第三个字段）
            status=$(echo "$result" | cut -d':' -f3)
            # 提取原因（从第四个字段到倒数第二个字段）
            reason=$(echo "$result" | cut -d':' -f4- | sed 's/:https\?:\/\///' | cut -d'/' -f1)
            # 提取URL（从https://开始到结尾）
            url=$(echo "$result" | grep -o 'https\?://.*')
            echo -e "   $app" >> "$REPORT_FILE"
            echo -e "     类型: $type" >> "$REPORT_FILE"
            echo -e "     状态: $status" >> "$REPORT_FILE"
            echo -e "     原因: $reason" >> "$REPORT_FILE"
            echo -e "     地址: $url" >> "$REPORT_FILE"
            echo -e "" >> "$REPORT_FILE"
        done
    else
        echo -e "   无" >> "$REPORT_FILE"
    fi
    
    # 生成失败测试的软件列表
    echo -e "\n❌ 测试失败的软件：" >> "$REPORT_FILE"
    echo -e "--------------------------------------------------------" >> "$REPORT_FILE"
    
    if [ ${#failed_results[@]} -gt 0 ]; then
        for result in "${failed_results[@]}"; do
            # 提取类型（前两个字符）
            type=$(echo "$result" | cut -d':' -f1)
            # 提取应用名称（第二个字段）
            app=$(echo "$result" | cut -d':' -f2)
            # 提取状态（第三个字段）
            status=$(echo "$result" | cut -d':' -f3)
            # 提取原因（从第四个字段到倒数第二个字段）
            reason=$(echo "$result" | cut -d':' -f4- | sed 's/:https\?:\/\///' | cut -d'/' -f1)
            # 提取URL（从https://开始到结尾）
            url=$(echo "$result" | grep -o 'https\?://.*')
            echo -e "   $app" >> "$REPORT_FILE"
            echo -e "     类型: $type" >> "$REPORT_FILE"
            echo -e "     状态: $status" >> "$REPORT_FILE"
            echo -e "     原因: $reason" >> "$REPORT_FILE"
            echo -e "     地址: $url" >> "$REPORT_FILE"
            echo -e "" >> "$REPORT_FILE"
        done
    else
        echo -e "   无" >> "$REPORT_FILE"
    fi
    
    # 生成统计信息
    local total=$((passed + failed))
    local pass_rate=0
    if [ $total -gt 0 ]; then
        pass_rate=$((passed * 100 / total))
    fi
    
    echo -e "\n📊 测试统计：" >> "$REPORT_FILE"
    echo -e "--------------------------------------------------------" >> "$REPORT_FILE"
    echo -e "   总测试数：$total" >> "$REPORT_FILE"
    echo -e "   通过测试：$passed" >> "$REPORT_FILE"
    echo -e "   失败测试：$failed" >> "$REPORT_FILE"
    echo -e "   通过率：$pass_rate%" >> "$REPORT_FILE"
    echo -e "========================================================" >> "$REPORT_FILE"
    
    echo -e "\n${WHITE}=== Test Complete ===${NC}"
    echo -e "\n${CYAN}📋 测试报告已生成：${NC} $REPORT_FILE"
    echo -e "\n${CYAN}📊 测试统计：${NC}"
    echo -e "   总测试数：$total"
    echo -e "   通过测试：${GREEN}$passed${NC}"
    echo -e "   失败测试：${RED}$failed${NC}"
    echo -e "   通过率：$pass_rate%"
}

# Run main
main
