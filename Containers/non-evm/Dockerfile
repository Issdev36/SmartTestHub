FROM rust:1.85-slim

# Setting up the environment variables explicitly
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/venv/bin:/root/.cargo/bin:/root/.local/share/solana/install/active_release/bin:/root/.avm/bin:${PATH}"
ENV SOLANA_INSTALL_DIR="/root/.local/share/solana/install"
# Disable X-Ray by default to prevent container restart loops
ENV AWS_XRAY_SDK_ENABLED=false
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

# Install Rust tools including cargo-tarpaulin for test coverage
RUN rustup component add clippy && \
    cargo install cargo-audit cargo-expand cargo-tarpaulin || true

# Create workdir and directory structure
WORKDIR /app
RUN mkdir -p /app/src /app/tests /app/config /app/input /app/logs \
    /app/logs/coverage /app/logs/security /app/logs/analysis /app/logs/reports \
    /app/logs/xray /app/target /app/.cargo

# Create default Cargo.toml template for dynamic updates
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

# Set proper permissions
RUN chmod -R 755 /app/logs /app/input /app/config && \
    chmod 644 /app/Cargo.toml 

# Create a wrapper script to handle the entrypoint
RUN echo '#!/bin/bash' > /app/entrypoint-wrapper.sh && \
    echo 'set -e' >> /app/entrypoint-wrapper.sh && \
    echo 'echo "Starting non-EVM container with wrapper..."' >> /app/entrypoint-wrapper.sh && \
    echo 'if [ ! -f /app/entrypoint.sh ]; then' >> /app/entrypoint-wrapper.sh && \
    echo '    echo "ERROR: entrypoint.sh is missing!"' >> /app/entrypoint-wrapper.sh && \
    echo '    exit 1' >> /app/entrypoint-wrapper.sh && \
    echo 'fi' >> /app/entrypoint-wrapper.sh && \
    echo 'chmod +x /app/entrypoint.sh' >> /app/entrypoint-wrapper.sh && \
    echo 'exec /app/entrypoint.sh' >> /app/entrypoint-wrapper.sh && \
    chmod +x /app/entrypoint-wrapper.sh

# Copy entrypoint script
COPY entrypoint.sh /app/entrypoint.sh
RUN dos2unix /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# Use the wrapper as the entrypoint
ENTRYPOINT ["/app/entrypoint-wrapper.sh"]
