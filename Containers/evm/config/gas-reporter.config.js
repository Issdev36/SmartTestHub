module.exports = {
  enabled: process.env.REPORT_GAS ? true : false,
  currency: "USD",
  gasPrice: 20, // gwei
  token: "ETH",
  coinmarketcap: process.env.COINMARKETCAP_API_KEY || "",
  outputFile: "logs/gas-report.txt",
  noColors: true,
  rst: true, // Output in reStructuredText format
  rstTitle: "Gas Usage Report",
  showTimeSpent: true,
  excludeContracts: ["Migrations", "Mock", "Test"],
  src: "./contracts",
  url: "http://localhost:8545",
  proxyResolver: "EtherRouter",
  artifactType: "hardhat",
  showMethodSig: true,
  maxMethodDiff: 10,
  maxDeploymentDiff: 100,
  remoteContracts: [],
  fast: false,
  L1: "ethereum",
  L2: "polygon",
  L2Url: "https://polygon-rpc.com/",
  forceTerminalOutput: true,
  forceTerminalOutputFormat: "terminal"
};
