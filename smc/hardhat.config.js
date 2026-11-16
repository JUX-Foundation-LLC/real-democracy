require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-verify");
const path = require('path');

// Single source of truth for the Besu chainId so the `besu` network and the
// Blockscout verification customChain entry can never drift apart.
const BESU_CHAIN_ID = Number.parseInt(process.env.BESU_CHAIN_ID || "1337", 10);

const defaultSourcesDir = path.join(__dirname, 'contracts/core');
const envSourcesPath = (process.env.HARDHAT_SOURCES_PATH || '').trim();
const resolvedSourcesDir = envSourcesPath
  ? (path.isAbsolute(envSourcesPath)
      ? envSourcesPath
      : path.join(__dirname, envSourcesPath))
  : defaultSourcesDir;
const normalizedSourcesPath = path.relative(__dirname, resolvedSourcesDir) || '.';

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
      mining: {
        auto: true,
        interval: 0
      },
      // Enable state persistence
      initialBaseFeePerGas: 0,
      allowUnlimitedContractSize: true,
      // Persist blockchain state to disk
      loggingEnabled: false,
    },
    localhost: {
      url: process.env.HARDHAT_RPC_URL || "http://127.0.0.1:8545",
      timeout: 60000,
    },
    // Besu QBFT persistent chain — use this network for all deployments going forward.
    // chainId is configurable so the same tooling deploys to prod (1337) or the
    // isolated dev chain (1338) by setting BESU_CHAIN_ID.
    besu: {
      url: process.env.BESU_RPC_URL || process.env.BLOCKCHAIN_RPC_URL || "http://localhost:8545",
      chainId: BESU_CHAIN_ID,
      // Signer comes strictly from the environment — never a key literal in
      // source (so this file is publishable). Dev supplies it via
      // .env.development (see .env.development.example); prod loads the rotated
      // operator key into .env.production. Unset ⇒ no signer (read-only ops
      // still work; signing then fails loudly instead of silently using a
      // well-known public key).
      accounts: [process.env.BLOCKCHAIN_SIGNER_PRIVATE_KEY].filter(Boolean),
      timeout: 60000,
      // Pin an explicit gas cap (= genesis block gas limit) so ethers skips
      // eth_estimateGas. Large contracts (e.g. JurisdictionFactory) otherwise
      // trigger a long besu estimate binary-search that can wedge a deploy for
      // many minutes without ever tripping the per-RPC timeout.
      gas: Number(process.env.BESU_DEPLOY_GAS_LIMIT || 8000000),
    },
  },
  paths: {
    sources: normalizedSourcesPath,
    cache: "./cache",
    artifacts: "./artifacts",
  },
  // Blockscout verification (JUX chain). Blockscout ignores the apiKey value but
  // hardhat-verify requires one to be present.
  etherscan: {
    apiKey: { besu: "blockscout" },
    customChains: [
      {
        network: "besu",
        chainId: BESU_CHAIN_ID,
        urls: {
          apiURL: process.env.BLOCKSCOUT_API_URL || "http://localhost:8082/api",
          browserURL: process.env.BLOCKSCOUT_BROWSER_URL || "https://explorer.juxfoundation.com",
        },
      },
    ],
  },
};
