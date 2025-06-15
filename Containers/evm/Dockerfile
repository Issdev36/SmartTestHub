FROM ghcr.io/foundry-rs/foundry:latest

# Install Node.js and system dependencies
RUN apk add --no-cache \
    bash \
    git \
    curl \
    build-base \
    libffi-dev \
    openssl-dev \
    python3 \
    py3-pip \
    dos2unix \
    inotify-tools \
    nodejs \
    npm

# Install Slither for security analysis
RUN pip install slither-analyzer

# Set working directory
WORKDIR /app

# Copy package.json and install Node.js dependencies
COPY package.json package-lock.json* ./
RUN npm install

# Install additional security and analysis tools
RUN npm install -g @openzeppelin/hardhat-upgrades \
    hardhat-contract-sizer hardhat-docgen hardhat-storage-layout \
    @ethereum/security-analysis || echo "Some packages may not be available"

# Copy all application files
COPY . .

# Fix script permissions and line endings
RUN dos2unix ./entrypoint.sh && chmod +x ./entrypoint.sh

# Create required directories that backend will use
RUN mkdir -p /app/input /app/logs /app/contracts /app/test \
    /app/logs/slither /app/logs/coverage /app/logs/gas /app/logs/foundry \
    /app/logs/reports /app/cache /app/artifacts

# Initialize Foundry project structure
RUN forge init --force || true

# Set proper permissions
RUN chmod -R 755 /app/logs /app/input /app/contracts /app/test

ENTRYPOINT ["./entrypoint.sh"]
