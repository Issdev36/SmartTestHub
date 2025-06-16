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
    nodejs npm python3 python3-pip python3-venv \
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

# Install Rust tools
RUN rustup component add clippy || echo "Failed to add clippy" && \
    cargo install cargo-audit cargo-expand || true

# Create workdir and directory structure
WORKDIR /app
RUN mkdir -p /app/src /app/tests /app/config /app/input /app/logs \
    /app/logs/coverage /app/logs/security /app/logs/analysis /app/logs/reports \
    /app/logs/xray /app/target /app/.cargo

# Create default Cargo.toml
RUN echo '[package]' > /app/Cargo.toml && \
    echo 'name = "solana-test-app"' >> /app/Cargo.toml && \
    echo 'version = "0.1.0"' >> /app/Cargo.toml && \
    echo 'edition = "2021"' >> /app/Cargo.toml && \
    echo '' >> /app/Cargo.toml && \
    echo '[lib]' >> /app/Cargo.toml && \
    echo 'crate-type = ["cdylib", "lib"]' >> /app/Cargo.toml && \
    echo '' >> /app/Cargo.toml && \
    echo '[dependencies]' >> /app/Cargo.toml && \
    echo 'solana-program = "1.17.0"' >> /app/Cargo.toml

# Create src directory with placeholder
RUN mkdir -p /app/src && \
    echo 'use solana_program::entrypoint::ProgramResult;' > /app/src/lib.rs && \
    echo 'pub fn process_instruction() -> ProgramResult {' >> /app/src/lib.rs && \
    echo '    Ok(())' >> /app/src/lib.rs && \
    echo '}' >> /app/src/lib.rs

# Create entrypoint script
RUN echo '#!/bin/bash' > /app/entrypoint.sh && \
    echo 'source /opt/venv/bin/activate' >> /app/entrypoint.sh && \
    echo 'echo "Non-EVM container started at $(date)"' >> /app/entrypoint.sh && \
    echo 'echo "Rust version: $(rustc --version)"' >> /app/entrypoint.sh && \
    echo 'echo "Cargo version: $(cargo --version)"' >> /app/entrypoint.sh && \
    echo 'echo "Python version: $(python3 --version)"' >> /app/entrypoint.sh && \
    echo 'echo "AWS X-Ray SDK version: $(pip show aws-xray-sdk | grep Version)"' >> /app/entrypoint.sh && \
    echo 'echo "Watching /app/input directory for changes..."' >> /app/entrypoint.sh && \
    echo 'inotifywait -m -e close_write,moved_to,create /app/input | ' >> /app/entrypoint.sh && \
    echo 'while read -r directory events filename; do' >> /app/entrypoint.sh && \
    echo '  echo "[$(date)] Processing $filename"' >> /app/entrypoint.sh && \
    echo '  if [[ "$filename" == *.rs ]]; then' >> /app/entrypoint.sh && \
    echo '    cp "$directory$filename" /app/src/' >> /app/entrypoint.sh && \
    echo '    echo "Running cargo check on $filename"' >> /app/entrypoint.sh && \
    echo '    cargo check 2>&1 | tee /app/logs/cargo_check.log' >> /app/entrypoint.sh && \
    echo '    echo "Running cargo audit on $filename"' >> /app/entrypoint.sh && \
    echo '    cargo audit 2>&1 | tee /app/logs/cargo_audit.log' >> /app/entrypoint.sh && \
    echo '  fi' >> /app/entrypoint.sh && \
    echo 'done' >> /app/entrypoint.sh && \
    dos2unix /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# Create base X-Ray config
RUN echo '{' > /app/config/xray-config.json && \
    echo '  "SamplingRules": [],' >> /app/config/xray-config.json && \
    echo '  "DaemonAddress": "127.0.0.1:2000",' >> /app/config/xray-config.json && \
    echo '  "ServiceName": "SmartTestHub-NonEVM",' >> /app/config/xray-config.json && \
    echo '  "LogLevel": "info",' >> /app/config/xray-config.json && \
    echo '  "LocalMode": true' >> /app/config/xray-config.json && \
    echo '}' >> /app/config/xray-config.json

# Set proper permissions
RUN chmod -R 755 /app/logs /app/input /app/config && \
    chmod 644 /app/Cargo.toml && \
    chmod 644 /app/src/lib.rs && \
    chmod 755 /app/src

ENTRYPOINT ["/app/entrypoint.sh"]
