#!/bin/bash
set -e

# Enhanced entrypoint script for Non-EVM (Solana) container
# Provides comprehensive testing, security analysis, and reporting

LOG_FILE="/app/logs/test.log"
ERROR_LOG="/app/logs/error.log"
SECURITY_LOG="/app/logs/security/security-audit.log"
PERFORMANCE_LOG="/app/logs/analysis/performance.log"

# Create all required directories
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$ERROR_LOG")"
mkdir -p "$(dirname "$SECURITY_LOG")"
mkdir -p "$(dirname "$PERFORMANCE_LOG")"
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
        *)
            echo "$timestamp $message" | tee -a "$LOG_FILE"
            ;;
    esac
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to setup Solana environment
setup_solana_environment() {
    log_with_timestamp "🔧 Setting up Solana environment..."
    
    # Generate keypair if it doesn't exist
    if [ ! -f ~/.config/solana/id.json ]; then
        log_with_timestamp "🔑 Generating new Solana keypair..."
        mkdir -p ~/.config/solana
        solana-keygen new --no-bip39-passphrase --silent --outfile ~/.config/solana/id.json
        log_with_timestamp "✅ Solana keypair generated"
    fi
    
    # Set Solana configuration
    local solana_url="${SOLANA_URL:-https://api.devnet.solana.com}"
    solana config set --url "$solana_url" --keypair ~/.config/solana/id.json >/dev/null 2>&1
    
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
}

# Function to detect project type
detect_project_type() {
    local contract_file="$1"
    
    if grep -q "anchor_lang" "$contract_file"; then
        echo "anchor"
    elif grep -q "solana_program" "$contract_file"; then
        echo "native"
    else
        echo "unknown"
    fi
}

# Function to create dynamic Cargo.toml based on detected dependencies
create_dynamic_cargo_toml() {
    local contract_name="$1"
    local contract_file="$2"
    local project_type="$3"
    
    log_with_timestamp "📝 Creating dynamic Cargo.toml for $contract_name ($project_type project)"
    
    case $project_type in
        "anchor")
            cat > "/app/Cargo.toml" <<EOF
[package]
name = "$contract_name"
version = "0.1.0"
edition = "2021"
description = "Anchor-based Solana smart contract"
license = "MIT"

[dependencies]
anchor-lang = "0.29.0"
anchor-spl = "0.29.0"
solana-program = "1.18.3"
borsh = { version = "0.10.3", features = ["derive"] }
thiserror = "1.0"

[dev-dependencies]
anchor-client = "0.29.0"
solana-program-test = "1.18.3"
solana-banks-client = "1.18.3"
tokio = { version = "1.0", features = ["full"] }

[lib]
name = "$contract_name"
path = "src/lib.rs"
crate-type = ["cdylib", "lib"]

[features]
default = []
no-entrypoint = []
test-sbf = []
EOF
            ;;
        "native")
            cat > "/app/Cargo.toml" <<EOF
[package]
name = "$contract_name"
version = "0.1.0"
edition = "2021"
description = "Native Solana smart contract"
license = "MIT"

[dependencies]
solana-program = "1.18.3"
borsh = { version = "0.10.3", features = ["derive"] }
thiserror = "1.0"
spl-token = { version = "4.0", features = ["no-entrypoint"] }
spl-associated-token-account = { version = "2.3", features = ["no-entrypoint"] }

[dev-dependencies]
solana-program-test = "1.18.3"
solana-banks-client = "1.18.3"
tokio = { version = "1.0", features = ["full"] }

[lib]
name = "$contract_name"
path = "src/lib.rs"
crate-type = ["cdylib", "lib"]

[features]
default = []
no-entrypoint = []
test-sbf = []
EOF
            ;;
        *)
            log_with_timestamp "⚠️ Unknown project type, using basic configuration"
            cat > "/app/Cargo.toml" <<EOF
[package]
name = "$contract_name"
version = "0.1.0"
edition = "2021"

[dependencies]
solana-program = "1.18.3"

[lib]
name = "$contract_name"
path = "src/lib.rs"
crate-type = ["cdylib", "lib"]
EOF
            ;;
    esac
}

