const { expect } = require('chai');
const { ethers } = require('hardhat');

// C2 follow-on (consolidation of #305/#306/#311): a TagBallotBox is born governed by the factory and
// handed off to its jurisdiction governor at the end of creation, so the factory is the ONLY place
// that can wire its PERMIT_TAG_VOTING capability gate. These tests prove the factory binds it at
// creation (when set) and that the bound gate is ENFORCED — not merely present.
describe('JurisdictionFactory — TagBallotBox capability wiring at creation', function () {
  const CAP_TAG_VOTING = ethers.id('permit_tag_voting');
  const VOTER_ROLE_ID = 1000;
  const Z = ethers.ZeroAddress;
  let deployer, voter, voteToken, catalog, registry, capReg, factory;

  beforeEach(async function () {
    [deployer, voter] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    catalog = await (await ethers.getContractFactory('RoleCatalog')).deploy(deployer.address);
    registry = await (await ethers.getContractFactory('JurisdictionRoleRegistry')).deploy(await catalog.getAddress(), deployer.address);
    capReg = await (await ethers.getContractFactory('CapabilityRegistry')).deploy(
      await catalog.getAddress(), await registry.getAddress(), deployer.address,
    );
    // ballotGovernor = deployer → created boxes are handed back to the deployer (the test signer),
    // so the test can re-open the transparent path + register a tag to exercise the gate.
    factory = await (await ethers.getContractFactory('JurisdictionFactory')).deploy(
      await voteToken.getAddress(), Z, deployer.address, Z,
    );
  });

  const create = (jid) => factory.createJurisdiction(jid, ethers.ZeroHash, ethers.ZeroHash, 6000, 6000, 3000, [], []);

  it('UNSET factory registry → tag box created with capabilityRegistry == address(0) (gate dormant)', async function () {
    await create(11);
    const tagBox = await ethers.getContractAt('TagBallotBox', (await factory.jurisdictions(11)).tagBallotBox);
    expect(await tagBox.capabilityRegistry()).to.equal(Z);
  });

  it('SET factory registry → tag box is bound at creation AND the gate is enforced', async function () {
    await factory.setCapabilityRegistry(await capReg.getAddress());
    await create(12);
    const tagBox = await ethers.getContractAt('TagBallotBox', (await factory.jurisdictions(12)).tagBallotBox);
    // (1) bound by construction
    expect(await tagBox.capabilityRegistry()).to.equal(await capReg.getAddress());

    // (2) ENFORCED: a voter whose role lacks PERMIT_TAG_VOTING is denied. Deployer is the tag box
    //     governor post-handoff → re-open the transparent path + register a tag to drive the gate.
    await voteToken.mint(voter.address, 1, 12);
    await catalog.defineRole(12, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash); // role with NO tag-voting cap
    await tagBox.setTransparentVotingDisabled(false);
    await tagBox.registerTag(ethers.id('tag:climate'), ethers.ZeroHash, false, false);
    await expect(tagBox.connect(voter).castVote(ethers.id('tag:climate'), 1, [1]))
      .to.be.revertedWith('TagBallotBox: tag voting not permitted');

    // grant the capability → now permitted
    await catalog.addCapability(12, VOTER_ROLE_ID, CAP_TAG_VOTING, 'permit_tag_voting');
    await expect(tagBox.connect(voter).castVote(ethers.id('tag:climate'), 1, [1])).to.not.be.reverted;
  });

  it('setCapabilityRegistry is onlyOwner', async function () {
    await expect(factory.connect(voter).setCapabilityRegistry(await capReg.getAddress()))
      .to.be.revertedWith('JurisdictionFactory: only owner');
  });
});
