const { expect } = require('chai');
const { ethers } = require('hardhat');
const { deployCoreContracts } = require('./helpers/fixture');

describe('Governance threshold bounds', function () {
  let ctx;

  beforeEach(async function () {
    ctx = await deployCoreContracts();
  });

  it('rejects RuleBallotBox constructor threshold above 10000 bps', async function () {
    const RuleBallotBox = await ethers.getContractFactory('RuleBallotBox');

    await expect(
      RuleBallotBox.deploy(
        await ctx.voteToken.getAddress(),
        1n,
        ctx.deployer.address,
        ethers.ZeroAddress,
        10001
      )
    ).to.be.revertedWith('RuleBallotBox: threshold too high');
  });

  it('rejects RuleBallotBox runtime threshold above 10000 bps', async function () {
    const RuleBallotBox = await ethers.getContractFactory('RuleBallotBox');
    const ruleBox = await RuleBallotBox.deploy(
      await ctx.voteToken.getAddress(),
      1n,
      ctx.deployer.address,
      ethers.ZeroAddress,
      6000
    );
    await ruleBox.waitForDeployment();

    await expect(ruleBox.setQuorumThreshold(10001)).to.be.revertedWith('RuleBallotBox: threshold too high');
  });

  it('rejects TagBallotBox constructor thresholds above 10000 bps', async function () {
    const TagBallotBox = await ethers.getContractFactory('TagBallotBox');

    await expect(
      TagBallotBox.deploy(
        await ctx.voteToken.getAddress(),
        1n,
        ctx.deployer.address,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        10001,
        5000
      )
    ).to.be.revertedWith('TagBox: activation too high');

    await expect(
      TagBallotBox.deploy(
        await ctx.voteToken.getAddress(),
        1n,
        ctx.deployer.address,
        ethers.ZeroAddress,
        ethers.ZeroAddress,
        8000,
        10001
      )
    ).to.be.revertedWith('TagBox: retirement too high');
  });

  it('rejects TagBallotBox setter thresholds above 10000 bps', async function () {
    const TagBallotBox = await ethers.getContractFactory('TagBallotBox');
    const tagBox = await TagBallotBox.deploy(
      await ctx.voteToken.getAddress(),
      1n,
      ctx.deployer.address,
      ethers.ZeroAddress,
      ethers.ZeroAddress,
      8000,
      3000
    );
    await tagBox.waitForDeployment();

    await expect(tagBox.setDefaultThresholds(10001, 1000)).to.be.revertedWith('TagBox: activation too high');

    await expect(tagBox.setDefaultThresholds(9000, 10001)).to.be.revertedWith('TagBox: retirement too high');

    const tagKey = ethers.id('tag:test');
    await tagBox.registerTag(tagKey, ethers.id('meta:test'), true, false);

    await expect(tagBox.setTagThresholds(tagKey, 10001, 9000)).to.be.revertedWith('TagBox: activation too high');

    await expect(tagBox.setTagThresholds(tagKey, 9000, 10001)).to.be.revertedWith('TagBox: retirement too high');
  });
});
