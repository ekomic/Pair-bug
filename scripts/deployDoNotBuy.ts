import { ethers, run } from 'hardhat';
import dotenv from 'dotenv';

dotenv.config({ path: '../.env' });

async function main() {
  console.log('Deploying DoNotBuy Contract...');
 
  const routerAddress = '0x610D2f07b7EdC67565160F587F37636194C34E74'; // Replace with correct address  0x62C0BBfC20F7e2cBCa6b64f5035c8f7fabc1806E
  const usdcAddress = '0x176211869cA2b568f2A7D4EE941E073a821EE1ff'; // Replace with correct or mock USDC address 0x885c07e77F18cb0FDBB1bb34F16d83945aa11c04


  if (!ethers.isAddress(routerAddress)) {
    throw new Error('Invalid routerAddress');
  }
  if (!ethers.isAddress(usdcAddress)) {
    throw new Error('Invalid usdcAddress');
  }

  try {
    const DoNotBuy = await ethers.deployContract('DoNotBuy', [routerAddress, usdcAddress], { gasLimit: 5000000 });
    await DoNotBuy.waitForDeployment();
    const DoNotBuyAddress = await DoNotBuy.getAddress();
    console.log(`DoNotBuy deployed at: ${DoNotBuyAddress}`);

    await new Promise((resolve) => setTimeout(resolve, 3000));

    await run('verify:verify', {
      address: DoNotBuyAddress,
      constructorArguments: [routerAddress, usdcAddress],
    });
    console.log('BankOfLinea verified!');
  } catch (error) {
    console.error('Deployment failed:', error);
    if (error.data) {
      console.error('Revert data:', error.data);
    }
    throw error;
  }
}

main().catch((error) => {
  console.error('Deployment error:', error);
  process.exitCode = 1;
});