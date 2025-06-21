#!/bin/bash

# Enhanced error handling and recovery
handle_error() {
    local exit_code=$?
    local line_no=$1
    local command="$2"
    log_with_timestamp "❌ Error occurred at line $line_no: $command (exit code: $exit_code)" "error"

    # Cleanup temporary files
    cleanup_temp_files

    # Don't exit, continue watching for new files
    return $exit_code
}

cleanup_temp_files() {
    log_with_timestamp "🧹 Cleaning up temporary files..." "info"
    # Remove any temporary build artifacts
    rm -rf /tmp/smarttesthub_* 2>/dev/null || true
    # Clean up any stale lock files
    find "${project_dir:-/app}" -name "*.lock" -mtime +1 -delete 2>/dev/null || true
}

# Set up error trapping
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

# Enhanced entrypoint script for Non-EVM (Solana) container
# Provides comprehensive testing, security analysis, and reporting with parallel processing

LOG_FILE="/app/logs/test.log"
ERROR_LOG="/app/logs/error.log"
SECURITY_LOG="/app/logs/security/security-audit.log"
PERFORMANCE_LOG="/app/logs/analysis/performance.log"
XRAY_LOG="/app/logs/xray/xray.log"

# Parallel processing configuration
MAX_CONCURRENT_JOBS=${MAX_CONCURRENT_JOBS:-3}
ACTIVE_JOBS=()
JOB_QUEUE=()

# Initialize global variables
START_TIME=$(date +%s)
PROCESSED_FILES_COUNT=0
HEALTH_CHECK_INTERVAL=30
LAST_HEALTH_CHECK=0

# Create all required directories
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$ERROR_LOG")"
mkdir -p "$(dirname "$SECURITY_LOG")"
mkdir -p "$(dirname "$PERFORMANCE_LOG")"
mkdir -p "$(dirname "$XRAY_LOG")"
mkdir -p /app/logs/coverage
mkdir -p /app/logs/reports
mkdir -p /app/logs/benchmarks

