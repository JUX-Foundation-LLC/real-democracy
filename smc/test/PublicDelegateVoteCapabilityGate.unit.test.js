const { expect } = require('chai');
const { ethers } = require('hardhat');

/** PublicDelegateVoteRegistry gates castPublicDelegateVote on PERMIT_DELEGATE once a registry is bound. */
describe('PublicDelegateVoteRegistry — on-chain capability gate', function () {
  const J = 3;
  const VOTER_ROLE_ID = 1000;
  const CAP_DELEGATE = ethers.id('permit_delegate');
  const proposalId = 7; // any externalNullifier (the generalized ballot key)
  const SUPPORT = 1n;    // generalized uint256 choice (boolean support)

  let deployer, delegate, catalog, registry, capReg, voteToken, reg;

  beforeEach(async function () {
    [deployer, delegate] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(delegate.address, 1, J);

    catalog = await (await ethers.getContractFactory('RoleCatalog')).deploy(deployer.address);
    await catalog.waitForDeployment();
    registry = await (await ethers.getContractFactory('JurisdictionRoleRegistry')).deploy(await catalog.getAddress(), deployer.address);
    await registry.waitForDeployment();
    capReg = await (await ethers.getContractFactory('CapabilityRegistry')).deploy(
      await catalog.getAddress(), await registry.getAddress(), deployer.address,
    );
    await capReg.waitForDeployment();

    reg = await (await ethers.getContractFactory('PublicDelegateVoteRegistry')).deploy(await voteToken.getAddress());
    await reg.waitForDeployment();
  });

  it('UNBOUND → delegate voting is open', async function () {
    await reg.connect(delegate).castPublicDelegateVote(proposalId, 1, SUPPORT);
    expect((await reg.votes(proposalId, 1)).choice).to.equal(SUPPORT);
  });

  it('BOUND + permissive voter base → allowed', async function () {
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash);
    await catalog.addCapability(J, VOTER_ROLE_ID, CAP_DELEGATE, 'permit_delegate');
    await reg.setCapabilityRegistry(await capReg.getAddress());
    await reg.connect(delegate).castPublicDelegateVote(proposalId, 1, SUPPORT);
    expect((await reg.votes(proposalId, 1)).choice).to.equal(SUPPORT);
  });

  it('BOUND + permit_delegate removed from voter base → DENIED', async function () {
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash);
    await reg.setCapabilityRegistry(await capReg.getAddress());
    await expect(reg.connect(delegate).castPublicDelegateVote(proposalId, 1, SUPPORT))
      .to.be.revertedWith('Registry: delegate voting not permitted');
  });
});
