const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('PluralityRuleBallotBox', function () {
  const J = 9;
  const ruleKey = ethers.id('pick_one');
  const N = 6;
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

    const Box = await ethers.getContractFactory('PluralityRuleBallotBox');
    box = await Box.deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 5000, ethers.ZeroAddress);
    await box.waitForDeployment();
    const config = ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [3]); // choices 0,1,2
    await box.registerRule(ruleKey, ethers.ZeroHash, config);
  });

  const vote = (i, choice) => box.connect(voters[i]).castVote(ruleKey, i + 1, [choice]);

  it('picks the choice with the most votes', async function () {
    // choice 2 gets 3 votes, choice 1 gets 2, choice 0 gets 1
    for (const [i, c] of [2, 2, 2, 1, 1, 0].entries()) await vote(i, c);
    const [v, total] = await box.currentResult(ruleKey);
    expect(total).to.equal(6n);
    expect(v).to.equal(2n);
  });

  it('breaks ties to the lowest index', async function () {
    // choice 1 and choice 2 tie at 2 each → winner is the lower index, 1
    for (const [i, c] of [2, 2, 1, 1].entries()) await vote(i, c);
    const [v] = await box.currentResult(ruleKey);
    expect(v).to.equal(1n);
  });

  it('re-vote moves the tally exactly', async function () {
    for (const [i, c] of [0, 0, 1].entries()) await vote(i, c); // choice 0 leads (2 vs 1)
    let [v] = await box.currentResult(ruleKey);
    expect(v).to.equal(0n);
    await vote(0, 1); // voter0: 0 → 1; now choice 1 leads (2 vs 1)
    [v] = await box.currentResult(ruleKey);
    expect(v).to.equal(1n);
    expect(await box.choiceVotes(ruleKey, 0)).to.equal(1n);
    expect(await box.choiceVotes(ruleKey, 1)).to.equal(2n);
  });

  it('rejects out-of-range choice + bad config', async function () {
    await expect(vote(0, 3)).to.be.revertedWith('PluralityRuleBox: choice out of range');
    const Box = await ethers.getContractFactory('PluralityRuleBallotBox');
    const b2 = await Box.deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 5000, ethers.ZeroAddress);
    await b2.waitForDeployment();
    const enc = (n) => ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [n]);
    // G2 (S10): choiceCount must be in (1, MAX_CHOICE_COUNT] — bounds the argmax loop (gas-DoS guard).
    await expect(b2.registerRule(ethers.id('x'), ethers.ZeroHash, enc(1)))
      .to.be.revertedWith('PluralityRuleBox: choiceCount out of range');
    await expect(b2.registerRule(ethers.id('y'), ethers.ZeroHash, enc(257)))
      .to.be.revertedWith('PluralityRuleBox: choiceCount out of range');
    await b2.registerRule(ethers.id('z'), ethers.ZeroHash, enc(256)); // MAX is accepted
    expect(await b2.choiceCountOf(ethers.id('z'))).to.equal(256n);
  });
});
