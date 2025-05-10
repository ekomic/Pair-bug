const hre = require("hardhat");
const { ethers } = hre;

async function main() {
  // Configuration
  const tokenAddress = "0x7F1fe5bf694DB4c48825E0831D5F0AB99992628b"; // DNB Token
  const routerAddress = "0x610D2f07b7EdC67565160F587F37636194C34E74"; // Lynex Router
  const pairAddress = "0xFa0D1acF05B085503Dbb657d049d5aACF6634435"; // Replace with your LP token address
  const slippageTolerance = 9950; // 99.5% = 0.995
  const deadline = Math.floor(Date.now() / 1000) + 10 * 60;

  const [signer] = await ethers.getSigners();
  console.log("Removing liquidity with:", signer.address);

  const lpToken = await ethers.getContractAt("IERC20", pairAddress, signer);
  const lpBalance1 = await lpToken.balanceOf(signer.address);
  const lpBalance = (lpBalance1 * BigInt(slippageTolerance)) / 10000n;
  const lpTotalSupply = await lpToken.totalSupply();

  if (lpBalance === 0n) throw new Error("No LP tokens to remove");

  const tokenContract = await ethers.getContractAt("IERC20", tokenAddress, signer);
  const wethAddress = await (async () => {
    const code = await ethers.provider.getCode(tokenAddress);
    return code === "0x" ? null : tokenAddress;
  })();

  const pairContract = await ethers.getContractAt(
    ["function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)"],
    pairAddress,
    signer
  );

  const [reserve0, reserve1] = await pairContract.getReserves();
  const tokenReserve = reserve0;
  const ethReserve = reserve1;

  const tokenAmount = (lpBalance * BigInt(tokenReserve)) / lpTotalSupply;
  const ethAmount = (lpBalance * BigInt(ethReserve)) / lpTotalSupply;

  const amountTokenMin = (tokenAmount * BigInt(slippageTolerance)) / 10000n;
  const amountETHMin = (ethAmount * BigInt(slippageTolerance)) / 10000n;

  console.log("Expected:", ethers.formatUnits(tokenAmount, 18), "DNB");
  console.log("Expected:", ethers.formatUnits(ethAmount, 18), "ETH");
  console.log("Min Token:", ethers.formatUnits(amountTokenMin, 18));
  console.log("Min ETH:", ethers.formatUnits(amountETHMin, 18));

  // Approve router
  const allowance = await lpToken.allowance(signer.address, routerAddress);
  if (allowance < lpBalance) {
    const approveTx = await lpToken.approve(routerAddress, lpBalance);
    await approveTx.wait();
  }

  // Remove liquidity
  const router = await ethers.getContractAt(
    [
      "function removeLiquidityETH(address token, bool stable, uint liquidity, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external returns (uint amountToken, uint amountETH)"
    ],
    routerAddress,
    signer
  );

  const tx = await router.removeLiquidityETH(
    tokenAddress,
    false,
    lpBalance,
    amountTokenMin,
    amountETHMin,
    signer.address,
    deadline,
    { gasLimit: 1000000 }
  );

  const receipt = await tx.wait();
  console.log("Liquidity removed successfully, tx hash:", tx.hash);
  console.log("Gas used:", receipt.gasUsed.toString());
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
