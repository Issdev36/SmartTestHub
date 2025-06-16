#!/bin/bash
set -e

# Enhanced entrypoint script for Non-EVM (Solana) container
# Provides comprehensive testing, security analysis, and reporting

LOG_FILE="/app/logs/test.log"
ERROR_LOG="/app/logs/error.log"
SECURITY_LOG="/app/logs/security/security-audit.log"
PERFORMANCE_LOG="/app/logs/analysis/performance.log"
XRAY_LOG="/app/logs/xray/xray.log"

# Create all required directories
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$ERROR_LOG")"
mkdir -p "$(dirname "$SECURITY_LOG")"
mkdir -p "$(dirname "$PERFORMANCE_LOG")"
mkdir -p "$(dirname "$XRAY_LOG")"
mkdir -p /app/logs/coverage
mkdir -p /app/logs/reports
mkdir -p /app/logs/benchmarks

# Load environment variables if .env exists
if [ -f "/app/.env" ]; then
    export $(cat /app/.env | grep -v '^#' | xargs)
    echo "✅ Environment variables loaded from .env"
fi

# Function to log with timestamp to multiple files
log_with_timestamp() {
    local message="$1"
    local log_type="${2:-info}"
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    
    case $log_type in
        "error")
            echo "$timestamp ❌ $message" | tee -a "$LOG_FILE" "$ERROR_LOG"
            ;;
        "security")
            echo "$timestamp 🛡️ $message" | tee -a "$LOG_FILE" "$SECURITY_LOG"
            ;;
        "performance")
            echo "$timestamp ⚡ $message" | tee -a "$LOG_FILE" "$PERFORMANCE_LOG"
            ;;
        "xray")
            echo "$timestamp 📡 $message" | tee -a "$LOG_FILE" "$XRAY_LOG"
            ;;
        *)
            echo "$timestamp $message" | tee -a "$LOG_FILE"
            ;;
    esac
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to start X-Ray daemon if installed
start_xray_daemon() {
    log_with_timestamp "📡 Setting up AWS X-Ray daemon..." "xray"
    
    if command_exists xray; then
        if [ -f "/app/config/xray-config.json" ]; then
            log_with_timestamp "📡 Starting X-Ray daemon with custom config..." "xray"
            nohup xray -c /app/config/xray-config.json > "$XRAY_LOG" 2>&1 &
        else
            log_with_timestamp "📡 Starting X-Ray daemon with default config..." "xray"
            nohup xray > "$XRAY_LOG" 2>&1 &
        fi
        
        # Check if daemon started properly
        sleep 2
        if pgrep xray > /dev/null; then
            log_with_timestamp "✅ X-Ray daemon started successfully" "xray"
        else
            log_with_timestamp "❌ Failed to start X-Ray daemon" "error"
        fi
    else
        log_with_timestamp "⚠️ X-Ray daemon not found in PATH, tracing disabled" "xray"
    fi
}

# Function to setup Solana environment
setup_solana_environment() {
    log_with_timestamp "🔧 Setting up Solana environment..."
    
    # Check if solana is in the PATH
    if ! command_exists solana; then
        log_with_timestamp "⚠️ Solana CLI not found in PATH" "error"
        log_with_timestamp "PATH: $PATH" "error"
        
        # Try to find Solana installation
        if [ -d "$HOME/.local/share/solana/install/active_release/bin" ]; then
            log_with_timestamp "🔍 Found Solana installation, adding to PATH" "error"
            export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
        else
            log_with_timestamp "❌ Cannot find Solana installation" "error"
            return 1
        fi
    fi
    
    # Double check after PATH update
    if ! command_exists solana; then
        log_with_timestamp "❌ Solana CLI still not found after PATH update" "error"
        return 1
    fi
    
    # Generate keypair if it doesn't exist
    if [ ! -f ~/.config/solana/id.json ]; then
        log_with_timestamp "🔑 Generating new Solana keypair..."
        mkdir -p ~/.config/solana
        if solana-keygen new --no-bip39-passphrase --silent --outfile ~/.config/solana/id.json; then
            log_with_timestamp "✅ Solana keypair generated"
        else
            log_with_timestamp "❌ Failed to generate Solana keypair" "error"
            return 1
        fi
    fi
    
    # Set Solana configuration
    local solana_url="${SOLANA_URL:-https://api.devnet.solana.com}"
    if solana config set --url "$solana_url" --keypair ~/.config/solana/id.json; then
        log_with_timestamp "✅ Solana config set successfully"
    else
        log_with_timestamp "❌ Failed to set Solana config" "error"
        return 1
    fi
    
    # Verify Solana setup
    if solana config get >/dev/null 2>&1; then
        log_with_timestamp "✅ Solana CLI configured successfully"
        solana config get | while read -r line; do
            log_with_timestamp "   $line"
        done
    else
        log_with_timestamp "❌ Failed to configure Solana CLI" "error"
        return 1
    fi
    
    # Request airdrop for devnet testing
    if [[ "$solana_url" == *"devnet"* ]]; then
        log_with_timestamp "💰 Requesting SOL airdrop for testing..."
        solana airdrop 2 >/dev/null 2>&1 || log_with_timestamp "⚠️ Airdrop failed (might be rate limited)"
    fi

    return 0
}

# Function to generate the tarpaulin config if it doesn't exist
generate_tarpaulin_config() {
    if [ ! -f "/app/config/tarpaulin.toml" ]; then
        log_with_timestamp "📝 Generating tarpaulin config file..."
        cat > "/app/config/tarpaulin.toml" <<EOF
[tarpaulin]
out = ["Html", "Xml"]
output-dir = "/app/logs/coverage"
timeout = 300
verbose = true
exclude-files = ["**/tests/**", "**/benches/**"]
coveralls = false
ignore-panics = true
line = true
count = true
ignored-fn-names = ["main"]
EOF
        log_with_timestamp "✅ Generated tarpaulin config file"
    fi
}

# Start X-Ray daemon if enabled
if [ "$AWS_XRAY_SDK_ENABLED" = "true" ]; then
    start_xray_daemon
fi

# Generate tarpaulin config if needed
generate_tarpaulin_config

# Rest of the script remains the same...
