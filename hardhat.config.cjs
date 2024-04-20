const { vars } = require("hardhat/config");

const FUJI_PRIVATE_KEY = vars.get("FUJI_PRIVATE_KEY");

module.exports = {
  solidity: "0.8.24",
  paths: {
    artifacts: "./src/artifacts",
  },
  defaultNetwork: "hardhat",
  networks: {
    localhost: {
      url: "http://127.0.0.1:8545"
    },
    hardhat: {
    },
    fuji: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      accounts: [FUJI_PRIVATE_KEY],
      chainId: 43113,
    },
    // avax: {
    //   url: "https://api.avax.network/ext/bc/C/rpc",
    //   accounts: [`0x` + process.env.PRIVATE_KEY],
    //   chainId: 43114,
    // },
  },
};