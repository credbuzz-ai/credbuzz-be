import { HardhatUserConfig } from "hardhat/config";
import "solidity-coverage";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-verify";

import "dotenv/config";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.26",
    settings: {
      optimizer: {
        enabled: false,
        runs: 200,
      },
    },
  },
  etherscan: {
    apiKey: {
      "base-mainnet": process.env.BASESCAN_API_KEY || "",
    },
    enabled: false,
    customChains: [
      {
        network: "base-mainnet",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
    ],
  },
  networks: {
    localhost: {
      chainId: 31337,
      url: "http://127.0.0.1:8545",
    },
    // base: {
    //   url: process.env.BASE_ALCHEMY_RPC_URL,
    //   chainId: 8453,
    //   accounts: process.env.BASE_PRIVATE_KEY
    //     ? [process.env.BASE_PRIVATE_KEY]
    //     : [],
    // },
  },
};

export default config;
