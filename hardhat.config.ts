import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY;

const config: HardhatUserConfig = {
  defaultNetwork: "hardhat",
  solidity: {
    compilers: [
      {
        version: "0.5.16",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          outputSelection: {
            "*": {
              "*": ["storageLayout"],
            },
          },
        },
      },
      {
        version: "0.8.13",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          outputSelection: {
            "*": {
              "*": ["storageLayout"],
            },
          },
        },
      },
    ],
  },
  gasReporter: {
    currency: "USD",
    enabled: false,
  },
  networks: {
    mainnet: {
      url: `https://rpc.coredao.org`,
      chainId: 1116,
      accounts: [`0x${PRIVATE_KEY}`],
    },
    testnet: {
      url: `https://rpc.test.btcs.network`,
      chainId: 1115,
      accounts: [`0x${PRIVATE_KEY}`],
    },
    rinkeby: {
      url: `https://rinkeby.infura.io/v3/9272c529b110464abab493da913448a2`,
      chainId: 4,
      accounts: [`0x${PRIVATE_KEY}`],
    },
    coverage: {
      url: "http://localhost:8555",
    },

    localhost: {
      url: `http://127.0.0.1:8545`,
    },
  },
  etherscan: {
    apiKey: {
      core: "c808613489e847cea9dbc7cca641afab",
      core_testnet: "47ef2296e33f44d2a56e0a5df8796ce0"
    },
    customChains: [
      {
        network: "core",
        chainId: 1116,
        urls: {
          apiURL: "https://openapi.coredao.org/api",
          browserURL: "https://scan.coredao.org"
        }
      },
      {
        network: "core_testnet",
        chainId: 1115,
        urls: {
          apiURL: "https://api.test.btcs.network/api",
          browserURL: "https://scan.test.btcs.network/"
        }
      }
    ]
  },
};

export default config;
