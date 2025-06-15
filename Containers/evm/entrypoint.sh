#!/bin/bash
set -e

echo "🚀 Starting EVM container..."

# Ensure required folders exist
mkdir -p /app/input
mkdir -p /app/logs
mkdir -p /app/contracts
mkdir -p /app/test
LOG_FILE="/app/logs/evm-test.log"

# Clear old log (or comment this line if you prefer appending)
: > "$LOG_FILE"

# Function to log with timestamp
log_with_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Watch the input folder where backend will drop .sol files
log_with_timestamp "📡 Watching /app/input for incoming Solidity files..."

inotifywait -m -e close_write,moved_to,create /app/input |
while read -r directory events filename; do
  if [[ "$filename" == *.sol ]]; then
    {
      log_with_timestamp "🆕 Detected Solidity contract: $filename"

      # Move file to /app/contracts (overwrite if same name exists)
      mkdir -p /app/contracts
      cp "/app/input/$filename" "/app/contracts/$filename"
      log_with_timestamp "📁 Copied $filename to contracts directory"

      # Extract contract name for better reporting
      contract_name=$(basename "$filename" .sol)
      
      # Create a basic test file if none exists
      if [ ! -f "/app/test/${contract_name}.test.js" ]; then
        cat > "/app/test/${contract_name}.test.js" <<EOF
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("${contract_name}", function () {
  it("Should deploy successfully", async function () {
    const Contract = await ethers.getContractFactory("${contract_name}");
    const contract = await Contract.deploy();
    await contract.deployed();
    expect(contract.address).to.not.be.undefined;
  });
});
EOF
        log_with_timestamp "📝 Created basic test file for $contract_name"
      fi

      # Run Hardhat compilation
      log_with_timestamp "🔨 Compiling contract with Hardhat..."
      if npx hardhat compile --config ./config/hardhat.config.js 2>&1 | tee -a "$LOG_FILE"; then
        log_with_timestamp "✅ Hardhat compilation successful"
      else
        log_with_timestamp "❌ Hardhat compilation failed for $filename"
      fi

      # Run Hardhat tests
      log_with_timestamp "🧪 Running Hardhat tests..."
      if npx hardhat test --config ./config/hardhat.config.js 2>&1 | tee -a "$LOG_FILE"; then
        log_with_timestamp "✅ Hardhat tests passed"
      else
        log_with_timestamp "❌ Hardhat tests failed for $filename"
      fi

      # Run Foundry tests if any .t.sol files exist
      if compgen -G './test/*.t.sol' > /dev/null 2>&1; then
        log_with_timestamp "🧪 Running Foundry tests..."
        if forge test 2>&1 | tee -a "$LOG_FILE"; then
          log_with_timestamp "✅ Foundry tests passed"
        else
          log_with_timestamp "❌ Foundry tests failed"
        fi
      else
        log_with_timestamp "ℹ️ No Foundry test files found, skipping forge test"
      fi

      # Run Slither analysis
      log_with_timestamp "🔎 Running Slither security analysis..."
      if slither ./contracts --json - 2>&1 | tee -a "$LOG_FILE"; then
        log_with_timestamp "✅ Slither analysis completed"
      else
        log_with_timestamp "⚠️ Slither analysis completed with findings"
      fi

      # Generate gas report
      log_with_timestamp "⛽ Generating gas usage report..."
      if npx hardhat test --config ./config/hardhat.config.js --reporter hardhat-gas-reporter 2>&1 | tee -a "$LOG_FILE"; then
        log_with_timestamp "✅ Gas report generated"
      else
        log_with_timestamp "⚠️ Gas report generation failed"
      fi

      # Run coverage analysis
      log_with_timestamp "📊 Running coverage analysis..."
      if npx hardhat coverage --config ./config/hardhat.config.js 2>&1 | tee -a "$LOG_FILE"; then
        log_with_timestamp "✅ Coverage analysis completed"
      else
        log_with_timestamp "⚠️ Coverage analysis failed"
      fi

      log_with_timestamp "🏁 All EVM analysis complete for $filename"
      log_with_timestamp "==========================================\n"
      
    } 2>&1
  fi
done
