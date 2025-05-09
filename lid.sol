const { ethers } = require("hardhat");

async function main() {
  const [signer] = await ethers.getSigners();
  console.log("Signer:", signer.address);

  const contractAddress = "0x4769516866d8fa2Bc2F48b5FF9136B9dC42Eb1f3";
  const routerAddress = "0x610D2f07b7EdC67565160F587F37636194C34E74"; // Verify as Lynex Router
  const liquidityReceiver = "0xd53686b4298Ac78B1d182E95FeAC1A4DD1D780bD";

  const token = new ethers.Contract(
    contractAddress,
    [
      "function approve(address spender, uint256 amount) external returns (bool)",
      "function allowance(address owner, address spender) view returns (uint256)"
    ],
    signer
  );
  const routerAbi = [
    "function addLiquidityETH(address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity)"
  ];
  const router = new ethers.Contract(routerAddress, routerAbi, signer);

  const tokenAmount = ethers.parseUnits("5000000", 18); // 5M DNB
  const ethAmount = ethers.parseEther("0.002256"); // 0.002256 ETH
  console.log("Token Amount:", tokenAmount.toString());
  console.log("ETH Amount:", ethAmount.toString());

  // Calculate slippage (95%) manually
  const tokenMin = ethers.parseUnits((5000000 * 0.95).toString(), 18); // 95% of 5M DNB
  const ethMin = ethers.parseEther((0.002256 * 0.95).toString()); // 95% of 0.002256 ETH
  console.log("Token Min:", tokenMin.toString());
  console.log("ETH Min:", ethMin.toString());

  const deadline = Math.floor(Date.now() / 1000) + 300; // 5 minutes
  const to = liquidityReceiver; // LP tokens to liquidity_receiver

  // Check and approve tokens
  const allowance = await token.allowance(signer.address, routerAddress);
  console.log("Current Allowance:", allowance.toString());
  // Compare as strings to avoid BigNumber issues
  if (allowance.toString() < tokenAmount.toString()) {
    console.log("Approving tokens...");
    const approveTx = await token.approve(routerAddress, tokenAmount);
    await approveTx.wait();
    console.log("Approved:", approveTx.hash);
  } else {
    console.log("Sufficient allowance");
  }

  // Add liquidity
  console.log("Adding liquidity...");
  const tx = await router.addLiquidityETH(
    contractAddress,
    tokenAmount,
    tokenMin,
    ethMin,
    to,
    deadline,
    { value: ethAmount, gasLimit: 500000 }
  );
  const receipt = await tx.wait();
  console.log("Liquidity added:", tx.hash);
  console.log("Gas used:", receipt.gasUsed.toString());
}

main().catch((error) => {
  console.error("Error:", error);
  if (error.reason) console.error("Revert reason:", error.reason);
  if (error.data) console.error("Revert data:", error.data);
  process.exitCode = 1;
});