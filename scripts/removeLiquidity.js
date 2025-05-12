const hre = require("hardhat");
const { ethers } = hre;

async function main() {
  const tokenAddress = "0x365994a2e4b4705c961C5D110970D2e7f52ADdb9";
  const routerAddress = "0x610D2f07b7EdC67565160F587F37636194C34E74";
  const pairAddress = "0xFa0D1acF05B085503Dbb657d049d5aACF6634435";
  const slippageTolerance = 9950; // 99.5%
  const maxDNBPerBatch = ethers.parseUnits("5000000", 18); // 5 million DNB

  const [signer] = await ethers.getSigners();
  console.log("Removing liquidity with:", signer.address);

  const lpToken = await ethers.getContractAt("IERC20", pairAddress, signer);
  const router = await ethers.getContractAt(
    ["function removeLiquidityETH(address token, bool stable, uint liquidity, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external returns (uint amountToken, uint amountETH)"],
    routerAddress,
    signer
  );

  const pairContract = await ethers.getContractAt(
    ["function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)"],
    pairAddress,
    signer
  );

  const [reserve0, reserve1] = await pairContract.getReserves();
  const tokenReserve = BigInt(reserve0);
  const ethReserve = BigInt(reserve1);
  const totalSupply = await lpToken.totalSupply();

  let lpBalance = await lpToken.balanceOf(signer.address);
  if (lpBalance === 0n) throw new Error("No LP tokens to remove");

  console.log("Starting loop...");
  while (lpBalance > 0n) {
    const tokenAmount = (lpBalance * tokenReserve) / totalSupply;

    // Determine LP to remove to stay within 5M DNB
    let currentLP;
    if (tokenAmount > maxDNBPerBatch) {
      currentLP = (maxDNBPerBatch * totalSupply) / tokenReserve;
    } else {
      currentLP = lpBalance;
    }

    const batchTokenAmount = (currentLP * tokenReserve) / totalSupply;
    const batchETHAmount = (currentLP * ethReserve) / totalSupply;

    const amountTokenMin = (batchTokenAmount * BigInt(slippageTolerance)) / 10000n;
    const amountETHMin = (batchETHAmount * BigInt(slippageTolerance)) / 10000n;
    const deadline = Math.floor(Date.now() / 1000) + 600;

    console.log(`Removing batch of ${ethers.formatUnits(batchTokenAmount, 18)} DNB...`);

    const tx = await router.removeLiquidityETH(
      tokenAddress,
      false,
      currentLP,
      amountTokenMin,
      amountETHMin,
      signer.address,
      deadline,
      { gasLimit: 1_000_000 }
    );

    const receipt = await tx.wait();
    console.log(`Batch removed. Tx: ${tx.hash} | Gas used: ${receipt.gasUsed}`);

    lpBalance -= currentLP;
  }

  console.log("All liquidity removed.");
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
