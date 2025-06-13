#!/bin/bash
set -e

echo "🚀 Starting EVM container..."

# Ensure required folders exist
mkdir -p /app/input
mkdir -p /app/logs
LOG_FILE="/app/logs/evm-test.log"

# Clear old log (or comment this line if you prefer appending)
: > "$LOG_FILE"

# Watch the input folder where backend will drop .sol files
echo "📡 Watching /app/input for incoming Solidity files..." | tee -a "$LOG_FILE"

inotifywait -m -e close_write,moved_to,create /app/input |
while read -r directory events filename; do
  if [[ "$filename" == *.sol ]]; then
    {
      echo "🆕 Detected Solidity contract: $filename"

      # Move file to /app/contracts (overwrite if same name exists)
      mkdir -p /app/contracts
      cp "/app/input/$filename" "/app/contracts/$filename"

      echo "📁 Copied $filename to contracts directory."

      # Run Hardhat tests
      echo "🧪 Running Hardhat tests..."
      if ! npx hardhat test --config ./config/hardhat.config.js; then
        echo "❌ Hardhat tests failed for $filename"
      fi

      # Run Foundry tests if any .t.sol files exist
      if compgen -G './test/*.t.sol' > /dev/null; then
        echo "🧪 Running Foundry tests..."
        if ! forge test; then
          echo "❌ Foundry tests failed."
        fi
      fi

      # Run Slither analysis
      echo "🔎 Running Slither analysis..."
      if ! slither .; then
        echo "❌ Slither analysis failed."
      fi

      echo "✅ All EVM analysis complete for $filename"
    } 2>&1 | tee -a "$LOG_FILE"
  fi
done

