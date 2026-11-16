const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('AverageRuleBallotBox', function () {
  const J = 9;
  const ruleKey = ethers.id('avg_rule');
  const N = 5;
  let deployer, voters, voteToken, box;

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    deployer = signers[0];
    voters = signers.slice(1, 1 + N);

    const Mock = await ethers.getContractFactory('MockVoteTokenForExecutor');
    voteToken = await Mock.deploy();
    await voteToken.waitForDeployment();
    for (let i = 0; i < N; i++) {
      await voteToken.mint(voters[i].address, i + 1, J);
    }

    const Box = await ethers.getContractFactory('AverageRuleBallotBox');
    box = await Box.deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 5000, ethers.ZeroAddress);
    await box.waitForDeployment();
    await box.registerRule(ruleKey, ethers.ZeroHash, '0x'); // empty config → default maxValue 100
  });

  const vote = (i, val) => box.connect(voters[i]).castVote(ruleKey, i + 1, [val]);

  it('computes the integer mean', async function () {
    for (const [i, val] of [10, 20, 30].entries()) await vote(i, val);
    const [v, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(3n);
    expect(v).to.equal(20n); // 60/3
  });

  it('re-vote adjusts the running sum exactly', async function () {
    for (const [i, val] of [10, 20, 30].entries()) await vote(i, val); // sum 60
    await vote(0, 90); // 10 → 90; sum 140
    const [v, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(3n);
    expect(v).to.equal(46n); // 140/3 = 46 (integer)
    expect(await box.sumValues(ruleKey)).to.equal(140n);
  });

  it('default maxValue is 100; rejects above it', async function () {
    await expect(vote(0, 101)).to.be.revertedWith('AverageRuleBox: value above maximum');
    await vote(0, 100); // allowed
    const [v] = await box.currentResult(ruleKey);
    expect(v).to.equal(100n);
  });

  it('honors a custom maxValue from config', async function () {
    const ruleKey2 = ethers.id('windows_hours');
    const config = ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [720]);
    await box.registerRule(ruleKey2, ethers.ZeroHash, config);
    await box.connect(voters[0]).castVote(ruleKey2, 1, [168]);
    await box.connect(voters[1]).castVote(ruleKey2, 2, [336]);
    const [v] = await box.currentResult(ruleKey2);
    expect(v).to.equal(252n); // (168+336)/2
    expect(await box.maxValueOf(ruleKey2)).to.equal(720n);
  });
});
