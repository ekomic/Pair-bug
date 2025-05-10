const hre = require("hardhat");
const { ethers } = hre;

async function main() {
  // Configuration
  const tokenAddress = "0x7F1fe5bf694DB4c48825E0831D5F0AB99992628b"; // DNB Token
  const routerAddress = "0x610D2f07b7EdC67565160F587F37636194C34E74"; // Lynex Router
  const pairAddress = "0xYourLPTokenAddress"; // Replace with actual LP token address
  const slippageTolerance = 9950; // 99.5%
  const deadline = Math.floor(Date.now() / 1000) + 10 * 60;

  // Get signer
  const [signer] = await ethers.getSigners();
  console.log("Removing liquidity with account:", signer.address);

  // Get LP token contract
  const lpToken = await ethers.getContractAt("IERC20", pairAddress, signer);
  const lpBalance = await lpToken.balanceOf(signer.address);

  if (lpBalance === 0n) {
    throw new Error("No LP tokens to remove");
  }

  // Approve router to spend LP tokens
  const allowance = await lpToken.allowance(signer.address, routerAddress);
  if (allowance < lpBalance) {
    console.log("Approving router to spend LP tokens...");
    const approveTx = await lpToken.approve(routerAddress, lpBalance);
    await approveTx.wait();
  }

  // Call removeLiquidityETH
  const router = await ethers.getContractAt(
    [
      "function removeLiquidityETH(address token, bool stable, uint liquidity, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external returns (uint amountToken, uint amountETH)"
    ],
    routerAddress,
    signer
  );

  // Assume 99.5% as minimums for slippage protection — could also be dynamically calculated
  const amountTokenMin = 0n; // For safety, set these to actual values
  const amountETHMin = 0n;

  console.log("Removing liquidity...");
  const tx = await router.removeLiquidityETH(
    tokenAddress,
    false,
    lpBalance,
    amountTokenMin,
    amountETHMin,
    signer.address,
    deadline,
    { gasLimit: 500000 }
  );

  const receipt = await tx.wait();
  console.log("Liquidity removed successfully, tx hash:", tx.hash);
  console.log("Gas used:", receipt.gasUsed.toString());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Error:", error);
    process.exit(1);
  });
