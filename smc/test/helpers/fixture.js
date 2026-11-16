const fs = require('fs');
const path = require('path');
const hre = require('hardhat');

const { ethers } = hre;

const defaultSecrets = (overrides = {}) => ({
  cryptoVote: ethers.ZeroHash,
  signKey: ethers.ZeroHash,
  userBiometric: ethers.ZeroHash,
  biometricTypeMask: 0,
  ...overrides,
});

const makeVoterId = (label) => ethers.id(label);

async function deployCoreContracts() {
  const [deployer, custodian, admin, alice, bob] = await ethers.getSigners();

  const VoteToken = await ethers.getContractFactory('VoteToken');
  const voteToken = await VoteToken.deploy();
  await voteToken.waitForDeployment();

  const ProposalManager = await ethers.getContractFactory('ProposalManager');
  const proposalManager = await ProposalManager.deploy(await voteToken.getAddress());
  await proposalManager.waitForDeployment();

  const VoteTokenMinter = await ethers.getContractFactory('VoteTokenMinter');
  const voteTokenMinter = await VoteTokenMinter.deploy(
    await voteToken.getAddress(),
    await proposalManager.getAddress(),
    deployer.address
  );
  await voteTokenMinter.waitForDeployment();

  const custodianRole = await voteToken.CUSTODIAN_ROLE();
  const adminRole = await voteToken.ADMIN_ROLE();

  await (await voteToken.grantRole(custodianRole, custodian.address)).wait();
  await (await voteToken.grantRole(custodianRole, await voteTokenMinter.getAddress())).wait();
  await (await voteToken.grantRole(adminRole, admin.address)).wait();
  await (await voteToken.grantRole(adminRole, await proposalManager.getAddress())).wait();

  const proposalTags = [ethers.id('tag:governance')];
  await proposalManager.connect(deployer).createProposal(
    'Fixture proposal',
    'Used in automated tests',
    true,
    ethers.ZeroHash,
    proposalTags,
    7
  );
  const defaultProposalId = 0n;

  const addresses = {
    voteToken: await voteToken.getAddress(),
    proposalManager: await proposalManager.getAddress(),
    voteTokenMinter: await voteTokenMinter.getAddress(),
    deployer: deployer.address,
    network: hre.network ? hre.network.name : 'hardhat',
    timestamp: new Date().toISOString(),
  };

  try {
    fs.writeFileSync(
      path.join(__dirname, '..', 'deployments.json'),
      JSON.stringify(addresses, null, 2)
    );
  } catch (e) {
    // best-effort write in CI
  }

  return {
    deployer,
    custodian,
    admin,
    alice,
    bob,
    voteToken,
    voteTokenMinter,
    proposalManager,
    defaultProposalId,
  };
}

module.exports = {
  deployCoreContracts,
  defaultSecrets,
  makeVoterId,
};
