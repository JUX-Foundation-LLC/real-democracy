const { expect } = require('chai');
const { ethers } = require('hardhat');

/** TagBallotBox enforces PERMIT_TAG_VOTING on-chain (via the shared BaseRuleBallotBox capability
 *  gate) once a CapabilityRegistry is bound — against the REAL RoleCatalog/JurisdictionRoleRegistry. */
describe('TagBallotBox — on-chain capability gate (PERMIT_TAG_VOTING)', function () {
  const J = 3;
  const VOTER_ROLE_ID = 1000;
  const CAP_TAG_VOTING = ethers.id('permit_tag_voting');
  const tagKey = ethers.id('foundational');

  let deployer, voter, catalog, registry, capReg, voteToken, box;

  beforeEach(async function () {
    [deployer, voter] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(voter.address, 1, J);

    catalog = await (await ethers.getContractFactory('RoleCatalog')).deploy(deployer.address);
    await catalog.waitForDeployment();
    registry = await (await ethers.getContractFactory('JurisdictionRoleRegistry')).deploy(await catalog.getAddress(), deployer.address);
    await registry.waitForDeployment();
    capReg = await (await ethers.getContractFactory('CapabilityRegistry')).deploy(
      await catalog.getAddress(), await registry.getAddress(), deployer.address,
    );
    await capReg.waitForDeployment();

    box = await (await ethers.getContractFactory('TagBallotBox')).deploy(
      await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, ethers.ZeroAddress, 6000, 3000,
    );
    await box.waitForDeployment();
    await box.registerTag(tagKey, ethers.id('foundational-meta'), true, false);
    // #310 HIGH-1: TagBallotBox defaults transparent-voting DISABLED. This suite asserts the
    // CAPABILITY gate over the transparent path, so re-open it here (the gate fires regardless of
    // which path; the anonymity default is covered in TagBallotBox.unit.test.js).
    await box.setTransparentVotingDisabled(false);
  });

  // ballot [1] = support
  const signal = () => box.connect(voter).castVote(tagKey, 1, [1]);

  it('UNBOUND → tag voting is open', async function () {
    await signal();
    expect(await box.voterCount(tagKey)).to.equal(1n);
  });

  it('BOUND + permissive voter base → allowed', async function () {
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash);
    await catalog.addCapability(J, VOTER_ROLE_ID, CAP_TAG_VOTING, 'permit_tag_voting');
    await box.setCapabilityRegistry(await capReg.getAddress());
    await signal();
    expect(await box.voterCount(tagKey)).to.equal(1n);
  });

  it('BOUND + tag-voting removed from the voter base → DENIED', async function () {
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash);
    await box.setCapabilityRegistry(await capReg.getAddress());
    await expect(signal()).to.be.revertedWith('TagBallotBox: tag voting not permitted');
  });
});
