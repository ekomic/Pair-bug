import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import 'hardhat-contract-sizer';
import dotenv from 'dotenv';

// Load environment variables from .env file
dotenv.config({ path: '.env' });

// Required environment variables for Linea Mainnet
const { INFURA_KEY, PRIVATE_KEY, LINEASCAN_API_KEY } = process.env;

// Validate required environment variables
if (!INFURA_KEY || !PRIVATE_KEY || !LINEASCAN_API_KEY) {
  throw new Error('INFURA_KEY, PRIVATE_KEY, or LINEASCAN_API_KEY is not set in .env file');
}

// Optional environment variables (e.g., for Base Sepolia)
const { BASESCAN_API_KEY } = process.env;

const config: HardhatUserConfig = {
  // Solidity compiler settings
  solidity: {
    compilers: [
      {
        version: '0.8.26',
        settings: {
          evmVersion: 'london', // Compatible with Linea Mainnet
          optimizer: {
            enabled: true,
            runs: 1000, // Optimize for gas efficiency
          },
        },
      },
    ],
  },

  // Default network for local development
  defaultNetwork: 'hardhat',

  // Network configurations
  networks: {
    hardhat: {},

    // Linea Sepolia testnet for testing
    'linea-sepolia': {
      url: `https://linea-sepolia.infura.io/v3/${INFURA_KEY}`, // Prefer Infura for reliability
      accounts: [PRIVATE_KEY],
      chainId: 59141,
      gasPrice: 'auto', // Let Hardhat estimate gas price
      gas: 10_000_000, // Added for consistency (optional, adjust as needed)
    },

    // Base Sepolia testnet (optional)
    'base-sepolia': {
      url: `https://base-sepolia.infura.io/v3/${INFURA_KEY}`,
      accounts: [PRIVATE_KEY],
      chainId: 84532,
      gasPrice: 'auto',
      gas: 10_000_000, // Added for consistency (optional, adjust as needed)
    },

    // Linea Mainnet configuration
    linea: {
      url: `https://linea-mainnet.infura.io/v3/${INFURA_KEY}`, // Primary RPC
      accounts: [PRIVATE_KEY], // Consider using a mnemonic for multiple accounts
      chainId: 59144, // Explicitly set Linea Mainnet chain ID
      gasPrice: 'auto', // Auto-estimate gas price
      gas: 30_000_000, // Increased 3x from 10M to 30M for complex deployments
      // Fallback RPCs for reliability
      fallbackUrls: [
        'https://rpc.linea.build', // Public Linea Mainnet RPC
        'https://linea-mainnet.publicnode.com',
      ],
    },
  },

  // Etherscan (Lineascan) configuration for contract verification
  etherscan: {
    apiKey: {
      'linea-sepolia': LINEASCAN_API_KEY,
      linea: LINEASCAN_API_KEY,
      ...(BASESCAN_API_KEY && { 'base-sepolia': BASESCAN_API_KEY }), // Conditionally include Base Sepolia
    },
    customChains: [
      {
        network: 'linea-sepolia',
        chainId: 59141,
        urls: {
          apiURL: 'https://api-sepolia.lineascan.build/api',
          browserURL: 'https://sepolia.lineascan.build',
        },
      },
      {
        network: 'base-sepolia',
        chainId: 84532,
        urls: {
          apiURL: 'https://api-sepolia.basescan.org/api',
          browserURL: 'https://sepolia.basescan.org',
        },
      },
      {
        network: 'linea',
        chainId: 59144,
        urls: {
          apiURL: 'https://api.lineascan.build/api',
          browserURL: 'https://lineascan.build',
        },
      },
    ],
  },

  // Contract sizer settings (optional)
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
  },
};

export default config;