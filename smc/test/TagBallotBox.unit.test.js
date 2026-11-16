const { expect } = require('chai');
const { ethers } = require('hardhat');

// TagBallotBox — ANONYMOUS, standing support tally for a Tag's EXISTENCE on the shared
// BaseRuleBallotBox. Only the SUBJECT (which tagKey) is public; voters are anonymous. The
// transparent path here exercises the SAME tally + hysteresis the anonymous path drives.
describe('TagBallotBox — anonymous standing tag-existence vote', function () {
  const J = 8;
  const Z = ethers.ZeroAddress;
  const ACT = 6000; // activation 60%
  const RET = 4000; // retirement 40%
  const topic = ethers.id('tag:climate');
  const govTag = ethers.id('tag_governance:reserved');
  const PERMIT_TAG_VOTING = ethers.id('permit_tag_voting');
  const PERMIT_RULE_VOTING = ethers.id('permit_rule_voting');
  const N = 5;
  let deployer, voters, voteToken, box;

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    deployer = signers[0];
    voters = signers.slice(1, 1 + N);
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    for (let i = 0; i < N; i++) await voteToken.mint(voters[i].address, i + 1, J);
    box = await (await ethers.getContractFactory('TagBallotBox')).deploy(
      await voteToken.getAddress(), J, deployer.address, Z, Z, ACT, RET
    );
    // #310 HIGH-1: TagBallotBox defaults transparent-voting DISABLED by construction (anonymity-
    // first). These tests drive the SHARED tally/hysteresis logic through the convenient transparent
    // path, so the harness re-opens it; the closed-by-default guarantee is asserted in its own block.
    await box.setTransparentVotingDisabled(false);
  });

  it('[HIGH-1] transparent tokenId path is CLOSED by construction (anonymity-first default)', async function () {
    const fresh = await (await ethers.getContractFactory('TagBallotBox')).deploy(
      await voteToken.getAddress(), J, deployer.address, Z, Z, ACT, RET
    );
    expect(await fresh.transparentVotingDisabled()).to.equal(true);
    await fresh.registerTag(topic, ethers.ZeroHash, false, false);
    await expect(fresh.connect(voters[0]).castVote(topic, 1, [1]))
      .to.be.revertedWith('RuleBox: transparent voting retired');
  });

  const signal = (i, key, v = 1) => box.connect(voters[i]).castVote(key, i + 1, [v]);
  const active = async (key) => (await box.tags(key)).active;

  it('structureId is tag_support', async function () {
    expect(await box.structureId()).to.equal(ethers.id('tag_support'));
  });

  it('rejects an invalid threshold pair at construction', async function () {
    const T = await ethers.getContractFactory('TagBallotBox');
    await expect(T.deploy(await voteToken.getAddress(), J, deployer.address, Z, Z, 4000, 6000))
      .to.be.revertedWith('TagBox: invalid thresholds');
    await expect(T.deploy(await voteToken.getAddress(), J, deployer.address, Z, Z, 10001, 4000))
      .to.be.reverted; // activation > MAX_BPS
  });

  it('ACTIVATES when support first crosses the activation threshold', async function () {
    await box.registerTag(topic, ethers.ZeroHash, false, false);
    expect(await active(topic)).to.equal(false);
    await signal(0, topic, 0); // oppose → 0/1 = 0%
    await signal(1, topic, 1); // 1/2 = 50% < 60% → still inactive
    expect(await active(topic)).to.equal(false);
    await expect(signal(2, topic, 1)).to.emit(box, 'TagActivated'); // 2/3 = 66% ≥ 60%
    expect(await active(topic)).to.equal(true);
  });

  it('RETIRES only when support < retirement (hysteresis holds between thresholds)', async function () {
    await box.registerTag(topic, ethers.ZeroHash, false, false);
    await signal(0, topic); await signal(1, topic); await signal(2, topic); // 3/3 → active
    expect(await active(topic)).to.equal(true);
    // two withdraws → 3 support / 5 = 60% (≥ retirement 40%) → STAYS active (hysteresis)
    await signal(3, topic, 0); await signal(4, topic, 0);
    expect(await active(topic)).to.equal(true);
    // two supporters flip → 1 support / 5 = 20% (< 40%) → retire
    await signal(0, topic, 0);
    await expect(signal(1, topic, 0)).to.emit(box, 'TagRetired');
    expect(await active(topic)).to.equal(false);
  });

  it('RESERVED governance tags are not votable and never retire', async function () {
    await box.registerTag(govTag, ethers.ZeroHash, true /*active*/, true /*reserved*/);
    expect(await active(govTag)).to.equal(true);
    await expect(signal(0, govTag, 0)).to.be.revertedWith('TagBox: reserved tag not votable');
    expect(await active(govTag)).to.equal(true); // unchanged — exempt from the support vote
  });

  it('re-vote (withdraw) adjusts the standing tally exactly', async function () {
    await box.registerTag(topic, ethers.ZeroHash, false, false);
    await signal(0, topic, 1); await signal(1, topic, 1); await signal(2, topic, 1); // 3/3
    await signal(0, topic, 0); // withdraw → 2/3
    const [bps, total] = await box.currentResult(topic);
    expect(total).to.equal(3n);
    expect(bps).to.equal(6666n); // 2*10000/3
  });

  describe('capability gate — PERMIT_TAG_VOTING, not PERMIT_RULE_VOTING', function () {
    it('a gate allowing PERMIT_TAG_VOTING permits the vote', async function () {
      const gate = await (await ethers.getContractFactory('MockPermitGate')).deploy(PERMIT_TAG_VOTING);
      await box.setCapabilityRegistry(await gate.getAddress());
      await box.registerTag(topic, ethers.ZeroHash, false, false);
      await expect(signal(0, topic)).to.not.be.reverted;
    });

    it('a gate allowing only PERMIT_RULE_VOTING DENIES the tag vote', async function () {
      const gate = await (await ethers.getContractFactory('MockPermitGate')).deploy(PERMIT_RULE_VOTING);
      await box.setCapabilityRegistry(await gate.getAddress());
      await box.registerTag(topic, ethers.ZeroHash, false, false);
      await expect(signal(0, topic)).to.be.revertedWith('TagBallotBox: tag voting not permitted');
    });

    it('the ANONYMOUS path also gates on PERMIT_TAG_VOTING (before verification)', async function () {
      const gate = await (await ethers.getContractFactory('MockPermitGate')).deploy(PERMIT_RULE_VOTING); // denies tag
      await box.registerTag(topic, ethers.ZeroHash, false, false);
      await box.setAnonymousVerifier(deployer.address);
      await box.setRuleExternalNullifier(topic, 999);
      await box.setCapabilityRegistry(await gate.getAddress());
      await expect(box.castVoteAnonymous(topic, [0, 0], [[0, 0], [0, 0]], [0, 0], 0, [1], 1, 0))
        .to.be.revertedWith('TagBallotBox: tag voting not permitted');
    });
  });
});