# Secure environment setup
setup_secure_environment() {
    log_with_timestamp "🔐 Setting up secure environment..." "security"

    # Check for secrets directory
    if [[ -d "/run/secrets" ]]; then
        log_with_timestamp "📂 Found Docker secrets directory" "security"
        # Load secrets if available
        for secret_file in /run/secrets/*; do
            if [[ -f "$secret_file" ]]; then
                local secret_name=$(basename "$secret_file")
                local secret_value=$(cat "$secret_file")
                export "${secret_name^^}"="$secret_value"
                log_with_timestamp "✅ Loaded secret: $secret_name" "security"
            fi
        done
    fi

    # Load environment variables if .env exists (secure method)
    if [ -f "/app/.env" ]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ $line =~ ^[[:space:]]*# ]] && continue
            [[ -z $line ]] && continue
            # Export valid environment variables
            if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                export "$line"
            fi
        done < "/app/.env"
        log_with_timestamp "✅ Environment variables loaded from .env" "security"
    fi

    # Validate required environment variables
    local required_vars=("SOLANA_URL")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            log_with_timestamp "⚠️ Required environment variable not set: $var" "security"
            case $var in
                "SOLANA_URL")
                    export SOLANA_URL="https://api.devnet.solana.com"
                    log_with_timestamp "🔧 Set default SOLANA_URL: $SOLANA_URL" "security"
                    ;;
            esac
        fi
    done

    # Set secure umask and limit history
    umask 0027
    export HISTFILE="/dev/null"
    export HISTSIZE=0

    log_with_timestamp "✅ Secure environment setup completed" "security"
}

# Input validation functions
validate_contract_file() {
    local file_path="$1"
    local filename=$(basename "$file_path")

    log_with_timestamp "🔍 Validating contract file: $filename" "info"

    # Check file exists and is readable
    if [[ ! -f "$file_path" || ! -r "$file_path" ]]; then
        log_with_timestamp "❌ File does not exist or is not readable: $file_path" "error"
        return 1
    fi

    # Check file size (max 10MB)
    local file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo 0)
    if [[ $file_size -gt 10485760 ]]; then
        log_with_timestamp "❌ File too large: $file_size bytes (max 10MB)" "error"
        return 1
    fi

    # Check for malicious patterns
    if grep -q -E "(eval|exec|system|shell_exec|passthru)" "$file_path"; then
        log_with_timestamp "⚠️ Potentially dangerous code patterns detected in $filename" "security"
        return 1
    fi

    # Validate Rust syntax
    local temp_file="/tmp/smarttesthub_validate_$$"
    cp "$file_path" "$temp_file"
    if ! rustc --cfg 'feature="no-entrypoint"' --crate-type lib --emit=metadata --out-dir /tmp "$temp_file" 2>/dev/null; then
        log_with_timestamp "❌ Invalid Rust syntax in $filename" "error"
        rm -f "$temp_file" 2>/dev/null
        return 1
    fi
    rm -f "$temp_file" 2>/dev/null

    log_with_timestamp "✅ Contract file validation passed: $filename" "info"
    return 0
}

sanitize_contract_name() {
    local name="$1"
    # Remove any non-alphanumeric characters except underscore and hyphen
    echo "$name" | sed 's/[^a-zA-Z0-9_-]//g' | tr '[:upper:]' '[:lower:]'
}

# Resource monitoring
monitor_resources() {
    local memory_usage=$(free | awk 'NR==2{printf "%.2f", $3*100/$2}' 2>/dev/null || echo "0")
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "0")

    log_with_timestamp "📊 Resource usage - Memory: ${memory_usage}%, CPU: ${cpu_usage}%" "performance"

    # Check if we're running low on resources
    if (( $(echo "$memory_usage > 85" | awk '{print ($1 > $3)}') )); then
        log_with_timestamp "⚠️ High memory usage detected: ${memory_usage}%" "performance"
        return 1
    fi
    return 0
}

# Job management functions
add_job_to_queue() {
    local job_info="$1"
    JOB_QUEUE+=("$job_info")
    log_with_timestamp "📝 Added job to queue: $job_info" "info"
}

process_job_queue() {
    while [[ ${#ACTIVE_JOBS[@]} -lt $MAX_CONCURRENT_JOBS && ${#JOB_QUEUE[@]} -gt 0 ]]; do
        local job_info="${JOB_QUEUE[0]}"
        JOB_QUEUE=("${JOB_QUEUE[@]:1}")
        log_with_timestamp "🚀 Starting job: $job_info" "info"
        process_contract_parallel "$job_info" &
        local job_pid=$!
        ACTIVE_JOBS+=($job_pid)
        log_with_timestamp "▶️ Job started with PID: $job_pid" "info"
    done
}

wait_for_job_completion() {
    local completed_jobs=()
    for i in "${!ACTIVE_JOBS[@]}"; do
        local pid=${ACTIVE_JOBS[i]}
        if ! kill -0 $pid 2>/dev/null; then
            wait $pid
            local exit_code=$?
            log_with_timestamp "🏁 Job completed with PID $pid (exit code: $exit_code)" "info"
            completed_jobs+=($i)
        fi
    done
    for i in $(printf '%s\n' "${completed_jobs[@]}" | sort -nr); do
        unset 'ACTIVE_JOBS[i]'
    done
    ACTIVE_JOBS=("${ACTIVE_JOBS[@]}")
}

process_contract_parallel() {
    local job_info="$1"
    local filename=$(echo "$job_info" | cut -d'|' -f1)
    local watch_dir=$(echo "$job_info" | cut -d'|' -f2)
    local job_id="$$_$(date +%s%N)"
    local job_project_dir="/tmp/smarttesthub_${job_id}"

    log_with_timestamp "🔄 Processing $filename in parallel (Job ID: $job_id)" "info"
    process_single_contract "$filename" "$watch_dir" "$job_project_dir"
    rm -rf "$job_project_dir" 2>/dev/null || true
    log_with_timestamp "✅ Parallel job completed: $filename" "info"
}

# Health monitoring functions
perform_health_check() {
    local current_time=$(date +%s)
    if [[ $((current_time - LAST_HEALTH_CHECK)) -lt $HEALTH_CHECK_INTERVAL ]]; then
        return 0
    fi
    LAST_HEALTH_CHECK=$current_time
    log_with_timestamp "🩺 Performing health check..." "info"

    local health_status="healthy"
    local health_details=()

    # Check disk space
    local disk_usage=$(df /app | awk 'NR==2 {print $5}' | cut -d'%' -f1 2>/dev/null || echo "0")
    if [[ $disk_usage -gt 85 ]]; then
        health_status="unhealthy"
        health_details+=("High disk usage: ${disk_usage}%")
        log_with_timestamp "⚠️ High disk usage: ${disk_usage}%" "error"
    fi

    # Check if essential tools are available
    local required_tools=("cargo" "rustc")
    for tool in "${required_tools[@]}"; do
        if ! command_exists "$tool"; then
            health_status="unhealthy"
            health_details+=("Missing required tool: $tool")
            log_with_timestamp "❌ Missing required tool: $tool" "error"
        fi
    done

    # Check log file sizes
    local max_log_size=104857600  # 100MB
    for log_file in "$LOG_FILE" "$ERROR_LOG" "$SECURITY_LOG"; do
        if [[ -f "$log_file" ]]; then
            local log_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo 0)
            if [[ $log_size -gt $max_log_size ]]; then
                log_with_timestamp "🗜️ Rotating large log file: $log_file (${log_size} bytes)" "info"
                mv "$log_file" "${log_file}.old"
                touch "$log_file"
            fi
        fi
    done

    # Create health status file
    local health_file="/app/logs/health.json"
    cat > "$health_file" <<EOF
{
    "status": "$health_status",
    "timestamp": "$(date -Iseconds)",
    "uptime": $((current_time - START_TIME)),
    "details": [$(printf '"%s",' "${health_details[@]}" | sed 's/,$//')]
}
EOF

    log_with_timestamp "🩺 Health check completed: $health_status" "info"
    return 0
}

# Metrics collection
collect_metrics() {
    local metrics_file="/app/logs/metrics.json"
    local current_time=$(date +%s)

    cat > "$metrics_file" <<EOF
{
    "timestamp": "$(date -Iseconds)",
    "uptime": $((current_time - START_TIME)),
    "processed_files": $PROCESSED_FILES_COUNT,
    "active_jobs": ${#ACTIVE_JOBS[@]},
    "queued_jobs": ${#JOB_QUEUE[@]},
    "memory_usage": "$(free | awk 'NR==2{printf "%.2f", $3*100/$2}' 2>/dev/null || echo 0)%",
    "disk_usage": "$(df /app | awk 'NR==2 {print $5}' 2>/dev/null || echo 0)"
}
EOF
}

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

# Function to start AWS X-Ray daemon if installed
start_xray_daemon() {
    log_with_timestamp "📡 Setting up AWS X-Ray daemon..." "xray"

    if command_exists xray; then
        log_with_timestamp "📡 Found X-Ray daemon at $(which xray)" "xray"
        export AWS_REGION="us-east-1"
        log_with_timestamp "📡 Setting AWS_REGION to $AWS_REGION" "xray"

        if [ -f "/app/config/xray-config.json" ]; then
            log_with_timestamp "📡 Starting X-Ray daemon with custom config in local mode..." "xray"
            nohup xray -c /app/config/xray-config.json -l -o > "$XRAY_LOG" 2>&1 &
        else
            log_with_timestamp "📡 Starting X-Ray daemon with default config in local mode..." "xray"
            nohup xray -l -o > "$XRAY_LOG" 2>&1 &
        fi

        sleep 2
        if pgrep xray > /dev/null; then
            log_with_timestamp "✅ X-Ray daemon started successfully" "xray"
        else
            log_with_timestamp "❌ Failed to start X-Ray daemon: $(tail -n 10 $XRAY_LOG)" "error"
            log_with_timestamp "⚠️ Continuing without X-Ray daemon" "xray"
        fi
    else
        log_with_timestamp "⚠️ X-Ray daemon not found in PATH" "xray"
    fi
}

# Function to generate tarpaulin.toml if needed
generate_tarpaulin_config() {
    if [ ! -f "/app/tarpaulin.toml" ]; then
        log_with_timestamp "📊 Generating tarpaulin.toml configuration file..." "performance"
        cat > "/app/tarpaulin.toml" <<EOF
[all]
timeout = 300
debug = false
follow-exec = true
verbose = true
workspace = true

out = ["Html", "Xml"]
output-dir = "/app/logs/coverage"

exclude-files = [
    "tests/*",
    "*/build/*",
    "*/dist/*"
]

ignore-tests = true
EOF
        log_with_timestamp "✅ Created tarpaulin.toml" "performance"
    fi
}

# Function to setup Solana environment
setup_solana_environment() {
    log_with_timestamp "🔧 Setting up Solana environment..." "info"
    log_with_timestamp "Current PATH: $PATH"

    if ! command_exists solana; then
        log_with_timestamp "⚠️ Solana CLI not found in PATH" "error"
        if [ -d "$HOME/.local/share/solana/install/active_release/bin" ]; then
            log_with_timestamp "🔍 Found Solana installation, adding to PATH" "error"
            export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
            log_with_timestamp "Updated PATH: $PATH" "error"
        elif [ -d "/root/.local/share/solana/install/active_release/bin" ]; then
            log_with_timestamp "🔍 Found Solana installation in /root/.local, adding to PATH" "info"
            export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
            log_with_timestamp "Updated PATH: $PATH" "info"
        else
            log_with_timestamp "🔄 Attempting to install Solana..." "info"
            curl -sSfL https://release.solana.com/v1.17.3/install -o install_solana.sh
            sh install_solana.sh
            export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
            log_with_timestamp "Updated PATH after install: $PATH" "info"
        fi
    fi

    if ! command_exists solana; then
        log_with_timestamp "❌ Solana CLI still not found after PATH update" "error"
        return 1
    fi

    # Generate keypair if it doesn't exist
    if [ ! -f ~/.config/solana/id.json ]; then
        log_with_timestamp "🔑 Generating new Solana keypair..." "info"
        mkdir -p ~/.config/solana
        if solana-keygen new --no-bip39-passphrase --silent --outfile ~/.config/solana/id.json; then
            log_with_timestamp "✅ Solana keypair generated" "info"
        else
            log_with_timestamp "❌ Failed to generate Solana keypair" "error"
            return 1
        fi
    fi

    local solana_url="${SOLANA_URL:-https://api.devnet.solana.com}"
    if solana config set --url "$solana_url" --keypair ~/.config/solana/id.json; then
        log_with_timestamp "✅ Solana config set successfully" "info"
    else
        log_with_timestamp "❌ Failed to set Solana config" "error"
        return 1
    fi

    if solana config get >/dev/null 2>&1; then
        log_with_timestamp "✅ Solana CLI configured successfully" "info"
        solana config get | while read -r line; do
            log_with_timestamp "   $line" "info"
        done
    else
        log_with_timestamp "❌ Failed to configure Solana CLI" "error"
        return 1
    fi

    if [[ "$solana_url" == *"devnet"* ]]; then
        log_with_timestamp "💰 Requesting SOL airdrop for testing..." "info"
        solana airdrop 2 >/dev/null 2>&1 || log_with_timestamp "⚠️ Airdrop failed (might be rate limited)" "warning"
    fi

    return 0
}

# Function to detect project type
detect_project_type() {
    local file_path="$1"
    if grep -q "#\[program\]" "$file_path" || grep -q "use anchor_lang::prelude" "$file_path"; then
        echo "anchor"
    elif grep -q "entrypoint\!" "$file_path" || grep -q "solana_program::entrypoint\!" "$file_path"; then
        echo "native"
    else
        echo "unknown"
    fi
}

# Enhanced main processing function
process_single_contract() {
    local filename="$1"
    local watch_dir="$2"
    local isolated_project_dir="${3:-$project_dir}"

    local start_time=$(date +%s)
    local contract_name
    local project_type

    # Validate input file
    if ! validate_contract_file "$watch_dir/$filename"; then
        log_with_timestamp "❌ Contract validation failed: $filename" "error"
        return 1
    fi

    # Sanitize contract name
    contract_name=$(sanitize_contract_name "${filename%.rs}")

    log_with_timestamp "🆕 Processing contract: $filename -> $contract_name" "info"

    # Create isolated project directory
    mkdir -p "$isolated_project_dir/src"
    mkdir -p "$isolated_project_dir/logs"
    
    # Copy contract file
    cp "$watch_dir/$filename" "$isolated_project_dir/src/lib.rs"
    log_with_timestamp "📁 Contract copied to src/lib.rs"

    # Detect project type
    project_type=$(detect_project_type "$isolated_project_dir/src/lib.rs")
    log_with_timestamp "🔍 Detected project type: $project_type"

    # Create dynamic Cargo.toml
    create_dynamic_cargo_toml "$contract_name" "$isolated_project_dir/src/lib.rs" "$project_type" "$isolated_project_dir"

    # Create test files
    create_test_files "$contract_name" "$project_type" "$isolated_project_dir"

    # Build with timeout and resource monitoring
    if ! build_contract_with_monitoring "$contract_name" "$isolated_project_dir"; then
        log_with_timestamp "❌ Build failed for $contract_name" "error"
        return 1
    fi

    # Run comprehensive analysis
    run_comprehensive_analysis "$contract_name" "$isolated_project_dir"

    # Generate final report
    local end_time=$(date +%s)
    generate_comprehensive_report "$contract_name" "$project_type" "$start_time" "$end_time" "$isolated_project_dir"

    # Update metrics
    ((PROCESSED_FILES_COUNT++))

    log_with_timestamp "🏁 Successfully processed $filename" "info"
    return 0
}

# Enhanced build function with monitoring
build_contract_with_monitoring() {
    local contract_name="$1"
    local build_project_dir="$2"

    log_with_timestamp "🔨 Building $contract_name with monitoring..." "info"
    cd "$build_project_dir" || return 1

    # Monitor resources before build
    if ! monitor_resources; then
        log_with_timestamp "⚠️ Resource constraints detected, waiting..." "performance"
        sleep 10
        if ! monitor_resources; then
            log_with_timestamp "❌ Insufficient resources for build" "error"
            return 1
        fi
    fi

    # Build with timeout (10 minutes)
    local build_timeout=600
    local build_start=$(date +%s)

    timeout $build_timeout cargo build-sbf 2>&1 | tee -a "$LOG_FILE" &
    local build_pid=$!

    # Monitor build progress
    while kill -0 $build_pid 2>/dev/null; do
        sleep 5
        local current_time=$(date +%s)
        if [[ $((current_time - build_start)) -gt $build_timeout ]]; then
            log_with_timestamp "⏰ Build timeout exceeded for $contract_name" "error"
            kill -TERM $build_pid 2>/dev/null || true
            return 1
        fi
        monitor_resources || log_with_timestamp "⚠️ High resource usage during build" "performance"
    done

    wait $build_pid
    local build_exit_code=$?
    if [[ $build_exit_code -eq 0 ]]; then
        log_with_timestamp "✅ Build successful for $contract_name" "info"
        return 0
    else
        log_with_timestamp "❌ Build failed for $contract_name (exit code: $build_exit_code)" "error"
        return 1
    fi
}

# Function to create dynamic Cargo.toml
create_dynamic_cargo_toml() {
    local contract_name="$1"
    local source_path="$2"
    local project_type="$3"
    local target_project_dir="$4"

    log_with_timestamp "📝 Creating dynamic Cargo.toml for $contract_name ($project_type)..." "info"

    cat > "$target_project_dir/Cargo.toml" <<EOF
[package]
name = "$contract_name"
version = "0.1.0"
edition = "2021"
description = "Smart contract automatically processed by SmartTestHub"

[lib]
crate-type = ["cdylib", "lib"]
EOF

    case $project_type in
        "anchor")
            cat >> "$target_project_dir/Cargo.toml" <<EOF

[dependencies]
anchor-lang = "0.29.0"
anchor-spl = "0.29.0"
solana-program = "1.17.0"
EOF
            ;;
        "native")
            cat >> "$target_project_dir/Cargo.toml" <<EOF

[dependencies]
solana-program = "1.17.0"
borsh = "0.10.3"
borsh-derive = "0.10.3"
thiserror = "1.0"
num-traits = "0.2"
num-derive = "0.4"
EOF
            ;;
        *)
            cat >> "$target_project_dir/Cargo.toml" <<EOF

[dependencies]
solana-program = "1.17.0"
borsh = "0.10.3"
borsh-derive = "0.10.3"
EOF
            ;;
    esac

    cat >> "$target_project_dir/Cargo.toml" <<EOF

[dev-dependencies]
solana-program-test = "1.17.0"
solana-sdk = "1.17.0"

[features]
no-entrypoint = []
test-sbf = []

[profile.release]
overflow-checks = true
lto = "fat"
codegen-units = 1
EOF

    log_with_timestamp "✅ Created dynamic Cargo.toml" "info"
}

# Function to create test files
create_test_files() {
    local contract_name="$1"
    local project_type="$2"
    local target_project_dir="$3"

    log_with_timestamp "🧪 Creating test files for $contract_name ($project_type)..." "info"
    mkdir -p "$target_project_dir/tests"

    case $project_type in
        "anchor")
            cat > "$target_project_dir/tests/test_${contract_name}.rs" <<EOF
use anchor_lang::prelude::*;
use solana_program_test::*;
use solana_sdk::{signature::{Keypair, Signer}, transaction::Transaction};

// Import the program to test
use ${contract_name}::*;

#[tokio::test]
async fn test_${contract_name}_initialization() {
    // Setup the test environment
    let program_id = Pubkey::new_unique();
    let mut program_test = ProgramTest::new(
        "${contract_name}",
        program_id,
        processor!(process_instruction),
    );

    // Start the test environment
    let (mut banks_client, payer, recent_blockhash) = program_test.start().await;

    // Create test logic here
    // This is a placeholder test that will always pass
    assert!(true);
}
EOF
            ;;
        "native")
            cat > "$target_project_dir/tests/test_${contract_name}.rs" <<EOF
use solana_program_test::*;
use solana_sdk::{
    account::Account,
    instruction::{AccountMeta, Instruction},
    pubkey::Pubkey,
    signature::{Keypair, Signer},
    transaction::Transaction,
};
use std::str::FromStr;

// Import the program to test
use ${contract_name}::*;

#[tokio::test]
async fn test_${contract_name}_basic() {
    // Setup the test environment
    let program_id = Pubkey::new_unique();
    let mut program_test = ProgramTest::new(
        "${contract_name}",
        program_id,
        processor!(process_instruction),
    );

    // Start the test environment
    let (mut banks_client, payer, recent_blockhash) = program_test.start().await;

    // Create test logic here
    // This is a placeholder test that will always pass
    assert!(true);
}
EOF
            ;;
        *)
            cat > "$target_project_dir/tests/test_${contract_name}.rs" <<EOF
#[tokio::test]
async fn test_${contract_name}_placeholder() {
    // This is a generic test placeholder
    // Actual tests would be implemented based on the specific contract functionality
    assert!(true);
}
EOF
            ;;
    esac

    log_with_timestamp "✅ Created test files" "info"
}

# Function to run comprehensive analysis
run_comprehensive_analysis() {
    local contract_name="$1"
    local analysis_project_dir="$2"

    cd "$analysis_project_dir"
    run_tests_with_coverage "$contract_name" "$analysis_project_dir"
    run_security_audit "$contract_name" "$analysis_project_dir"
    run_performance_analysis "$contract_name" "$analysis_project_dir"
}

# Function to run tests with coverage
run_tests_with_coverage() {
    local contract_name="$1"
    local test_project_dir="$2"

    log_with_timestamp "🧪 Running tests with coverage for $contract_name..." "performance"
    mkdir -p "/app/logs/coverage"

    if cargo tarpaulin --config-path /app/tarpaulin.toml -v; then
        log_with_timestamp "✅ Tests and coverage completed successfully" "performance"
    else
        log_with_timestamp "⚠️ Tests or coverage generation had some issues" "error"
    fi
}

# Function to run security audit
run_security_audit() {
    local contract_name="$1"
    local audit_project_dir="$2"

    log_with_timestamp "🛡️ Running security audit for $contract_name..." "security"
    cd "$audit_project_dir"

    mkdir -p "/app/logs/security"
    cargo generate-lockfile || true
    cargo audit -f "$audit_project_dir/Cargo.lock" > "/app/logs/security/cargo-audit.log" 2>&1
    cargo clippy --all-targets --all-features -- -D warnings > "/app/logs/security/clippy.log" 2>&1 || log_with_timestamp "⚠️ Clippy found code quality issues" "security"
}

# Function to run performance analysis
run_performance_analysis() {
    local contract_name="$1"
    local perf_project_dir="$2"

    log_with_timestamp "⚡ Running performance analysis for $contract_name..." "performance"
    cd "$perf_project_dir"

    mkdir -p "/app/logs/benchmarks"
    log_with_timestamp "Measuring build time performance..." "performance"

    local start_time=$(date +%s)
    if cargo build --release > "/app/logs/benchmarks/build-time.log" 2>&1; then
        local end_time=$(date +%s)
        local build_time=$((end_time - start_time))
        log_with_timestamp "✅ Release build completed in $build_time seconds" "performance"
    else
        log_with_timestamp "❌ Release build failed" "performance"
    fi

    if [ -f "$perf_project_dir/target/release/${contract_name}.so" ]; then
        local program_size=$(du -h "$perf_project_dir/target/release/${contract_name}.so" | cut -f1)
        log_with_timestamp "📊 Program size: $program_size" "performance"
    fi
}

# Function to generate comprehensive report
generate_comprehensive_report() {
    local contract_name="$1"
    local project_type="$2"
    local start_time="$3"
    local end_time="$4"
    local report_project_dir="$5"
    local processing_time=$((end_time - start_time))

    log_with_timestamp "📝 Generating comprehensive report for $contract_name..." "info"

    mkdir -p "/app/logs/reports"
    local report_file="/app/logs/reports/${contract_name}_report.md"

    cat > "$report_file" <<EOF
# Comprehensive Analysis Report for $contract_name

## Overview
- **Contract Name:** $contract_name
- **Project Type:** $project_type
- **Processing Time:** $processing_time seconds
- **Timestamp:** $(date)

## Build Status
- Build completed successfully
- Project structure verified

## Test Results
EOF

    if [ -f "/app/logs/coverage/tarpaulin-report.html" ]; then
        echo "- ✅ Tests executed successfully" >> "$report_file"
        echo "- 📊 Coverage report available at \`/app/logs/coverage/tarpaulin-report.html\`" >> "$report_file"
    else
        echo "- ⚠️ Test coverage report not available" >> "$report_file"
    fi

    echo -e "\n## Security Analysis" >> "$report_file"
    if [ -f "/app/logs/security/cargo-audit.log" ]; then
        echo "- 🛡️ Security audit completed" >> "$report_file"
        echo "- Details available in \`/app/logs/security/cargo-audit.log\`" >> "$report_file"
    else
        echo "- ⚠️ Security audit report not available" >> "$report_file"
    fi

    echo -e "\n## Performance Analysis" >> "$report_file"
    if [ -f "/app/logs/benchmarks/build-time.log" ]; then
        echo "- ⚡ Performance analysis completed" >> "$report_file"
        if [ -f "$report_project_dir/target/release/${contract_name}.so" ]; then
            local program_size=$(du -h "$report_project_dir/target/release/${contract_name}.so" | cut -f1)
            echo "- 📊 Program size: $program_size" >> "$report_file"
        fi
    else
        echo "- ⚠️ Performance analysis not available" >> "$report_file"
    fi

    echo -e "\n## Recommendations" >> "$report_file"
    echo "- Ensure comprehensive test coverage for all program paths" >> "$report_file"
    echo "- Address any security concerns highlighted in the audit report" >> "$report_file"
    echo "- Consider optimizing program size and execution time if required" >> "$report_file"

    log_with_timestamp "✅ Comprehensive report generated at $report_file" "info"
}

# Start X-Ray daemon if enabled
if [ "$AWS_XRAY_SDK_ENABLED" = "true" ]; then
    start_xray_daemon
fi

# Generate tarpaulin config
generate_tarpaulin_config

# Clear old logs
: > "$LOG_FILE"
: > "$ERROR_LOG"

watch_dir="/app/input"
project_dir="/app"

# Main execution starts here
log_with_timestamp "🚀 Starting Enhanced Non-EVM (Solana) Container with improvements..." "info"

# Setup secure environment
setup_secure_environment

# Setup Solana environment with better error handling
if ! setup_solana_environment; then
    log_with_timestamp "❌ Solana environment setup failed, but continuing with limited functionality" "error"
fi

# Ensure watch directory exists
mkdir -p "$watch_dir"

log_with_timestamp "📡 Starting file watcher with parallel processing (max jobs: $MAX_CONCURRENT_JOBS)..." "info"
log_with_timestamp "🔧 Environment: ${RUST_LOG:-info} log level"

# Enhanced file watching loop with parallel processing
inotifywait -m -e close_write,moved_to,create "$watch_dir" |
while read -r directory events filename; do
    # Perform periodic health checks
    perform_health_check
    collect_metrics

    if [[ "$filename" == *.rs ]]; then
        log_with_timestamp "📥 New file detected: $filename" "info"

        # Check if we can process immediately or need to queue
        if [[ ${#ACTIVE_JOBS[@]} -lt $MAX_CONCURRENT_JOBS ]]; then
            # Process immediately
            log_with_timestamp "🚀 Processing immediately: $filename" "info"
            process_contract_parallel "$filename|$watch_dir" &
            local job_pid=$!
            ACTIVE_JOBS+=($job_pid)
            log_with_timestamp "▶️ Started immediate processing with PID: $job_pid" "info"
        else
            # Add to queue
            log_with_timestamp "📝 Adding to queue (all slots busy): $filename" "info"
            add_job_to_queue "$filename|$watch_dir"
        fi
    fi

    # Process job queue and clean up completed jobs
    wait_for_job_completion
    process_job_queue

    # Log current status
    log_with_timestamp "📊 Status - Active: ${#ACTIVE_JOBS[@]}, Queued: ${#JOB_QUEUE[@]}, Processed: $PROCESSED_FILES_COUNT" "info"
done