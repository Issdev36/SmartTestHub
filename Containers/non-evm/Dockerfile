FROM rust:1.85-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/root/.cargo/bin:/root/.local/share/solana/install/active_release/bin:/root/.avm/bin:$PATH"

# Install system dependencies including Node.js
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git pkg-config build-essential libssl-dev libudev-dev \
    llvm clang libclang-dev cmake dos2unix ca-certificates unzip inotify-tools \
    nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Install Solana CLI
RUN curl --proto '=https' --tlsv1.2 -sSfL https://release.solana.com/stable/install | sh

# Install AVM (Anchor Version Manager) and Anchor CLI
RUN cargo install --git https://github.com/coral-xyz/anchor avm --locked --force
RUN avm install 0.29.0 && avm use 0.29.0

# Alternative method: Install Anchor CLI directly via Cargo (uncomment if AVM method fails)
# RUN cargo install --git https://github.com/coral-xyz/anchor anchor-cli --locked --force

# Install other Rust tools
RUN cargo install cargo-tarpaulin cargo-audit cargo-deny cargo-outdated && \
    rustup component add clippy

# Create workdir and test file structure
WORKDIR /app
RUN mkdir -p /app/src /app/tests /app/config

# Copy config and entrypoint
COPY config /app/config
COPY entrypoint.sh /app/entrypoint.sh
RUN dos2unix /app/entrypoint.sh && chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