# Function to create test files if they don't exist
create_test_files() {
    local contract_name="$1"
    local project_type="$2"
    
    # Create integration test
    if [ ! -f "/app/tests/integration.rs" ]; then
        mkdir -p /app/tests
        case $project_type in
            "anchor")
                cat > "/app/tests/integration.rs" <<EOF
use anchor_lang::prelude::*;
use solana_program_test::*;
use solana_sdk::{signature::Signer, transaction::Transaction};

#[tokio::test]
async fn test_${contract_name}_integration() {
    let program_test = ProgramTest::new(
        "${contract_name}",
        ${contract_name}::id(),
        processor!(${contract_name}::entry),
    );
    let (mut banks_client, payer, recent_blockhash) = program_test.start().await;
    
    // Add your integration tests here
    assert!(true, "Integration test placeholder");
}
EOF
                ;;
            *)
                cat > "/app/tests/integration.rs" <<EOF
use solana_program_test::*;
use solana_sdk::{signature::Signer, transaction::Transaction};

#[tokio::test]
async fn test_${contract_name}_integration() {
    let program_test = ProgramTest::default();
    let (mut banks_client, payer, recent_blockhash) = program_test.start().await;
    
    // Add your integration tests here
    assert!(true, "Integration test placeholder");
}
EOF
                ;;
        esac
        log_with_timestamp "📝 Created integration test file"
    fi
}

# Function to run comprehensive security audit
run_security_audit() {
    local contract_name="$1"
    
    log_with_timestamp "🛡️ Running comprehensive security audit..." "security"
    
    # Run cargo-audit with custom config if available
    if [ -f "/app/config/audit.toml" ]; then
        log_with_timestamp "🔍 Running cargo-audit with custom configuration..." "security"
        if cargo audit --config /app/config/audit.toml --json 2>&1 | tee /app/logs/security/audit-report.json; then
            log_with_timestamp "✅ Security audit completed successfully" "security"
        else
            log_with_timestamp "⚠️ Security audit found issues - check logs/security/audit-report.json" "security"
        fi
    else
        log_with_timestamp "🔍 Running cargo-audit with default configuration..." "security"
        if cargo audit --json 2>&1 | tee /app/logs/security/audit-report.json; then
            log_with_timestamp "✅ Security audit completed successfully" "security"
        else
            log_with_timestamp "⚠️ Security audit found issues" "security"
        fi
    fi
    
    # Run cargo-deny for additional security checks
    if command_exists cargo-deny; then
        log_with_timestamp "🔒 Running cargo-deny for license and security checks..." "security"
        if cargo deny check 2>&1 | tee /app/logs/security/deny-report.txt; then
            log_with_timestamp "✅ Cargo-deny checks passed" "security"
        else
            log_with_timestamp "⚠️ Cargo-deny found issues" "security"
        fi
    fi
}

# Function to run performance benchmarks
run_performance_analysis() {
    local contract_name="$1"
    
    log_with_timestamp "⚡ Running performance analysis..." "performance"
    
    # Create benchmarks directory if it doesn't exist
    mkdir -p /app/benches
    
    # Create a basic benchmark if none exists
    if [ ! -f "/app/benches/${contract_name}_bench.rs" ]; then
        cat > "/app/benches/${contract_name}_bench.rs" <<EOF
use criterion::{black_box, criterion_group, criterion_main, Criterion};

fn benchmark_${contract_name}(c: &mut Criterion) {
    c.bench_function("${contract_name}_basic", |b| {
        b.iter(|| {
            // Add your benchmark code here
            black_box(1 + 1)
        })
    });
}

criterion_group!(benches, benchmark_${contract_name});
criterion_main!(benches);
EOF
        log_with_timestamp "📊 Created benchmark file for $contract_name" "performance"
    fi
    
    # Add criterion to Cargo.toml if not present
    if ! grep -q "criterion" /app/Cargo.toml; then
        cat >> /app/Cargo.toml <<EOF

[dev-dependencies]
criterion = { version = "0.5", features = ["html_reports"] }

[[bench]]
name = "${contract_name}_bench"
harness = false
EOF
        log_with_timestamp "📊 Added criterion benchmark configuration" "performance"
    fi
}

