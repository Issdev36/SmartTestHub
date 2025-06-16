FROM rust:1.85-slim

# Setting up the environment variables explicitly
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/.cargo/bin:/root/.local/share/solana/install/active_release/bin:/root/.avm/bin:${PATH}"
ENV SOLANA_INSTALL_DIR="/root/.local/share/solana/install"

# Install system dependencies including Node.js
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git pkg-config build-essential libssl-dev libudev-dev \
    llvm clang libclang-dev cmake dos2unix ca-certificates unzip inotify-tools \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Install Solana CLI with explicit export in the same RUN command
RUN curl --proto '=https' --tlsv1.2 -sSfL https://release.solana.com/stable/install | sh && \
    echo 'export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"' >> /root/.bashrc && \
    echo 'export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"' >> /root/.profile && \
    export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"

# Verify Solana is installed
RUN solana --version || echo "Solana CLI not found in PATH"

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
    --locked && \
    rustup component add clippy

# Install wasm-pack for WebAssembly builds if needed
RUN curl https://rustwasm.github.io/wasm-pack/installer/init.sh -sSf | sh || \
    echo "wasm-pack installation failed, continuing..."

# Create workdir and comprehensive directory structure
WORKDIR /app
RUN mkdir -p /app/src /app/tests /app/config /app/input /app/logs \
    /app/logs/coverage /app/logs/security /app/logs/analysis /app/logs/reports \
    /app/target /app/.cargo

# Copy config files
COPY config /app/config
COPY entrypoint.sh /app/entrypoint.sh
RUN dos2unix /app/entrypoint.sh && chmod +x /app/entrypoint.sh

# Create a startup wrapper script that will handle permissions at runtime
# and ensure the PATH is set correctly
RUN echo '#!/bin/bash\n\
export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"\n\
chmod +x /app/entrypoint.sh\n\
exec /app/entrypoint.sh "$@"' > /docker-entrypoint.sh \
    && chmod +x /docker-entrypoint.sh

# Create initial Cargo.toml
COPY Cargo.toml /app/Cargo.toml
COPY src /app/src

# Set proper permissions
RUN chmod -R 755 /app/logs /app/input /app/config && \
    chmod 644 /app/config/*.toml

# Use the wrapper script as entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
