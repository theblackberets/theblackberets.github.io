#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# HARSH ALPINE SYSTEM CLEANUP SCRIPT
# Removes UI/Desktop components, users, services, and cleans system thoroughly
# ============================================================================

# --- Configuration Section: CUSTOMIZE THESE LISTS ---

# List of non-system users to delete (e.g., users created for UI/Desktop testing)
USERS_TO_DELETE=(
    "uiuser1"
    "testdesktop"
    # Add other user names here, separated by spaces
)

# List of packages commonly associated with a Desktop Environment or UI.
# REVIEW and REMOVE packages you want to keep (e.g., 'bash' if you need it)
PACKAGES_TO_REMOVE=(
    # X Server/Display Managers
    "xorg-server"
    "xorg-server-common"
    "xinit"
    "xorg-xinit"
    "lightdm"
    "sddm"
    "gdm"
    "lxdm"
    # Desktop Environments/Window Managers
    "xfce4"
    "xfce4-terminal"
    "xfce4-session"
    "xfce4-panel"
    "kde-base"
    "kde-plasma"
    "gnome"
    "gnome-shell"
    "gnome-session"
    "i3"
    "i3-wm"
    "openbox"
    "fluxbox"
    "lxde"
    "lxqt"
    "mate"
    "cinnamon"
    # Core UI components
    "mesa-dri"
    "mesa-doc"
    "ttf-dejavu"
    "ttf-dejavu-core"
    "ttf-dejavu-common"
    # Example Applications
    "firefox"
    "chromium"
    "chromium-browser"
    "pcmanfm"
    "thunar"
    "nautilus"
    # Additional UI packages
    "alsa-utils"
    "pulseaudio"
    "pulseaudio-utils"
)

# Service files to disable/remove
SERVICES_TO_DISABLE=(
    "lightdm"
    "sddm"
    "gdm"
    "lxdm"
    "xdm"
    "display-manager"
    "x11"
    "alsa"
    "pulseaudio"
)

# Directories to clean (will be emptied, not removed)
DIRECTORIES_TO_CLEAN=(
    "/tmp"
    "/var/tmp"
    "/var/cache/apk"
    "/root/.cache"
    "/root/.local/share"
    "/root/.config"
)

# UI-related directories to remove completely
UI_DIRECTORIES_TO_REMOVE=(
    "/usr/share/xsessions"
    "/usr/share/applications"
    "/usr/share/desktop-directories"
    "/usr/share/icons"
    "/usr/share/pixmaps"
    "/etc/X11"
    "/root/.Xauthority"
    "/root/.xinitrc"
    "/root/.xsession"
    "/root/.xsessionrc"
)

# --- Execution Section: DO NOT MODIFY BELOW THIS LINE ---

# Setup cleanup trap for temp files and processes
TEMP_FILES=()
BACKGROUND_PIDS=()

cleanup_temp() {
    # Clean up temp files
    for file in "${TEMP_FILES[@]}"; do
        rm -f "$file" 2>/dev/null || true
    done
    
    # Kill any background processes we started
    for pid in "${BACKGROUND_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    
    # Wait for processes to finish
    wait 2>/dev/null || true
}

# Trap for cleanup on exit, error, or interrupt
trap cleanup_temp EXIT INT TERM

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Function to check if running as root
check_root() {
    if [ "$(id -u)" != "0" ]; then
        if command -v doas >/dev/null 2>&1; then
            echo "ERROR: This script must be run as root or using 'doas ./cleanup.sh'" >&2
        elif command -v sudo >/dev/null 2>&1; then
            echo "ERROR: This script must be run as root or using 'sudo ./cleanup.sh'" >&2
        else
            echo "ERROR: This script must be run as root. Install doas or sudo, or run as root user." >&2
        fi
        exit 1
    fi
}

# Function to safely remove directory
safe_remove_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        log "  -> Removing directory: $dir"
        rm -rf "$dir" 2>/dev/null || {
            log "  WARNING: Could not remove $dir (may be in use)"
            return 1
        }
        return 0
    fi
    return 0
}

