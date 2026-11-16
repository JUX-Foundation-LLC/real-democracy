const { expect } = require('chai');
const { ethers } = require('hardhat');

// §8.4: an Amendment to a FINALIZED object, once it passes, is an Executive Action (JGE) that bumps
// the object's metadataHash → the new legal text in the ballotbox DB. Prove the primitive on a B.2
// rule: a passed JGE action calls box.registerRule(RULE, newHash) and the rule's metadataHash updates.
// (The decision is a separate boolean ballot; the action's effect is the metadata bump.)
describe('Amendment apply-on-pass — Executive Action bumps metadataHash (§8.4)', function () {
  const JUR = 8;
  let deployer, alice, bob, outsider, voteToken, executor, box;
  const T_ALICE = 1, T_BOB = 2;
  const RULE = ethers.id('min_foundation_take'); // the finalized rule being amended
  const H0 = ethers.id('legal-text-v0');
  const H1 = ethers.id('legal-text-v1-amended');

  beforeEach(async function () {
    [deployer, alice, bob, outsider] = await ethers.getSigners();
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    await voteToken.waitForDeployment();
    await voteToken.mint(alice.address, T_ALICE, JUR);
    await voteToken.mint(bob.address, T_BOB, JUR);

    const factory = await (await ethers.getContractFactory('JurisdictionFactory'))
      .deploy(await voteToken.getAddress(), ethers.ZeroAddress, deployer.address, ethers.ZeroAddress);
    await factory.waitForDeployment();
    executor = await (await ethers.getContractFactory('JurisdictionGovernanceExecutor'))
      .deploy(await voteToken.getAddress(), await factory.getAddress(), 0);
    await executor.waitForDeployment();

    // Box governor starts as deployer so we can register the "finalized" rule R; then hand to JGE.
    box = await (await ethers.getContractFactory('BooleanRuleBallotBox'))
      .deploy(await voteToken.getAddress(), JUR, deployer.address, ethers.ZeroAddress, 6000, ethers.ZeroAddress);
    await box.waitForDeployment();
    await box.registerRule(RULE, H0, '0x'); // finalized rule, legal text = H0
    await box.updateGovernor(await executor.getAddress());
    await executor.setRuleBallotBoxOverride(JUR, await box.getAddress());
  });

  it('updates the finalized rule metadataHash when the amendment action passes', async function () {
    expect((await box.ruleMeta(RULE)).metadataHash).to.equal(H0);

    // The amendment is an Executive Action that re-registers RULE with the new text hash H1.
    const callData = box.interface.encodeFunctionData('registerRule', [RULE, H1, '0x']);
    const tx = await executor.connect(alice).propose(JUR, T_ALICE, await box.getAddress(), callData, ethers.ZeroHash);
    const receipt = await tx.wait();
    const proposed = receipt.logs
      .map((l) => { try { return executor.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === 'ActionProposed');
    const { actionId, ruleKey: decisionKey } = proposed.args;

    // Vote the DECISION ballot (distinct from RULE) to quorum.
    await box.connect(alice).castVote(decisionKey, T_ALICE, [1]);
    await box.connect(bob).castVote(decisionKey, T_BOB, [1]);

    await ethers.provider.send('evm_increaseTime', [72 * 3600 + 1]);
    await ethers.provider.send('evm_mine', []);
    await executor.connect(outsider).execute(actionId);

    // The finalized rule's legal text is now H1 — democratically amended via the Executive Action.
    expect((await box.ruleMeta(RULE)).metadataHash).to.equal(H1);
  });

  it('does NOT bump the metadataHash if the amendment fails quorum', async function () {
    const callData = box.interface.encodeFunctionData('registerRule', [RULE, H1, '0x']);
    const tx = await executor.connect(alice).propose(JUR, T_ALICE, await box.getAddress(), callData, ethers.ZeroHash);
    const receipt = await tx.wait();
    const proposed = receipt.logs
      .map((l) => { try { return executor.interface.parseLog(l); } catch { return null; } })
      .find((p) => p && p.name === 'ActionProposed');
    const { actionId, ruleKey: decisionKey } = proposed.args;

    await box.connect(alice).castVote(decisionKey, T_ALICE, [1]); // support
    await box.connect(bob).castVote(decisionKey, T_BOB, [0]);     // oppose → 50% < 60% quorum

    await ethers.provider.send('evm_increaseTime', [72 * 3600 + 1]);
    await ethers.provider.send('evm_mine', []);
    await expect(executor.execute(actionId)).to.be.revertedWith('Executor: support below quorum');
    expect((await box.ruleMeta(RULE)).metadataHash).to.equal(H0); // unchanged
  });
});
