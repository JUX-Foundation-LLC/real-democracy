const { expect } = require('chai');
const { ethers } = require('hardhat');

// HandoverKind enum mirror (matches SuccessorRegistry.sol)
const KIND = {
  Unspecified: 0,
  VoluntaryHandover: 1,
  KeyRecovery: 2
};

describe('SuccessorRegistry', function () {
  const JURISDICTION_ID = 8;
  const OLD_TOKEN = 1;
  const NEW_TOKEN = 2;
  const NEWER_TOKEN = 3;

  let deployer, recorder, outsider;
  let registry;

  beforeEach(async function () {
    [deployer, recorder, outsider] = await ethers.getSigners();

    const Registry = await ethers.getContractFactory('SuccessorRegistry');
    registry = await Registry.deploy(deployer.address);
    await registry.waitForDeployment();

    const RECORDER_ROLE = await registry.RECORDER_ROLE();
    await registry.grantRole(RECORDER_ROLE, recorder.address);
  });

  it('records a handover and exposes the link in both directions', async function () {
    await expect(
      registry
        .connect(recorder)
        .recordHandover(OLD_TOKEN, NEW_TOKEN, JURISDICTION_ID, KIND.KeyRecovery, 'lost key')
    )
      .to.emit(registry, 'HandoverRecorded')
      .withArgs(
        OLD_TOKEN,
        NEW_TOKEN,
        JURISDICTION_ID,
        KIND.KeyRecovery,
        recorder.address,
        'lost key'
      );

    expect(await registry.successorOf(OLD_TOKEN)).to.equal(NEW_TOKEN);
    expect(await registry.predecessorOf(NEW_TOKEN)).to.equal(OLD_TOKEN);

    const record = await registry.recordOf(OLD_TOKEN);
    expect(record.successorTokenId).to.equal(NEW_TOKEN);
    expect(record.jurisdictionId).to.equal(JURISDICTION_ID);
    expect(record.kind).to.equal(KIND.KeyRecovery);
    expect(record.recordedBy).to.equal(recorder.address);
    expect(record.reason).to.equal('lost key');
    expect(record.recordedAt).to.be.gt(0);
  });

  it('rejects writes from accounts without RECORDER_ROLE', async function () {
    await expect(
      registry
        .connect(outsider)
        .recordHandover(OLD_TOKEN, NEW_TOKEN, JURISDICTION_ID, KIND.VoluntaryHandover, 'nope')
    ).to.be.reverted;
  });

  it('is write-once: a recorded successor cannot be overwritten', async function () {
    await registry
      .connect(recorder)
      .recordHandover(OLD_TOKEN, NEW_TOKEN, JURISDICTION_ID, KIND.VoluntaryHandover, 'migrate');

    await expect(
      registry
        .connect(recorder)
        .recordHandover(OLD_TOKEN, NEWER_TOKEN, JURISDICTION_ID, KIND.KeyRecovery, 'rewrite attempt')
    )
      .to.be.revertedWithCustomError(registry, 'SuccessorAlreadyRecorded')
      .withArgs(OLD_TOKEN, NEW_TOKEN);
  });

  it('rejects zero ids and self-succession', async function () {
    await expect(
      registry.connect(recorder).recordHandover(0, NEW_TOKEN, JURISDICTION_ID, KIND.VoluntaryHandover, '')
    ).to.be.revertedWithCustomError(registry, 'InvalidTokenId');

    await expect(
      registry.connect(recorder).recordHandover(OLD_TOKEN, 0, JURISDICTION_ID, KIND.VoluntaryHandover, '')
    ).to.be.revertedWithCustomError(registry, 'InvalidTokenId');

    await expect(
      registry.connect(recorder).recordHandover(OLD_TOKEN, OLD_TOKEN, JURISDICTION_ID, KIND.VoluntaryHandover, '')
    ).to.be.revertedWithCustomError(registry, 'SelfSuccession');
  });

  it('walks a multi-hop succession chain to the active terminal', async function () {
    // 1 -> 2 -> 3 (two successive recoveries)
    await registry
      .connect(recorder)
      .recordHandover(OLD_TOKEN, NEW_TOKEN, JURISDICTION_ID, KIND.KeyRecovery, 'first recovery');
    await registry
      .connect(recorder)
      .recordHandover(NEW_TOKEN, NEWER_TOKEN, JURISDICTION_ID, KIND.KeyRecovery, 'second recovery');

    const [terminal, reached] = await registry.latestSuccessor(OLD_TOKEN, 10);
    expect(terminal).to.equal(NEWER_TOKEN);
    expect(reached).to.equal(true);

    // A token with no successor is its own terminal.
    const [selfTerminal, selfReached] = await registry.latestSuccessor(NEWER_TOKEN, 10);
    expect(selfTerminal).to.equal(NEWER_TOKEN);
    expect(selfReached).to.equal(true);
  });

  it('reports terminalReached=false when maxHops is exhausted', async function () {
    await registry
      .connect(recorder)
      .recordHandover(OLD_TOKEN, NEW_TOKEN, JURISDICTION_ID, KIND.KeyRecovery, 'first');
    await registry
      .connect(recorder)
      .recordHandover(NEW_TOKEN, NEWER_TOKEN, JURISDICTION_ID, KIND.KeyRecovery, 'second');

    // Only allow 1 hop across a 2-hop chain.
    const [current, reached] = await registry.latestSuccessor(OLD_TOKEN, 1);
    expect(current).to.equal(NEW_TOKEN);
    expect(reached).to.equal(false);
  });
});