# Function to safely clean directory
safe_clean_dir() {
    local dir="$1"
    if [ -d "$dir" ]; then
        log "  -> Cleaning directory: $dir"
        find "$dir" -mindepth 1 -delete 2>/dev/null || {
            log "  WARNING: Could not clean $dir completely"
            return 1
        }
        return 0
    fi
    return 0
}

log "=========================================="
log "Starting HARSH Alpine System Cleanup"
log "=========================================="
log ""

# Check for root privileges
check_root

# Verify we're on Alpine Linux
if ! command -v apk >/dev/null 2>&1; then
    log "ERROR: This script is designed for Alpine Linux (apk package manager)" >&2
    exit 1
fi

## STEP 1: Stopping and Disabling Services
log "## Step 1/7: Stopping and disabling UI-related services..."

# Kill any running UI processes first
log "  -> Stopping UI-related processes..."
pkill -x Xorg >/dev/null 2>&1 || true
pkill -x lightdm >/dev/null 2>&1 || true
pkill -x sddm >/dev/null 2>&1 || true
pkill -x gdm >/dev/null 2>&1 || true
pkill -x lxdm >/dev/null 2>&1 || true
pkill -f "desktop-session" >/dev/null 2>&1 || true
sleep 1

for service in "${SERVICES_TO_DISABLE[@]}"; do
    # Check if service exists
    if [ -f "/etc/init.d/$service" ] || [ -f "/etc/conf.d/$service" ]; then
        log "  -> Stopping service: $service"
        
        # Stop service if running (try multiple methods)
        if [ -f "/etc/init.d/$service" ]; then
            /etc/init.d/"$service" stop >/dev/null 2>&1 || true
        fi
        
        if command -v rc-service >/dev/null 2>&1; then
            rc-service "$service" stop >/dev/null 2>&1 || true
        fi
        
        # Disable service
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del "$service" >/dev/null 2>&1 || true
        fi
        
        # Remove service files
        rm -f "/etc/init.d/$service" 2>/dev/null || true
        rm -f "/etc/conf.d/$service" 2>/dev/null || true
        
        # Remove systemd service files if they exist
        rm -f "/etc/systemd/system/$service.service" 2>/dev/null || true
        rm -f "/usr/lib/systemd/system/$service.service" 2>/dev/null || true
        
        log "  ✓ Service $service stopped and disabled"
    fi
done

# Verify services are stopped
log "  -> Verifying services are stopped..."
for service in "${SERVICES_TO_DISABLE[@]}"; do
    if pgrep -f "$service" >/dev/null 2>&1; then
        log "  WARNING: Service $service may still be running"
        pkill -f "$service" >/dev/null 2>&1 || true
    fi
done

log "Service cleanup complete."
log ""

## STEP 2: Removing Users and Home Directories
log "## Step 2/7: Deleting specified users and their home directories..."
USER_COUNT=0
for user in "${USERS_TO_DELETE[@]}"; do
    if id "$user" &>/dev/null; then
        log "  -> Deleting user and home directory: $user"
        
        # Kill all processes owned by user
        pkill -u "$user" >/dev/null 2>&1 || true
        sleep 1
        
        # Remove user and home directory
        if deluser --remove-home "$user" 2>/dev/null; then
            log "  ✓ User $user deleted successfully"
            USER_COUNT=$((USER_COUNT + 1))
        else
            log "  WARNING: Failed to delete user $user completely"
        fi
    else
        log "  -> User '$user' does not exist. Skipping."
    fi
done
log "User cleanup complete. ($USER_COUNT users removed)"
log ""

