#!/bin/bash
set -e

LOG_FILE="/app/logs/test.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

watch_dir="/app/src"
project_dir="/app"

echo "📡 Watching for new smart contract files in $watch_dir ..."

# Ensure the watch directory exists
mkdir -p "$watch_dir"

# Start watching for Rust smart contract files
inotifywait -m -e close_write,moved_to,create "$watch_dir" |
while read -r directory events filename; do
    if [[ "$filename" == *.rs ]]; then
        echo "🆕 Detected new Rust file: $filename"

        # Extract base name (e.g., vault.rs → vault)
        contract_name="${filename%.rs}"

        # Replace old lib.rs if it exists
        rm -f "$watch_dir/lib.rs"
        mv "$watch_dir/$filename" "$watch_dir/lib.rs"

        # Dynamically rewrite Cargo.toml
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

        echo "📝 Updated Cargo.toml for contract: $contract_name"

        # Build the smart contract
        echo "⚙️  Building contract..."
        if ! cargo build-bpf; then
            echo "❌ Build failed for $contract_name. Skipping tests."
            continue
        fi

        # Run BPF unit tests
        echo "🧪 Running tests..."
        if ! cargo test-bpf; then
            echo "❌ Tests failed for $contract_name."
            continue
        fi
        echo "✅ Tests passed for $contract_name"

        # Run Tarpaulin for test coverage
        echo "🧮 Generating coverage report with Tarpaulin..."
        if ! cargo tarpaulin --out Html; then
            echo "⚠️ Coverage generation failed"
        else
            echo "✅ Coverage report generated at /app/html/index.html"
        fi

        # Static analysis using Clippy
        echo "🔎 Running static analysis with Clippy..."
        if ! cargo clippy -- -D warnings; then
            echo "⚠️ Clippy found issues"
        else
            echo "✅ Clippy check passed"
        fi

        # Security audit with cargo-audit
        echo "🛡️ Running dependency security audit..."
        if ! cargo audit; then
            echo "⚠️ Vulnerabilities found in dependencies"
        else
            echo "✅ No known vulnerabilities found"
        fi

        # Optional fuzzing
        echo "🎯 Checking for fuzz targets..."
        if [[ -d fuzz && -f fuzz/fuzz_targets/fuzz_target_1.rs ]]; then
            echo "🚀 Running fuzz target..."
            if ! cargo fuzz run fuzz_target_1; then
                echo "⚠️ Fuzzing failed"
            else
                echo "✅ Fuzzing completed"
            fi
        else
            echo "ℹ️ No fuzz targets found. Skipping fuzzing."
        fi

        echo "🏁 Done processing $filename"
    fi
done

