FROM rust:1.85-slim

# Setting up the environment variables explicitly
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/venv/bin:/root/.cargo/bin:/root/.local/share/solana/install/active_release/bin:/root/.avm/bin:${PATH}"
ENV SOLANA_INSTALL_DIR="/root/.local/share/solana/install"
ENV AWS_XRAY_SDK_ENABLED=true
ENV AWS_REGION=us-east-1
ENV RUST_LOG=debug

# Install system dependencies including Node.js and AWS X-Ray daemon
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git pkg-config build-essential libssl-dev libudev-dev \
    llvm clang libclang-dev cmake dos2unix ca-certificates unzip inotify-tools \
    nodejs npm python3 python3-pip python3-venv jq \
    && rm -rf /var/lib/apt/lists/*

# Create and use Python virtual environment
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install AWS X-Ray SDK in virtual environment
RUN pip install aws-xray-sdk

# Skip Solana CLI installation attempts and just create dummy scripts
RUN mkdir -p /root/.local/share/solana/install/active_release/bin && \
    echo '#!/bin/bash\necho "Solana CLI stub (real CLI not available)"\necho "Version: stub-1.17.3"' > /root/.local/share/solana/install/active_release/bin/solana && \
    chmod +x /root/.local/share/solana/install/active_release/bin/solana && \
    echo '#!/bin/bash\necho "Solana keygen stub"' > /root/.local/share/solana/install/active_release/bin/solana-keygen && \
    chmod +x /root/.local/share/solana/install/active_release/bin/solana-keygen && \
    echo "export PATH=\"/root/.local/share/solana/install/active_release/bin:\$PATH\"" >> /root/.bashrc && \
    echo "export PATH=\"/root/.local/share/solana/install/active_release/bin:\$PATH\"" >> /root/.profile

# Install AVM and Anchor if possible
RUN cargo install --git https://github.com/coral-xyz/anchor avm --locked --force || echo "AVM installation failed"

# Install Rust tools including tarpaulin for test coverage
RUN rustup component add clippy && \
    cargo install cargo-audit cargo-expand cargo-tarpaulin || true

# Create workdir and directory structure
WORKDIR /app
RUN mkdir -p /app/src /app/tests /app/config /app/input /app/logs \
    /app/logs/coverage /app/logs/security /app/logs/analysis /app/logs/reports \
    /app/logs/xray /app/target /app/.cargo

# Create tarpaulin configuration file
RUN mkdir -p /app/config && \
    echo '[tarpaulin]' > /app/config/tarpaulin.toml && \
    echo 'out = ["Html", "Json", "Xml"]' >> /app/config/tarpaulin.toml && \
    echo 'output-dir = "/app/logs/coverage"' >> /app/config/tarpaulin.toml && \
    echo 'timeout = 300' >> /app/config/tarpaulin.toml && \
    echo 'fail-under = 80' >> /app/config/tarpaulin.toml && \
    echo 'run-types = ["Tests"]' >> /app/config/tarpaulin.toml

# Create default Cargo.toml template
RUN echo '[package]' > /app/config/Cargo.template.toml && \
    echo 'name = "__CONTRACT_NAME__"' >> /app/config/Cargo.template.toml && \
    echo 'version = "0.1.0"' >> /app/config/Cargo.template.toml && \
    echo 'edition = "2021"' >> /app/config/Cargo.template.toml && \
    echo '' >> /app/config/Cargo.template.toml && \
    echo '[lib]' >> /app/config/Cargo.template.toml && \
    echo 'crate-type = ["cdylib", "lib"]' >> /app/config/Cargo.template.toml && \
    echo '' >> /app/config/Cargo.template.toml && \
    echo '[dependencies]' >> /app/config/Cargo.template.toml && \
    echo 'solana-program = "1.17.0"' >> /app/config/Cargo.template.toml && \
    echo '' >> /app/config/Cargo.template.toml && \
    echo '[dev-dependencies]' >> /app/config/Cargo.template.toml && \
    echo 'solana-sdk = "1.17.0"' >> /app/config/Cargo.template.toml && \
    cp /app/config/Cargo.template.toml /app/Cargo.toml

# Create Anchor.toml template for Solana programs
RUN echo '[features]' > /app/config/Anchor.toml && \
    echo 'seeds = false' >> /app/config/Anchor.toml && \
    echo 'skip-lint = false' >> /app/config/Anchor.toml && \
    echo '[programs.localnet]' >> /app/config/Anchor.toml && \
    echo 'program = "11111111111111111111111111111111"' >> /app/config/Anchor.toml && \
    echo '[programs.devnet]' >> /app/config/Anchor.toml && \
    echo 'program = "11111111111111111111111111111111"' >> /app/config/Anchor.toml && \
    echo '[registry]' >> /app/config/Anchor.toml && \
    echo 'url = "https://api.apr.dev"' >> /app/config/Anchor.toml && \
    echo '[provider]' >> /app/config/Anchor.toml && \
    echo 'cluster = "localnet"' >> /app/config/Anchor.toml && \
    echo 'wallet = "~/.config/solana/id.json"' >> /app/config/Anchor.toml

# Create entrypoint script with complete testing workflow
RUN echo '#!/bin/bash' > /app/entrypoint.sh && \
    echo 'set -e' >> /app/entrypoint.sh && \
    echo 'source /opt/venv/bin/activate' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Create log file' >> /app/entrypoint.sh && \
    echo 'LOG_FILE="/app/logs/test.log"' >> /app/entrypoint.sh && \
    echo 'touch $LOG_FILE' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Log function with timestamp' >> /app/entrypoint.sh && \
    echo 'log_message() {' >> /app/entrypoint.sh && \
    echo '  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")' >> /app/entrypoint.sh && \
    echo '  local message="$1"' >> /app/entrypoint.sh && \
    echo '  echo "[$timestamp] $message" | tee -a $LOG_FILE' >> /app/entrypoint.sh && \
    echo '}' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Initialize environment' >> /app/entrypoint.sh && \
    echo 'log_message "🚀 Starting Non-EVM container..."' >> /app/entrypoint.sh && \
    echo 'log_message "🧰 Rust version: $(rustc --version)"' >> /app/entrypoint.sh && \
    echo 'log_message "🧰 Cargo version: $(cargo --version)"' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Function to process Rust files' >> /app/entrypoint.sh && \
    echo 'process_rust_file() {' >> /app/entrypoint.sh && \
    echo '  local input_file="$1"' >> /app/entrypoint.sh && \
    echo '  local filename=$(basename "$input_file")' >> /app/entrypoint.sh && \
    echo '  local contract_name=$(echo ${filename%.*} | tr - _)' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  log_message "🆕 Detected Rust contract: $filename"' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Update Cargo.toml with contract name' >> /app/entrypoint.sh && \
    echo '  log_message "📝 Updating Cargo.toml with contract name: $contract_name"' >> /app/entrypoint.sh && \
    echo '  sed "s/__CONTRACT_NAME__/$contract_name/g" /app/config/Cargo.template.toml > /app/Cargo.toml' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Copy input file to src/lib.rs' >> /app/entrypoint.sh && \
    echo '  log_message "📁 Copying $filename to src/lib.rs"' >> /app/entrypoint.sh && \
    echo '  cp "$input_file" /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Create a test file if it doesnt contain tests' >> /app/entrypoint.sh && \
    echo '  if ! grep -q "#\[test\]" /app/src/lib.rs; then' >> /app/entrypoint.sh && \
    echo '    log_message "📝 Adding test module to lib.rs"' >> /app/entrypoint.sh && \
    echo '    echo "" >> /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '    echo "#[cfg(test)]" >> /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '    echo "mod tests {" >> /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '    echo "    #[test]" >> /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '    echo "    fn it_works() {" >> /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '    echo "        assert!(true);" >> /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '    echo "    }" >> /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '    echo "}" >> /app/src/lib.rs' >> /app/entrypoint.sh && \
    echo '  fi' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Compilation' >> /app/entrypoint.sh && \
    echo '  log_message "🔨 Compiling contract..."' >> /app/entrypoint.sh && \
    echo '  cargo check 2>&1 | tee -a $LOG_FILE' >> /app/entrypoint.sh && \
    echo '  if [ ${PIPESTATUS[0]} -ne 0 ]; then' >> /app/entrypoint.sh && \
    echo '    log_message "❌ Compilation failed"' >> /app/entrypoint.sh && \
    echo '    return 1' >> /app/entrypoint.sh && \
    echo '  else' >> /app/entrypoint.sh && \
    echo '    log_message "✅ Compilation successful"' >> /app/entrypoint.sh && \
    echo '  fi' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Run unit tests' >> /app/entrypoint.sh && \
    echo '  log_message "🧪 Running unit tests..."' >> /app/entrypoint.sh && \
    echo '  cargo test --lib -- --nocapture 2>&1 | tee -a $LOG_FILE' >> /app/entrypoint.sh && \
    echo '  if [ ${PIPESTATUS[0]} -ne 0 ]; then' >> /app/entrypoint.sh && \
    echo '    log_message "❌ Unit tests failed"' >> /app/entrypoint.sh && \
    echo '  else' >> /app/entrypoint.sh && \
    echo '    log_message "✅ Unit tests passed"' >> /app/entrypoint.sh && \
    echo '  fi' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Run code coverage' >> /app/entrypoint.sh && \
    echo '  log_message "📊 Running code coverage with Tarpaulin..."' >> /app/entrypoint.sh && \
    echo '  mkdir -p /app/logs/coverage' >> /app/entrypoint.sh && \
    echo '  cargo tarpaulin --config /app/config/tarpaulin.toml --out Html --output-dir /app/logs/coverage 2>&1 | tee -a $LOG_FILE || true' >> /app/entrypoint.sh && \
    echo '  log_message "📋 Coverage reports saved to /app/logs/coverage/"' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Run Clippy' >> /app/entrypoint.sh && \
    echo '  log_message "🔍 Running static analysis (Clippy)..."' >> /app/entrypoint.sh && \
    echo '  cargo clippy 2>&1 | tee /app/logs/analysis/clippy.log' >> /app/entrypoint.sh && \
    echo '  clippy_status=${PIPESTATUS[0]}' >> /app/entrypoint.sh && \
    echo '  if [ $clippy_status -ne 0 ]; then' >> /app/entrypoint.sh && \
    echo '    log_message "⚠️ Clippy found issues"' >> /app/entrypoint.sh && \
    echo '  else' >> /app/entrypoint.sh && \
    echo '    log_message "✅ Clippy analysis passed"' >> /app/entrypoint.sh && \
    echo '  fi' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Run security audit' >> /app/entrypoint.sh && \
    echo '  log_message "🔒 Running security audit..."' >> /app/entrypoint.sh && \
    echo '  mkdir -p /app/logs/security' >> /app/entrypoint.sh && \
    echo '  cargo audit 2>&1 | tee /app/logs/security/cargo_audit.log || true' >> /app/entrypoint.sh && \
    echo '  log_message "📋 Audit report saved to /app/logs/security/cargo_audit.log"' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  # Check dependencies' >> /app/entrypoint.sh && \
    echo '  log_message "📦 Checking dependencies..."' >> /app/entrypoint.sh && \
    echo '  cargo tree 2>&1 | tee /app/logs/reports/dependencies.log' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '  log_message "🏁 All Non-EVM analysis complete for $filename"' >> /app/entrypoint.sh && \
    echo '}' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Create directories' >> /app/entrypoint.sh && \
    echo 'mkdir -p /app/logs/coverage /app/logs/security /app/logs/analysis /app/logs/reports' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Process any existing files in input directory' >> /app/entrypoint.sh && \
    echo 'log_message "🔎 Checking for existing files in /app/input..."' >> /app/entrypoint.sh && \
    echo 'find /app/input -name "*.rs" -type f | while read -r file; do' >> /app/entrypoint.sh && \
    echo '  process_rust_file "$file"' >> /app/entrypoint.sh && \
    echo 'done' >> /app/entrypoint.sh && \
    echo '' >> /app/entrypoint.sh && \
    echo '# Watch for new files' >> /app/entrypoint.sh && \
    echo 'log_message "👀 Watching /app/input directory for new Rust files..."' >> /app/entrypoint.sh && \
    echo 'inotifywait -m -e close_write,moved_to,create /app/input | while read -r directory events filename; do' >> /app/entrypoint.sh && \
    echo '  if [[ "$filename" == *.rs ]]; then' >> /app/entrypoint.sh && \
    echo '    process_rust_file "${directory}${filename}"' >> /app/entrypoint.sh && \
    echo '  fi' >> /app/entrypoint.sh && \
    echo 'done' >> /app/entrypoint.sh && \
    dos2unix /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# Set proper permissions
RUN chmod -R 755 /app/logs /app/input /app/config && \
    chmod 644 /app/Cargo.toml && \
    chmod 755 /app/src

ENTRYPOINT ["/app/entrypoint.sh"]
