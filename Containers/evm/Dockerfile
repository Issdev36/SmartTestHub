FROM ghcr.io/foundry-rs/foundry:latest

# Set the user to root explicitly
USER root

# Install system dependencies (without nodejs from apt)
RUN apt-get update && apt-get install -y \
    bash \
    git \
    curl \
    build-essential \
    libffi-dev \
    libssl-dev \
    python3 \
    python3-pip \
    python3-venv \
    dos2unix \
    inotify-tools \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# Install Node.js v18 (LTS)
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y nodejs \
    && node --version \
    && npm --version

# Create a Python virtual environment and install Slither
RUN python3 -m venv /opt/venv && \
    . /opt/venv/bin/activate && \
    pip install slither-analyzer && \
    echo 'source /opt/venv/bin/activate' >> /root/.bashrc

# Add virtual environment to PATH
ENV PATH="/opt/venv/bin:${PATH}"

# Set working directory
WORKDIR /app

# Install node-gyp dependencies for native modules
RUN apt-get update && apt-get install -y \
    python3 make g++ \
    && npm install -g node-gyp

# Copy package.json and install Node.js dependencies
COPY package.json package-lock.json* ./
RUN npm install --no-optional || npm install --no-optional --force

# Install additional security and analysis tools
RUN npm install -g @openzeppelin/hardhat-upgrades \
    hardhat-contract-sizer hardhat-docgen hardhat-storage-layout \
    @ethereum/security-analysis solidity-coverage hardhat-gas-reporter eth-gas-reporter \
    || echo "Some packages may not be available"

# Copy all application files
COPY . .

# Fix script permissions and line endings and create a startup script
RUN dos2unix ./entrypoint.sh && chmod +x ./entrypoint.sh

# Create a startup wrapper script that will handle permissions at runtime
RUN echo '#!/bin/bash\n\
# Activate Python virtual environment\n\
source /opt/venv/bin/activate\n\
\n\
# Make script executable and run it\n\
chmod +x /app/entrypoint.sh\n\
exec /app/entrypoint.sh "$@"' > /docker-entrypoint.sh \
    && chmod +x /docker-entrypoint.sh

# Create required directories that backend will use
RUN mkdir -p /app/input /app/logs /app/contracts /app/test \
    /app/logs/slither /app/logs/coverage /app/logs/gas /app/logs/foundry \
    /app/logs/reports /app/cache /app/artifacts

# Initialize Foundry project structure
RUN forge init --force || true

# Set proper permissions
RUN chmod -R 755 /app/logs /app/input /app/contracts /app/test

# Add environment variable loading
ENV NODE_ENV=development
ENV REPORT_GAS=true

# Use the wrapper script as entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
