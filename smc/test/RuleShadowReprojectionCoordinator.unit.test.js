const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('RuleShadowReprojectionCoordinator', function () {
  this.timeout(180000);
  const J = 9;
  const K = 10;
  const ruleKey = ethers.id('standing_rule');
  const digest = (label) => ethers.id(label);
  let deployer, governor, operator, outsider, voter, token, registry, coordinator, source, shadow;

  async function booleanBox(jurisdiction = J) {
    const Box = await ethers.getContractFactory('BooleanRuleBallotBox');
    const box = await Box.deploy(await token.getAddress(), jurisdiction, deployer.address,
      ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await box.waitForDeployment();
    await (await box.registerRule(ruleKey, ethers.ZeroHash, '0x')).wait();
    return box;
  }

  async function stage(box = shadow, expected = [10000, 1, true]) {
    return coordinator.connect(operator).stage(
      J, ruleKey, await box.getAddress(), 42,
      digest('electorate'), digest('source'), digest('replay'), ...expected
    );
  }

  beforeEach(async function () {
    [deployer, governor = deployer, operator = deployer, outsider = deployer, voter = deployer] = await ethers.getSigners();
    const Token = await ethers.getContractFactory('MockVoteTokenForExecutor');
    token = await Token.deploy();
    await token.waitForDeployment();
    await (await token.mint(voter.address, 1, J)).wait();

    source = await booleanBox();
    shadow = await booleanBox();
    await (await shadow.connect(voter).castVote(ruleKey, 1, [1])).wait();

    const Registry = await ethers.getContractFactory('JurisdictionRuleRegistry');
    registry = await Registry.deploy(deployer.address);
    await registry.waitForDeployment();
    await (await registry.bindRuleBox(J, ruleKey, await source.getAddress())).wait();
    await (await registry.setJurisdictionGovernor(J, governor.address)).wait();

    const Coordinator = await ethers.getContractFactory('RuleShadowReprojectionCoordinator');
    coordinator = await Coordinator.deploy(await registry.getAddress());
    await coordinator.waitForDeployment();
    await (await registry.connect(governor).setReprojectionCoordinator(J, await coordinator.getAddress())).wait();
    await (await coordinator.connect(governor).setOperator(J, operator.address, true)).wait();
  });

  it('stages audit commitments and atomically activates a verified same-structure shadow', async function () {
    await (await stage()).wait();
    const s = await coordinator.stages(1);
    expect(s.sourceBox).to.equal(await source.getAddress());
    expect(s.shadowBox).to.equal(await shadow.getAddress());
    expect(s.sourceCheckpoint).to.equal(42);
    expect(s.electorateDigest).to.equal(digest('electorate'));

    await (await coordinator.connect(outsider).activate(1)).wait();
    expect(await registry.boxFor(J, ruleKey)).to.equal(await shadow.getAddress());
    expect((await coordinator.stages(1)).activated).to.equal(true);
  });

  it('allows fire-and-forget activation after one-time governor authorization', async function () {
    await stage();
    await expect(coordinator.connect(operator).activate(1))
      .to.emit(coordinator, 'ReprojectionActivated');
    await expect(coordinator.connect(outsider).setOperator(J, outsider.address, true))
      .to.be.revertedWith('Reprojection: only jurisdiction governor');
    expect(await registry.boxFor(J, ruleKey)).to.equal(await shadow.getAddress());
  });

  it('fails closed when the replay tally does not match the approved expectation', async function () {
    await stage(shadow, [0, 1, false]);
    await expect(coordinator.connect(governor).activate(1)).to.be.revertedWith('Reprojection: tally mismatch');
    expect(await registry.boxFor(J, ruleKey)).to.equal(await source.getAddress());
    expect((await coordinator.stages(1)).activated).to.equal(false);
  });

  it('fails closed if the current binding changed after staging', async function () {
    await stage();
    const replacement = await booleanBox();
    await registry.connect(governor).bindRuleBox(J, ruleKey, await replacement.getAddress());
    await expect(coordinator.connect(governor).activate(1)).to.be.revertedWith('Reprojection: source changed');
    expect(await registry.boxFor(J, ruleKey)).to.equal(await replacement.getAddress());
  });

  it('rejects cross-jurisdiction and cross-structure shadows', async function () {
    const wrongJ = await booleanBox(K);
    await expect(stage(wrongJ)).to.be.revertedWith('Reprojection: jurisdiction mismatch');

    const Median = await ethers.getContractFactory('MedianRuleBallotBox');
    const median = await Median.deploy(await token.getAddress(), J, deployer.address,
      ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await median.waitForDeployment();
    await median.registerRule(ruleKey, ethers.ZeroHash,
      ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [100]));
    await expect(stage(median)).to.be.revertedWith('Reprojection: structure mismatch');
  });

  it('requires non-empty audit evidence and honors governor cancellation', async function () {
    await expect(coordinator.connect(operator).stage(
      J, ruleKey, await shadow.getAddress(), 42,
      ethers.ZeroHash, digest('source'), digest('replay'), 10000, 1, true
    )).to.be.revertedWith('Reprojection: electorate digest required');

    await stage();
    await coordinator.connect(governor).cancel(1);
    await expect(coordinator.connect(governor).activate(1)).to.be.revertedWith('Reprojection: stage closed');
    expect(await registry.boxFor(J, ruleKey)).to.equal(await source.getAddress());
  });

  it('registry callback cannot be invoked by an operator or outsider', async function () {
    await expect(registry.connect(operator).activateReprojectedRuleBox(
      J, ruleKey, await source.getAddress(), await shadow.getAddress()
    )).to.be.revertedWith('Registry: not reprojection coordinator');
  });
});
