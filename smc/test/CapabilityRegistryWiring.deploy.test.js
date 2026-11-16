const { expect } = require('chai');
const { ethers } = require('hardhat');
const { ensureCapabilityRegistry } = require('../scripts/lib/capabilityWiring');

/**
 * DEPLOY-PATH proof for audit #315 finding C2.
 *
 * The contract-level gates are already covered (RuleBallotBoxCapabilityGate / PublicDelegateVoteCapabilityGate
 * / TagBallotBoxCapabilityGate). The BUG was the DEPLOY WIRING: CapabilityRegistry was never deployed or
 * bound, so every consumer ran with capabilityRegistry==address(0) and the gates were on-chain no-ops.
 *
 * This test exercises the SAME helper the deploy scripts now use (`ensureCapabilityRegistry`) and proves:
 *   1. wiring binds the registry on every consumer (rule box, delegate registry, tag box);
 *   2. enforcement is OFF before wiring (no-op) and ON after (a voter WITHOUT the permit reverts);
 *   3. the helper is idempotent (no second tx) and the registry's sources match the catalog/registry
 *      the boxes resolve against (no split-brain).
 */
describe('CapabilityRegistry — deploy wiring turns enforcement ON (C2)', function () {
  const J = 3;
  const VOTER_ROLE_ID = 1000;
  const CAP_RULE_VOTING = ethers.id('permit_rule_voting');
  const CAP_DELEGATE = ethers.id('permit_delegate');
  const ruleKey = ethers.id('rule_pass_threshold');

  let deployer, voter, catalog, registry, capReg, voteToken, ruleBox, delegateReg;

  beforeEach(async function () {
    [deployer, voter] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(voter.address, 1, J);

    // Mirror deploy_role_registry.js ordering: catalog → registry → CapabilityRegistry (same sources).
    catalog = await (await ethers.getContractFactory('RoleCatalog')).deploy(deployer.address);
    await catalog.waitForDeployment();
    registry = await (await ethers.getContractFactory('JurisdictionRoleRegistry'))
      .deploy(await catalog.getAddress(), deployer.address);
    await registry.waitForDeployment();
    capReg = await (await ethers.getContractFactory('CapabilityRegistry'))
      .deploy(await catalog.getAddress(), await registry.getAddress(), deployer.address);
    await capReg.waitForDeployment();

    // Consumers, deployer-governed/owned (the bootstrap window the deploy scripts wire in).
    ruleBox = await (await ethers.getContractFactory('BooleanRuleBallotBox'))
      .deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await ruleBox.waitForDeployment();
    await ruleBox.registerRule(ruleKey, ethers.ZeroHash, '0x');

    delegateReg = await (await ethers.getContractFactory('PublicDelegateVoteRegistry'))
      .deploy(await voteToken.getAddress());
    await delegateReg.waitForDeployment();
  });

  it('no split-brain: the registry resolves against the SAME catalog + role registry the seed/boxes use', async function () {
    expect((await capReg.roleCatalog()).toLowerCase()).to.equal((await catalog.getAddress()).toLowerCase());
    expect((await capReg.roleRegistry()).toLowerCase()).to.equal((await registry.getAddress()).toLowerCase());
  });

  it('rule box: gate is OFF until wired, then ENFORCED (unpermitted voter reverts, permitted passes)', async function () {
    // BEFORE wiring: address(0) → gate is a no-op even with NO voter role defined.
    expect(await ruleBox.capabilityRegistry()).to.equal(ethers.ZeroAddress);
    await ruleBox.connect(voter).castVote(ruleKey, 1, [1]); // passes — enforcement OFF

    // Restrictive base (voter role exists but lacks permit_rule_voting), then WIRE via the helper.
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash);
    const wired = await ensureCapabilityRegistry(ruleBox, await capReg.getAddress());
    expect(wired).to.equal(true);
    expect((await ruleBox.capabilityRegistry()).toLowerCase()).to.equal((await capReg.getAddress()).toLowerCase());

    // ENFORCEMENT ON: a voter without the permit is now DENIED on-chain.
    await expect(ruleBox.connect(voter).castVote(ruleKey, 1, [1]))
      .to.be.revertedWith('RuleBox: rule voting not permitted');

    // Grant the permit on the permissive base → the same voter passes.
    await catalog.addCapability(J, VOTER_ROLE_ID, CAP_RULE_VOTING, 'permit_rule_voting');
    await ruleBox.connect(voter).castVote(ruleKey, 1, [1]);
    expect((await ruleBox.currentResult(ruleKey))[1]).to.equal(1n);

    // Idempotent: re-wiring the same address sends no tx.
    expect(await ensureCapabilityRegistry(ruleBox, await capReg.getAddress())).to.equal(false);
  });

  it('delegate registry: wiring enforces PERMIT_DELEGATE on-chain', async function () {
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash); // base lacks delegate
    const wired = await ensureCapabilityRegistry(delegateReg, await capReg.getAddress());
    expect(wired).to.equal(true);

    await expect(delegateReg.connect(voter).castPublicDelegateVote(7, 1, 1n))
      .to.be.revertedWith('Registry: delegate voting not permitted');

    await catalog.addCapability(J, VOTER_ROLE_ID, CAP_DELEGATE, 'permit_delegate');
    await delegateReg.connect(voter).castPublicDelegateVote(7, 1, 1n);
    expect((await delegateReg.votes(7, 1)).choice).to.equal(1n);
  });
});
