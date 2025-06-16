FROM rust:1.85-slim

# Setting up the environment variables explicitly
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/opt/venv/bin:/root/.cargo/bin:/root/.local/share/solana/install/active_release/bin:/root/.avm/bin:${PATH}"
ENV SOLANA_INSTALL_DIR="/root/.local/share/solana/install"
ENV AWS_XRAY_SDK_ENABLED=true
ENV AWS_REGION=us-east-1

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

# Install Solana CLI with fallbacks
RUN mkdir -p /root/.local/share/solana/install/active_release/bin && \
    cd /tmp && \
    (curl -sSfL https://release.solana.com/v1.17.3/install -o install_solana.sh || \
     curl -sSfL https://github.com/solana-labs/solana/releases/download/v1.17.3/install -o install_solana.sh || \
     curl -sSfL https://github.com/solana-labs/solana/archive/refs/tags/v1.17.3.tar.gz -o solana.tar.gz) && \
    if [ -f install_solana.sh ]; then \
        sh install_solana.sh || echo "Solana installer failed, will proceed with other setup"; \
    elif [ -f solana.tar.gz ]; then \
        mkdir -p /tmp/solana-build && \
        tar -xzf solana.tar.gz -C /tmp/solana-build --strip-components=1 && \
        cd /tmp/solana-build && \
        cargo build --release && \
        mkdir -p /root/.local/share/solana/install/active_release/bin && \
        find . -type f -executable -name "solana*" -exec cp {} /root/.local/share/solana/install/active_release/bin/ \; ; \
    fi && \
    echo 'export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"' >> /root/.bashrc && \
    echo 'export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"' >> /root/.profile

# Create a dummy solana script if the real one wasn't installed
RUN if [ ! -f /root/.local/share/solana/install/active_release/bin/solana ]; then \
        mkdir -p /root/.local/share/solana/install/active_release/bin && \
        echo '#!/bin/bash\necho "Solana CLI stub (real CLI not available)"\necho "Version: stub-1.17.3"\necho ""' > /root/.local/share/solana/install/active_release/bin/solana && \
        chmod +x /root/.local/share/solana/install/active_release/bin/solana && \
        echo '#!/bin/bash\necho "Solana keygen stub"\nif [ "$1" = "new" ]; then mkdir -p ~/.config/solana && echo "{\"dummy\":\"keypair\"}" > $4; fi' > /root/.local/share/solana/install/active_release/bin/solana-keygen && \
        chmod +x /root/.local/share/solana/install/active_release/bin/solana-keygen; \
    fi

# Install AVM (Anchor Version Manager) and Anchor CLI with error handling
RUN cargo install --git https://github.com/coral-xyz/anchor avm --locked --force || \
    echo "AVM installation failed, will try alternative method"

# Try to install and use Anchor via AVM, fallback to direct cargo install
RUN (avm install 0.29.0 && avm use 0.29.0) || \
    (echo "AVM failed, installing Anchor CLI directly via cargo..." && \
     cargo install --git https://github.com/coral-xyz/anchor anchor-cli --locked --force)

# Install comprehensive Rust tools for testing and analysis
RUN cargo install cargo-tarpaulin cargo-audit cargo-deny cargo-outdated \
    cargo-license cargo-tree cargo-udeps cargo-unused-features cargo-machete \
    cargo-expand cargo-llvm-cov \
    --locked && \
    rustup component add clippy

# Install wasm-pack for WebAssembly builds if needed
RUN curl https://rustwasm.github.io/wasm-pack/installer/init.sh -sSf | sh || \
    echo "wasm-pack installation failed, continuing..."

# Install AWS X-Ray daemon with proper permissions
RUN curl -O https://s3.us-east-2.amazonaws.com/aws-xray-assets.us-east-2/xray-daemon/aws-xray-daemon-linux-3.x.zip && \
    unzip aws-xray-daemon-linux-3.x.zip && \
    cp xray /usr/local/bin/ && \
    chmod +x /usr/local/bin/xray && \
    rm -rf aws-xray-daemon-linux-3.x.zip cfg README.md LICENSE xray

# Create workdir and comprehensive directory structure
WORKDIR /app
RUN mkdir -p /app/src /app/tests /app/config /app/input /app/logs \
    /app/logs/coverage /app/logs/security /app/logs/analysis /app/logs/reports \
    /app/logs/xray /app/target /app/.cargo

# Copy config files
COPY config /app/config
COPY entrypoint.sh /app/entrypoint.sh
RUN dos2unix /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# Create a startup wrapper script that will handle permissions at runtime
# and ensure the PATH is set correctly
RUN echo '#!/bin/bash\n\
# Activate Python virtual environment\n\
source /opt/venv/bin/activate\n\
\n\
# Make sure Solana is in the PATH\n\
export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"\n\
\n\
# Verify and print current PATH\n\
echo "Current PATH: $PATH"\n\
echo "Checking for solana: $(which solana 2>/dev/null || echo \"Not found\")"\n\
echo "Checking for xray: $(which xray 2>/dev/null || echo \"Not found\")"\n\
\n\
# Make script executable and run it\n\
chmod +x /app/entrypoint.sh\n\
exec /app/entrypoint.sh "$@"' > /docker-entrypoint.sh \
    && chmod +x /docker-entrypoint.sh

# Create initial Cargo.toml
COPY Cargo.toml /app/Cargo.toml
COPY src /app/src

# Set proper permissions
RUN chmod -R 755 /app/logs /app/input /app/config && \
    chmod 644 /app/config/*.toml || true

# Create base X-Ray config with local mode enabled
RUN echo '{\n  "SamplingRules": [],\n  "DaemonAddress": "127.0.0.1:2000",\n  "ServiceName": "SmartTestHub-NonEVM",\n  "LogLevel": "info",\n  "LocalMode": true\n}' > /app/config/xray-config.json

# Use the wrapper script as entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
