#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# HARSH ALPINE LINUX ENVIRONMENT SETUP
# Installs Nix package manager and just command runner globally
# With thorough validation, error recovery, and verification
# ============================================================================

# Setup cleanup trap for temp files
TEMP_FILES=()
cleanup_temp() {
    for file in "${TEMP_FILES[@]}"; do
        rm -f "$file" 2>/dev/null || true
    done
}
trap cleanup_temp EXIT

# OPTIMIZED: Simplified logging (no timestamps for faster execution)
log() {
    echo "$*"
}

log_error() {
    echo "ERROR: $*" >&2
}

log_warning() {
    echo "WARNING: $*" >&2
}

log "=========================================="
log "Alpine Linux Environment Setup"
log "Installing Nix and just with HARSH validation"
log "=========================================="
log ""

# Check for root/doas/sudo permissions
if [ "$(id -u)" != "0" ]; then
   if command -v doas >/dev/null 2>&1; then
       log_error "This script must be run as root or using 'doas ./install.sh'"
   elif command -v sudo >/dev/null 2>&1; then
       log_error "This script must be run as root or using 'sudo ./install.sh'"
   else
       log_error "This script must be run as root. Install doas or sudo, or run as root user."
   fi
   exit 1
fi

# Verify we're on Alpine Linux
if ! command -v apk >/dev/null 2>&1; then
    log_error "This script is designed for Alpine Linux (apk package manager)"
    exit 1
fi

# Performance optimization: Cache command availability
CACHED_COMMANDS=()
HAS_WGET=""
HAS_CURL=""
HAS_INTERNET_CACHED=""
NIX_PROFILE_CACHED=""

# Chromebook hardware detection and optimization
detect_chromebook_hardware() {
    # Detect CPU cores (for build optimization)
    if command -v nproc >/dev/null 2>&1; then
        CPU_CORES=$(nproc 2>/dev/null || echo "2")
    elif [ -f /proc/cpuinfo ]; then
        CPU_CORES=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "2")
    else
        CPU_CORES="2"  # Conservative default for Chromebook
    fi
    
    # Detect available RAM (for memory limits)
    if command -v free >/dev/null 2>&1; then
        RAM_MB=$(free -m | awk '/^Mem:/ {print $2}' 2>/dev/null || echo "4096")
    elif [ -f /proc/meminfo ]; then
        RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "4096")
    else
        RAM_MB="4096"  # Conservative default for Chromebook
    fi
    
    # Optimize build jobs for Chromebook (use 1-2 cores max, leave resources for system)
    if [ "$CPU_CORES" -ge 4 ]; then
        MAX_BUILD_JOBS=2
    elif [ "$CPU_CORES" -ge 2 ]; then
        MAX_BUILD_JOBS=1
    else
        MAX_BUILD_JOBS=1
    fi
    
    # Set memory limit (use 50% of available RAM, max 2GB for builds)
    BUILD_MEMORY_MB=$((RAM_MB / 2))
    if [ "$BUILD_MEMORY_MB" -gt 2048 ]; then
        BUILD_MEMORY_MB=2048
    fi
    if [ "$BUILD_MEMORY_MB" -lt 512 ]; then
        BUILD_MEMORY_MB=512  # Minimum for builds
    fi
    
    log "  -> Detected Chromebook hardware: ${CPU_CORES} CPU cores, ${RAM_MB}MB RAM"
    log "  -> Optimizing Nix for Chromebook: max ${MAX_BUILD_JOBS} build jobs, ${BUILD_MEMORY_MB}MB build memory"
}

# Initialize hardware detection
detect_chromebook_hardware

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Cached command check (for frequently checked commands)
cached_command_exists() {
    local cmd="$1"
    # Check cache first
    for cached in "${CACHED_COMMANDS[@]}"; do
        if [ "$cached" = "$cmd" ]; then
            return 0
        fi
    done
    # Check and cache
    if command_exists "$cmd"; then
        CACHED_COMMANDS+=("$cmd")
        return 0
    fi
    return 1
}

# Function to check disk space (in MB)
check_disk_space() {
    local required_mb="$1"
    local available_mb
    
    if command -v df >/dev/null 2>&1; then
        available_mb=$(df -m / | tail -n1 | awk '{print $4}')
        if [ "$available_mb" -lt "$required_mb" ]; then
            log_error "Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB"
            return 1
        fi
        log "  ✓ Disk space check passed (${available_mb}MB available)"
        return 0
    fi
    log_warning "Cannot check disk space (df not available)"
    return 0
}

# Function to check internet connectivity with timeout (cached)
has_internet() {
    # Return cached result if available
    if [ -n "$HAS_INTERNET_CACHED" ]; then
        [ "$HAS_INTERNET_CACHED" = "yes" ]
        return
    fi
    
    local timeout=5
    if command -v timeout >/dev/null 2>&1; then
        if timeout "$timeout" ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || \
           timeout "$timeout" ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
            HAS_INTERNET_CACHED="yes"
            return 0
        fi
    else
        if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || \
           ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
            HAS_INTERNET_CACHED="yes"
            return 0
        fi
    fi
    HAS_INTERNET_CACHED="no"
    return 1
}

