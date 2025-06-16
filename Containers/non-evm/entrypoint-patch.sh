#!/bin/bash

# Apply these changes to the main entrypoint.sh

# 1. Fix for X-Ray daemon - add an existence check for xray
sed -i 's/which xray > \/dev\/null 2>&1/command -v xray > \/dev\/null 2>\&1/' /app/entrypoint.sh

# 2. Add echo after cargo tarpaulin call to show if it's not installed
sed -i 's/cargo tarpaulin --config-path \/app\/tarpaulin.toml -v;/cargo tarpaulin --config-path \/app\/tarpaulin.toml -v || { echo "Tarpaulin not found or failed"; };/' /app/entrypoint.sh

# 3. Add safe fallback for the watch setup at the end
sed -i 's/inotifywait -m -e close_write,moved_to,create "$watch_dir" |/\
echo "Setting up directory watch on $watch_dir..."\n\
if ! inotifywait -m -e close_write,moved_to,create "$watch_dir" 2>\/dev\/null |/' /app/entrypoint.sh

# 4. Add fallback if inotifywait fails
cat << 'EOF' > /tmp/fallback_code
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
EOF

# Insert the fallback code after the if condition
sed -i '/if ! inotifywait -m -e close_write,moved_to,create "$watch_dir" 2>\/dev\/null |/r /tmp/fallback_code' /app/entrypoint.sh

# Create processed directory to track files
mkdir -p /app/processed

echo "Patches applied successfully"
