const { expect } = require('chai');
const { buildPtsDeploymentProof } = require('../scripts/lib/pts_deployment_proof');

describe('PTS deployment proof manifest receipt', () => {
  const address = `0x${'1'.repeat(40)}`;
  const txHash = `0x${'2'.repeat(64)}`;
  const blockHash = `0x${'3'.repeat(64)}`;

  it('persists chain, address, deployment receipt and runtime code hash without historical state reads', async () => {
    const provider = {
      getTransactionReceipt: async () => ({
        status: 1, blockNumber: 13, blockHash, contractAddress: address
      }),
      getBlock: async () => ({ hash: blockHash }),
      getCode: async (_address, block) => {
        if (block !== undefined) throw new Error('historical state unavailable');
        return '0x6000';
      },
      getNetwork: async () => ({ chainId: 1339n })
    };
    const proof = await buildPtsDeploymentProof({
      ethers: { keccak256: () => `0x${'4'.repeat(64)}` }, provider,
      contract: { getAddress: async () => address, deploymentTransaction: () => ({ hash: txHash }) }
    });
    expect(proof).to.deep.equal({
      chainId: 1339, address, transactionHash: txHash, blockNumber: 13,
      blockHash, runtimeCodeHash: `0x${'4'.repeat(64)}`
    });
  });
});
