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
# Provides comprehensive testing, security analysis, and reporting with parallel processing foundation

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
    
    # Load Docker secrets if available
    if [[ -d "/run/secrets" ]]; then
        log_with_timestamp "📂 Found Docker secrets directory" "security"
        for secret_file in /run/secrets/*; do
            if [[ -f "$secret_file" ]]; then
                local secret_name=$(basename "$secret_file")
                local secret_value=$(cat "$secret_file")
                export "${secret_name^^}"="$secret_value"
                log_with_timestamp "✅ Loaded secret: $secret_name" "security"
            fi
        done
    fi
    
    # Load .env file securely
    if [ -f "/app/.env" ]; then
        while IFS= read -r line; do
            [[ $line =~ ^[[:space:]]*# ]] && continue
            [[ -z $line ]] && continue
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
    
    # Secure umask and history
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
    
    if [[ ! -f "$file_path" || ! -r "$file_path" ]]; then
        log_with_timestamp "❌ File does not exist or is not readable: $file_path" "error"
        return 1
    fi
    
    local file_size=$(stat -f%z "$file_path" 2>/dev/null || stat -c%s "$file_path" 2>/dev/null || echo 0)
    if [[ $file_size -gt 10485760 ]]; then
        log_with_timestamp "❌ File too large: $file_size bytes (max 10MB)" "error"
        return 1
    fi
    
    if grep -q -E "(eval|exec|system|shell_exec|passthru)" "$file_path"; then
        log_with_timestamp "⚠️ Potentially dangerous code patterns detected in $filename" "security"
        return 1
    fi
    
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
    echo "$name" | sed 's/[^a-zA-Z0-9_-]//g' | tr '[:upper:]' '[:lower:]'
}

# Resource monitoring
monitor_resources() {
    local memory_usage=$(free | awk 'NR==2{printf "%.2f", $3*100/$2}' 2>/dev/null || echo "0")
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo "0")
    log_with_timestamp "📊 Resource usage - Memory: ${memory_usage}%, CPU: ${cpu_usage}%" "performance"
    
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
        ACTIVE_JOBS+=($!)
    done
}

wait_for_job_completion() {
    local completed=()
    for i in "${!ACTIVE_JOBS[@]}"; do
        local pid=${ACTIVE_JOBS[i]}
        if ! kill -0 $pid 2>/dev/null; then
            wait $pid
            log_with_timestamp "🏁 Job completed with PID $pid" "info"
            completed+=($i)
        fi
    done
    for i in $(printf '%s\n' "${completed[@]}" | sort -nr); do
        unset 'ACTIVE_JOBS[i]'
    done
    ACTIVE_JOBS=("${ACTIVE_JOBS[@]}")
}

process_contract_parallel() {
    local job_info="$1"
    local filename=$(echo "$job_info" | cut -d'|' -f1)
    local watch_dir=$(echo "$job_info" | cut -d'|' -f2)
    local job_id="$$_$(date +%s%N)"
    local job_dir="/tmp/smarttesthub_${job_id}"
    log_with_timestamp "🔄 Processing $filename in parallel (Job ID: $job_id)" "info"
    process_single_contract "$filename" "$watch_dir" "$job_dir"
    rm -rf "$job_dir" 2>/dev/null || true
    log_with_timestamp "✅ Parallel job completed: $filename" "info"
}

# Health monitoring functions
perform_health_check() {
    local now=$(date +%s)
    if [[ $((now - LAST_HEALTH_CHECK)) -lt $HEALTH_CHECK_INTERVAL ]]; then return 0; fi
    LAST_HEALTH_CHECK=$now
    log_with_timestamp "🩺 Performing health check..." "info"
    local status="healthy"
    local details=()
    local disk=$(df /app | awk 'NR==2{print $5}' | cut -d'%' -f1 2>/dev/null || echo 0)
    if [[ $disk -gt 85 ]]; then
        status="unhealthy"
        details+=("High disk usage: ${disk}%")
        log_with_timestamp "⚠️ High disk usage: ${disk}%" "error"
    fi
    for tool in cargo rustc; do
        if ! command_exists $tool; then
            status="unhealthy"
            details+=("Missing tool: $tool")
            log_with_timestamp "❌ Missing required tool: $tool" "error"
        fi
    done
    for f in "$LOG_FILE" "$ERROR_LOG" "$SECURITY_LOG"; do
        if [[ -f $f ]]; then
            local sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
            (( sz > 104857600 )) && {
                log_with_timestamp "🗜️ Rotating large log file: $f ($sz bytes)" "info"
                mv "$f" "${f}.old"
                touch "$f"
            }
        fi
    done
    cat > /app/logs/health.json <<EOF
{
  "status":"$status",
  "timestamp":"$(date -Iseconds)",
  "uptime":$((now-START_TIME)),
  "details":[$(printf '"%s",' "${details[@]}" | sed 's/,$//')]
}
EOF
    log_with_timestamp "🩺 Health check completed: $status" "info"
}

# Metrics collection
collect_metrics() {
    local now=$(date +%s)
    cat > /app/logs/metrics.json <<EOF
{
  "timestamp":"$(date -Iseconds)",
  "uptime":$((now-START_TIME)),
  "processed_files":$PROCESSED_FILES_COUNT,
  "active_jobs":${#ACTIVE_JOBS[@]},
  "queued_jobs":${#JOB_QUEUE[@]},
  "memory_usage":"$(free | awk 'NR==2{printf "%.2f", $3*100/$2}')%",
  "disk_usage":"$(df /app | awk 'NR==2{print $5}')%"
}
EOF
}

# Logging and utility functions
log_with_timestamp() {
    local msg="$1" type="${2:-info}" ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
    case $type in
      error) echo "$ts ❌ $msg" | tee -a "$LOG_FILE" "$ERROR_LOG" ;;
      security) echo "$ts 🛡️ $msg" | tee -a "$LOG_FILE" "$SECURITY_LOG" ;;
      performance) echo "$ts ⚡ $msg" | tee -a "$LOG_FILE" "$PERFORMANCE_LOG" ;;
      xray) echo "$ts 📡 $msg" | tee -a "$LOG_FILE" "$XRAY_LOG" ;;
      *) echo "$ts $msg" | tee -a "$LOG_FILE" ;;
    esac
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# X-Ray setup
start_xray_daemon() {
    log_with_timestamp "📡 Setting up AWS X-Ray daemon..." "xray"
    if command_exists xray; then
        export AWS_REGION="us-east-1"
        log_with_timestamp "📡 Starting X-Ray daemon..." "xray"
        nohup xray -l -o > "$XRAY_LOG" 2>&1 &
        sleep 2
        if pgrep xray >/dev/null; then
            log_with_timestamp "✅ X-Ray daemon started" "xray"
        else
            log_with_timestamp "❌ Failed to start X-Ray daemon" "error"
        fi
    else
        log_with_timestamp "⚠️ X-Ray daemon not found" "xray"
    fi
}

# Coverage config
generate_tarpaulin_config() {
    if [ ! -f /app/tarpaulin.toml ]; then
        log_with_timestamp "📊 Generating tarpaulin.toml..." "performance"
        cat > /app/tarpaulin.toml <<EOF
[all]
timeout = 300
debug = false
follow-exec = true
verbose = true
workspace = true

out = ["Html","Xml"]
output-dir = "/app/logs/coverage"

exclude-files = ["tests/*","*/build/*","*/dist/*"]
ignore-tests = true
EOF
        log_with_timestamp "✅ Created tarpaulin.toml" "performance"
    fi
}

# Solana environment setup
setup_solana_environment() {
    log_with_timestamp "🔧 Setting up Solana environment..." "info"
    log_with_timestamp "PATH: $PATH" "info"
    if ! command_exists solana; then
        log_with_timestamp "⚠️ Solana CLI not found" "error"
        for p in "$HOME/.local/share/solana/install/active_release/bin" "/root/.local/share/solana/install/active_release/bin"; do
            if [ -d "$p" ]; then
                export PATH="$p:$PATH"
                log_with_timestamp "🔍 Added $p to PATH" "info"
                break
            fi
        done
    fi
    if ! command_exists solana; then
        log_with_timestamp "🔄 Installing Solana CLI..." "info"
        curl -sSfL https://release.solana.com/v1.17.3/install | sh
        export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"
    fi
    if ! command_exists solana; then
        log_with_timestamp "❌ Solana CLI still missing" "error"
        return 1
    fi
    if [ ! -f ~/.config/solana/id.json ]; then
        mkdir -p ~/.config/solana
        solana-keygen new --no-bip39-passphrase --silent --outfile ~/.config/solana/id.json
        log_with_timestamp "✅ Solana keypair generated" "info"
    fi
    local url="${SOLANA_URL:-https://api.devnet.solana.com}"
    solana config set --url "$url" --keypair ~/.config/solana/id.json
    return 0
}

# Project type detection
detect_project_type() {
    local f="$1"
    if grep -q "#\[program\]" "$f" || grep -q "use anchor_lang::prelude" "$f"; then
        echo "anchor"
    elif grep -q "entrypoint\!" "$f"; then
        echo "native"
    else
        echo "unknown"
    fi
}

# Main contract processing
process_single_contract() {
    local filename="$1" watch_dir="$2" iso_dir="${3:-$project_dir}"
    local start=$(date +%s)
    local name type
    validate_contract_file "$watch_dir/$filename" || return 1
    name=$(sanitize_contract_name "${filename%.rs}")
    log_with_timestamp "🆕 Processing $filename as $name" "info"
    mkdir -p "$iso_dir/src" "$iso_dir/logs"
    cp "$watch_dir/$filename" "$iso_dir/src/lib.rs"
    type=$(detect_project_type "$iso_dir/src/lib.rs")
    create_dynamic_cargo_toml "$name" "$iso_dir/src/lib.rs" "$type" "$iso_dir"
    create_test_files "$name" "$type" "$iso_dir"
    build_contract_with_monitoring "$name" "$iso_dir" || return 1
    run_comprehensive_analysis "$name" "$iso_dir"
    local end=$(date +%s)
    generate_comprehensive_report "$name" "$type" "$start" "$end" "$iso_dir"
    ((PROCESSED_FILES_COUNT++))
    log_with_timestamp "🏁 Completed $filename" "info"
}

build_contract_with_monitoring() {
    local name="$1" dir="$2"
    log_with_timestamp "🔨 Building $name..." "info"
    cd "$dir"
    monitor_resources || { sleep 10; monitor_resources || return 1; }
    timeout 600 cargo build-sbf 2>&1 | tee -a "$LOG_FILE" &
    local pid=$!
    local start=$(date +%s)
    while kill -0 $pid 2>/dev/null; do
        sleep 5
        (( $(date +%s)-start > 600 )) && { kill $pid; return 1; }
        monitor_resources || log_with_timestamp "⚠️ High usage during build" "performance"
    done
    wait $pid
    return $?
}

create_dynamic_cargo_toml() {
    local name="$1" src="$2" type="$3" dir="$4"
    log_with_timestamp "📝 Creating Cargo.toml for $name ($type)" "info"
    cat > "$dir/Cargo.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"
edition = "2021"
description = "Processed by SmartTestHub"

[lib]
crate-type = ["cdylib","lib"]

[dependencies]
solana-program = "1.17.0"
borsh = "0.10.3"
borsh-derive = "0.10.3"
EOF
    if [[ "$type" == "anchor" ]]; then
        cat >> "$dir/Cargo.toml" <<EOF
anchor-lang = "0.29.0"
anchor-spl = "0.29.0"
EOF
    fi
    cat >> "$dir/Cargo.toml" <<EOF

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
}

create_test_files() {
    local name="$1" type="$2" dir="$3"
    log_with_timestamp "🧪 Creating tests for $name ($type)" "info"
    mkdir -p "$dir/tests"
    case "$type" in
        anchor)
            cat > "$dir/tests/test_${name}.rs" <<EOF
use anchor_lang::prelude::*;
use solana_program_test::*;
use solana_sdk::signature::Signer;

use ${name}::*;

#[tokio::test]
async fn test_${name}_init() {
    let program_id = Pubkey::new_unique();
    let mut pt = ProgramTest::new("${name}", program_id, processor!(process_instruction));
    let (mut banks, payer, _) = pt.start().await;
    assert!(true);
}
EOF
            ;;
        native)
            cat > "$dir/tests/test_${name}.rs" <<EOF
use solana_program_test::*;
use solana_sdk::signature::Signer;

use ${name}::*;

#[tokio::test]
async fn test_${name}_basic() {
    let program_id = Pubkey::new_unique();
    let mut pt = ProgramTest::new("${name}", program_id, processor!(process_instruction));
    let (mut banks, payer, _) = pt.start().await;
    assert!(true);
}
EOF
            ;;
        *)
            cat > "$dir/tests/test_${name}.rs" <<EOF
#[tokio::test]
async fn test_${name}_placeholder() {
    assert!(true, "Placeholder test");
}
EOF
            ;;
    esac
    log_with_timestamp "✅ Created tests for $name" "info"
}

run_comprehensive_analysis() {
    local name="$1" dir="$2"
    cd "$dir"
    run_tests_with_coverage "$name"
    run_security_audit "$name"
    run_performance_analysis "$name"
}

run_tests_with_coverage() {
    local name="$1"
    log_with_timestamp "🧪 Running coverage for $name" "performance"
    mkdir -p /app/logs/coverage
    if cargo tarpaulin --config-path /app/tarpaulin.toml -v; then
        log_with_timestamp "✅ Coverage completed" "performance"
    else
        log_with_timestamp "⚠️ Coverage issues" "error"
    fi
}

run_security_audit() {
    local name="$1" dir="$2"
    log_with_timestamp "🛡️ Running security audit for $name" "security"
    mkdir -p /app/logs/security
    cargo generate-lockfile >/dev/null 2>&1 || true
    cargo audit -f "$dir/Cargo.lock" > /app/logs/security/cargo-audit.log 2>&1
    cargo clippy --all-targets --all-features -- -D warnings > /app/logs/security/clippy.log 2>&1 || log_with_timestamp "⚠️ Clippy warnings" "security"
}

run_performance_analysis() {
    local name="$1" dir="$2"
    log_with_timestamp "⚡ Running performance for $name" "performance"
    mkdir -p /app/logs/benchmarks
    local s=$(date +%s)
    cargo build --release > /app/logs/benchmarks/build-time.log 2>&1
    local e=$(date +%s)
    log_with_timestamp "✅ Release build in $((e-s))s" "performance"
    if [[ -f "$dir/target/release/${name}.so" ]]; then
        local sz=$(du -h "$dir/target/release/${name}.so" | cut -f1)
        log_with_timestamp "📊 Program size: $sz" "performance"
    fi
}

generate_comprehensive_report() {
    local name="$1" type="$2" start="$3" end="$4" dir="$5"
    local elapsed=$((end-start))
    log_with_timestamp "📝 Generating report for $name" "info"
    mkdir -p /app/logs/reports
    local rpt="/app/logs/reports/${name}_report.md"
    cat > "$rpt" <<EOF
# Report for $name

- **Project Type:** $type
- **Processing Time:** ${elapsed}s

## Tests & Coverage
EOF
    if [[ -f /app/logs/coverage/tarpaulin-report.html ]]; then
        echo "- ✅ Coverage report: /app/logs/coverage/tarpaulin-report.html" >> "$rpt"
    else
        echo "- ⚠️ No coverage report" >> "$rpt"
    fi
    cat >> "$rpt" <<EOF

## Security
- Details: /app/logs/security/cargo-audit.log
- Clippy: /app/logs/security/clippy.log

## Performance
- Build time: /app/logs/benchmarks/build-time.log
EOF
    log_with_timestamp "✅ Report generated at $rpt" "info"
}

# Start X-Ray if enabled
if [[ "$AWS_XRAY_SDK_ENABLED" == "true" ]]; then
    start_xray_daemon
fi

generate_tarpaulin_config

# Clear logs
: > "$LOG_FILE"
: > "$ERROR_LOG"

watch_dir="/app/input"
project_dir="/app"

log_with_timestamp "🚀 Starting Enhanced Non-EVM (Solana) Container" "info"

# Secure and Solana environment
setup_secure_environment
setup_solana_environment || log_with_timestamp "❌ Solana setup failed" "error"

mkdir -p "$watch_dir"

log_with_timestamp "📡 Watching $watch_dir (max jobs: $MAX_CONCURRENT_JOBS)" "info"

# Main file-watcher loop with parallel processing
inotifywait -m -e close_write,moved_to,create "$watch_dir" |
while read -r dir ev file; do
    perform_health_check
    collect_metrics

    if [[ "$file" == *.rs ]]; then
        log_with_timestamp "📥 Detected: $file" "info"
        if [[ ${#ACTIVE_JOBS[@]} -lt $MAX_CONCURRENT_JOBS ]]; then
            process_contract_parallel "$file|$watch_dir" &
        else
            add_job_to_queue "$file|$watch_dir"
        fi
    fi

    wait_for_job_completion
    process_job_queue

    log_with_timestamp "📊 Status - Active:${#ACTIVE_JOBS[@]} Queued:${#JOB_QUEUE[@]} Processed:$PROCESSED_FILES_COUNT" "info"
done