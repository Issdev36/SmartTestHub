#!/bin/bash
set -e

LOG_FILE="/app/logs/test.log"
mkdir -p "$(dirname "$LOG_FILE")"

# Function to log with timestamp
log_with_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Clear old log
: > "$LOG_FILE"

watch_dir="/app/input"
project_dir="/app"

log_with_timestamp "🚀 Starting Non-EVM (Solana) container..."
log_with_timestamp "📡 Watching for new smart contract files in $watch_dir ..."

# Ensure the watch directory exists
mkdir -p "$watch_dir"

# Generate a new Solana keypair if one doesn't exist
if [ ! -f ~/.config/solana/id.json ]; then
    log_with_timestamp "🔑 Generating Solana keypair..."
    mkdir -p ~/.config/solana
    solana-keygen new --no-bip39-passphrase --silent --outfile ~/.config/solana/id.json
fi

# Set Solana to use localhost for testing
solana config set --url localhost >/dev/null 2>&1 || true
log_with_timestamp "✅ Solana CLI configured"

# Start watching for Rust smart contract files dropped by backend
inotifywait -m -e close_write,moved_to,create "$watch_dir" |
while read -r directory events filename; do
    if [[ "$filename" == *.rs ]]; then
        {
            log_with_timestamp "🆕 Detected new Rust file: $filename"

            # Extract base name (e.g., vault.rs → vault)
            contract_name="${filename%.rs}"

            # Create src directory if it doesn't exist
            mkdir -p "$project_dir/src"

            # Replace old lib.rs if it exists
            rm -f "$project_dir/src/lib.rs"
            cp "$watch_dir/$filename" "$project_dir/src/lib.rs"

            # Dynamically rewrite Cargo.toml based on detected contract
            cat > "$project_dir/Cargo.toml" <<EOF
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

[features]
no-entrypoint = []
EOF

            log_with_timestamp "📝 Updated Cargo.toml for contract: $contract_name"

            # Check if this is an Anchor project (contains anchor imports)
            if grep -q "anchor_lang" "$project_dir/src/lib.rs"; then
                log_with_timestamp "🏗️ Detected Anchor project, using anchor build..."
                
                # Create/update Anchor.toml for the specific contract
                cat > "$project_dir/Anchor.toml" <<EOF
[features]
seed = false
skip-lint = false

[programs.localnet]
$contract_name = "target/deploy/${contract_name}.so"

[registry]
url = "https://api.apr.dev"

[provider]
cluster = "Localnet"
wallet = "~/.config/solana/id.json"

[scripts]
test = "yarn run ts-mocha -p ./tsconfig.json -t 1000000 tests/**/*.ts"
EOF

                # Try to build with Anchor
                log_with_timestamp "🔨 Building with Anchor..."
                if anchor build 2>&1 | tee -a "$LOG_FILE"; then
                    log_with_timestamp "✅ Anchor build successful"
                else
                    log_with_timestamp "❌ Anchor build failed, trying cargo build-sbf..."
                    if cargo build-sbf 2>&1 | tee -a "$LOG_FILE"; then
                        log_with_timestamp "✅ Cargo build-sbf successful"
                    else
                        log_with_timestamp "❌ Build failed for $contract_name. Skipping tests."
                        continue
                    fi
                fi

                # Run Anchor tests if test files exist
                if [ -d "tests" ] && [ "$(ls -A tests/ 2>/dev/null)" ]; then
                    log_with_timestamp "🧪 Running Anchor tests..."
                    if anchor test --skip-local-validator 2>&1 | tee -a "$LOG_FILE"; then
                        log_with_timestamp "✅ Anchor tests passed"
                    else
                        log_with_timestamp "❌ Anchor tests failed for $contract_name"
                    fi
                else
                    log_with_timestamp "ℹ️ No Anchor test files found"
                fi
            else
                log_with_timestamp "🏗️ Building native Solana program..."
                # Build the smart contract using cargo build-sbf (updated command)
                if cargo build-sbf 2>&1 | tee -a "$LOG_FILE"; then
                    log_with_timestamp "✅ Build successful"
                else
                    log_with_timestamp "❌ Build failed for $contract_name. Skipping tests."
                    continue
                fi

                # Run BPF unit tests
                log_with_timestamp "🧪 Running native Solana tests..."
                if cargo test-sbf 2>&1 | tee -a "$LOG_FILE"; then
                    log_with_timestamp "✅ Tests passed for $contract_name"
                else
                    log_with_timestamp "❌ Tests failed for $contract_name"
                fi
            fi

            # Run Tarpaulin for test coverage (only for unit tests)
            log_with_timestamp "🧮 Generating coverage report with Tarpaulin..."
            if cargo tarpaulin --out Html --output-dir ./logs/coverage 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ Coverage report generated at /app/logs/coverage/tarpaulin-report.html"
            else
                log_with_timestamp "⚠️ Coverage generation failed"
            fi

            # Static analysis using Clippy
            log_with_timestamp "🔎 Running static analysis with Clippy..."
            if cargo clippy -- -D warnings 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ Clippy check passed"
            else
                log_with_timestamp "⚠️ Clippy found issues"
            fi

            # Security audit with cargo-audit
            log_with_timestamp "🛡️ Running dependency security audit..."
            if cargo audit 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ No known vulnerabilities found"
            else
                log_with_timestamp "⚠️ Vulnerabilities found in dependencies"
            fi

            # Check for outdated dependencies
            log_with_timestamp "📦 Checking for outdated dependencies..."
            if cargo outdated 2>&1 | tee -a "$LOG_FILE"; then
                log_with_timestamp "✅ Dependency check completed"
            else
                log_with_timestamp "⚠️ Could not check for outdated dependencies"
            fi

            log_with_timestamp "🏁 Done processing $filename"
            log_with_timestamp "==========================================\n"
            
        } 2>&1
    fi
done
