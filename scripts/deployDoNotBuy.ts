import { ethers, run } from 'hardhat';
import dotenv from 'dotenv';

dotenv.config({ path: '../.env' });

async function main() {
  console.log('Deploying DoNotBuy Contract...');

  const routerAddress = '0x610D2f07b7EdC67565160F587F37636194C34E74'; // Lynex Router (verify this)
  const usdcAddress = '0x176211869cA2b568f2A7D4EE941E073a821EE1ff'; // Circle USDC on Linea

  if (!ethers.isAddress(routerAddress)) {
    throw new Error('Invalid routerAddress');
  }
  if (!ethers.isAddress(usdcAddress)) {
    throw new Error('Invalid usdcAddress');
  }

  try {
    const [deployer] = await ethers.getSigners();
    console.log('Deploying from:', deployer.address);

    const DoNotBuy = await ethers.deployContract('DoNotBuy', [routerAddress, usdcAddress], {
      gasLimit: 5000000,
      gasPrice: ethers.parseUnits('0.1', 'gwei') // Adjust based on Linea Mainnet
    });

    console.log('Waiting for deployment...');
    await DoNotBuy.waitForDeployment();
    const DoNotBuyAddress = await DoNotBuy.getAddress();
    console.log(`DoNotBuy deployed at: ${DoNotBuyAddress}`);

    console.log('Waiting for verification...');
    await new Promise((resolve) => setTimeout(resolve, 10000)); // Increased delay

    await run('verify:verify', {
      address: DoNotBuyAddress,
      constructorArguments: [routerAddress, usdcAddress],
    });
    console.log('DoNotBuy verified!');
  } catch (error) {
    console.error('Deployment failed:', error);
    if (error.data) {
      console.error('Revert data:', error.data);
    }
    if (error.reason) {
      console.error('Revert reason:', error.reason);
    }
    throw error;
  }
}

main().catch((error) => {
  console.error('Deployment error:', error);
  process.exitCode = 1;
});