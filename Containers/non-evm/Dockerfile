FROM rust:1.85-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/root/.cargo/bin:/root/.local/share/solana/install/active_release/bin:$PATH"

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git pkg-config build-essential libssl-dev libudev-dev \
    llvm clang libclang-dev cmake dos2unix ca-certificates unzip inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Install Solana CLI
RUN curl --proto '=https' --tlsv1.2 -sSfL https://release.solana.com/stable/install | sh

# Install Anchor CLI (manual method instead of AVM to avoid unstable feature errors)
RUN curl -L https://github.com/coral-xyz/anchor/releases/download/v0.29.0/anchor-cli-linux-x86_64.tar.gz -o anchor.tar.gz && \
    tar -xzf anchor.tar.gz && \
    mv anchor /usr/local/bin/anchor && \
    rm anchor.tar.gz

# Install Rust tools
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

