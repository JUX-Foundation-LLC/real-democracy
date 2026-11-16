const { expect } = require('chai');
const { ethers } = require('hardhat');

// RoleBallotBox — ANONYMOUS, standing democratic role grants on the shared BaseRuleBallotBox.
// Only the SUBJECT (which voterId is up for which role) is public; voters are anonymous. The
// transparent path here exercises the SAME tally/publish logic the anonymous path drives.
describe('RoleBallotBox — anonymous standing role grants', function () {
  const J = 7;
  const ADMIN_ROLE = 1;
  const Z = ethers.ZeroAddress;
  const candidate = ethers.id('candidate-voter'); // SUBJECT voterId (public)
  const PERMIT_ROLE_VOTING = ethers.id('permit_role_voting');
  const PERMIT_RULE_VOTING = ethers.id('permit_rule_voting');
  const N = 5;
  let deployer, voters, voteToken, registry, catalog, box;

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    deployer = signers[0];
    voters = signers.slice(1, 1 + N);
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    for (let i = 0; i < N; i++) await voteToken.mint(voters[i].address, i + 1, J);
    registry = await (await ethers.getContractFactory('MockRoleRegistry')).deploy();
    catalog = await (await ethers.getContractFactory('MockRoleCatalog')).deploy();
    await catalog.setActiveRole(J, ADMIN_ROLE, true);
    box = await (await ethers.getContractFactory('RoleBallotBox')).deploy(
      await voteToken.getAddress(), J, deployer.address, Z, 5000 /*50%*/, Z,
      await registry.getAddress(), await catalog.getAddress()
    );
    // #310 HIGH-1: RoleBallotBox defaults transparent-voting DISABLED by construction (anonymity-
    // first). These tests drive the SHARED tally/publish logic through the convenient transparent
    // path, so the harness re-opens it; the closed-by-default guarantee is asserted in its own block.
    await box.setTransparentVotingDisabled(false);
  });

  it('[HIGH-1] transparent tokenId path is CLOSED by construction (anonymity-first default)', async function () {
    // A fresh box, untouched, must reject the transparent castVote — no deploy-script flip required.
    const fresh = await (await ethers.getContractFactory('RoleBallotBox')).deploy(
      await voteToken.getAddress(), J, deployer.address, Z, 5000, Z,
      await registry.getAddress(), await catalog.getAddress()
    );
    expect(await fresh.transparentVotingDisabled()).to.equal(true);
    const k = await fresh.ballotKey(candidate, ADMIN_ROLE, true);
    await fresh.registerRoleBallot(candidate, ADMIN_ROLE, true, ethers.ZeroHash);
    await expect(fresh.connect(voters[0]).castVote(k, 1, [1]))
      .to.be.revertedWith('RuleBox: transparent voting retired');
  });

  const key = (grant = true) => box.ballotKey(candidate, ADMIN_ROLE, grant);
  const support = (i, k, v = 1) => box.connect(voters[i]).castVote(k, i + 1, [v]);

  it('structureId is role_support', async function () {
    expect(await box.structureId()).to.equal(ethers.id('role_support'));
  });

  it('registers a grant ballot (active role) + tallies support', async function () {
    const k = await key(true);
    await expect(box.registerRoleBallot(candidate, ADMIN_ROLE, true, ethers.ZeroHash))
      .to.emit(box, 'RoleBallotRegistered').withArgs(k, candidate, ADMIN_ROLE, true, ethers.ZeroHash);
    await support(0, k); await support(1, k); await support(2, k);
    const [bps, total, quorum] = await box.currentResult(k);
    expect(total).to.equal(3n);
    expect(bps).to.equal(10000n);
    expect(quorum).to.equal(true);
  });

  it('rejects a grant ballot for an inactive role', async function () {
    await expect(box.registerRoleBallot(candidate, 99, true, ethers.ZeroHash))
      .to.be.revertedWith('RoleBox: inactive role');
  });

  it('publishes a GRANT on quorum → registry.grantRoles(jur, voterId, [roleId])', async function () {
    const k = await key(true);
    await box.registerRoleBallot(candidate, ADMIN_ROLE, true, ethers.ZeroHash);
    await support(0, k); await support(1, k); await support(2, k);
    await box.publishRoleBallot(k);
    expect(await registry.grantCount()).to.equal(1n);
    expect(await registry.lastWasGrant()).to.equal(true);
    expect(await registry.lastRoleId()).to.equal(BigInt(ADMIN_ROLE));
    expect(await registry.lastVoterId()).to.equal(candidate);
    expect(await registry.lastJurisdiction()).to.equal(BigInt(J));
  });

  it('refuses to publish without quorum (support < 50%)', async function () {
    const k = await key(true);
    await box.registerRoleBallot(candidate, ADMIN_ROLE, true, ethers.ZeroHash);
    await support(0, k, 1); await support(1, k, 0); await support(2, k, 0); // 1/3 = 33%
    await expect(box.publishRoleBallot(k)).to.be.revertedWith('RoleBox: quorum not met');
  });

  it('publishes a REVOKE (grant=false) → registry.revokeRoles (demotion path)', async function () {
    const k = await key(false); // revoke ballot — no active-role requirement
    await box.registerRoleBallot(candidate, ADMIN_ROLE, false, ethers.ZeroHash);
    await support(0, k); await support(1, k); await support(2, k);
    await box.publishRoleBallot(k);
    expect(await registry.revokeCount()).to.equal(1n);
    expect(await registry.lastWasGrant()).to.equal(false);
  });

  it('re-vote (withdraw support) adjusts the standing tally exactly', async function () {
    const k = await key(true);
    await box.registerRoleBallot(candidate, ADMIN_ROLE, true, ethers.ZeroHash);
    await support(0, k, 1); await support(1, k, 1); await support(2, k, 1); // 3/3
    await support(0, k, 0); // voter 0 → oppose; now 2/3
    const [bps, total] = await box.currentResult(k);
    expect(total).to.equal(3n);
    expect(bps).to.equal(6666n); // 2*10000/3
  });

  describe('capability gate — PERMIT_ROLE_VOTING, not PERMIT_RULE_VOTING', function () {
    it('a gate allowing PERMIT_ROLE_VOTING permits the vote', async function () {
      const gate = await (await ethers.getContractFactory('MockPermitGate')).deploy(PERMIT_ROLE_VOTING);
      await box.setCapabilityRegistry(await gate.getAddress());
      const k = await key(true);
      await box.registerRoleBallot(candidate, ADMIN_ROLE, true, ethers.ZeroHash);
      await expect(support(0, k)).to.not.be.reverted;
    });

    it('a gate allowing only PERMIT_RULE_VOTING DENIES the role vote (proves the right permit)', async function () {
      const gate = await (await ethers.getContractFactory('MockPermitGate')).deploy(PERMIT_RULE_VOTING);
      await box.setCapabilityRegistry(await gate.getAddress());
      const k = await key(true);
      await box.registerRoleBallot(candidate, ADMIN_ROLE, true, ethers.ZeroHash);
      await expect(support(0, k)).to.be.revertedWith('RoleBox: role voting not permitted');
    });

    it('the ANONYMOUS path also gates on PERMIT_ROLE_VOTING (jurisdiction-wide, before verification)', async function () {
      const gate = await (await ethers.getContractFactory('MockPermitGate')).deploy(PERMIT_RULE_VOTING); // denies role
      const k = await key(true);
      await box.registerRoleBallot(candidate, ADMIN_ROLE, true, ethers.ZeroHash);
      await box.setAnonymousVerifier(deployer.address); // any non-zero — we revert at the gate first
      await box.setRuleExternalNullifier(k, 999);
      await box.setCapabilityRegistry(await gate.getAddress());
      await expect(box.castVoteAnonymous(k, [0, 0], [[0, 0], [0, 0]], [0, 0], 0, [1], 1, 0))
        .to.be.revertedWith('RoleBox: role voting not permitted');
    });
  });
});
