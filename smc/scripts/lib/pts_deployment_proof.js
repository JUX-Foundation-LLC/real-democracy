'use strict';

const buildPtsDeploymentProof = async ({ ethers, provider, contract, transactionHash = null }) => {
  const address = await contract.getAddress();
  const deploymentTx = contract.deploymentTransaction?.() || contract.deployTransaction || null;
  const txHash = transactionHash || deploymentTx?.hash;
  if (!txHash) throw new Error('PTS deployment transaction hash is required');
  const receipt = await provider.getTransactionReceipt(txHash);
  if (!receipt || Number(receipt.status) !== 1 || !receipt.blockHash) {
    throw new Error(`PTS deployment transaction ${txHash} is not a successful canonical receipt`);
  }
  if (receipt.contractAddress && receipt.contractAddress.toLowerCase() !== address.toLowerCase()) {
    throw new Error('PTS deployment receipt contract address does not match deployed bank');
  }
  const block = await provider.getBlock(receipt.blockNumber);
  if (!block?.hash || block.hash.toLowerCase() !== receipt.blockHash.toLowerCase()) {
    throw new Error('PTS deployment receipt block is not canonical');
  }
  const runtimeCode = await provider.getCode(address);
  if (!runtimeCode || runtimeCode === '0x') throw new Error('PTS deployment has no current runtime code');
  const network = await provider.getNetwork();
  return {
    chainId: Number(network.chainId), address, transactionHash: txHash,
    blockNumber: Number(receipt.blockNumber), blockHash: block.hash,
    runtimeCodeHash: ethers.keccak256(runtimeCode)
  };
};

module.exports = { buildPtsDeploymentProof };
