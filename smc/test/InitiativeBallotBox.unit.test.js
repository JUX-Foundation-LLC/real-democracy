const { expect } = require('chai');
const { ethers } = require('hardhat');

// InitiativeBallotBox — ANONYMOUS, WINDOW-FINALIZED on-chain vote on the shared BaseRuleBallotBox.
// Only the SUBJECT (the initiative) is public; voters anonymous. The transparent path exercises the
// SAME tally + window + finalize the anonymous path drives.
describe('InitiativeBallotBox — anonymous window-finalized initiative vote', function () {
  const J = 9;
  const Z = ethers.ZeroAddress;
  const key = ethers.id('initiative:budget-2026');
  const PERMIT_INITIATIVE_VOTING = ethers.id('permit_initiative_voting');
  const PERMIT_RULE_VOTING = ethers.id('permit_rule_voting');
  const N = 5;
  let deployer, voters, voteToken, box;

  const now = async () => (await ethers.provider.getBlock('latest')).timestamp;
  const increase = async (secs) => { await ethers.provider.send('evm_increaseTime', [secs]); await ethers.provider.send('evm_mine', []); };

  beforeEach(async function () {
    const signers = await ethers.getSigners();
    deployer = signers[0];
    voters = signers.slice(1, 1 + N);
    voteToken = await (await ethers.getContractFactory('MockVoteTokenForExecutor')).deploy();
    for (let i = 0; i < N; i++) await voteToken.mint(voters[i].address, i + 1, J);
    box = await (await ethers.getContractFactory('InitiativeBallotBox')).deploy(
      await voteToken.getAddress(), J, deployer.address, Z, 5000, Z
    );
    // #310 HIGH-1: InitiativeBallotBox defaults transparent-voting DISABLED by construction
    // (anonymity-first). These tests drive the SHARED tally/window/finalize logic through the
    // transparent path, so the harness re-opens it; closed-by-default is asserted in its own block.
    await box.setTransparentVotingDisabled(false);
  });

  it('[HIGH-1] transparent tokenId path is CLOSED by construction (anonymity-first default)', async function () {
    const fresh = await (await ethers.getContractFactory('InitiativeBallotBox')).deploy(
      await voteToken.getAddress(), J, deployer.address, Z, 5000, Z
    );
    expect(await fresh.transparentVotingDisabled()).to.equal(true);
    const t = (await ethers.provider.getBlock('latest')).timestamp;
    await fresh.registerInitiative(key, ethers.ZeroHash, t, t + 1000, 5000);
    await expect(fresh.connect(voters[0]).castVote(key, 1, [1]))
      .to.be.revertedWith('RuleBox: transparent voting retired');
  });

  const vote = (i, v = 1) => box.connect(voters[i]).castVote(key, i + 1, [v]);
  // open a window [now, now+span] with the given pass threshold
  const openWindow = async (span = 1000, threshold = 5000) => {
    const t = await now();
    await box.registerInitiative(key, ethers.ZeroHash, t, t + span, threshold);
    return t + span; // votingEnd
  };

  it('structureId is initiative_pass', async function () {
    expect(await box.structureId()).to.equal(ethers.id('initiative_pass'));
  });

  it('registers once; rejects a re-register / bad window / bad threshold', async function () {
    await openWindow();
    await expect(box.registerInitiative(key, ethers.ZeroHash, 1, 100, 5000)).to.be.revertedWith('InitBox: already registered');
    const k2 = ethers.id('initiative:other');
    await expect(box.registerInitiative(k2, ethers.ZeroHash, 100, 100, 5000)).to.be.revertedWith('InitBox: bad window');
    await expect(box.registerInitiative(k2, ethers.ZeroHash, 1, 100, 0)).to.be.revertedWith('InitBox: bad threshold');
  });

  it('tallies votes cast WITHIN the window', async function () {
    await openWindow();
    await vote(0); await vote(1); await vote(2);
    const [bps, total] = await box.currentResult(key);
    expect(total).to.equal(3n);
    expect(bps).to.equal(10000n);
  });

  it('rejects a vote BEFORE the window opens', async function () {
    const t = await now();
    await box.registerInitiative(key, ethers.ZeroHash, t + 500, t + 1500, 5000);
    await expect(vote(0)).to.be.revertedWith('InitBox: outside voting window');
  });

  it('rejects a vote AFTER the window closes', async function () {
    await openWindow(100);
    await increase(200);
    await expect(vote(0)).to.be.revertedWith('InitBox: outside voting window');
  });

  it('finalize requires the window closed; locks PASS when support ≥ threshold', async function () {
    await openWindow(100, 5000);
    await vote(0); await vote(1); await vote(2); // 100% ≥ 50%
    await expect(box.finalize(key)).to.be.revertedWith('InitBox: window still open');
    await increase(200);
    await expect(box.finalize(key)).to.emit(box, 'InitiativeFinalized');
    const ini = await box.initiatives(key);
    expect(ini.finalized).to.equal(true);
    expect(ini.passed).to.equal(true);
  });

  it('finalize locks FAIL when support < threshold', async function () {
    await openWindow(100, 6000);
    await vote(0, 1); await vote(1, 0); await vote(2, 0); // 1/3 = 33% < 60%
    await increase(200);
    await box.finalize(key);
    expect((await box.initiatives(key)).passed).to.equal(false);
  });

  it('seals after finalize — no further votes, no re-finalize', async function () {
    await openWindow(100);
    await vote(0); await increase(200); await box.finalize(key);
    await expect(box.finalize(key)).to.be.revertedWith('InitBox: already finalized');
    // a late voter (token 1) is rejected at the finalized gate
    await expect(box.connect(voters[1]).castVote(key, 2, [1])).to.be.revertedWith('InitBox: finalized');
  });

  it('re-vote within the window adjusts the tally exactly', async function () {
    await openWindow();
    await vote(0, 1); await vote(1, 1); await vote(2, 1); // 3/3
    await vote(0, 0); // flip → 2/3
    const [bps, total] = await box.currentResult(key);
    expect(total).to.equal(3n);
    expect(bps).to.equal(6666n);
  });

  describe('capability gate — PERMIT_INITIATIVE_VOTING, not PERMIT_RULE_VOTING', function () {
    it('a gate allowing PERMIT_INITIATIVE_VOTING permits the vote', async function () {
      const gate = await (await ethers.getContractFactory('MockPermitGate')).deploy(PERMIT_INITIATIVE_VOTING);
      await box.setCapabilityRegistry(await gate.getAddress());
      await openWindow();
      await expect(vote(0)).to.not.be.reverted;
    });
    it('a gate allowing only PERMIT_RULE_VOTING DENIES the initiative vote', async function () {
      const gate = await (await ethers.getContractFactory('MockPermitGate')).deploy(PERMIT_RULE_VOTING);
      await box.setCapabilityRegistry(await gate.getAddress());
      await openWindow();
      await expect(vote(0)).to.be.revertedWith('InitBox: initiative voting not permitted');
    });
  });
});
