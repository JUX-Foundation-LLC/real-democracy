const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('RuleValueBallotBox', function () {
  let deployer, alice, bob;
  let voteToken, box;
  const J = 10;
  const T_ALICE = 1;
  const T_BOB = 2;
  const key = (name) => ethers.keccak256(ethers.toUtf8Bytes(name));

  beforeEach(async function () {
    [deployer, alice, bob] = await ethers.getSigners();
    const Mock = await ethers.getContractFactory('MockVoteTokenForExecutor');
    voteToken = await Mock.deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(alice.address, T_ALICE, J);
    await voteToken.mint(bob.address, T_BOB, J);

    const Box = await ethers.getContractFactory('RuleValueBallotBox');
    box = await Box.deploy(await voteToken.getAddress(), J, deployer.address);
    await box.waitForDeployment();

    await box.registerRule(key('bool_rule'), 1, 0, 0, 0, ethers.ZeroHash);
    await box.registerRule(key('slider_rule'), 2, 0, 8760, 0, ethers.ZeroHash); // hours
    await box.registerRule(key('plurality_rule'), 3, 5, 0, 0, ethers.ZeroHash);
    await box.registerRule(key('ranked_rule'), 4, 4, 0, 0, ethers.ZeroHash);
  });

  it('accepts valid ballots per type and tracks revisions/counts', async function () {
    await box.connect(alice).castRuleVote(key('bool_rule'), T_ALICE, [1]);
    await box.connect(alice).castRuleVote(key('slider_rule'), T_ALICE, [168]);
    await box.connect(alice).castRuleVote(key('plurality_rule'), T_ALICE, [3]);
    await expect(box.connect(alice).castRuleVote(key('ranked_rule'), T_ALICE, [2, 0, 1]))
      .to.emit(box, 'RuleValueVoteCast');

    // Move a ballot — never-closing box, revision increments.
    await box.connect(alice).castRuleVote(key('bool_rule'), T_ALICE, [0]);
    const [value,, revision] = await box.getBallot(key('bool_rule'), T_ALICE);
    expect(value.map(Number)).to.deep.equal([0]);
    expect(revision).to.equal(2);
    expect(await box.ballotCount(key('bool_rule'))).to.equal(1n); // same token, one voter

    await box.connect(bob).castRuleVote(key('bool_rule'), T_BOB, [1]);
    expect(await box.ballotCount(key('bool_rule'))).to.equal(2n);
  });

  it('rejects malformed ballots per type', async function () {
    await expect(box.connect(alice).castRuleVote(key('bool_rule'), T_ALICE, [2]))
      .to.be.revertedWith('RuleValueBallotBox: boolean ballot must be [0] or [1]');
    await expect(box.connect(alice).castRuleVote(key('slider_rule'), T_ALICE, [9000]))
      .to.be.revertedWith('RuleValueBallotBox: slider value above maximum');
    await expect(box.connect(alice).castRuleVote(key('plurality_rule'), T_ALICE, [5]))
      .to.be.revertedWith('RuleValueBallotBox: choice out of range');
    await expect(box.connect(alice).castRuleVote(key('ranked_rule'), T_ALICE, [1, 1]))
      .to.be.revertedWith('RuleValueBallotBox: duplicate ranked choice');
    await expect(box.connect(alice).castRuleVote(key('ranked_rule'), T_ALICE, [9]))
      .to.be.revertedWith('RuleValueBallotBox: ranked choice out of range');
  });

  it('enforces token eligibility and governor-only registration', async function () {
    await expect(box.connect(bob).castRuleVote(key('bool_rule'), T_ALICE, [1]))
      .to.be.revertedWith('RuleValueBallotBox: not token owner');
    await voteToken.setInactive(T_ALICE, true);
    await expect(box.connect(alice).castRuleVote(key('bool_rule'), T_ALICE, [1]))
      .to.be.revertedWith('RuleValueBallotBox: inactive token');
    await expect(box.connect(alice).registerRule(key('x'), 1, 0, 0, 0, ethers.ZeroHash))
      .to.be.revertedWith('RuleValueBallotBox: only governor');
  });

  it('supports open-ended future vote structures (custom types)', async function () {
    // Majority-judgement-style: a grade (0-6) per choice, type code 100.
    await box.registerRule(key('mj_rule'), 100, 0, 6, 5, ethers.ZeroHash);
    await box.connect(alice).castRuleVote(key('mj_rule'), T_ALICE, [4, 6, 0, 2, 5]);
    const [value] = await box.getBallot(key('mj_rule'), T_ALICE);
    expect(value.map(Number)).to.deep.equal([4, 6, 0, 2, 5]);
    await expect(box.connect(alice).castRuleVote(key('mj_rule'), T_ALICE, [7]))
      .to.be.revertedWith('RuleValueBallotBox: value above maximum');
    await expect(box.connect(alice).castRuleVote(key('mj_rule'), T_ALICE, [1, 1, 1, 1, 1, 1]))
      .to.be.revertedWith('RuleValueBallotBox: ballot too long');
  });
});
