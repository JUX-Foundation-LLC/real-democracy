const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('JurisdictionRuleRegistry', function () {
  const J = 9;
  const K = 10; // a different jurisdiction
  const ruleKey = ethers.id('quorum_threshold');
  let deployer, governor, outsider, alice, voteToken, boolBoxJ, boolBoxK, registry;

  beforeEach(async function () {
    [deployer, governor, outsider, alice] = await ethers.getSigners();

    const Mock = await ethers.getContractFactory('MockVoteTokenForExecutor');
    voteToken = await Mock.deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(alice.address, 1, J);

    const Box = await ethers.getContractFactory('BooleanRuleBallotBox');
    boolBoxJ = await Box.deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await boolBoxJ.waitForDeployment();
    await boolBoxJ.registerRule(ruleKey, ethers.ZeroHash, '0x');

    boolBoxK = await Box.deploy(await voteToken.getAddress(), K, deployer.address, ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await boolBoxK.waitForDeployment();

    const Registry = await ethers.getContractFactory('JurisdictionRuleRegistry');
    registry = await Registry.deploy(deployer.address);
    await registry.waitForDeployment();
  });

  it('binds a rule to a box + reads the result through the registry', async function () {
    await registry.bindRuleBox(J, ruleKey, await boolBoxJ.getAddress());
    expect(await registry.boxFor(J, ruleKey)).to.equal(await boolBoxJ.getAddress());

    await boolBoxJ.connect(alice).castVote(ruleKey, 1, [1]); // support
    const [value, total, q] = await registry.resultFor(J, ruleKey);
    expect(total).to.equal(1n);
    expect(value).to.equal(10000n); // 100% support
    expect(q).to.equal(true);
  });

  it('rejects a box pinned to a different jurisdiction', async function () {
    await expect(registry.bindRuleBox(J, ruleKey, await boolBoxK.getAddress()))
      .to.be.revertedWith('Registry: box jurisdiction mismatch');
  });

  it('rejects a target that is not an IRuleBallotBox', async function () {
    // the vote token is a real contract but not a ballotbox → bind reverts
    await expect(registry.bindRuleBox(J, ruleKey, await voteToken.getAddress())).to.be.reverted;
  });

  it('only the governor or a registrar can bind', async function () {
    await expect(registry.connect(outsider).bindRuleBox(J, ruleKey, await boolBoxJ.getAddress()))
      .to.be.revertedWithCustomError(registry, 'NotAuthorized');

    // hand jurisdiction authority to `governor`, then it can bind
    await registry.setJurisdictionGovernor(J, governor.address);
    await registry.connect(governor).bindRuleBox(J, ruleKey, await boolBoxJ.getAddress());
    expect(await registry.boxFor(J, ruleKey)).to.equal(await boolBoxJ.getAddress());
  });

  it('clears a binding', async function () {
    await registry.bindRuleBox(J, ruleKey, await boolBoxJ.getAddress());
    await registry.clearRuleBox(J, ruleKey);
    expect(await registry.boxFor(J, ruleKey)).to.equal(ethers.ZeroAddress);
    await expect(registry.resultFor(J, ruleKey)).to.be.revertedWith('Registry: rule not bound');
  });

  it('§5.3 type-change reuse: bindRuleBox rebinds a rule to a different structure box', async function () {
    await registry.bindRuleBox(J, ruleKey, await boolBoxJ.getAddress());
    const Median = await ethers.getContractFactory('MedianRuleBallotBox');
    const medianJ = await Median.deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await medianJ.waitForDeployment();
    await medianJ.registerRule(ruleKey, ethers.ZeroHash, ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [100]));
    await registry.bindRuleBox(J, ruleKey, await medianJ.getAddress()); // rebind = the type-change primitive
    expect(await registry.boxFor(J, ruleKey)).to.equal(await medianJ.getAddress());
  });

  describe('rule→tag binding (#343, one-tag-per-rule)', function () {
    const tagA = ethers.id('lighting');
    const tagB = ethers.id('show_economics');
    let tagBoxJ, tagBoxK;

    beforeEach(async function () {
      const Tag = await ethers.getContractFactory('TagBallotBox');
      // (voteToken, jurisdictionId, governor=deployer, chainClock, forwarder, activationBps, retirementBps)
      tagBoxJ = await Tag.deploy(await voteToken.getAddress(), J, deployer.address, ethers.ZeroAddress, ethers.ZeroAddress, 3000, 1500);
      await tagBoxJ.waitForDeployment();
      await tagBoxJ.registerTag(tagA, ethers.ZeroHash, true, false);
      await tagBoxJ.registerTag(tagB, ethers.ZeroHash, true, false);

      tagBoxK = await Tag.deploy(await voteToken.getAddress(), K, deployer.address, ethers.ZeroAddress, ethers.ZeroAddress, 3000, 1500);
      await tagBoxK.waitForDeployment();
      await tagBoxK.registerTag(tagA, ethers.ZeroHash, true, false);

      await registry.bindRuleBox(J, ruleKey, await boolBoxJ.getAddress());
    });

    it('binds a rule its delegation tag + tagFor reads it', async function () {
      await expect(registry.bindRuleTag(J, ruleKey, tagA, await tagBoxJ.getAddress()))
        .to.emit(registry, 'RuleTagBound')
        .withArgs(J, ruleKey, tagA, await tagBoxJ.getAddress());
      expect(await registry.tagFor(J, ruleKey)).to.equal(tagA);
    });

    it('is single-valued — rebinding overwrites (one-tag invariant)', async function () {
      await registry.bindRuleTag(J, ruleKey, tagA, await tagBoxJ.getAddress());
      await registry.bindRuleTag(J, ruleKey, tagB, await tagBoxJ.getAddress());
      expect(await registry.tagFor(J, ruleKey)).to.equal(tagB); // not A+B — a single tag
    });

    it('rejects binding a tag before the rule has a box', async function () {
      const otherRule = ethers.id('payout_split');
      await expect(registry.bindRuleTag(J, otherRule, tagA, await tagBoxJ.getAddress()))
        .to.be.revertedWith('Registry: rule not bound');
    });

    it('rejects a tag box pinned to a different jurisdiction (tag→jur explicit)', async function () {
      await expect(registry.bindRuleTag(J, ruleKey, tagA, await tagBoxK.getAddress()))
        .to.be.revertedWith('Registry: tag jurisdiction mismatch');
    });

    it('rejects an unknown tag on the right jurisdiction box', async function () {
      const unknown = ethers.id('does_not_exist');
      await expect(registry.bindRuleTag(J, ruleKey, unknown, await tagBoxJ.getAddress()))
        .to.be.revertedWith('Registry: unknown tag');
    });

    it('only the governor or a registrar can bind/clear a tag', async function () {
      await expect(registry.connect(outsider).bindRuleTag(J, ruleKey, tagA, await tagBoxJ.getAddress()))
        .to.be.revertedWithCustomError(registry, 'NotAuthorized');
    });

    it('clears a tag binding', async function () {
      await registry.bindRuleTag(J, ruleKey, tagA, await tagBoxJ.getAddress());
      await expect(registry.clearRuleTag(J, ruleKey))
        .to.emit(registry, 'RuleTagCleared').withArgs(J, ruleKey, tagA);
      expect(await registry.tagFor(J, ruleKey)).to.equal(ethers.ZeroHash);
    });
  });
});