# Function to generate comprehensive report
generate_comprehensive_report() {
    local contract_name="$1"
    local project_type="$2"
    local start_time="$3"
    local end_time="$4"
    
    local duration=$((end_time - start_time))
    
    log_with_timestamp "📋 Generating comprehensive test report..."
    
    cat > "/app/logs/reports/comprehensive-report-${contract_name}.md" <<EOF
# Comprehensive Test Report: ${contract_name}

## Test Summary
- **Contract Name**: ${contract_name}
- **Project Type**: ${project_type}
- **Test Duration**: ${duration} seconds
- **Test Date**: $(date '+%Y-%m-%d %H:%M:%S')
- **Solana Network**: ${SOLANA_URL:-devnet}

## Test Results Overview
$(grep -c "✅" "$LOG_FILE" || echo "0") successful operations
$(grep -c "❌" "$LOG_FILE" || echo "0") failed operations  
$(grep -c "⚠️" "$LOG_FILE" || echo "0") warnings

## Compilation Status
- **Build Status**: $(grep -q "✅.*successful" "$LOG_FILE" && echo "✅ PASSED" || echo "❌ FAILED")
- **Test Status**: $(grep -q "✅.*tests passed" "$LOG_FILE" && echo "✅ PASSED" || echo "❌ FAILED")

## Security Analysis
- **Audit Status**: $(grep -q "✅.*audit.*completed" "$LOG_FILE" && echo "✅ CLEAN" || echo "⚠️ ISSUES FOUND")
- **Clippy Status**: $(grep -q "✅.*Clippy.*passed" "$LOG_FILE" && echo "✅ PASSED" || echo "⚠️ ISSUES FOUND")

## Coverage Analysis
- **Coverage Report**: $([ -f "/app/logs/coverage/tarpaulin-report.html" ] && echo "✅ GENERATED" || echo "❌ FAILED")
- **Coverage Threshold**: ${COVERAGE_THRESHOLD:-70}%

## Generated Artifacts
- **Main Log**: \`logs/test.log\`
- **Error Log**: \`logs/error.log\`
- **Security Report**: \`logs/security/audit-report.json\`
- **Coverage Report**: \`logs/coverage/tarpaulin-report.html\`
- **Performance Log**: \`logs/analysis/performance.log\`

## File Locations
- **Source**: \`src/lib.rs\`
- **Tests**: \`tests/\`
- **Benchmarks**: \`benches/\`
- **Build Output**: \`target/\`

---
Generated by SmartTestHub Non-EVM Container
EOF

    log_with_timestamp "📋 Comprehensive report saved to logs/reports/comprehensive-report-${contract_name}.md"
}

# Clear old logs
: > "$LOG_FILE"
: > "$ERROR_LOG"

watch_dir="/app/input"
project_dir="/app"

log_with_timestamp "🚀 Starting Enhanced Non-EVM (Solana) Container..."
log_with_timestamp "📡 Watching for smart contract files in $watch_dir..."
log_with_timestamp "🔧 Environment: ${RUST_LOG:-info} log level"

# Setup Solana environment
setup_solana_environment || {
    log_with_timestamp "❌ Failed to setup Solana environment" "error"
    exit 1
}

# Ensure watch directory exists
mkdir -p "$watch_dir"

# Start file watching loop
inotifywait -m -e close_write,moved_to,create "$watch_dir" |
while read -r directory events filename; do
    if [[ "$filename" == *.rs ]]; then
        {
            start_time=$(date +%s)
            log_with_timestamp "🆕 Processing new Rust contract: $filename"
            
            # Extract contract name
            contract_name="${filename%.rs}"
            
            # Create source directory
            mkdir -p "$project_dir/src"
            
            # Copy contract file
            cp "$watch_dir/$filename" "$project_dir/src/lib.rs"
            log_with_timestamp "📁 Contract copied to src/lib.rs"
            
            # Detect project type
            project_type=$(detect_project_type "$project_dir/src/lib.rs")
            log_with_timestamp "🔍 Detected project type: $project_type"
            
            # Create dynamic Cargo.toml
            create_dynamic_cargo_toml "$contract_name" "$project_dir/src/lib.rs" "$project_type"
            
            # Create test files
            create_test_files "$contract_name" "$project_type"
            
            # Build the project
            log_with_timestamp "🔨 Building $contract_name ($project_type)..."
            case $project_type in
                "anchor")
                    # Create/update Anchor.toml
                    cat > "$project_dir/Anchor.toml" <<EOF
[features]
seed = false
skip-lint = false

[programs.localnet]
$contract_name = "target/deploy/${contract_name}.so"

[registry]
url = "https://api.apr.dev"

[provider]
cluster = "${SOLANA_URL:-https://api.devnet.solana.com}"
wallet = "~/.config/solana/id.json"

[scripts]
test = "cargo test-sbf"

[test]
startup_wait = 5000
shutdown_wait = 2000
upgrade_wait = 1000
EOF
                    
                    if anchor build 2>&1 | tee -a "$LOG_FILE"; then
                        log_with_timestamp "✅ Anchor build successful"
                    else
                        log_with_timestamp "❌ Anchor build failed, trying cargo build-sbf..." "error"
                        if cargo build-sbf 2>&1 | tee -a "$LOG_FILE"; then
                            log_with_timestamp "✅ Cargo build-sbf successful"
                        else
                            log_with_timestamp "❌ All builds failed for $contract_name" "error"
                            continue
                        fi
                    fi
                    ;;
                *)
                    if cargo build-sbf 2>&1 | tee -a "$LOG_FILE"; then
                        log_with_timestamp "✅ Build successful"
                    else
                        log_with_timestamp "❌ Build failed for $contract_name" "error"
                        continue
                    fi
                    ;;
            esac
            
            # Run tests
            log_with_timestamp "🧪 Running tests for $contract_name..."
            case $project_type in
                "anchor")
                    if anchor test --skip-local-validator 2>&1 | tee -a "$LOG_FILE"; then
                        log_with_timestamp "✅ Anchor tests passed"
                    else
                        log_with_timestamp "❌ Anchor tests failed" "error"
                    fi
                    ;;
                *)
                    if cargo test-sbf 2>&1 | tee -a "$LOG_FILE"; then
                        log_with_timestamp "✅ Native Solana tests passed"
                    else
                        log_with_timestamp "❌ Native Solana tests failed" "error"
                    fi
                    ;;
            esac
            
            # Run integration tests
            log_with_timestamp "🔗 Running integration tests..."
            if cargo test --test integration 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ Integration tests passed"
            else
                log_with_timestamp "⚠️ Integration tests failed or skipped"
            fi
            
            # Generate coverage report
            log_with_timestamp "📊 Generating coverage report with Tarpaulin..."
            if cargo tarpaulin --config /app/config/tarpaulin.toml 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ Coverage report generated successfully"
            else
                log_with_timestamp "⚠️ Coverage generation failed"
            fi
            
            # Static analysis with Clippy
            log_with_timestamp "🔎 Running static analysis with Clippy..."
            clippy_args="-- -D warnings"
            if [ "$CLIPPY_PEDANTIC" = "true" ]; then
                clippy_args="-- -D warnings -D clippy::pedantic"
            fi
            
            if cargo clippy $clippy_args 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ Clippy check passed"
            else
                log_with_timestamp "⚠️ Clippy found issues"
            fi
            
            # Security audit
            run_security_audit "$contract_name"
            
            # Performance analysis
            run_performance_analysis "$contract_name"
            
            # Check for outdated dependencies
            log_with_timestamp "📦 Checking for outdated dependencies..."
            if cargo outdated 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ Dependency check completed"
            else
                log_with_timestamp "⚠️ Could not check dependencies"
            fi
            
            # Generate documentation
            log_with_timestamp "📚 Generating documentation..."
            if cargo doc --no-deps 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ Documentation generated"
            else
                log_with_timestamp "⚠️ Documentation generation failed"
            fi
            
            # Clean up build artifacts to save space
            log_with_timestamp "🧹 Cleaning up build artifacts..."
            cargo clean --release 2>/dev/null || true
            
            # Generate comprehensive report
            end_time=$(date +%s)
            generate_comprehensive_report "$contract_name" "$project_type" "$start_time" "$end_time"
            
            log_with_timestamp "🏁 Completed processing $filename"
            log_with_timestamp "==========================================\n"
            
        } 2>&1
    fi
done
