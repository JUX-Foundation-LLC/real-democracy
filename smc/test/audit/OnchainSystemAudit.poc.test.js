// ADVERSARIAL AUDIT PoC — independent on-chain system audit (NOT the contract author).
// Reproduces the headline governance-integrity findings against the REAL contracts
// (BooleanRuleBallotBox / PluralityRuleBallotBox / JurisdictionGovernanceExecutor).
//
//   cd vote/smc && npx hardhat test test/audit/OnchainSystemAudit.poc.test.js
//
// See docs/onchain-system-audit/ONCHAIN_SYSTEM_AUDIT.md (S1, S3) for the writeup.

const { expect } = require('chai');
const { ethers } = require('hardhat');

describe('on-chain system audit PoC', function () {
  const JUR = 1;

  async function deployBox(structure, voteToken, governor, quorumBps) {
    const f = await ethers.getContractFactory(structure);
    const box = await f.deploy(
      await voteToken.getAddress(), JUR, governor, ethers.ZeroAddress, quorumBps, ethers.ZeroAddress,
    );
    await box.waitForDeployment();
    return box;
  }

  // -----------------------------------------------------------------------------------
  // S3 — the box "quorum" is a SUPPORT supermajority among PARTICIPANTS, with no turnout
  // floor: a single vote passes regardless of how many tokens are eligible.
  // -----------------------------------------------------------------------------------
  it('S3: Boolean rule reports quorumMet on a SINGLE support vote (no turnout floor)', async function () {
    const [deployer, alice] = await ethers.getSigners();
    const voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    // Five eligible holders exist...
    for (let id = 1; id <= 5; id++) await voteToken.mint((id === 1 ? alice : deployer).address, id, JUR);

    const box = await deployBox('BooleanRuleBallotBox', voteToken, deployer.address, 6000);
    const RULE = ethers.id('rule:should_pass');
    await box.registerRule(RULE, ethers.ZeroHash, '0x');

    // ...but only ONE of them votes.
    await box.connect(alice).castVote(RULE, 1, [1]);

    const [value, totalVotes, quorumMet] = await box.currentResult(RULE);
    expect(totalVotes).to.equal(1n);          // 1 of 5 eligible
    expect(value).to.equal(10000n);           // 100% support among participants
    expect(quorumMet).to.equal(true);         // "quorum" met — no minimum turnout
  });

  it('S3: Plurality reports quorumMet=true on a single vote unconditionally', async function () {
    const [deployer, alice] = await ethers.getSigners();
    const voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(alice.address, 1, JUR);

    const box = await deployBox('PluralityRuleBallotBox', voteToken, deployer.address, 6000);
    const RULE = ethers.id('rule:pick_one');
    await box.registerRule(RULE, ethers.ZeroHash, ethers.AbiCoder.defaultAbiCoder().encode(['uint16'], [3]));
    await box.connect(alice).castVote(RULE, 1, [2]);

    const [value, totalVotes, quorumMet] = await box.currentResult(RULE);
    expect(totalVotes).to.equal(1n);
    expect(value).to.equal(2n);               // winning choice
    expect(quorumMet).to.equal(true);         // always true once any vote exists
  });

  // -----------------------------------------------------------------------------------
  // S1 — a SINGLE VoteToken holder captures governance: propose → self-vote → execute an
  // arbitrary governor-privileged call, because minTotalVotes defaults to 1 and "quorum"
  // is support-among-participants. Here the captured action hands the box's governor to the
  // attacker (full control of setQuorumThreshold / setAnonymousVerifier / registerRule …).
  // -----------------------------------------------------------------------------------
  it('S1 (fixed): one voter can no longer execute a governor takeover with a single self-vote', async function () {
    const [deployer, attacker, ...others] = await ethers.getSigners();
    const voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(attacker.address, 1, JUR);
    // A real electorate of additional holders exists (and never votes).
    for (let i = 0; i < 4; i++) await voteToken.mint(others[i].address, 2 + i, JUR);

    // factory arg is unused once an override is set; pass a non-zero placeholder.
    const factory = await (await ethers.getContractFactory('JurisdictionFactory'))
      .deploy(await voteToken.getAddress(), ethers.ZeroAddress, deployer.address, ethers.ZeroAddress);
    await factory.waitForDeployment();
    const executor = await (await ethers.getContractFactory('JurisdictionGovernanceExecutor'))
      .deploy(await voteToken.getAddress(), await factory.getAddress(), 0);
    await executor.waitForDeployment();

    const box = await deployBox('BooleanRuleBallotBox', voteToken, deployer.address, 6000);
    await box.updateGovernor(await executor.getAddress());          // executor is the box governor
    await executor.setRuleBallotBoxOverride(JUR, await box.getAddress());

    // Attacker proposes: target = the box itself, call = updateGovernor(attacker).
    const evilCall = box.interface.encodeFunctionData('updateGovernor', [attacker.address]);
    const tx = await executor.connect(attacker).propose(JUR, 1, await box.getAddress(), evilCall, ethers.ZeroHash);
    const rcpt = await tx.wait();
    const parsed = rcpt.logs.map((l) => { try { return executor.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === 'ActionProposed');
    const actionId = parsed.args.actionId;
    const decisionKey = parsed.args.ruleKey;

    // ONE self-vote on the decision ballot — 1 of 5 eligible holders.
    await box.connect(attacker).castVote(decisionKey, 1, [1]);

    // FIXED (turnout gate + waiting time): the capture no longer works. Immediately, the waiting
    // time blocks it; after the wait, 1 of 5 is below the default 30% turnout (2 votes required).
    await expect(executor.connect(attacker).execute(actionId)).to.be.revertedWith('Executor: waiting time not over');
    await ethers.provider.send('evm_increaseTime', [72 * 3600 + 1]);
    await ethers.provider.send('evm_mine', []);
    await expect(executor.connect(attacker).execute(actionId)).to.be.revertedWith('Executor: participation below floor');

    expect(await box.governor()).to.equal(await executor.getAddress()); // governance NOT captured
  });

  it('S1 (mitigation): a real participation floor blocks the single-voter capture', async function () {
    const [deployer, attacker, ...others] = await ethers.getSigners();
    const voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(attacker.address, 1, JUR);
    for (let i = 0; i < 4; i++) await voteToken.mint(others[i].address, 2 + i, JUR);

    const factory = await (await ethers.getContractFactory('JurisdictionFactory'))
      .deploy(await voteToken.getAddress(), ethers.ZeroAddress, deployer.address, ethers.ZeroAddress);
    await factory.waitForDeployment();
    const executor = await (await ethers.getContractFactory('JurisdictionGovernanceExecutor'))
      .deploy(await voteToken.getAddress(), await factory.getAddress(), 0);
    await executor.waitForDeployment();
    const box = await deployBox('BooleanRuleBallotBox', voteToken, deployer.address, 6000);
    await box.updateGovernor(await executor.getAddress());
    await executor.setRuleBallotBoxOverride(JUR, await box.getAddress());
    await executor.setMinTotalVotes(JUR, 3); // steward sets an absolute floor of 3

    const evilCall = box.interface.encodeFunctionData('updateGovernor', [attacker.address]);
    const tx = await executor.connect(attacker).propose(JUR, 1, await box.getAddress(), evilCall, ethers.ZeroHash);
    const rcpt = await tx.wait();
    const parsed = rcpt.logs.map((l) => { try { return executor.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === 'ActionProposed');
    const actionId = parsed.args.actionId;
    const decisionKey = parsed.args.ruleKey;

    await box.connect(attacker).castVote(decisionKey, 1, [1]);
    await ethers.provider.send('evm_increaseTime', [72 * 3600 + 1]);
    await ethers.provider.send('evm_mine', []);
    await expect(executor.connect(attacker).execute(actionId)).to.be.revertedWith('Executor: participation below floor');
    // NB: the floor is an ABSOLUTE count, not a fraction of the electorate — 3 colluding
    // tokens still pass it regardless of a 1000-holder jurisdiction (see report S1).
  });
});
