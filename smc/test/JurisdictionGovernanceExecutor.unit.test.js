const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('JurisdictionGovernanceExecutor', function () {
  const JURISDICTION_ID = 8;
  let deployer, alice, bob, carol, outsider;
  let voteToken, bank, executor, ruleBox;

  const TOKEN_ALICE = 1;
  const TOKEN_BOB = 2;
  const TOKEN_CAROL = 3;

  beforeEach(async function () {
    [deployer, alice, bob, carol, outsider] = await ethers.getSigners();

    const MockVoteToken = await ethers.getContractFactory('MockVoteTokenForExecutor');
    voteToken = await MockVoteToken.deploy();
    await voteToken.waitForDeployment();

    await voteToken.mint(alice.address, TOKEN_ALICE, JURISDICTION_ID);
    await voteToken.mint(bob.address, TOKEN_BOB, JURISDICTION_ID);
    await voteToken.mint(carol.address, TOKEN_CAROL, JURISDICTION_ID);

    const Bank = await ethers.getContractFactory('JurisdictionPts1155Bank');
    bank = await Bank.deploy(deployer.address, await voteToken.getAddress(), 'ipfs://pts/');
    await bank.waitForDeployment();
    await bank.configureJurisdiction(JURISDICTION_ID, deployer.address, ethers.ZeroAddress);

    // Factory is only consulted as a registry; for the unit test we use the
    // override path, so any factory-shaped address works. Deploy a real one.
    const Factory = await ethers.getContractFactory('JurisdictionFactory');
    const factory = await Factory.deploy(
      await voteToken.getAddress(),
      ethers.ZeroAddress,
      deployer.address,
      ethers.ZeroAddress
    );
    await factory.waitForDeployment();

    const Executor = await ethers.getContractFactory('JurisdictionGovernanceExecutor');
    executor = await Executor.deploy(await voteToken.getAddress(), await factory.getAddress(), 0);
    await executor.waitForDeployment();

    // §8.3: JGE reads the B.2 box's `currentResult` — use a BooleanRuleBallotBox (the action's
    // decision is a boolean "should we execute?"). Votes here feed `currentResult` exactly as
    // anonymous votes (castVoteAnonymous) would; JGE no longer touches the transparent
    // submitRuleVote/ruleSupportBps path.
    const RuleBallotBox = await ethers.getContractFactory('BooleanRuleBallotBox');
    ruleBox = await RuleBallotBox.deploy(
      await voteToken.getAddress(),
      JURISDICTION_ID,
      await executor.getAddress(), // executor is governor
      ethers.ZeroAddress,
      6000,
      ethers.ZeroAddress // trustedForwarder
    );
    await ruleBox.waitForDeployment();

    await executor.setRuleBallotBoxOverride(JURISDICTION_ID, await ruleBox.getAddress());

    // Executor governs the bank for this jurisdiction.
    await bank.setJurisdictionGovernor(JURISDICTION_ID, await executor.getAddress());
  });

  const proposeOperatorGrant = async (proposerSigner, proposerTokenId, operator) => {
    const callData = bank.interface.encodeFunctionData('setJurisdictionOperator', [
      JURISDICTION_ID,
      operator,
      true
    ]);
    const tx = await executor
      .connect(proposerSigner)
      .propose(JURISDICTION_ID, proposerTokenId, await bank.getAddress(), callData, ethers.ZeroHash);
    const receipt = await tx.wait();
    const proposed = receipt.logs
      .map((log) => { try { return executor.interface.parseLog(log); } catch { return null; } })
      .find((parsed) => parsed && parsed.name === 'ActionProposed');
    return { actionId: proposed.args.actionId, ruleKey: proposed.args.ruleKey };
  };

  // Default waiting time is 72h; tests that expect to reach the vote gates wait it out first.
  const waitOutDelay = async (seconds = 72 * 3600 + 1) => {
    await ethers.provider.send('evm_increaseTime', [seconds]);
    await ethers.provider.send('evm_mine', []);
  };

  it('rejects proposals from non token holders', async function () {
    const callData = bank.interface.encodeFunctionData('setJurisdictionOperator', [JURISDICTION_ID, outsider.address, true]);
    await expect(
      executor.connect(outsider).propose(JURISDICTION_ID, TOKEN_ALICE, await bank.getAddress(), callData, ethers.ZeroHash)
    ).to.be.revertedWith('Executor: not token owner');
  });

  it('rejects proposals with inactive tokens', async function () {
    await voteToken.setInactive(TOKEN_ALICE, true);
    const callData = bank.interface.encodeFunctionData('setJurisdictionOperator', [JURISDICTION_ID, bob.address, true]);
    await expect(
      executor.connect(alice).propose(JURISDICTION_ID, TOKEN_ALICE, await bank.getAddress(), callData, ethers.ZeroHash)
    ).to.be.revertedWith('Executor: vote token inactive');
  });

  it('executes a passed action on the bank after quorum support', async function () {
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);

    expect(await bank.isJurisdictionOperator(JURISDICTION_ID, carol.address)).to.equal(false);

    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]); // support
    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [1]); // support

    await waitOutDelay();
    // Permissionless execution: an outsider may trigger the passed action.
    await executor.connect(outsider).execute(actionId);

    expect(await bank.isJurisdictionOperator(JURISDICTION_ID, carol.address)).to.equal(true);

    const action = await executor.getAction(actionId);
    expect(action.executed).to.equal(true);
  });

  it('refuses execution below quorum support', async function () {
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);

    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]); // support
    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [0]); // oppose
    // 50% support < 60% quorum
    await waitOutDelay();

    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: support below quorum');
  });

  it('refuses execution below the participation floor', async function () {
    await executor.setMinTotalVotes(JURISDICTION_ID, 2);
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);

    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await waitOutDelay();

    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: participation below floor');
  });

  it('refuses double execution and cancelled actions', async function () {
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [1]);
    await waitOutDelay();
    await executor.execute(actionId);
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: already executed');

    const second = await proposeOperatorGrant(bob, TOKEN_BOB, outsider.address);
    await executor.connect(bob).cancel(second.actionId);
    await expect(executor.execute(second.actionId)).to.be.revertedWith('Executor: cancelled');
  });

  it('bubbles inner revert reasons from failed action calls', async function () {
    // Action targets the bank with an invalid call (zero operator address).
    const callData = bank.interface.encodeFunctionData('setJurisdictionOperator', [
      JURISDICTION_ID,
      ethers.ZeroAddress,
      true
    ]);
    const tx = await executor
      .connect(alice)
      .propose(JURISDICTION_ID, TOKEN_ALICE, await bank.getAddress(), callData, ethers.ZeroHash);
    const receipt = await tx.wait();
    const proposed = receipt.logs
      .map((log) => { try { return executor.interface.parseLog(log); } catch { return null; } })
      .find((parsed) => parsed && parsed.name === 'ActionProposed');

    await ruleBox.connect(alice).castVote(proposed.args.ruleKey, TOKEN_ALICE, [1]);
    await ruleBox.connect(bob).castVote(proposed.args.ruleKey, TOKEN_BOB, [1]);
    await waitOutDelay();
    await expect(executor.execute(proposed.args.actionId)).to.be.revertedWith(
      'JurisdictionPts1155Bank: invalid operator'
    );
  });

  it('locks configuration behind the vote after steward renounce', async function () {
    await executor.renounceBootstrapSteward();
    await expect(
      executor.setMinTotalVotes(JURISDICTION_ID, 3)
    ).to.be.revertedWith('Executor: steward or vote required');

    // …but the democratic path still works: a passed action targeting the
    // executor itself can change configuration.
    const callData = executor.interface.encodeFunctionData('setMinTotalVotes', [JURISDICTION_ID, 3]);
    const tx = await executor
      .connect(alice)
      .propose(JURISDICTION_ID, TOKEN_ALICE, await executor.getAddress(), callData, ethers.ZeroHash);
    const receipt = await tx.wait();
    const proposed = receipt.logs
      .map((log) => { try { return executor.interface.parseLog(log); } catch { return null; } })
      .find((parsed) => parsed && parsed.name === 'ActionProposed');

    await ruleBox.connect(alice).castVote(proposed.args.ruleKey, TOKEN_ALICE, [1]);
    await ruleBox.connect(bob).castVote(proposed.args.ruleKey, TOKEN_BOB, [1]);
    await waitOutDelay();
    await executor.execute(proposed.args.actionId);

    expect(await executor.minTotalVotes(JURISDICTION_ID)).to.equal(3n);
  });

  // ------------------------------------------------------------------
  // Turnout gate + waiting time (audit S1/S2/S12, GOVERNANCE G1 parts 2-3)
  // ------------------------------------------------------------------

  const mintElectorate = async (count, firstTokenId = 100) => {
    const signers = await ethers.getSigners();
    for (let i = 0; i < count; i++) {
      await voteToken.mint(signers[5 + (i % (signers.length - 5))].address, firstTokenId + i, JURISDICTION_ID);
    }
  };

  it('defaults to 30% turnout and a 72 hour wait when nothing is configured', async function () {
    const [bps, delay] = await executor.turnoutPolicyFor(JURISDICTION_ID);
    expect(bps).to.equal(3000n);
    expect(delay).to.equal(72n * 3600n);
    expect(await executor.requiredVotes(JURISDICTION_ID)).to.equal(2n); // 30% of 3 is 1, raised to 2
  });

  it('never lets one member of a small electorate act alone', async function () {
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, alice.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await waitOutDelay();
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: participation below floor');
    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [1]);
    await executor.execute(actionId);
  });

  it('fixes the waiting time when an action is proposed; later policy changes do not touch it', async function () {
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [1]);

    // Shortening the delay does not rush the pending action…
    await executor.setTurnoutPolicy(JURISDICTION_ID, 3000, 0);
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: waiting time not over');
    // …and lengthening it does not push the action back.
    await executor.setTurnoutPolicy(JURISDICTION_ID, 3000, 30 * 24 * 3600);
    await waitOutDelay();
    await executor.execute(actionId);
  });

  it('caps the requirement at the electorate so no setting can lock governance', async function () {
    await executor.setMinTotalVotes(JURISDICTION_ID, ethers.MaxUint256);
    expect(await executor.requiredVotes(JURISDICTION_ID)).to.equal(3n);

    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [1]);
    await ruleBox.connect(carol).castVote(ruleKey, TOKEN_CAROL, [1]);
    await waitOutDelay();
    await executor.execute(actionId);
  });

  it('accepts only a Boolean decision box for this jurisdiction that the executor governs', async function () {
    const deployBox = async (name, jurisdictionId, governor) => {
      const box = await (await ethers.getContractFactory(name)).deploy(
        await voteToken.getAddress(), jurisdictionId, governor, ethers.ZeroAddress, 6000, ethers.ZeroAddress);
      await box.waitForDeployment();
      return box.getAddress();
    };
    const self = await executor.getAddress();
    await expect(executor.setRuleBallotBoxOverride(JURISDICTION_ID, await deployBox('BooleanRuleBallotBox', 9, self)))
      .to.be.revertedWith('Executor: decision box jurisdiction mismatch');
    await expect(executor.setRuleBallotBoxOverride(JURISDICTION_ID, await deployBox('BooleanRuleBallotBox', JURISDICTION_ID, outsider.address)))
      .to.be.revertedWith('Executor: decision box not governed');
    await expect(executor.setRuleBallotBoxOverride(JURISDICTION_ID, await deployBox('PluralityRuleBallotBox', JURISDICTION_ID, self)))
      .to.be.revertedWith('Executor: decision box must be boolean');
    await executor.setRuleBallotBoxOverride(JURISDICTION_ID, await deployBox('BooleanRuleBallotBox', JURISDICTION_ID, self));
  });

  it('refuses execution before the waiting time is over, even with unanimous support', async function () {
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [1]);
    await ruleBox.connect(carol).castVote(ruleKey, TOKEN_CAROL, [1]);

    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: waiting time not over');
    await waitOutDelay(72 * 3600 - 60);
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: waiting time not over');
    await waitOutDelay(120);
    await executor.execute(actionId);
  });

  it('blocks a lone self-voter in a larger electorate (the capture case)', async function () {
    await mintElectorate(7); // 10 active tokens -> 3 votes required
    expect(await executor.requiredVotes(JURISDICTION_ID)).to.equal(3n);

    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, alice.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await waitOutDelay();
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: participation below floor');

    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [1]);
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: participation below floor');

    await ruleBox.connect(carol).castVote(ruleKey, TOKEN_CAROL, [1]);
    await executor.execute(actionId); // exactly 3 of 10
  });

  it('rounds the turnout requirement up', async function () {
    await mintElectorate(8); // 11 active tokens -> 3.3 -> 4 votes required
    expect(await executor.requiredVotes(JURISDICTION_ID)).to.equal(4n);
  });

  it('lets the rest of the electorate defeat an action during the waiting time', async function () {
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, alice.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await ruleBox.connect(bob).castVote(ruleKey, TOKEN_BOB, [0]);
    await ruleBox.connect(carol).castVote(ruleKey, TOKEN_CAROL, [0]);
    await waitOutDelay();
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: support below quorum');
  });

  it('passes with an electorate of one (the Foundational practice case)', async function () {
    await voteToken.setInactive(TOKEN_BOB, true);
    await voteToken.setInactive(TOKEN_CAROL, true);
    expect(await executor.requiredVotes(JURISDICTION_ID)).to.equal(1n);

    await executor.setTurnoutPolicy(JURISDICTION_ID, 3000, 3600); // steward shortens the wait to 1h
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);

    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: waiting time not over');
    await waitOutDelay(3601);
    await executor.execute(actionId);
    expect(await bank.isJurisdictionOperator(JURISDICTION_ID, carol.address)).to.equal(true);
  });

  it('keeps the absolute floor on top of the turnout share', async function () {
    await executor.setMinTotalVotes(JURISDICTION_ID, 3);
    expect(await executor.requiredVotes(JURISDICTION_ID)).to.equal(3n);
  });

  it('expires an action 30 days after its waiting time ends', async function () {
    const { actionId, ruleKey } = await proposeOperatorGrant(alice, TOKEN_ALICE, carol.address);
    await ruleBox.connect(alice).castVote(ruleKey, TOKEN_ALICE, [1]);
    await waitOutDelay(72 * 3600 + 30 * 24 * 3600 + 60);
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: action expired');
  });

  it('validates turnout policy values and who may set them', async function () {
    await expect(executor.setTurnoutPolicy(JURISDICTION_ID, 0, 3600))
      .to.be.revertedWith('Executor: participation bps out of range');
    await expect(executor.setTurnoutPolicy(JURISDICTION_ID, 7501, 3600))
      .to.be.revertedWith('Executor: participation bps out of range');
    await expect(executor.setTurnoutPolicy(JURISDICTION_ID, 3000, 31 * 24 * 3600))
      .to.be.revertedWith('Executor: delay too long');
    await expect(executor.connect(alice).setTurnoutPolicy(JURISDICTION_ID, 1, 0))
      .to.be.revertedWith('Executor: steward or vote required');

    await expect(executor.setTurnoutPolicy(JURISDICTION_ID, 5000, 7200))
      .to.emit(executor, 'TurnoutPolicyUpdated').withArgs(JURISDICTION_ID, 5000, 7200);
    const [bps, delay] = await executor.turnoutPolicyFor(JURISDICTION_ID);
    expect(bps).to.equal(5000n);
    expect(delay).to.equal(7200n);
  });

  it('after steward renounce, the turnout policy changes only by a vote that waits out the delay', async function () {
    await executor.renounceBootstrapSteward();
    await expect(executor.setTurnoutPolicy(JURISDICTION_ID, 1, 0))
      .to.be.revertedWith('Executor: steward or vote required');

    const callData = executor.interface.encodeFunctionData('setTurnoutPolicy', [JURISDICTION_ID, 5000, 3600]);
    const tx = await executor
      .connect(alice)
      .propose(JURISDICTION_ID, TOKEN_ALICE, await executor.getAddress(), callData, ethers.ZeroHash);
    const receipt = await tx.wait();
    const proposed = receipt.logs
      .map((log) => { try { return executor.interface.parseLog(log); } catch { return null; } })
      .find((parsed) => parsed && parsed.name === 'ActionProposed');

    await ruleBox.connect(alice).castVote(proposed.args.ruleKey, TOKEN_ALICE, [1]);
    await ruleBox.connect(bob).castVote(proposed.args.ruleKey, TOKEN_BOB, [1]);
    await expect(executor.execute(proposed.args.actionId)).to.be.revertedWith('Executor: waiting time not over');
    await waitOutDelay();
    await executor.execute(proposed.args.actionId);

    const [bps, delay] = await executor.turnoutPolicyFor(JURISDICTION_ID);
    expect(bps).to.equal(5000n);
    expect(delay).to.equal(3600n);
  });
});
