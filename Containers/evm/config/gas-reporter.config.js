module.exports = {
  enabled: true,
  currency: "USD",
  coinmarketcap: process.env.COINMARKETCAP_API_KEY || "",
  token: "ETH",
  outputFile: "gas-report.txt",
  noColors: true
};

