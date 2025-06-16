FROM rust:1.85-slim

# Environment setup
ENV PATH="/opt/venv/bin:/root/.cargo/bin:/root/.local/share/solana/install/active_release/bin:${PATH}"
ENV RUST_LOG=info
ENV AWS_XRAY_SDK_ENABLED=true

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl git build-essential libssl-dev libudev-dev dos2unix unzip \
    nodejs npm python3 python3-pip python3-venv inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Create Python virtual environment and install AWS X-Ray SDK
RUN python3 -m venv /opt/venv && \
    . /opt/venv/bin/activate && \
    pip install aws-xray-sdk

# Create Solana CLI stubs
RUN mkdir -p /root/.local/share/solana/install/active_release/bin && \
    echo '#!/bin/bash\necho "Solana CLI stub v1.17.3"\n' > /root/.local/share/solana/install/active_release/bin/solana && \
    chmod +x /root/.local/share/solana/install/active_release/bin/solana && \
    echo '#!/bin/bash\necho "Solana keygen stub"\n' > /root/.local/share/solana/install/active_release/bin/solana-keygen && \
    chmod +x /root/.local/share/solana/install/active_release/bin/solana-keygen && \
    echo 'export PATH="/root/.local/share/solana/install/active_release/bin:$PATH"' >> /root/.bashrc

# Install Rust tools
RUN rustup component add clippy && \
    cargo install cargo-audit cargo-expand || true

# Setup application directory
WORKDIR /app
RUN mkdir -p /app/src /app/input /app/logs /app/config

# Create Cargo.toml
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

# Create sample source file
RUN mkdir -p /app/src && \
    echo 'use solana_program::entrypoint::ProgramResult;' > /app/src/lib.rs && \
    echo 'pub fn process_instruction() -> ProgramResult {' >> /app/src/lib.rs && \
    echo '    Ok(())' >> /app/src/lib.rs && \
    echo '}' >> /app/src/lib.rs

# Create entrypoint script
RUN echo '#!/bin/bash' > /app/entrypoint.sh && \
    echo 'source /opt/venv/bin/activate' >> /app/entrypoint.sh && \
    echo 'echo "Non-EVM container started"' >> /app/entrypoint.sh && \
    echo 'echo "Watching /app/input directory for changes..."' >> /app/entrypoint.sh && \
    echo 'inotifywait -m -e close_write,moved_to,create /app/input | ' >> /app/entrypoint.sh && \
    echo 'while read -r directory events filename; do' >> /app/entrypoint.sh && \
    echo '  echo "Processing $filename"' >> /app/entrypoint.sh && \
    echo '  # Add your processing logic here' >> /app/entrypoint.sh && \
    echo 'done' >> /app/entrypoint.sh && \
    chmod +x /app/entrypoint.sh

# Set permissions
RUN chmod -R 755 /app/logs /app/input /app/config

ENTRYPOINT ["/app/entrypoint.sh"]
