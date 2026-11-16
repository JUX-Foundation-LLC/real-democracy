const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * Proves the ballotbox enforces democratic permission ON-CHAIN once a CapabilityRegistry is bound —
 * so self-custody / third-party callers are gated identically to the first-party backend.
 * Open when unbound (backend-enforced bootstrap); permissive voter base allows; restriction denies;
 * an elevated role restores.
 */
describe('BaseRuleBallotBox — on-chain capability gate', function () {
  const J = 3;
  const VOTER_ROLE_ID = 1000;
  const PROPOSER_ROLE_ID = 2;
  const CAP_RULE_VOTING = ethers.id('permit_rule_voting');
  const ruleKey = ethers.id('rule_pass_threshold');

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

    box = await (await ethers.getContractFactory('BooleanRuleBallotBox')).deploy(
      await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 6000, ethers.ZeroAddress,
    );
    await box.waitForDeployment();
    await box.registerRule(ruleKey, ethers.ZeroHash, '0x');
  });

  it('UNBOUND registry → voting is open (backend-enforced bootstrap)', async function () {
    await box.connect(voter).castVote(ruleKey, 1, [1]);
    const [, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(1n);
  });

  it('BOUND + permissive voter base → allowed on-chain', async function () {
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash);
    await catalog.addCapability(J, VOTER_ROLE_ID, CAP_RULE_VOTING, 'permit_rule_voting');
    await box.setCapabilityRegistry(await capReg.getAddress());

    await box.connect(voter).castVote(ruleKey, 1, [1]);
    expect((await box.currentResult(ruleKey))[1]).to.equal(1n);
  });

  it('BOUND + rule-voting removed from the voter base → a plain voter is DENIED', async function () {
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash); // base lacks rule voting
    await box.setCapabilityRegistry(await capReg.getAddress());

    await expect(box.connect(voter).castVote(ruleKey, 1, [1]))
      .to.be.revertedWith('RuleBox: rule voting not permitted');
  });

  it('an elevated role restores the denied capability', async function () {
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash); // restricted base
    await catalog.defineRole(J, PROPOSER_ROLE_ID, 'proposer', 'Proposer', ethers.ZeroHash);
    await catalog.addCapability(J, PROPOSER_ROLE_ID, CAP_RULE_VOTING, 'permit_rule_voting');
    await registry.grantRoles(J, await voteToken.voterIdOf(1), [PROPOSER_ROLE_ID]);
    await box.setCapabilityRegistry(await capReg.getAddress());

    await box.connect(voter).castVote(ruleKey, 1, [1]); // allowed via elevated role
    expect((await box.currentResult(ruleKey))[1]).to.equal(1n);
  });
});