## STEP 3: Removing UI-Related Packages (with dependencies)
log "## Step 3/7: Removing UI-related packages and dependencies..."
if [ ${#PACKAGES_TO_REMOVE[@]} -gt 0 ]; then
    # Create temp file for package list
    PACKAGE_LIST=$(mktemp)
    TEMP_FILES+=("$PACKAGE_LIST")
    
    # Filter to only installed packages
    INSTALLED_COUNT=0
    for pkg in "${PACKAGES_TO_REMOVE[@]}"; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            echo "$pkg" >> "$PACKAGE_LIST"
            INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
        fi
    done
    
    if [ "$INSTALLED_COUNT" -gt 0 ]; then
        log "  -> Found $INSTALLED_COUNT installed UI packages to remove"
        log "  -> Removing packages (this may take a while)..."
        
        # Remove packages with all dependencies
        if apk del --purge $(cat "$PACKAGE_LIST") 2>&1 | tee /tmp/apk-remove.log; then
            log "  ✓ Packages removed successfully"
        else
            log "  WARNING: Some packages may have failed to remove. Check /tmp/apk-remove.log"
        fi
        
        # Clean up temp log
        rm -f /tmp/apk-remove.log 2>/dev/null || true
    else
        log "  -> No specified UI packages were found installed."
    fi
    
    rm -f "$PACKAGE_LIST"
else
    log "  -> Package list is empty. Skipping package removal."
fi
log "Package removal complete."
log ""

## STEP 4: Cleaning up Orphaned Dependencies
log "## Step 4/7: Cleaning up orphaned dependencies..."
log "  -> Running 'apk autoremove' to remove unused dependencies..."
if apk autoremove >/dev/null 2>&1; then
    log "  ✓ Orphaned dependencies removed"
else
    log "  WARNING: apk autoremove had issues"
fi

log "  -> Cleaning package cache..."
apk cache clean >/dev/null 2>&1 || true
log "  ✓ Package cache cleaned"
log ""

## STEP 5: Cleaning Temporary and Cache Directories
log "## Step 5/7: Cleaning temporary and cache directories..."

# Clean each directory
for dir in "${DIRECTORIES_TO_CLEAN[@]}"; do
    safe_clean_dir "$dir"
done

# Additional cleanup
log "  -> Cleaning additional system caches..."
rm -rf /var/cache/* 2>/dev/null || true
rm -rf /root/.cache/* 2>/dev/null || true
rm -rf /root/.local/share/* 2>/dev/null || true
rm -rf /tmp/* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true

# Clean log files (keep system logs, remove UI-related)
log "  -> Cleaning UI-related log files..."
find /var/log -name "*Xorg*" -delete 2>/dev/null || true
find /var/log -name "*lightdm*" -delete 2>/dev/null || true
find /var/log -name "*gdm*" -delete 2>/dev/null || true
find /var/log -name "*sddm*" -delete 2>/dev/null || true

# Clean package manager caches
log "  -> Cleaning package manager caches..."
apk cache clean >/dev/null 2>&1 || true
rm -rf /var/cache/apk/* 2>/dev/null || true

log "Cache cleanup complete."
log ""

## STEP 6: Removing UI-Related Directories and Files
log "## Step 6/7: Removing UI-related directories and configuration files..."

# Remove directories
for dir in "${UI_DIRECTORIES_TO_REMOVE[@]}"; do
    safe_remove_dir "$dir"
done

# Remove X11 lock files and sockets
log "  -> Removing X11 lock files and sockets..."
rm -f /tmp/.X*-lock 2>/dev/null || true
rm -rf /tmp/.X11-unix 2>/dev/null || true
rm -f /tmp/.ICE-unix/* 2>/dev/null || true
rm -rf /tmp/.ICE-unix 2>/dev/null || true

# Remove desktop session files
log "  -> Removing desktop session files..."
find /usr/share/xsessions -type f -delete 2>/dev/null || true
find /etc/X11 -type f -name "*.conf" -delete 2>/dev/null || true
find /etc/X11 -type d -empty -delete 2>/dev/null || true

# Remove additional UI config files
log "  -> Removing additional UI configuration files..."
rm -rf /root/.config/xfce4 2>/dev/null || true
rm -rf /root/.config/gtk-* 2>/dev/null || true
rm -rf /root/.config/pulse 2>/dev/null || true
rm -rf /root/.config/menus 2>/dev/null || true
rm -f /root/.gtkrc* 2>/dev/null || true
rm -f /root/.Xresources 2>/dev/null || true

# Remove font caches
log "  -> Removing font caches..."
rm -rf /root/.cache/fontconfig 2>/dev/null || true
rm -rf /var/cache/fontconfig 2>/dev/null || true

log "UI directory cleanup complete."
log ""

## STEP 7: Clean up Kali tools and cool terminal tools
log "## Step 7/9: Cleaning up Kali tools and cool terminal tools..."

# Remove Kali tools symlinks from /usr/local/bin
log "  -> Removing Kali tools symlinks..."
KALI_TOOLS=(
    "nmap"
    "sqlmap"
    "john"
    "hashcat"
    "aircrack-ng"
    "tcpdump"
    "nc"
    "netcat"
    "nikto"
    "gobuster"
    "exploitdb"
    "binwalk"
    "radare2"
    "gdb"
    "strace"
    "ettercap"
    "crackmapexec"
)

KALI_REMOVED_COUNT=0
for tool in "${KALI_TOOLS[@]}"; do
    if [ -L "/usr/local/bin/$tool" ] || [ -f "/usr/local/bin/$tool" ]; then
        # Check if it's a symlink to Nix store (our installation)
        if [ -L "/usr/local/bin/$tool" ]; then
            LINK_TARGET=$(readlink -f "/usr/local/bin/$tool" 2>/dev/null || true)
            if [[ "$LINK_TARGET" == /nix/store/* ]] || [[ "$LINK_TARGET" == /tmp/* ]]; then
                rm -f "/usr/local/bin/$tool" 2>/dev/null && KALI_REMOVED_COUNT=$((KALI_REMOVED_COUNT + 1)) || true
            fi
        fi
    fi
done

if [ "$KALI_REMOVED_COUNT" -gt 0 ]; then
    log "  ✓ Removed $KALI_REMOVED_COUNT Kali tool symlinks"
else
    log "  -> No Kali tool symlinks found to remove"
fi

# Remove cool terminal tool symlinks from /usr/local/bin
log "  -> Removing cool terminal tool symlinks..."
COOL_TERMINAL_TOOLS=(
    "starship"
    "bat"
    "exa"
    "fd"
    "rg"
    "ripgrep"
    "fzf"
    "tmux"
    "zsh"
    "htop"
    "neofetch"
    "jq"
    "yq"
)

COOL_REMOVED_COUNT=0
for tool in "${COOL_TERMINAL_TOOLS[@]}"; do
    if [ -L "/usr/local/bin/$tool" ] || [ -f "/usr/local/bin/$tool" ]; then
        # Check if it's a symlink to Nix store (our installation)
        if [ -L "/usr/local/bin/$tool" ]; then
            LINK_TARGET=$(readlink -f "/usr/local/bin/$tool" 2>/dev/null || true)
            if [[ "$LINK_TARGET" == /nix/store/* ]] || [[ "$LINK_TARGET" == /tmp/* ]]; then
                rm -f "/usr/local/bin/$tool" 2>/dev/null && COOL_REMOVED_COUNT=$((COOL_REMOVED_COUNT + 1)) || true
            fi
        fi
    fi
done

if [ "$COOL_REMOVED_COUNT" -gt 0 ]; then
    log "  ✓ Removed $COOL_REMOVED_COUNT cool terminal tool symlinks"
else
    log "  -> No cool terminal tool symlinks found to remove"
fi

# Remove Starship configuration
log "  -> Removing Starship configuration..."
rm -rf /etc/starship 2>/dev/null || true
log "  ✓ Starship configuration removed"

# Remove zsh configuration
log "  -> Removing zsh configuration..."
rm -rf /etc/zsh 2>/dev/null || true
log "  ✓ Zsh configuration removed"

# Remove Kali tools and cool terminal tools from Nix profile if installed via Nix
if command -v nix >/dev/null 2>&1; then
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
    fi
    
    # Remove kali-tools from Nix profile (NixOS-style installation)
    # Handle multiple profile entries and be robust
    KALI_PROFILE_ENTRIES=$(nix profile list 2>/dev/null | grep -i "kali-tools" | awk '{print $1}' || true)
    if [ -n "$KALI_PROFILE_ENTRIES" ]; then
        log "  -> Removing kali-tools from Nix profile..."
        for entry in $KALI_PROFILE_ENTRIES; do
            nix profile remove "$entry" >/dev/null 2>&1 || true
        done
        log "  ✓ kali-tools removed from Nix profile"
    fi
    
    # Remove cool-terminal from Nix profile (NixOS-style installation)
    # Handle multiple profile entries and be robust
    COOL_PROFILE_ENTRIES=$(nix profile list 2>/dev/null | grep -i "cool-terminal" | awk '{print $1}' || true)
    if [ -n "$COOL_PROFILE_ENTRIES" ]; then
        log "  -> Removing cool-terminal from Nix profile..."
        for entry in $COOL_PROFILE_ENTRIES; do
            nix profile remove "$entry" >/dev/null 2>&1 || true
        done
        log "  ✓ cool-terminal removed from Nix profile"
    fi
fi

log "Kali tools and cool terminal tools cleanup complete."
log ""

## STEP 8: Clean up just and Nix
log "## Step 8/9: Cleaning up just and Nix..."

# Remove just command runner
log "  -> Removing just command runner..."
# Remove wrapper, symlinks, and any just binaries in /usr/local/bin
rm -f /usr/local/bin/just-wrapper 2>/dev/null || true
rm -f /usr/local/bin/just.real 2>/dev/null || true
rm -f /usr/local/bin/just 2>/dev/null || true
rm -f /usr/local/bin/justdo 2>/dev/null || true

# Remove default justfile
rm -f /usr/local/share/theblackberets/justfile 2>/dev/null || true
rmdir /usr/local/share/theblackberets 2>/dev/null || true

# Remove via apk
if apk info -e just >/dev/null 2>&1; then
    apk del just >/dev/null 2>&1 || log "  WARNING: Failed to remove just via apk"
    log "  ✓ just removed via apk"
fi

# Remove from Nix profile if installed via Nix
if command -v nix >/dev/null 2>&1; then
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    if nix profile list 2>/dev/null | grep -q "just"; then
        nix profile remove $(nix profile list 2>/dev/null | grep "just" | awk '{print $1}') >/dev/null 2>&1 || true
        log "  ✓ just removed from Nix profile"
    fi
fi

# Clean up Nix
log "  -> Cleaning up Nix..."
# Clean Nix temp files and caches
if [ -d /nix ]; then
    log "  -> Cleaning Nix temporary files..."
    rm -rf /nix/var/nix/temproots/* 2>/dev/null || true
    rm -rf /nix/var/nix/gcroots/auto/* 2>/dev/null || true
    rm -rf /tmp/nix-* 2>/dev/null || true
    
    # Stop Nix daemon
    if command -v rc-service >/dev/null 2>&1; then
        rc-service nix-daemon stop >/dev/null 2>&1 || true
        rc-update del nix-daemon >/dev/null 2>&1 || true
    elif [ -f /etc/init.d/nix-daemon ]; then
        /etc/init.d/nix-daemon stop >/dev/null 2>&1 || true
    fi
    
    # Remove from profile
    sed -i '/nix/d' /etc/profile 2>/dev/null || true
    
    # Remove config
    rm -f /etc/nix/nix.conf 2>/dev/null || true
    
    # Remove via apk
    if apk info -e nix >/dev/null 2>&1; then
        apk del nix >/dev/null 2>&1 || log "  WARNING: Failed to remove Nix via apk"
        log "  ✓ Nix package removed"
    fi
    
    # Remove store (WARNING: This removes ALL Nix packages!)
    log "  -> Removing Nix store (this removes ALL Nix packages)..."
    rm -rf /nix 2>/dev/null || true
    log "  ✓ Nix store removed"
    
    # Remove user
    if id -u nixbld >/dev/null 2>&1; then
        deluser nixbld >/dev/null 2>&1 || true
        log "  ✓ nixbld user removed"
    fi
fi

# Remove wrapper scripts and alias configurations
log "  -> Removing wrapper scripts and aliases..."
rm -f /usr/local/bin/LOCAL_AI 2>/dev/null || true
rm -f /etc/profile.d/just-alias.sh 2>/dev/null || true
rm -f /etc/profile.d/theblackberets-bashrc.sh 2>/dev/null || true
rm -f /usr/local/bin/update-user-bashrc 2>/dev/null || true

# Remove Starship initialization from bashrc config (if present)
if [ -f /etc/profile.d/theblackberets-bashrc.sh ]; then
    # Remove Starship init section
    sed -i '/# Initialize Starship prompt/,/^fi$/d' /etc/profile.d/theblackberets-bashrc.sh 2>/dev/null || true
    # Remove modern CLI aliases section
    sed -i '/# Modern CLI aliases/,/^fi$/d' /etc/profile.d/theblackberets-bashrc.sh 2>/dev/null || true
fi

log "  ✓ Wrapper scripts and aliases removed"

# Remove bashrc configuration from system files
log "  -> Removing bashrc configuration from system files..."
# Remove from /etc/skel/.bashrc (remove our specific section)
if [ -f /etc/skel/.bashrc ]; then
    sed -i '/# The Black Berets - Source system-wide bashrc configuration/,/^fi$/d' /etc/skel/.bashrc 2>/dev/null || true
    log "  ✓ Removed bashrc config from /etc/skel/.bashrc"
fi
# Remove from /root/.bashrc (remove our specific section)
if [ -f /root/.bashrc ]; then
    sed -i '/# The Black Berets - Source system-wide bashrc configuration/,/^fi$/d' /root/.bashrc 2>/dev/null || true
    log "  ✓ Removed bashrc config from /root/.bashrc"
fi

log "just and Nix cleanup complete."
log ""

## STEP 9: Final system cleanup
log "## Step 9/9: Final system cleanup..."

# Clean up any remaining temporary files
log "  -> Cleaning remaining temporary files..."
rm -rf /tmp/* 2>/dev/null || true
rm -rf /var/tmp/* 2>/dev/null || true

# Clean package cache one more time
log "  -> Final package cache cleanup..."
apk cache clean >/dev/null 2>&1 || true

log "Final cleanup complete."
log ""

# Final verification
log "=========================================="
log "Final Verification"
log "=========================================="

# Check for remaining UI processes
UI_PROCESSES=$(pgrep -af "Xorg|lightdm|sddm|gdm|desktop" 2>/dev/null | wc -l || echo "0")
if [ "$UI_PROCESSES" -gt 0 ]; then
    log "  WARNING: Found $UI_PROCESSES UI-related processes still running"
    log "  Run 'ps aux | grep -E \"(X|desktop|display)\"' to see them"
else
    log "  ✓ No UI processes detected"
fi

# Check for remaining UI packages
REMAINING_PACKAGES=$(apk info 2>/dev/null | grep -E "(xorg|xfce|gnome|kde|lightdm|sddm)" | wc -l || echo "0")
if [ "$REMAINING_PACKAGES" -gt 0 ]; then
    log "  WARNING: Found $REMAINING_PACKAGES UI-related packages still installed"
    log "  Run 'apk info | grep -E \"(xorg|xfce|gnome|kde|lightdm|sddm)\"' to see them"
else
    log "  ✓ No UI packages detected"
fi

log ""

# Final summary
log "=========================================="
log "Cleanup Summary"
log "=========================================="
log "✓ Services stopped and disabled"
log "✓ Users removed: $USER_COUNT"
log "✓ UI packages removed"
log "✓ Orphaned dependencies cleaned"
log "✓ Temporary files and caches cleaned"
log "✓ UI directories and configs removed"
log "✓ Log files cleaned"
log "✓ Cool terminal tools removed"
log "✓ just command runner removed"
log "✓ Nix package manager removed"
log ""
log "=========================================="
log "HARSH CLEANUP COMPLETED!"
log "=========================================="
log ""
log "IMPORTANT NOTES:"
log "1. Review /etc/ for any remaining UI-related configurations"
log "2. Check /etc/init.d/ and /etc/conf.d/ for any remaining services"
log "3. Verify no UI processes are running: ps aux | grep -E '(X|desktop|display)'"
log "4. Consider rebooting for a completely clean state"
log ""
log "To verify cleanup:"
log "  apk info | grep -E '(xorg|xfce|gnome|kde|lightdm|sddm)'"
log "  ls -la /etc/init.d/ | grep -E '(x|display|desktop)'"
log "  ps aux | grep -E '(X|desktop|display)'"
log ""
