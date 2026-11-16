const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('MedianRuleBallotBox', function () {
  const J = 9;
  const ruleKey = ethers.id('threshold_rule');
  const N = 7;
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

    const Box = await ethers.getContractFactory('MedianRuleBallotBox');
    box = await Box.deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 5000, ethers.ZeroAddress);
    await box.waitForDeployment();
    const config = ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [100]);
    await box.registerRule(ruleKey, ethers.ZeroHash, config);
  });

  const vote = (i, val) => box.connect(voters[i]).castVote(ruleKey, i + 1, [val]);

  it('odd count → exact middle', async function () {
    for (const [i, val] of [10, 20, 30, 40, 50].entries()) await vote(i, val);
    const [v, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(5n);
    expect(v).to.equal(30n);
  });

  it('even count → lower median', async function () {
    for (const [i, val] of [10, 20, 30, 40].entries()) await vote(i, val);
    const [v, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(4n);
    expect(v).to.equal(20n); // lower of the two central values (20, 30)
  });

  it('is manipulation-resistant — an extreme vote barely moves the median', async function () {
    for (const [i, val] of [38, 40, 42, 39, 41].entries()) await vote(i, val);
    let [v] = await box.currentResult(ruleKey);
    expect(v).to.equal(40n); // median of [38,39,40,41,42]

    await vote(5, 100); // outlier; [38,39,40,41,42,100], lower median still 40
    [v] = await box.currentResult(ruleKey);
    expect(v).to.equal(40n); // a MEAN would jump to 50 — median holds
  });

  it('re-vote decrements the histogram EXACTLY', async function () {
    for (const [i, val] of [10, 20, 30].entries()) await vote(i, val);
    let [v] = await box.currentResult(ruleKey);
    expect(v).to.equal(20n);

    await vote(0, 90); // voter0: 10 → 90; now [20,30,90], median 30
    [v] = await box.currentResult(ruleKey);
    expect(v).to.equal(30n);
    expect(await box.hist(ruleKey, 10)).to.equal(0n);
    expect(await box.hist(ruleKey, 90)).to.equal(1n);
  });

  it('rejects value above maxValue + reports structureId', async function () {
    await expect(vote(0, 101)).to.be.revertedWith('MedianRuleBox: value above maximum');
    expect(await box.structureId()).to.equal(ethers.id('median'));
  });
});
