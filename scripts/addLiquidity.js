const hre = require("hardhat");
const { ethers } = hre;

async function main() {
  // Configuration
  const tokenAddress = "0x7F1fe5bf694DB4c48825E0831D5F0AB99992628b"; // DNB Token
  const routerAddress = "0x610D2f07b7EdC67565160F587F37636194C34E74"; // Lynex Router
  const liquidityReceiver = "0xd53686b4298Ac78B1d182E95FeAC1A4DD1D780bD"; // LP token recipient
  const tokenAmount = ethers.parseUnits("4000000", 18); // 4,000,000 DNB
  const ethAmount = ethers.parseUnits("0.000456", 18); // 0.002256 ETH
  const slippageTolerance = 9950; // 95% as per contract
  const deadline = Math.floor(Date.now() / 1000) + 10 * 60; // 30 minutes from now

  // Get signer (account)
  const [signer] = await ethers.getSigners();
  console.log("Adding liquidity with account:", signer.address);

  // Check balances
  const tokenContract = await ethers.getContractAt("IERC20", tokenAddress, signer);
  const tokenBalance = await tokenContract.balanceOf(signer.address);
  const ethBalance = await ethers.provider.getBalance(signer.address);
  console.log("Token balance:", ethers.formatUnits(tokenBalance, 18), "DNB");
  console.log("ETH balance:", ethers.formatUnits(ethBalance, 18), "ETH");

  // Use BigInt comparison
  if (tokenBalance < tokenAmount) {
    throw new Error("Insufficient DNB token balance");
  }
  if (ethBalance < ethAmount) {
    throw new Error("Insufficient ETH balance");
  }

  // Verify existing allowance
  const allowance = await tokenContract.allowance(signer.address, routerAddress);
  console.log("Router allowance:", ethers.formatUnits(allowance, 18), "DNB");
  if (allowance < tokenAmount) {
    throw new Error("Insufficient allowance for router");
  }

  // Calculate minimum amounts for slippage
  const amountTokenMin = (tokenAmount * BigInt(slippageTolerance)) / BigInt(10000);
  const amountETHMin = (ethAmount * BigInt(slippageTolerance)) / BigInt(10000);

  // Add liquidity
  const routerContract = await ethers.getContractAt(
    [
      "function addLiquidityETH(address token, bool stable, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity)"
    ],
    routerAddress,
    signer
  );

  console.log("Adding liquidity...");
  console.log("Token Amount:", ethers.formatUnits(tokenAmount, 18), "DNB");
  console.log("ETH Amount:", ethers.formatUnits(ethAmount, 18), "ETH");
  console.log("Min Token Amount:", ethers.formatUnits(amountTokenMin, 18), "DNB");
  console.log("Min ETH Amount:", ethers.formatUnits(amountETHMin, 18), "ETH");
  console.log("Recipient:", liquidityReceiver);
  console.log("Deadline:", deadline);

  const liquidityTx = await routerContract.addLiquidityETH(
    tokenAddress,
    false,
    tokenAmount,
    amountTokenMin,
    amountETHMin,
    signer.address, // LP tokens to liquidity_receiver
    deadline,
    { value: ethAmount, gasLimit: 500000 }
  );

  const receipt = await liquidityTx.wait();
  console.log("Liquidity added successfully, tx hash:", liquidityTx.hash);
  console.log("Gas used:", receipt.gasUsed.toString());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error:", error);
    process.exit(1);
  });
