const { ethers } = require("hardhat");

async function cancelPendingTx() {
  const [signer] = await ethers.getSigners();

  const tx = {
    to: await signer.getAddress(),
    value: 0,
    nonce: 23,
    gasLimit: 21000,
    gasPrice: ethers.parseUnits("0.04", "gwei"), // Higher than the original tx
  };

  const sentTx = await signer.sendTransaction(tx);
  console.log("Replacement transaction sent:", sentTx.hash);
  await sentTx.wait();
}

cancelPendingTx();
