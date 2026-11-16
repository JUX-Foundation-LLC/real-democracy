const { expect } = require('chai');
const { ethers } = require('hardhat');

// Proof: on a GLOBAL (unscoped) executor, an action passed in a tiny jurisdiction can act on a big
// one. The fix is structural: one SCOPED executor per jurisdiction, governor of that jurisdiction's
// structures only (second test).
describe('executor cross-jurisdiction reach (PoC)', function () {
  it('UNSCOPED: a one-member jurisdiction passes an action that changes another jurisdiction', async function () {
    const [deployer, loner, attackerOperator, ...members] = await ethers.getSigners();
    const BIG = 8, TINY = 15;
    const voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.mint(loner.address, 1, TINY);
    for (let i = 0; i < 10; i++) await voteToken.mint(members[i].address, 100 + i, BIG);

    const bank = await (await ethers.getContractFactory('JurisdictionPts1155Bank'))
      .deploy(deployer.address, await voteToken.getAddress(), 'ipfs://pts/');
    await bank.configureJurisdiction(BIG, deployer.address, ethers.ZeroAddress);
    const factory = await (await ethers.getContractFactory('JurisdictionFactory'))
      .deploy(await voteToken.getAddress(), ethers.ZeroAddress, deployer.address, ethers.ZeroAddress);
    const executor = await (await ethers.getContractFactory('JurisdictionGovernanceExecutor'))
      .deploy(await voteToken.getAddress(), await factory.getAddress(), 0);
    const tinyBox = await (await ethers.getContractFactory('BooleanRuleBallotBox')).deploy(
      await voteToken.getAddress(), TINY, await executor.getAddress(), ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await executor.setRuleBallotBoxOverride(TINY, await tinyBox.getAddress());
    await bank.setJurisdictionGovernor(BIG, await executor.getAddress());

    // The loner (jurisdiction 15) proposes a change to jurisdiction 8's bank.
    const callData = bank.interface.encodeFunctionData('setJurisdictionOperator', [BIG, attackerOperator.address, true]);
    const tx = await executor.connect(loner).propose(TINY, 1, await bank.getAddress(), callData, ethers.ZeroHash);
    const rcpt = await tx.wait();
    const ev = rcpt.logs.map((l) => { try { return executor.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === 'ActionProposed');
    await tinyBox.connect(loner).castVote(ev.args.ruleKey, 1, [1]);
    await ethers.provider.send('evm_increaseTime', [72 * 3600 + 1]);
    await ethers.provider.send('evm_mine', []);
    await executor.connect(loner).execute(ev.args.actionId);

    expect(await bank.isJurisdictionOperator(BIG, attackerOperator.address)).to.equal(true);
  });

  it('SCOPED: an executor serves one jurisdiction and refuses every other id', async function () {
    const [deployer, loner, member] = await ethers.getSigners();
    const BIG = 8, TINY = 15;
    const voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.mint(loner.address, 1, TINY);
    await voteToken.mint(member.address, 100, BIG);
    const factory = await (await ethers.getContractFactory('JurisdictionFactory'))
      .deploy(await voteToken.getAddress(), ethers.ZeroAddress, deployer.address, ethers.ZeroAddress);
    const bigExecutor = await (await ethers.getContractFactory('JurisdictionGovernanceExecutor'))
      .deploy(await voteToken.getAddress(), await factory.getAddress(), BIG);
    expect(await bigExecutor.scopeJurisdictionId()).to.equal(BigInt(BIG));

    const tinyBox = await (await ethers.getContractFactory('BooleanRuleBallotBox')).deploy(
      await voteToken.getAddress(), TINY, await bigExecutor.getAddress(), ethers.ZeroAddress, 6000, ethers.ZeroAddress);

    // Even the steward cannot wire another jurisdiction into a scoped executor…
    await expect(bigExecutor.setRuleBallotBoxOverride(TINY, await tinyBox.getAddress()))
      .to.be.revertedWith('Executor: jurisdiction out of scope');
    await expect(bigExecutor.setTurnoutPolicy(TINY, 1, 0)).to.be.revertedWith('Executor: jurisdiction out of scope');
    await expect(bigExecutor.setMinTotalVotes(TINY, 1)).to.be.revertedWith('Executor: jurisdiction out of scope');
    // …and a member of another jurisdiction cannot propose on it.
    await expect(bigExecutor.connect(loner).propose(TINY, 1, await tinyBox.getAddress(), '0x', ethers.ZeroHash))
      .to.be.revertedWith('Executor: jurisdiction out of scope');

    // Its own jurisdiction works as before.
    await bigExecutor.setTurnoutPolicy(BIG, 3000, 3600);
    await bigExecutor.setMinTotalVotes(BIG, 1);
  });
});
