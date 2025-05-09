import { ethers, run } from 'hardhat';
import dotenv from 'dotenv';

dotenv.config({ path: '../.env' });

async function main() {
  console.log('Deploying BankOfLinea Contract...');

  const marketingWallet = process.env.MARKETING_WALLET;

  if (!marketingWallet) {
    throw new Error('MARKETING_WALLET is not set in .env file');
  }

  const BankOfLinea = await ethers.deployContract('BankOfLinea');
  await BankOfLinea.waitForDeployment();
  const BankOfLineaAddress = await BankOfLinea.getAddress();

  console.log(`BankOfLinea deployed at: ${BankOfLineaAddress}`);

  // Wait a few seconds before verifying
  await new Promise((resolve) => setTimeout(resolve, 3000));

  try {
    await run('verify:verify', {
      address: BankOfLineaAddress,
      constructorArguments: [],
    });
    console.log('BankOfLinea successfully verified!');
  } catch (error) {
    console.error('Verification failed:', error);
  }
}

main().catch((error) => {
  console.error('Deployment error:', error);
  process.exitCode = 1;
});