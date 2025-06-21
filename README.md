# SmartTestHub

A comprehensive smart contract testing environment that provides automated testing, security analysis, and reporting for both EVM and non-EVM blockchain platforms.

## 🏗️ Architecture

SmartTestHub consists of two main containerized environments:

### EVM Container
- **Foundry**: Fast Ethereum testing framework
- **Hardhat**: Development environment for Ethereum
- **Slither**: Static analysis security tool
- **Gas Reporter**: Gas usage analysis
- **Coverage**: Test coverage reporting

### Non-EVM Container (Solana)
- **Solana CLI**: Solana development tools
- **Anchor Framework**: Solana's smart contract framework
- **Cargo Tools**: Rust development and testing tools
- **Tarpaulin**: Code coverage for Rust
- **Clippy**: Rust linter and static analyzer

## 🚀 How It Works

1. **Backend Integration**: Your backend drops contract files into the appropriate container's `/app/input` directory
2. **File Detection**: Each container watches for new files using `inotifywait`
3. **Automated Testing**: When a file is detected, the container automatically:
   - Compiles the contract
   - Runs comprehensive tests
   - Performs security analysis
   - Generates coverage reports
   - Logs all results
4. **Log Output**: All test results are written to `/app/logs/` which your backend can read and send to the frontend

## 📁 Directory Structure

```
SmartTestHub/
├── Containers/
│   ├── docker-compose.yml
│   ├── evm/
│   │   ├── Dockerfile
│   │   ├── package.json
│   │   ├── entrypoint.sh
│   │   ├── config/
│   │   │   ├── hardhat.config.js
│   │   │   ├── foundry.toml
│   │   │   └── slither.config.json
│   │   ├── input/          # Backend drops .sol files here
│   │   └── logs/           # Test results written here
│   └── non-evm/
│       ├── Dockerfile
│       ├── Cargo.toml
│       ├── entrypoint.sh
│       ├── config/
│       │   ├── Anchor.toml
│       │   └── tarpaulin.toml
│       ├── src/
│       │   └── lib.rs
│       ├── input/          # Backend drops .rs files here
│       └── logs/           # Test results written here
└── shared_logs/            # Shared log directory
    ├── evm/
    └── non-evm/
```

## 🛠️ Setup Instructions

1. **Build the containers**:
   ```bash
   cd Containers
   docker-compose build
   ```

2. **Start the services**:
   ```bash
   docker-compose up -d
   ```

3. **Verify containers are running**:
   ```bash
   docker-compose ps
   ```

## 🔄 Testing Workflow

### EVM Testing (Solidity)
1. Backend drops `.sol` file into `./evm/input/`
2. Container detects file and moves it to `./evm/contracts/`
3. Runs the following tests:
   - Hardhat compilation
   - Hardhat unit tests
   - Foundry tests (if available)
   - Slither security analysis
   - Gas usage reporting
   - Coverage analysis
4. All results logged to `./evm/logs/evm-test.log`

### Non-EVM Testing (Solana/Rust)
1. Backend drops `.rs` file into `./non-evm/input/`
2. Container detects file and processes it as `lib.rs`
3. Dynamically updates `Cargo.toml` with contract name
4. Runs the following tests:
   - Cargo/Anchor compilation
   - Unit tests (cargo test-sbf or anchor test)
   - Coverage analysis (Tarpaulin)
   - Static analysis (Clippy)
   - Security audit (cargo-audit)
   - Dependency checks
5. All results logged to `./non-evm/logs/test.log`

## 📊 Log Format

All logs include timestamps and structured output:
```
[2024-01-15 10:30:45] 🆕 Detected Solidity contract: MyContract.sol
[2024-01-15 10:30:46] 📁 Copied MyContract.sol to contracts directory
[2024-01-15 10:30:47] 🔨 Compiling contract with Hardhat...
[2024-01-15 10:30:50] ✅ Hardhat compilation successful
[2024-01-15 10:30:51] 🧪 Running Hardhat tests...
[2024-01-15 10:30:55] ✅ Hardhat tests passed
...
[2024-01-15 10:31:20] 🏁 All EVM analysis complete for MyContract.sol
```

## 🔧 Backend Integration

Your backend should:

1. **File Placement**: Drop test files into the appropriate input directories:
   - EVM: `./Containers/evm/input/filename.sol`
   - Non-EVM: `./Containers/non-evm/input/filename.rs`

2. **Log Monitoring**: Read test results from:
   - EVM: `./Containers/shared_logs/evm/evm-test.log`
   - Non-EVM: `./Containers/shared_logs/non-evm/test.log`

3. **File Management**: Clean up processed files from input directories as needed

## 🐛 Troubleshooting

- **Container not starting**: Check `docker-compose logs <service-name>`
- **Tests not triggering**: Verify files are being placed in `/input/` directories
- **Build failures**: Check the logs for missing dependencies or configuration issues

## 🔄 Container Management

- **Restart services**: `docker-compose restart`
- **View logs**: `docker-compose logs -f <service-name>`
- **Stop services**: `docker-compose down`
- **Rebuild**: `docker-compose build --no-cache`

## 📋 Supported File Types

- **EVM**: `.sol` (Solidity smart contracts)
- **Non-EVM**: `.rs` (Rust smart contracts for Solana)

The system automatically detects the contract type and applies the appropriate testing framework
