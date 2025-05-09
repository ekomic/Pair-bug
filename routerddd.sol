Compiled 3 Solidity files successfully (evm target: london).
Deploying TestWETH...
TestWETH deployed at: 0xcfB1a3465fE628121Ad525Fc8c23f5Df08098310
Deploying TestFactory...
TestFactory deployed at: 0x70E6587EdCdb02de01dA48560148cAA14e7B48cC
Deploying TestRouter...
TestRouter deployed at: 0x62C0BBfC20F7e2cBCa6b64f5035c8f7fabc1806E
TestUSDC deployed at: 0x885c07e77F18cb0FDBB1bb34F16d83945aa11c04




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
    },

    // Base Sepolia testnet (optional)
    'base-sepolia': {
      url: `https://base-sepolia.infura.io/v3/${INFURA_KEY}`,
      accounts: [PRIVATE_KEY],
      chainId: 84532,
      gasPrice: 'auto',
    },

    // Linea Mainnet configuration
    linea: {
      url: `https://linea-mainnet.infura.io/v3/${INFURA_KEY}`, // Primary RPC
      accounts: [PRIVATE_KEY], // Consider using a mnemonic for multiple accounts
      chainId: 59144, // Explicitly set Linea Mainnet chain ID
      gasPrice: 'auto', // Auto-estimate gas price
      gas: 10_000_000, // Set a reasonable gas limit (adjust as needed)
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















import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import dotenv from 'dotenv';
import 'hardhat-contract-sizer';

dotenv.config({ path: '.env' });

const { INFURA_KEY, PRIVATE_KEY, LINEASCAN_API_KEY, BASESCAN_API_KEY } = process.env;

if (!INFURA_KEY || !PRIVATE_KEY || !LINEASCAN_API_KEY || !BASESCAN_API_KEY) {
  throw new Error(
    'INFURA_KEY, PRIVATE_KEY or LINEASCAN_API_KEY is not set in .env file',
  );
}

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: '0.8.26',
        settings: {
          evmVersion: 'london',
          optimizer: {
            enabled: true,
            runs: 1000,
          },
        },
      },
    ],
  },
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {},
    'linea-sepolia': {
      url: `https://rpc.sepolia.linea.build`, //https://rpc.sepolia.linea.build https://linea-sepolia-rpc.publicnode.com
      accounts: [PRIVATE_KEY],
    },
    'base-sepolia': {
      url: `https://base-sepolia.infura.io/v3/${INFURA_KEY}`,
      accounts: [PRIVATE_KEY],
    },

    linea: {
      url: `https://linea-mainnet.infura.io/v3/${INFURA_KEY}`,
      accounts: [PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: {
      'linea-sepolia': LINEASCAN_API_KEY,
      linea: LINEASCAN_API_KEY,
      'base-sepolia': BASESCAN_API_KEY,
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
};

export default config;