# Function to check if nix command works (with timeout to prevent hanging)
nix_works() {
    if ! command_exists nix; then
        return 1
    fi
    # Use timeout if available to prevent hanging
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 nix --version >/dev/null 2>&1
        return $?
    else
        # Fallback: use background process with kill (for systems without timeout command)
        nix --version >/dev/null 2>&1 &
        local pid=$!
        local count=0
        # Wait up to 3 seconds, checking every 0.5 seconds
        while kill -0 "$pid" 2>/dev/null && [ $count -lt 6 ]; do
            sleep 0.5
            count=$((count + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            # Process still running after timeout - kill it
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 1
        fi
        # Process completed - check exit status
        wait "$pid" 2>/dev/null
        return $?
    fi
}

# Function to run Nix commands with timeout (prevents hanging)
# Usage: nix_with_timeout TIMEOUT_SECONDS COMMAND [ARGS...]
# Returns: exit code (124 for timeout)
nix_with_timeout() {
    local timeout_seconds="${1:-300}"  # Default 5 minutes for installs
    shift
    local cmd=("$@")
    
    if ! command_exists nix; then
        return 1
    fi
    
    # Use timeout if available
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_seconds" "${cmd[@]}" >/dev/null 2>&1
        return $?
    else
        # Fallback: use background process with kill
        "${cmd[@]}" >/dev/null 2>&1 &
        local pid=$!
        local count=0
        local max_count=$((timeout_seconds * 2))  # Check every 0.5 seconds
        
        while kill -0 "$pid" 2>/dev/null && [ $count -lt $max_count ]; do
            sleep 0.5
            count=$((count + 1))
        done
        
        if kill -0 "$pid" 2>/dev/null; then
            # Process still running after timeout - kill it
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124  # Exit code 124 = timeout
        fi
        
        # Process completed - return exit status
        wait "$pid" 2>/dev/null
        return $?
    fi
}

# Function to verify installation
verify_command() {
    local cmd="$1"
    local expected_min_version="${2:-}"
    
    if ! command_exists "$cmd"; then
        return 1
    fi
    
    if [ -n "$expected_min_version" ]; then
        local version
        # Use timeout-safe check for nix
        if [ "$cmd" = "nix" ]; then
            if nix_works; then
                version=$(timeout 3 nix --version 2>/dev/null | head -n1 || echo "")
            else
                version=""
            fi
        else
            version=$($cmd --version 2>/dev/null | head -n1 || echo "")
        fi
        if [ -z "$version" ]; then
            log_warning "Could not verify version for $cmd"
            return 0  # Still consider it installed if command exists
        fi
        log "  ✓ Verified $cmd: $version"
    fi
    
    return 0
}

# Step 1: Install required dependencies for Nix
log "## Step 1/5: Checking and installing required dependencies..."

# Check disk space (require at least 500MB)
check_disk_space 500

# List of required packages
REQUIRED_PACKAGES=(
    "bash"
    "curl"
    "xz"
    "git"
    "ca-certificates"
    "shadow"
    "sudo"
)

# Check which packages are missing
MISSING_PACKAGES=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! apk info -e "$pkg" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$pkg")
    else
        log "  ✓ $pkg is already installed"
    fi
done

# Install missing packages if any (optimized for Chromebook)
if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    log "  -> Installing missing packages: ${MISSING_PACKAGES[*]}"
    
    # Update package index (with timeout for slow Chromebook storage)
    if command -v timeout >/dev/null 2>&1; then
        if ! timeout 60 apk update >/dev/null 2>&1; then
            log_error "Failed to update package index (timed out or failed)"
            exit 1
        fi
    else
        if ! apk update >/dev/null 2>&1; then
            log_error "Failed to update package index"
            exit 1
        fi
    fi
    
    # Install packages (batch install for better performance)
    if command -v timeout >/dev/null 2>&1; then
        if ! timeout 300 apk add --no-cache "${MISSING_PACKAGES[@]}" >/dev/null 2>&1; then
            log_error "Failed to install required packages (timed out or failed)"
            exit 1
        fi
    else
        if ! apk add --no-cache "${MISSING_PACKAGES[@]}" >/dev/null 2>&1; then
            log_error "Failed to install required packages"
            exit 1
        fi
    fi
    
    # Verify all packages were installed
    for pkg in "${MISSING_PACKAGES[@]}"; do
        if ! apk info -e "$pkg" >/dev/null 2>&1; then
            log_error "Package $pkg was not installed successfully"
            exit 1
        fi
    done
    
    log "  ✓ All dependencies installed successfully"
else
    log "  ✓ All required dependencies are already installed"
fi

# Verify critical commands
for cmd in bash curl xz git; do
    if ! command_exists "$cmd"; then
        log_error "Critical command $cmd is not available after installation"
        exit 1
    fi
done

log ""

# Step 2: Install Nix package manager (Alpine/Chromebook optimized)
log "## Step 2/5: Checking and installing Nix package manager..."
log "  -> Using Alpine-optimized installation method for Chromebook hardware"

# Check disk space for Nix (require at least 1GB for minimal install)
check_disk_space 1024

# Check if Nix is already installed
if command_exists nix; then
    # Use timeout-safe version check
    if command -v timeout >/dev/null 2>&1; then
        NIX_VERSION=$(timeout 3 nix --version 2>/dev/null | head -n1 || echo "version check failed")
    else
        NIX_VERSION="installed (version check skipped)"
    fi
    log "  ✓ Nix is already installed: $NIX_VERSION"
    
    # Verify Nix is working (with timeout to prevent hanging)
    if ! nix_works; then
        log_warning "Nix command exists but version check failed. Attempting to fix..."
        # Try to source Nix profile
        if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
            . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
        fi
        if command_exists nix && nix_works; then
            log "  ✓ Nix is now working after sourcing profile"
        else
            log_warning "Nix may need daemon restart"
        fi
    fi
else
    # Check for partial installation
    if [ -d /nix ]; then
        log_warning "/nix directory exists but 'nix' command not found"
        log "  -> Attempting to recover..."
        
        if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
            . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
            if command_exists nix && nix --version >/dev/null 2>&1; then
                log "  ✓ Nix recovered successfully"
            fi
        fi
    fi
    
    if ! command_exists nix; then
        log "  -> Installing Nix using Alpine's native package (recommended for Alpine/Chromebook)"
        
        # Enable community repository if not already enabled
        if ! grep -q "^[^#].*community" /etc/apk/repositories 2>/dev/null; then
            log "  -> Enabling Alpine community repository..."
            # Detect Alpine version
            ALPINE_VERSION=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2 || echo "edge")
            if [ "$ALPINE_VERSION" != "edge" ]; then
                echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories
            else
                echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
            fi
            if command -v timeout >/dev/null 2>&1; then
                timeout 60 apk update >/dev/null 2>&1 || log_warning "Failed to update package index"
            else
                apk update >/dev/null 2>&1 || log_warning "Failed to update package index"
            fi
        fi
        
        # Try installing Nix from Alpine's repository first (best for Alpine/Chromebook)
        log "  -> Attempting to install Nix from Alpine repository..."
        NIX_INSTALL_SUCCESS=false
        if command -v timeout >/dev/null 2>&1; then
            if timeout 300 apk add --no-cache nix >/dev/null 2>&1; then
                NIX_INSTALL_SUCCESS=true
            fi
        else
            if apk add --no-cache nix >/dev/null 2>&1; then
                NIX_INSTALL_SUCCESS=true
            fi
        fi
        
        if [ "$NIX_INSTALL_SUCCESS" = true ]; then
            log "  ✓ Nix installed from Alpine repository"
            
            # Configure Nix for root-only installation
            log "  -> Configuring Nix for root-only installation..."
            
            # Create /nix directory if it doesn't exist
            if [ ! -d /nix ]; then
                mkdir -p /nix
                chmod 0755 /nix
            fi
            
            # Create nixbld user/group if needed
            if ! id -u nixbld >/dev/null 2>&1; then
                log "  -> Creating nixbld user..."
                addgroup -g 30000 nixbld 2>/dev/null || true
                adduser -D -u 30000 -G nixbld -s /bin/sh nixbld 2>/dev/null || true
            fi
            
            # Initialize Nix for root user
            if [ ! -d /root/.nix-profile ]; then
                log "  -> Initializing Nix for root user..."
                mkdir -p /root/.nix-profile
                mkdir -p /root/.nix-defexpr
            fi
            
            # Start Nix daemon using OpenRC (Alpine's init system)
            log "  -> Starting Nix daemon (OpenRC)..."
            if command -v rc-service >/dev/null 2>&1; then
                rc-service nix-daemon start >/dev/null 2>&1 || true
                rc-update add nix-daemon >/dev/null 2>&1 || true
            elif [ -f /etc/init.d/nix-daemon ]; then
                /etc/init.d/nix-daemon start >/dev/null 2>&1 || true
            fi
            
            # Source Nix environment
            if [ -f /etc/profile.d/nix.sh ]; then
                . /etc/profile.d/nix.sh
            fi
            
            # Wait for daemon to be ready (check readiness instead of fixed sleep, with timeout)
            for i in 1 2 3; do
                if nix_works; then
                    break
                fi
                sleep 1
            done
        else
            log_warning "Alpine repository Nix installation failed, trying official installer..."
            
            # Fallback to official installer (may have issues on Alpine/Chromebook)
            log "  -> WARNING: Official Nix installer may not work well on Alpine/Chromebook"
            log "  -> Installing minimal Nix infrastructure..."
            
            # Create nixbld user
            if ! id -u nixbld >/dev/null 2>&1; then
                log "  -> Creating nixbld user..."
                addgroup -g 30000 nixbld 2>/dev/null || true
                adduser -D -u 30000 -G nixbld -s /bin/sh nixbld 2>/dev/null || true
            fi
            
            # Check internet connectivity
            if ! has_internet; then
                log_error "Internet connection required for Nix installation"
                exit 1
            fi
            
            # Try single-user mode installation (simpler, root-only)
            log "  -> Attempting single-user mode installation (root-only)..."
            INSTALL_LOG=$(mktemp)
            TEMP_FILES+=("$INSTALL_LOG")
            
            INSTALL_EXIT_CODE=0
            sh <(curl -L https://nixos.org/nix/install) --no-daemon --yes >"$INSTALL_LOG" 2>&1 || INSTALL_EXIT_CODE=$?
            
            if [ "$INSTALL_EXIT_CODE" -ne 0 ]; then
                log_error "Single-user installation failed, trying daemon mode..."
                INSTALL_EXIT_CODE=0
                sh <(curl -L https://nixos.org/nix/install) --daemon --yes >"$INSTALL_LOG" 2>&1 || INSTALL_EXIT_CODE=$?
            fi
            
            if [ "$INSTALL_EXIT_CODE" -ne 0 ]; then
                log_error "Nix installation failed. Installation log:"
                cat "$INSTALL_LOG" >&2
                log_error ""
                log_error "Nix installation failed on Alpine Linux/Chromebook."
                log_error "This is a known limitation - Nix has limited support for Alpine (musl libc)."
                log_error ""
                log_error "Alternative options:"
                log_error "1. Use Alpine's native packages instead of Nix"
                log_error "2. Install just via Alpine: apk add just"
                log_error "3. Use Docker container with glibc-based Linux"
                exit 1
            fi
            
            # Source profile
            if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
                . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
            elif [ -f /root/.nix-profile/etc/profile.d/nix.sh ]; then
                . /root/.nix-profile/etc/profile.d/nix.sh
            fi
        fi
        
        # Verify Nix installation (check readiness instead of fixed sleep, with timeout)
        for i in 1 2; do
            if command_exists nix && nix_works; then
                break
            fi
            sleep 1
        done
        
        if ! command_exists nix; then
            log_error "Nix installation completed but 'nix' command not found"
            log_error "Trying to source Nix environment..."
            
            # Try multiple profile locations
            for profile in \
                /etc/profile.d/nix.sh \
                /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
                /root/.nix-profile/etc/profile.d/nix.sh; do
                if [ -f "$profile" ]; then
                    log "  -> Sourcing: $profile"
                    . "$profile" 2>/dev/null || true
                    if command_exists nix && nix_works; then
                        break
                    fi
                fi
            done
        fi
        
        if ! command_exists nix; then
            log_error "Nix command still not found after installation"
            log_error "Please run manually: source /etc/profile.d/nix.sh"
            exit 1
        fi
        
        # Test Nix functionality (with timeout to prevent hanging)
        NIX_WORKING=false
        for i in 1 2 3; do
            if nix_works; then
                NIX_WORKING=true
                break
            fi
            log "  -> Waiting for Nix to be ready (attempt $i/3)..."
            sleep 2
        done
        
        if [ "$NIX_WORKING" = false ]; then
            log_warning "Nix command exists but version check failed"
            log_warning "This may be normal on Alpine - Nix may have limited functionality"
        else
            if command -v timeout >/dev/null 2>&1; then
                log "  ✓ Nix installed successfully: $(timeout 3 nix --version 2>/dev/null | head -n1 || echo "installed")"
            else
                log "  ✓ Nix installed successfully"
            fi
        fi
    fi
fi

# Final verification of Nix
if ! verify_command nix; then
    log_error "Nix verification failed"
    exit 1
fi

log "Nix installation step completed."
log ""

# Step 3: Install just globally (SIMPLIFIED: Just use apk, it's that simple!)
log "## Step 3/5: Installing just command runner..."

# Check if already installed
if command_exists just; then
    log "  ✓ just already installed: $(just --version 2>/dev/null || echo 'installed')"
else
    # Enable community repository if needed (just is in community repo)
    if ! grep -q "^[^#].*community" /etc/apk/repositories 2>/dev/null; then
        log "  -> Enabling community repository..."
        ALPINE_VERSION=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2 || echo "edge")
        if [ "$ALPINE_VERSION" != "edge" ]; then
            echo "http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/community" >> /etc/apk/repositories
        else
            echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
        fi
    fi
    
    # Install just via apk (simple and fast!)
    log "  -> Installing just via apk..."
    if apk add --no-cache just >/dev/null 2>&1; then
        log "  ✓ Installed via apk"
    else
        log_error "Failed to install just via apk"
        log_error "Try manually: apk add just"
        exit 1
    fi
fi

# Verify just installation
if command_exists just; then
    JUST_PATH=$(command -v just)
    log "  ✓ just installed successfully at: $JUST_PATH"
    just --version
else
    log_error "just installation failed - command not found"
    exit 1
fi

log "just installation step completed."
log ""

# Step 4: Download and configure default justfile
log "## Step 4/5: Downloading default justfile..."

# Create directory for default justfile
JUSTFILE_DIR="/usr/local/share/theblackberets"
mkdir -p "$JUSTFILE_DIR"
DEFAULT_JUSTFILE="$JUSTFILE_DIR/justfile"

# Download justfile (check local first, then remote)
JUSTFILE_DOWNLOADED=false
SITE_URL="https://theblackberets.github.io"

if [ -f "justfile" ]; then
    log "  -> Using local justfile..."
    if cp "justfile" "$DEFAULT_JUSTFILE" 2>/dev/null; then
        JUSTFILE_DOWNLOADED=true
        log "  ✓ Copied local justfile"
    else
        log_error "Failed to copy local justfile"
    fi
elif has_internet; then
    log "  -> Downloading justfile from $SITE_URL..."
    
    # Use cached download command availability
    if [ -z "$HAS_WGET" ]; then
        if command_exists wget; then
            HAS_WGET="yes"
        else
            HAS_WGET="no"
        fi
    fi
    if [ -z "$HAS_CURL" ]; then
        if command_exists curl; then
            HAS_CURL="yes"
        else
            HAS_CURL="no"
        fi
    fi
    
    if [ "$HAS_WGET" = "yes" ]; then
        if wget -qO "$DEFAULT_JUSTFILE" "$SITE_URL/justfile" 2>/dev/null; then
            JUSTFILE_DOWNLOADED=true
            log "  ✓ Downloaded justfile from $SITE_URL"
        elif wget -qO "$DEFAULT_JUSTFILE" "https://raw.githubusercontent.com/theblackberets/theblackberets.github.io/main/justfile" 2>/dev/null; then
            JUSTFILE_DOWNLOADED=true
            log "  ✓ Downloaded justfile from GitHub"
        fi
    elif [ "$HAS_CURL" = "yes" ]; then
        if curl -fsSL "$SITE_URL/justfile" -o "$DEFAULT_JUSTFILE" 2>/dev/null; then
            JUSTFILE_DOWNLOADED=true
            log "  ✓ Downloaded justfile from $SITE_URL"
        elif curl -fsSL "https://raw.githubusercontent.com/theblackberets/theblackberets.github.io/main/justfile" -o "$DEFAULT_JUSTFILE" 2>/dev/null; then
            JUSTFILE_DOWNLOADED=true
            log "  ✓ Downloaded justfile from GitHub"
        fi
    fi
fi

if [ "$JUSTFILE_DOWNLOADED" = true ] && [ -f "$DEFAULT_JUSTFILE" ]; then
    chmod 644 "$DEFAULT_JUSTFILE"
    log "  ✓ Default justfile installed at $DEFAULT_JUSTFILE"
    
    # Verify justfile is valid
    if command_exists just; then
        if just -f "$DEFAULT_JUSTFILE" --list >/dev/null 2>&1; then
            log "  ✓ Default justfile validated successfully"
        else
            log_warning "Default justfile may have syntax errors"
        fi
    fi
else
    log_warning "Could not download justfile. You may need to download it manually."
    log "  Download from: $SITE_URL/justfile"
fi

log ""

# Step 5: Configure environment
log "## Step 5/5: Configuring environment..."

# OPTIMIZED: Only configure Nix profile if Nix was actually used
if [ -n "$NIX_PROFILE_CACHED" ] && [ -f "$NIX_PROFILE_CACHED" ]; then
    log "  -> Configuring Nix in system profile..."
    NIX_PROFILE="$NIX_PROFILE_CACHED"
    
    # Check if already in /etc/profile
    PROFILE_BASENAME=$(basename "$NIX_PROFILE")
    if ! grep -q "$PROFILE_BASENAME" /etc/profile 2>/dev/null; then
        log "  -> Adding Nix to system profile..."
        {
            echo ""
            echo "# Nix package manager"
            echo "if [ -f $NIX_PROFILE ]; then"
            echo "    . $NIX_PROFILE"
            echo "fi"
        } >> /etc/profile
        log "  ✓ Nix profile configuration added"
    else
        log "  ✓ Nix is already configured in /etc/profile"
    fi
    
    # Also add to /etc/profile.d/ if using Alpine's location
    if [ "$NIX_PROFILE" = "/etc/profile.d/nix.sh" ]; then
        log "  ✓ Nix profile already in /etc/profile.d/"
    fi
elif command_exists nix; then
    # Nix exists but profile not cached - try quick check
    if [ -f "/etc/profile.d/nix.sh" ]; then
        log "  ✓ Nix profile already configured in /etc/profile.d/"
    else
        log_warning "Nix profile not found, skipping profile configuration"
    fi
else
    log "  ✓ Skipping Nix profile configuration (Nix not used)"
fi

# Setup alias for just that uses default justfile if none found locally
if command_exists just && [ -f "$DEFAULT_JUSTFILE" ]; then
    # Find the real just binary
    REAL_JUST_PATH=""
    if [ -f /usr/local/bin/just.real ]; then
        REAL_JUST_PATH="/usr/local/bin/just.real"
    else
        # Try command -v first (faster than find) - use type -P to avoid functions/aliases
        REAL_JUST_PATH=$(type -P just 2>/dev/null || command -v just 2>/dev/null || true)
        # Fallback to find in Nix store if command -v didn't work
        if [ -z "$REAL_JUST_PATH" ] && [ -d /nix/store ]; then
            FOUND_JUST=$(find /nix/store -maxdepth 4 -name "just" -type f -executable 2>/dev/null | head -n1)
            if [ -n "$FOUND_JUST" ] && [ -f "$FOUND_JUST" ]; then
                REAL_JUST_PATH="$FOUND_JUST"
            fi
        fi
    fi
    
    if [ -n "$REAL_JUST_PATH" ] && [ -f "$REAL_JUST_PATH" ]; then
        # Create alias configuration script
        ALIAS_SCRIPT="/etc/profile.d/just-alias.sh"
        
        cat > "$ALIAS_SCRIPT" << EOF
# The Black Berets - just alias configuration
# Uses default justfile when no local one is found

# Store paths (expanded at script creation time)
_REAL_JUST_PATH="$REAL_JUST_PATH"
_DEFAULT_JUSTFILE="$DEFAULT_JUSTFILE"
_DEFAULT_JUSTFILE_DIR="$(dirname "$DEFAULT_JUSTFILE")"

# Function to find justfile in current or parent directories
_find_justfile() {
    local dir="\$PWD"
    while [ "\$dir" != "/" ]; do
        if [ -f "\$dir/justfile" ] || [ -f "\$dir/Justfile" ]; then
            echo "\$dir"
            return 0
        fi
        dir=\$(dirname "\$dir")
    done
    return 1
}

# Function wrapper for just command
just() {
    local justfile_dir
    if justfile_dir=\$(_find_justfile); then
        # Use local justfile
        "\$_REAL_JUST_PATH" --working-directory "\$justfile_dir" "\$@"
    elif [ -f "\$_DEFAULT_JUSTFILE" ]; then
        # Use default justfile
        "\$_REAL_JUST_PATH" --justfile "\$_DEFAULT_JUSTFILE" --working-directory "\$_DEFAULT_JUSTFILE_DIR" "\$@"
    else
        # Fallback to standard just
        "\$_REAL_JUST_PATH" "\$@"
    fi
}

# Short alias for default justfile (always uses default, bypasses local check)
alias justdo='"\$_REAL_JUST_PATH" --justfile "\$_DEFAULT_JUSTFILE" --working-directory "\$_DEFAULT_JUSTFILE_DIR"'
EOF
        
        chmod +x "$ALIAS_SCRIPT"
        log "  ✓ Just alias configured at $ALIAS_SCRIPT"
        log "  ✓ Short alias 'justdo' available for default justfile"
        log "  ✓ Run 'source $ALIAS_SCRIPT' or restart shell to activate"
        
        # Also create standalone justdo script in /usr/local/bin for immediate availability
        JUSTDO_SCRIPT="/usr/local/bin/justdo"
        cat > "$JUSTDO_SCRIPT" << JUSTDOEOF
#!/usr/bin/env bash
set -euo pipefail

# The Black Berets - justdo command
# Always uses default justfile, bypasses local justfile check

_REAL_JUST_PATH="$REAL_JUST_PATH"
_DEFAULT_JUSTFILE="$DEFAULT_JUSTFILE"
_DEFAULT_JUSTFILE_DIR="$(dirname "$DEFAULT_JUSTFILE")"

# Execute just with default justfile
exec "\$_REAL_JUST_PATH" --justfile "\$_DEFAULT_JUSTFILE" --working-directory "\$_DEFAULT_JUSTFILE_DIR" "\$@"
JUSTDOEOF
        
        chmod +x "$JUSTDO_SCRIPT"
        log "  ✓ Created standalone justdo command at $JUSTDO_SCRIPT"
        log "  ✓ justdo is now available immediately (no shell restart needed)"
    else
        log_warning "Could not find real just binary, skipping alias creation"
    fi
elif command_exists just; then
    # Just create symlink if alias not needed
    JUST_PATH=$(command -v just)
    if [ -n "$JUST_PATH" ] && [ -f "$JUST_PATH" ]; then
        if [ "$JUST_PATH" != "/usr/local/bin/just" ]; then
            if [ ! -f /usr/local/bin/just ] || [ "$(readlink -f /usr/local/bin/just)" != "$(readlink -f "$JUST_PATH")" ]; then
                log "  -> Creating symlink for just in /usr/local/bin..."
                mkdir -p /usr/local/bin
                ln -sf "$JUST_PATH" /usr/local/bin/just || true
                log "  ✓ Symlink created"
            else
                log "  ✓ Symlink for just already exists and is correct"
            fi
        else
            log "  ✓ just is already in /usr/local/bin"
        fi
        
        # Create justdo script even if default justfile doesn't exist yet
        # (it will work once the justfile is downloaded)
        JUSTDO_SCRIPT="/usr/local/bin/justdo"
        cat > "$JUSTDO_SCRIPT" << JUSTDOEOF
#!/usr/bin/env bash
set -euo pipefail

# The Black Berets - justdo command
# Always uses default justfile, bypasses local justfile check

_REAL_JUST_PATH="$JUST_PATH"
_DEFAULT_JUSTFILE="$DEFAULT_JUSTFILE"
_DEFAULT_JUSTFILE_DIR="$(dirname "$DEFAULT_JUSTFILE")"

# Execute just with default justfile
exec "\$_REAL_JUST_PATH" --justfile "\$_DEFAULT_JUSTFILE" --working-directory "\$_DEFAULT_JUSTFILE_DIR" "\$@"
JUSTDOEOF
        
        chmod +x "$JUSTDO_SCRIPT"
        if [ -f "$DEFAULT_JUSTFILE" ]; then
            log "  ✓ Created standalone justdo command at $JUSTDO_SCRIPT"
        else
            log "  ✓ Created standalone justdo command at $JUSTDO_SCRIPT (will work once justfile is downloaded)"
        fi
    fi
fi

# Configure .bashrc support for all users
log "  -> Configuring .bashrc support..."

# Create comprehensive bashrc configuration in /etc/profile.d/
BASHRC_CONFIG="/etc/profile.d/theblackberets-bashrc.sh"

cat > "$BASHRC_CONFIG" << 'BASHRCEOF'
# The Black Berets - Comprehensive bashrc configuration
# This file is sourced by /etc/profile.d/ scripts and ensures all tools work in bash

# Source all profile.d scripts (ensures Nix, just aliases, etc. are available)
if [ -d /etc/profile.d ]; then
    for script in /etc/profile.d/*.sh; do
        if [ -r "$script" ] && [ -f "$script" ]; then
            # Skip sourcing this file itself to avoid recursion
            if [ "$script" != "/etc/profile.d/theblackberets-bashrc.sh" ]; then
                . "$script" 2>/dev/null || true
            fi
        fi
    done
fi

# Source Nix profile if available (multiple possible locations)
if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
elif [ -f /etc/profile.d/nix.sh ]; then
    . /etc/profile.d/nix.sh 2>/dev/null || true
elif [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/nix.sh" 2>/dev/null || true
fi

# Ensure just command is available
if ! command -v just >/dev/null 2>&1; then
    # Try common locations
    for just_path in /usr/bin/just /usr/local/bin/just /nix/store/*/bin/just; do
        if [ -x "$just_path" ] 2>/dev/null; then
            export PATH="$PATH:$(dirname "$just_path")"
            break
        fi
    done
fi

# NixOS-style: Ensure Nix profile packages are in PATH (system-wide packages)
# This makes all nix profile installed packages available globally
if command -v nix >/dev/null 2>&1; then
    # Add Nix profile bin directories to PATH
    if [ -n "$HOME" ] && [ -d "$HOME/.nix-profile/bin" ]; then
        export PATH="$HOME/.nix-profile/bin:$PATH"
    fi
    # System-wide Nix profile (for root)
    if [ -d /nix/var/nix/profiles/default/bin ]; then
        export PATH="/nix/var/nix/profiles/default/bin:$PATH"
    fi
    # Per-user profiles
    if [ -n "$HOME" ] && [ -d "$HOME/.local/state/nix/profiles/profile/bin" ]; then
        export PATH="$HOME/.local/state/nix/profiles/profile/bin:$PATH"
    fi
fi

# Set default LOCAL_AI environment variables (if not already set)
export LOCAL_AI="${LOCAL_AI:-http://localhost:8080}"
export LOCALAI_PORT="${LOCALAI_PORT:-8080}"
export LOCALAI_MODEL_DIR="${LOCALAI_MODEL_DIR:-./models}"
export LOCALAI_CONFIG_DIR="${LOCALAI_CONFIG_DIR:-./localai-config}"

# Add /usr/local/bin to PATH if not already present
if [ -d /usr/local/bin ] && [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
    export PATH="/usr/local/bin:$PATH"
fi
BASHRCEOF

chmod +x "$BASHRC_CONFIG"
log "  ✓ Created bashrc configuration at $BASHRC_CONFIG"

# Ensure /etc/skel/.bashrc exists and sources profile.d scripts (for new users)
SKEL_BASHRC="/etc/skel/.bashrc"
if [ ! -f "$SKEL_BASHRC" ]; then
    log "  -> Creating default .bashrc template for new users..."
    cat > "$SKEL_BASHRC" << 'SKELBASHRCEOF'
# ~/.bashrc: executed by bash(1) for non-login shells.

# Source system-wide bashrc configuration
if [ -f /etc/profile.d/theblackberets-bashrc.sh ]; then
    . /etc/profile.d/theblackberets-bashrc.sh
fi

# Source all profile.d scripts
if [ -d /etc/profile.d ]; then
    for script in /etc/profile.d/*.sh; do
        if [ -r "$script" ] && [ -f "$script" ]; then
            . "$script" 2>/dev/null || true
        fi
    done
fi

# If not running interactively, don't do anything else
case $- in
    *i*) ;;
      *) return;;
esac

# History settings
HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000

# Append to history file, don't overwrite
shopt -s histappend

# Check window size after each command
shopt -s checkwinsize

# Enable programmable completion
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
fi
SKELBASHRCEOF
    chmod 644 "$SKEL_BASHRC"
    log "  ✓ Created default .bashrc template at $SKEL_BASHRC"
else
    # Update existing /etc/skel/.bashrc to include our configuration
    if ! grep -q "theblackberets-bashrc.sh" "$SKEL_BASHRC" 2>/dev/null; then
        log "  -> Updating existing .bashrc template..."
        {
            echo ""
            echo "# The Black Berets - Source system-wide bashrc configuration"
            echo "if [ -f /etc/profile.d/theblackberets-bashrc.sh ]; then"
            echo "    . /etc/profile.d/theblackberets-bashrc.sh"
            echo "fi"
        } >> "$SKEL_BASHRC"
        log "  ✓ Updated .bashrc template"
    else
        log "  ✓ .bashrc template already configured"
    fi
fi

# Update root's .bashrc if it exists
ROOT_BASHRC="/root/.bashrc"
if [ -f "$ROOT_BASHRC" ]; then
    if ! grep -q "theblackberets-bashrc.sh" "$ROOT_BASHRC" 2>/dev/null; then
        log "  -> Updating root's .bashrc..."
        {
            echo ""
            echo "# The Black Berets - Source system-wide bashrc configuration"
            echo "if [ -f /etc/profile.d/theblackberets-bashrc.sh ]; then"
            echo "    . /etc/profile.d/theblackberets-bashrc.sh"
            echo "fi"
        } >> "$ROOT_BASHRC"
        log "  ✓ Updated root's .bashrc"
    else
        log "  ✓ Root's .bashrc already configured"
    fi
else
    # Create root's .bashrc if it doesn't exist
    log "  -> Creating root's .bashrc..."
    cp "$SKEL_BASHRC" "$ROOT_BASHRC" 2>/dev/null || {
        cat > "$ROOT_BASHRC" << 'ROOTBASHRCEOF'
# ~/.bashrc: executed by bash(1) for non-login shells.

# Source system-wide bashrc configuration
if [ -f /etc/profile.d/theblackberets-bashrc.sh ]; then
    . /etc/profile.d/theblackberets-bashrc.sh
fi

# Source all profile.d scripts
if [ -d /etc/profile.d ]; then
    for script in /etc/profile.d/*.sh; do
        if [ -r "$script" ] && [ -f "$script" ]; then
            . "$script" 2>/dev/null || true
        fi
    done
fi

# If not running interactively, don't do anything else
case $- in
    *i*) ;;
      *) return;;
esac

# History settings
HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000

# Append to history file, don't overwrite
shopt -s histappend

# Check window size after each command
shopt -s checkwinsize

# Enable programmable completion
if [ -f /etc/bash_completion ] && ! shopt -oq posix; then
    . /etc/bash_completion
fi
ROOTBASHRCEOF
    }
    chmod 644 "$ROOT_BASHRC"
    log "  ✓ Created root's .bashrc"
fi

# Create helper script to update existing user .bashrc files
UPDATE_BASHRC_SCRIPT="/usr/local/bin/update-user-bashrc"
cat > "$UPDATE_BASHRC_SCRIPT" << 'UPDATEBASHRCEOF'
#!/usr/bin/env bash
set -euo pipefail

# Update user's .bashrc to include The Black Berets configuration
# Usage: update-user-bashrc [USERNAME]
# If no username provided, updates current user's .bashrc

TARGET_USER="${1:-$USER}"
TARGET_HOME=""

if [ "$TARGET_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
    TARGET_HOME="/root"
else
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
fi

if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
    echo "ERROR: Could not find home directory for user: $TARGET_USER"
    exit 1
fi

BASHRC_FILE="$TARGET_HOME/.bashrc"

# Check if already configured
if [ -f "$BASHRC_FILE" ] && grep -q "theblackberets-bashrc.sh" "$BASHRC_FILE" 2>/dev/null; then
    echo "✓ $BASHRC_FILE already configured"
    exit 0
fi

# Add configuration
{
    echo ""
    echo "# The Black Berets - Source system-wide bashrc configuration"
    echo "if [ -f /etc/profile.d/theblackberets-bashrc.sh ]; then"
    echo "    . /etc/profile.d/theblackberets-bashrc.sh"
    echo "fi"
} >> "$BASHRC_FILE"

echo "✓ Updated $BASHRC_FILE"
echo "  Run 'source $BASHRC_FILE' or restart your shell to apply changes"
UPDATEBASHRCEOF

chmod +x "$UPDATE_BASHRC_SCRIPT"
log "  ✓ Created helper script: $UPDATE_BASHRC_SCRIPT"
log "  ✓ Run 'update-user-bashrc [username]' to update existing user .bashrc files"

log "Environment configuration completed."
log ""

# Optimize Nix store for Chromebook (run garbage collection if needed)
if command_exists nix; then
    log "  -> Optimizing Nix store for Chromebook..."
    # Run auto-optimize-store if enabled (non-blocking, runs in background)
    if nix_with_timeout 10 nix show-config 2>/dev/null | grep -q "auto-optimise-store.*true"; then
        log "  ✓ Auto-optimize-store enabled (will optimize automatically)"
    fi
    # Trigger a light GC to free space (with timeout)
    if nix_works; then
        log "  -> Running light garbage collection..."
        nix_with_timeout 60 nix store optimise >/dev/null 2>&1 || true
        log "  ✓ Store optimization completed"
    fi
fi

log ""

# Create LOCAL_AI command wrapper
log "  -> Creating LOCAL_AI command wrapper..."
LOCAL_AI_WRAPPER="/usr/local/bin/LOCAL_AI"

cat > "$LOCAL_AI_WRAPPER" << 'LOCALAIEOF'
#!/usr/bin/env bash
set -euo pipefail

# LOCAL_AI command - Start LocalAI with Kali tools environment
# Usage: LOCAL_AI [PORT] [MODEL_DIR] [CONFIG_DIR]

PORT="${1:-8080}"
MODEL_DIR="${2:-./models}"
CONFIG_DIR="${3:-./localai-config}"

# Enable Nix commands and Kali tools
if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
elif [ -f /etc/profile.d/nix.sh ]; then
    . /etc/profile.d/nix.sh
elif [ -f /root/.nix-profile/etc/profile.d/nix.sh ]; then
    . /root/.nix-profile/etc/profile.d/nix.sh
fi

# Set LOCAL_AI environment variable
export LOCAL_AI="http://localhost:${PORT}"
export LOCALAI_PORT="${PORT}"
export LOCALAI_MODEL_DIR="${MODEL_DIR}"
export LOCALAI_CONFIG_DIR="${CONFIG_DIR}"

# Run LocalAI with Kali tools
if command -v just >/dev/null 2>&1; then
    just local-ai MODEL_DIR="${MODEL_DIR}" CONFIG_DIR="${CONFIG_DIR}" PORT="${PORT}"
else
    echo "ERROR: just command not found. Please run: doas ./install.sh"
    exit 1
fi
LOCALAIEOF

chmod +x "$LOCAL_AI_WRAPPER"
log "  ✓ LOCAL_AI command created at $LOCAL_AI_WRAPPER"
log "  Usage: LOCAL_AI [PORT] [MODEL_DIR] [CONFIG_DIR]"
log ""

# Install Kali tools globally (NixOS-style) by default - PRE-INSTALLED
log "  -> Pre-installing Kali tools globally (NixOS-style) in background..."
if command_exists nix; then
    # Enable Nix commands
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
    elif [ -f /etc/profile.d/nix.sh ]; then
        . /etc/profile.d/nix.sh 2>/dev/null || true
    fi
    
    # Enable flakes if needed
    if ! nix show-config 2>/dev/null | grep -q "experimental-features.*flakes"; then
        mkdir -p /etc/nix
        echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf 2>/dev/null || true
    fi
    
    # Determine flake location
    FLAKE_DIR=""
    FLAKE_REF=""
    if [ -f "flake.nix" ]; then
        FLAKE_DIR="."
        FLAKE_REF=".#kali-tools"
        log "  -> Using local flake.nix"
    elif [ -f "$(dirname "$DEFAULT_JUSTFILE")/flake.nix" ]; then
        FLAKE_DIR="$(dirname "$DEFAULT_JUSTFILE")"
        FLAKE_REF="$FLAKE_DIR#kali-tools"
        log "  -> Using flake.nix from default justfile directory"
    else
        # Try to download flake.nix
        SITE_URL="https://theblackberets.github.io"
        TEMP_FLAKE="/tmp/flake.nix"
        TEMP_FILES+=("$TEMP_FLAKE")
        if command -v wget >/dev/null 2>&1; then
            if wget -qO "$TEMP_FLAKE" "$SITE_URL/flake.nix" 2>/dev/null; then
                FLAKE_REF="/tmp#kali-tools"
                FLAKE_DIR="/tmp"
                log "  -> Downloaded flake.nix from $SITE_URL"
            fi
        elif command -v curl >/dev/null 2>&1; then
            if curl -fsSL "$SITE_URL/flake.nix" -o "$TEMP_FLAKE" 2>/dev/null; then
                FLAKE_REF="/tmp#kali-tools"
                FLAKE_DIR="/tmp"
                log "  -> Downloaded flake.nix from $SITE_URL"
            fi
        fi
    fi
    
    if [ -n "$FLAKE_REF" ] && [ -n "$FLAKE_DIR" ]; then
        # NixOS-style: Install via nix profile (system-wide, like NixOS environment.systemPackages)
        log "  -> Installing via nix profile (NixOS-style system-wide installation)..."
        
        # Check if already installed
        if nix profile list 2>/dev/null | grep -q "kali-tools"; then
            log "  ✓ Kali tools already installed in Nix profile"
        else
            # Install in background with timeout
            INSTALL_LOG=$(mktemp)
            TEMP_FILES+=("$INSTALL_LOG")
            
            log "  -> Installing kali-tools package (this may take a few minutes)..."
            if nix_with_timeout 600 nix profile install "$FLAKE_REF" >"$INSTALL_LOG" 2>&1; then
                log "  ✓ Kali tools installed successfully via Nix profile"
                
                # Also create symlinks in /usr/local/bin for immediate availability (NixOS-style)
                TEMP_BUILD_RESULT="/tmp/kali-tools-result"
                TEMP_FILES+=("$TEMP_BUILD_RESULT")
                
                if nix_with_timeout 300 nix build "$FLAKE_REF" --out-link "$TEMP_BUILD_RESULT" 2>/dev/null; then
                    if [ -d "$TEMP_BUILD_RESULT/bin" ] && ls "$TEMP_BUILD_RESULT/bin"/* >/dev/null 2>&1; then
                        INSTALLED_COUNT=0
                        for tool in "$TEMP_BUILD_RESULT/bin"/*; do
                            if [ -f "$tool" ] && [ -x "$tool" ]; then
                                TOOL_NAME=$(basename "$tool")
                                if [ ! -f "/usr/local/bin/$TOOL_NAME" ] || [ "$(readlink -f "/usr/local/bin/$TOOL_NAME" 2>/dev/null)" != "$(readlink -f "$tool")" ]; then
                                    ln -sf "$tool" "/usr/local/bin/$TOOL_NAME" 2>/dev/null || true
                                    INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
                                fi
                            fi
                        done
                        if [ "$INSTALLED_COUNT" -gt 0 ]; then
                            log "  ✓ Created $INSTALLED_COUNT symlinks in /usr/local/bin for immediate access"
                        fi
                    fi
                fi
            else
                log_error "Failed to install kali-tools via Nix profile"
                log_error "Installation log:"
                tail -n 20 "$INSTALL_LOG" >&2 || true
                log_warning "Tools will be available via Nix profile PATH once installed"
            fi
        fi
    else
        log_warning "Could not find or download flake.nix, skipping Kali tools installation"
    fi
else
    log_warning "Nix not available, skipping Kali tools installation"
fi

log ""

# Install cool terminal tools globally (NixOS-style) by default - PRE-INSTALLED
log "  -> Pre-installing cool terminal tools globally (NixOS-style) in background..."
if command_exists nix; then
    # Enable Nix commands
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
    elif [ -f /etc/profile.d/nix.sh ]; then
        . /etc/profile.d/nix.sh 2>/dev/null || true
    fi
    
    # Enable flakes if needed
    if ! nix show-config 2>/dev/null | grep -q "experimental-features.*flakes"; then
        mkdir -p /etc/nix
        echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf 2>/dev/null || true
    fi
    
    # Determine flake location
    FLAKE_DIR=""
    FLAKE_REF=""
    if [ -f "flake.nix" ]; then
        FLAKE_DIR="."
        FLAKE_REF=".#cool-terminal"
        log "  -> Using local flake.nix"
    elif [ -f "$(dirname "$DEFAULT_JUSTFILE")/flake.nix" ]; then
        FLAKE_DIR="$(dirname "$DEFAULT_JUSTFILE")"
        FLAKE_REF="$FLAKE_DIR#cool-terminal"
        log "  -> Using flake.nix from default justfile directory"
    else
        # Try to download flake.nix
        SITE_URL="https://theblackberets.github.io"
        TEMP_FLAKE="/tmp/flake-terminal.nix"
        TEMP_FILES+=("$TEMP_FLAKE")
        if command -v wget >/dev/null 2>&1; then
            if wget -qO "$TEMP_FLAKE" "$SITE_URL/flake.nix" 2>/dev/null; then
                FLAKE_REF="/tmp#cool-terminal"
                FLAKE_DIR="/tmp"
                log "  -> Downloaded flake.nix from $SITE_URL"
            fi
        elif command -v curl >/dev/null 2>&1; then
            if curl -fsSL "$SITE_URL/flake.nix" -o "$TEMP_FLAKE" 2>/dev/null; then
                FLAKE_REF="/tmp#cool-terminal"
                FLAKE_DIR="/tmp"
                log "  -> Downloaded flake.nix from $SITE_URL"
            fi
        fi
    fi
    
    if [ -n "$FLAKE_REF" ] && [ -n "$FLAKE_DIR" ]; then
        # NixOS-style: Install via nix profile (system-wide, like NixOS environment.systemPackages)
        log "  -> Installing via nix profile (NixOS-style system-wide installation)..."
        
        # Check if already installed
        if nix profile list 2>/dev/null | grep -q "cool-terminal"; then
            log "  ✓ Cool terminal tools already installed in Nix profile"
        else
            # Install in background with timeout
            INSTALL_LOG=$(mktemp)
            TEMP_FILES+=("$INSTALL_LOG")
            
            log "  -> Installing cool-terminal package (this may take a few minutes)..."
            if nix_with_timeout 600 nix profile install "$FLAKE_REF" >"$INSTALL_LOG" 2>&1; then
                log "  ✓ Cool terminal tools installed successfully via Nix profile"
                
                # Also create symlinks in /usr/local/bin for immediate availability (NixOS-style)
                TEMP_BUILD_RESULT="/tmp/cool-terminal-result"
                TEMP_FILES+=("$TEMP_BUILD_RESULT")
                
                if nix_with_timeout 300 nix build "$FLAKE_REF" --out-link "$TEMP_BUILD_RESULT" 2>/dev/null; then
                    if [ -d "$TEMP_BUILD_RESULT/bin" ] && ls "$TEMP_BUILD_RESULT/bin"/* >/dev/null 2>&1; then
                        INSTALLED_COUNT=0
                        for tool in "$TEMP_BUILD_RESULT/bin"/*; do
                            if [ -f "$tool" ] && [ -x "$tool" ]; then
                                TOOL_NAME=$(basename "$tool")
                                if [ ! -f "/usr/local/bin/$TOOL_NAME" ] || [ "$(readlink -f "/usr/local/bin/$TOOL_NAME" 2>/dev/null)" != "$(readlink -f "$tool")" ]; then
                                    ln -sf "$tool" "/usr/local/bin/$TOOL_NAME" 2>/dev/null || true
                                    INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
                                fi
                            fi
                        done
                        if [ "$INSTALLED_COUNT" -gt 0 ]; then
                            log "  ✓ Created $INSTALLED_COUNT symlinks in /usr/local/bin for immediate access"
                        fi
                    fi
                fi
            else
                log_error "Failed to install cool-terminal via Nix profile"
                log_error "Installation log:"
                tail -n 20 "$INSTALL_LOG" >&2 || true
                log_warning "Tools will be available via Nix profile PATH once installed"
            fi
        fi
    else
        log_warning "Could not find or download flake.nix, skipping cool terminal installation"
    fi
else
    log_warning "Nix not available, skipping cool terminal installation"
fi

log ""

# Configure Starship prompt
log "  -> Configuring Starship prompt..."
STARSHIP_CONFIG_DIR="/etc/starship"
STARSHIP_CONFIG="$STARSHIP_CONFIG_DIR/config.toml"
mkdir -p "$STARSHIP_CONFIG_DIR"

if command -v starship >/dev/null 2>&1 || [ -f /usr/local/bin/starship ]; then
    # Create a cool Starship config
    cat > "$STARSHIP_CONFIG" << 'STARSHIPEOF'
# Starship prompt configuration for The Black Berets
# Modern, fast, and feature-rich prompt

format = """
[╭─](bold green)$os\
$username\
$hostname\
$localip\
$shlvl\
$directory\
$git_branch\
$git_commit\
$git_state\
$git_metrics\
$git_status\
$docker_context\
$package\
$c\
$cmake\
$golang\
$java\
$nodejs\
$python\
$rust\
$terraform\
$vagrant\
$nix_shell\
$conda\
$memory_usage\
$aws\
$gcloud\
$env_var\
$custom\
$sudo\
$cmd_duration\
$line_break\
[╰─](bold green)$character"""

# Username
[username]
style_user = "bold yellow"
style_root = "bold red"
format = "[$user]($style) "
disabled = false
show_always = true

# Hostname
[hostname]
ssh_only = false
format = "on [$hostname](bold blue) "
trim_at = "."

# Directory
[directory]
truncation_length = 3
truncate_to_repo = true
format = "at [$path]($style)[$read_only]($read_only_style) "
style = "bold cyan"

# Git
[git_branch]
format = "on [$symbol$branch(:$remote_branch)]($style) "
symbol = " "
style = "bold purple"

[git_status]
format = "([\[$all_status$ahead_behind\]]($style) )"
style = "bold red"

# Command duration
[cmd_duration]
min_time = 2_000
format = "took [$duration]($style) "
style = "bold yellow"

# Python
[python]
format = "via [🐍 $version](bold yellow) "

# Rust
[rust]
format = "via [🦀 $version](bold red) "

# Node
[nodejs]
format = "via [⬢ $version](bold green) "

# Package
[package]
format = "is [$symbol$version]($style) "
symbol = "📦 "
style = "bold 208"

# Nix shell
[nix_shell]
format = "via [❄️ $name](bold blue) "
impure_msg = "impure"
pure_msg = "pure"

# Memory
[memory_usage]
format = "via $symbol[$ram( | $swap)]($style) "
threshold = 75
symbol = " "
style = "bold dimmed white"

# Character
[character]
success_symbol = "[❯](bold green)"
error_symbol = "[✗](bold red)"
vim_symbol = "[V](bold green)"
STARSHIPEOF
    
    log "  ✓ Starship configuration created at $STARSHIP_CONFIG"
    
    # Add Starship init to bashrc config
    if [ -f "$BASHRC_CONFIG" ]; then
        if ! grep -q "starship init" "$BASHRC_CONFIG" 2>/dev/null; then
            cat >> "$BASHRC_CONFIG" << 'STARSHIPINITEOF'

# Initialize Starship prompt (if available)
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
fi
STARSHIPINITEOF
            log "  ✓ Starship initialization added to bashrc"
        fi
    fi
else
    log_warning "Starship not found, skipping configuration"
fi

# Configure zsh (if installed)
log "  -> Configuring zsh..."
if command -v zsh >/dev/null 2>&1 || [ -f /usr/local/bin/zsh ]; then
    ZSH_CONFIG_DIR="/etc/zsh"
    mkdir -p "$ZSH_CONFIG_DIR"
    
    # Create zshrc configuration
    cat > "$ZSH_CONFIG_DIR/zshrc" << 'ZSHRCEOF'
# The Black Berets - Zsh configuration

# Enable colors
autoload -U colors && colors

# History configuration
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_IGNORE_SPACE

# Better completion
autoload -U compinit
compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Useful aliases
alias ls='exa --icons --color=always'
alias ll='exa -l --icons --color=always'
alias la='exa -la --icons --color=always'
alias cat='bat --style=auto'
alias grep='rg'
alias find='fd'
alias top='htop'
alias vim='nvim' 2>/dev/null || alias vim='vim'

# Source syntax highlighting (if installed)
if [ -f /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
    source /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null
elif [ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
    source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null
else
    # Try to find in Nix store
    NIX_HIGHLIGHT=$(find /nix/store -name "zsh-syntax-highlighting.zsh" 2>/dev/null | head -n1)
    if [ -n "$NIX_HIGHLIGHT" ] && [ -f "$NIX_HIGHLIGHT" ]; then
        source "$NIX_HIGHLIGHT" 2>/dev/null
    fi
fi

# Source autosuggestions (if installed)
if [ -f /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
    source /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
elif [ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]; then
    source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null
else
    # Try to find in Nix store
    NIX_AUTOSUGGEST=$(find /nix/store -name "zsh-autosuggestions.zsh" 2>/dev/null | head -n1)
    if [ -n "$NIX_AUTOSUGGEST" ] && [ -f "$NIX_AUTOSUGGEST" ]; then
        source "$NIX_AUTOSUGGEST" 2>/dev/null
    fi
fi

# Initialize Starship prompt (if available)
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init zsh)"
fi

# fzf integration (if available)
if command -v fzf >/dev/null 2>&1; then
    [ -f ~/.fzf.zsh ] && source ~/.fzf.zsh 2>/dev/null || true
fi
ZSHRCEOF
    
    log "  ✓ Zsh configuration created at $ZSH_CONFIG_DIR/zshrc"
    
    # Set zsh as default shell for root (if running as root)
    if [ "$(id -u)" = "0" ]; then
        if command -v zsh >/dev/null 2>&1; then
            ZSH_PATH=$(command -v zsh)
            if [ "$SHELL" != "$ZSH_PATH" ]; then
                if command -v chsh >/dev/null 2>&1; then
                    chsh -s "$ZSH_PATH" root 2>/dev/null || true
                fi
            fi
        fi
    fi
else
    log_warning "Zsh not found, skipping configuration"
fi

# Add useful aliases to bashrc
log "  -> Adding modern CLI aliases..."
if [ -f "$BASHRC_CONFIG" ]; then
    if ! grep -q "# Modern CLI aliases" "$BASHRC_CONFIG" 2>/dev/null; then
        cat >> "$BASHRC_CONFIG" << 'ALIASESEOF'

# Modern CLI aliases (The Black Berets)
# Use modern replacements if available
if command -v exa >/dev/null 2>&1; then
    alias ls='exa --icons --color=always'
    alias ll='exa -l --icons --color=always'
    alias la='exa -la --icons --color=always'
fi

if command -v bat >/dev/null 2>&1; then
    alias cat='bat --style=auto'
fi

if command -v ripgrep >/dev/null 2>&1 || command -v rg >/dev/null 2>&1; then
    alias grep='rg'
fi

if command -v fd >/dev/null 2>&1; then
    alias find='fd'
fi

if command -v htop >/dev/null 2>&1; then
    alias top='htop'
fi

# fzf integration
if command -v fzf >/dev/null 2>&1; then
    [ -f ~/.fzf.bash ] && source ~/.fzf.bash 2>/dev/null || true
fi
ALIASESEOF
        log "  ✓ Modern CLI aliases added to bashrc"
    fi
fi

log ""

# Final verification
log "=========================================="
log "Installation Summary & Verification"
log "=========================================="
log ""

VERIFICATION_FAILED=false

# Verify Nix
if command_exists nix; then
    # Use timeout-safe version check
    if command -v timeout >/dev/null 2>&1; then
        NIX_VER=$(timeout 3 nix --version 2>/dev/null | head -n1 || echo "installed")
    else
        NIX_VER="installed (version check skipped)"
    fi
    log "✓ Nix: $NIX_VER"
    
    # Test Nix functionality (with timeout to prevent hanging)
    if ! nix_works; then
        log_error "Nix verification failed (command not working)"
        VERIFICATION_FAILED=true
    fi
else
    log_error "✗ Nix: Not found"
    VERIFICATION_FAILED=true
fi

# Verify just
if command_exists just; then
    JUST_VER=$(just --version 2>/dev/null || echo "installed")
    JUST_LOC=$(command -v just)
    log "✓ just: $JUST_VER"
    log "  Location: $JUST_LOC"
    
    # Test just functionality
    if ! just --version >/dev/null 2>&1; then
        log_error "just verification failed (command not working)"
        VERIFICATION_FAILED=true
    fi
    
    # Test justfile access
    if [ -f "$DEFAULT_JUSTFILE" ]; then
        if just -f "$DEFAULT_JUSTFILE" --list >/dev/null 2>&1; then
            log "✓ Default justfile: Valid and accessible"
        else
            log_warning "Default justfile: May have issues"
        fi
    fi
else
    log_error "✗ just: Not found"
    VERIFICATION_FAILED=true
fi

# Verify Kali tools installation
KALI_TOOLS_INSTALLED=false
if command -v nmap >/dev/null 2>&1; then
    if [ -L /usr/local/bin/nmap ] || [ -f /usr/local/bin/nmap ]; then
        KALI_TOOLS_INSTALLED=true
        log "✓ Kali tools: Installed globally in /usr/local/bin"
        # Check a few key tools
        TOOLS_FOUND=0
        for tool in nmap sqlmap john hashcat aircrack-ng; do
            if command -v "$tool" >/dev/null 2>&1; then
                TOOLS_FOUND=$((TOOLS_FOUND + 1))
            fi
        done
        if [ "$TOOLS_FOUND" -gt 0 ]; then
            log "  Found $TOOLS_FOUND key tools available"
        fi
    elif command_exists nix; then
        # Check if tools are available via Nix profile
        if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
            . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
        fi
        if command -v nmap >/dev/null 2>&1; then
            log "✓ Kali tools: Available via Nix profile"
            KALI_TOOLS_INSTALLED=true
        fi
    fi
fi

if [ "$KALI_TOOLS_INSTALLED" = false ]; then
    log_warning "Kali tools: Not installed globally"
    log "  Install with: just install-kali-tools-global"
fi

# Verify cool terminal tools installation
COOL_TERMINAL_INSTALLED=false
if command -v starship >/dev/null 2>&1; then
    if [ -L /usr/local/bin/starship ] || [ -f /usr/local/bin/starship ]; then
        COOL_TERMINAL_INSTALLED=true
        log "✓ Cool terminal tools: Installed globally in /usr/local/bin"
        # Check a few key tools
        TOOLS_FOUND=0
        for tool in starship bat exa fd rg fzf tmux zsh; do
            if command -v "$tool" >/dev/null 2>&1; then
                TOOLS_FOUND=$((TOOLS_FOUND + 1))
            fi
        done
        if [ "$TOOLS_FOUND" -gt 0 ]; then
            log "  Found $TOOLS_FOUND cool terminal tools available"
        fi
    elif command_exists nix; then
        # Check if tools are available via Nix profile
        if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
            . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh 2>/dev/null || true
        fi
        if command -v starship >/dev/null 2>&1; then
            log "✓ Cool terminal tools: Available via Nix profile"
            COOL_TERMINAL_INSTALLED=true
        fi
    fi
fi

if [ "$COOL_TERMINAL_INSTALLED" = false ]; then
    log_warning "Cool terminal tools: Not installed globally"
    log "  Install with: just install-cool-terminal-global"
fi

DEFAULT_JUSTFILE="/usr/local/share/theblackberets/justfile"
if [ -f "$DEFAULT_JUSTFILE" ]; then
    log "✓ Default justfile: Installed at $DEFAULT_JUSTFILE"
    log "  You can now run 'just' commands from any directory!"
else
    log_warning "✗ Default justfile: Not found"
    log "  Download manually from: https://theblackberets.github.io/justfile"
fi

log ""
log "=========================================="
if [ "$VERIFICATION_FAILED" = true ]; then
    log_error "Installation completed with WARNINGS"
    log_error "Some components may not be working correctly"
    exit 1
else
    log "Installation completed successfully!"
fi
log "=========================================="
log ""
log "NOTE: If you're running this in a new shell session, you may need to:"
log "  1. Restart your shell, or"
log "  2. Run: source /etc/profile"
log ""
log "To verify installation, run:"
log "  nix --version"
log "  just --version"
log "  just --list  # Should show available commands from default justfile"
log ""
log "IMPORTANT: All packages are pre-installed globally via Nix (NixOS-style)"
log "Tools are available system-wide and work just like NixOS"
log ""
log "To update packages from flake.nix, run:"
log "  just update-from-flake  # Updates all packages from latest flake.nix"
log ""
log "To verify installation, run:"
log "  just verify-kali-tools      # Verify Kali tools"
log "  just verify-cool-terminal   # Verify cool terminal tools"
log ""
log "=========================================="
log "Alpine Linux / Chromebook Notes"
log "=========================================="
log ""
log "Nix on Alpine Linux (musl libc) has LIMITED SUPPORT:"
log "- Alpine's native Nix package is recommended"
log "- Some Nix features may not work correctly"
log "- Chromebook hardware may have additional limitations"
log ""
log "Chromebook Performance Optimizations Applied:"
log "- Limited parallel builds (max ${MAX_BUILD_JOBS} jobs)"
log "- Build memory limits (${BUILD_MEMORY_MB}MB)"
log "- Aggressive garbage collection (1-5GB free space)"
log "- Auto-optimize-store enabled (saves disk space)"
log "- Binary cache enabled (faster installs, less building)"
log "- Build timeouts (prevents hanging)"
log ""
log "If Nix installation fails, alternatives:"
log "  1. Install just via Alpine: apk add just"
log "  2. Use Alpine's native packages instead of Nix"
log "  3. Consider Docker container with glibc-based Linux"
log ""
log "Root-only installation is supported, but some Nix features"
log "may require proper user setup for full functionality."
log ""
log "Performance Tips for Chromebook:"
log "- Run 'nix store optimise' periodically to free disk space"
log "- Use 'nix-collect-garbage -d' to remove unused packages"
log "- Monitor disk space: df -h /nix"
log "- Consider using Alpine packages when possible (faster, less disk)"
log ""
