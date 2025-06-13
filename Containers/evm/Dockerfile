FROM node:18-alpine

# Install essential system packages
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
    inotify-tools  # for watching files with inotifywait

# Install chokidar-cli globally (optional if not using it)
RUN npm install -g chokidar-cli

# Install Slither
RUN pip install slither-analyzer

# Set working directory
WORKDIR /app

# Copy package.json and install dependencies
COPY package.json package-lock.json* ./
RUN npm install

# Copy all files (including watcher logic and configs)
COPY . .

# Fix script permissions and line endings
RUN dos2unix /entrypoint.sh && chmod +x /entrypoint.sh

# Create directory where backend will drop files (if it doesn't exist)
RUN mkdir -p /app/input

# Entrypoint will handle watching and testing
ENTRYPOINT ["/entrypoint.sh"]

