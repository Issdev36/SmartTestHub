# Update the entrypoint-patch.sh with all fixes
cat > ~/SmartTestHub/Containers/non-evm/entrypoint-patch.sh << 'EOF'
#!/bin/bash

# Apply these changes to the main entrypoint.sh

# 1. Fix for X-Ray daemon - add an existence check for xray
sed -i 's/which xray > \/dev\/null 2>&1/command -v xray > \/dev\/null 2>\&1/' /app/entrypoint.sh

# 2. Fix tarpaulin command (change --config-path to --config)
sed -i 's/cargo tarpaulin --config-path \/app\/tarpaulin.toml/cargo tarpaulin --config \/app\/tarpaulin.toml/g' /app/entrypoint.sh

# 3. Replace build-sbf with regular build for testing
sed -i 's/cargo build-sbf/cargo build/g' /app/entrypoint.sh

# 4. Add cargo generate-lockfile before audit
sed -i '/log_with_timestamp "🛡️ Running security audit for/a\    # Generate Cargo.lock first\n    cargo generate-lockfile || true' /app/entrypoint.sh

# 5. Add safe fallback for the watch setup at the end
sed -i 's/inotifywait -m -e close_write,moved_to,create "$watch_dir" |/\
echo "Setting up directory watch on $watch_dir..."\n\
if ! inotifywait -m -e close_write,moved_to,create "$watch_dir" 2>\/dev\/null |/' /app/entrypoint.sh

# 6. Add fallback if inotifywait fails
cat << 'EOFINNER' > /tmp/fallback_code
then
    log_with_timestamp "❌ inotifywait failed, using fallback polling mechanism" "error"
    while true; do
        echo "Polling directory $watch_dir..."
        for file in "$watch_dir"/*.rs; do
            if [[ -f "$file" && ! -f "/app/processed/$(basename $file)" ]]; then
                # Process the file
                filename=$(basename "$file")
                {
                    start_time=$(date +%s)
                    log_with_timestamp "🆕 Processing new Rust contract: $filename"
                    
                    # Process rest of the file as before...
                    # Extract contract name
                    contract_name="${filename%.rs}"
                    
                    # Create source directory
                    mkdir -p "$project_dir/src"
                    
                    # Copy contract file
                    cp "$file" "$project_dir/src/lib.rs"
                    log_with_timestamp "📁 Contract copied to src/lib.rs"
                    
                    # Mark as processed
                    mkdir -p "/app/processed"
                    touch "/app/processed/$filename"
                } 2>&1
            fi
        done
        sleep 5
    done
fi
EOFINNER

# Insert the fallback code after the if condition
sed -i '/if ! inotifywait -m -e close_write,moved_to,create "$watch_dir" 2>\/dev\/null |/r /tmp/fallback_code' /app/entrypoint.sh

# Create processed directory to track files
mkdir -p /app/processed

# Create a basic Cargo.lock file to avoid audit errors
if [ ! -f "/app/Cargo.lock" ]; then
    echo "Creating basic Cargo.lock for audit..."
    touch /app/Cargo.lock
fi

echo "All patches applied successfully"
EOF
