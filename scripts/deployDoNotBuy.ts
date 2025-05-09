import { ethers } from 'hardhat';

async function main() {
  // Get the deployer account
  const [deployer] = await ethers.getSigners();
  console.log('Deploying with account:', deployer.address);

  // Verify deployer address
  if (deployer.address.toLowerCase() !== '0xAf5Cf61a41cc28773BED7C75f0eD96BbFef9F2a1'.toLowerCase()) {
    throw new Error('Deployer address does not match expected account');
  }

  // Check account balance
  let balance: bigint;
  try {
    balance = await ethers.provider.getBalance(deployer.address);
  } catch (error) {
    throw new Error(`Failed to fetch account balance: ${error.message}`);
  }
  const minBalance = ethers.parseEther('0.003'); // Minimum 0.06 ETH for 30M gas at 2 Gwei
  if (balance < minBalance) {
    throw new Error(
      `Insufficient balance: ${ethers.formatEther(balance)} ETH. Need at least ${ethers.formatEther(minBalance)} ETH.`
    );
  }
  console.log(`Account balance: ${ethers.formatEther(balance)} ETH`);

  // Get gas price with retries and fallback provider
  let gasPrice: bigint;
  const maxRetries = 3;
  let attempt = 0;
  const providers = [
    ethers.provider, // Primary provider (Infura)
    new ethers.JsonRpcProvider('https://rpc.linea.build'), // Fallback provider
  ];

  while (attempt < maxRetries) {
    for (const provider of providers) {
      try {
        gasPrice = await provider.getGasPrice();
        gasPrice = gasPrice * BigInt(120) / BigInt(100); // Increase by 20% for priority
        console.log(`Gas price set to: ${ethers.formatUnits(gasPrice, 'gwei')} Gwei`);
        break;
      } catch (error) {
        console.warn(`Failed to fetch gas price from provider (attempt ${attempt + 1}/${maxRetries}):`, error);
      }
    }
    if (gasPrice) break;
    attempt++;
    if (attempt === maxRetries) {
      console.warn('Using fallback gas price: 2 Gwei');
      gasPrice = ethers.parseUnits('2', 'gwei'); // Fallback gas price
    }
    // Wait 2 seconds before retrying
    await new Promise(resolve => setTimeout(resolve, 2000));
  }

  // Set gas limit from hardhat.config.ts
  const gasLimit = 30_000_000;

  // Deploy DoNotBuy contract
  const DoNotBuy = await ethers.getContractFactory('DoNotBuy');
  const contract = await DoNotBuy.deploy(
    '0x610D2f07b7EdC67565160F587F37636194C34E74', // Router address (to be verified)
    '0x176211869cA2b568f2A7D4EE941E073a821EE1ff', // USDC address (verified)
    { gasPrice, gasLimit }
  );

  console.log('Deploying DoNotBuy...');
  await contract.deployed();
  console.log('DoNotBuy deployed to:', contract.address);

  // Instructions for Lineascan verification
  console.log('Verify the contract on Lineascan with:');
  console.log(
    `npx hardhat verify --network linea ${contract.address} 0x610D2f07b7EdC67565160F587F37636194C34E74 0x176211869cA2b568f2A7D4EE941E073a821EE1ff`
  );
}

main().catch((error) => {
  console.error('Deployment failed:', error);
  process.exitCode = 1;
});