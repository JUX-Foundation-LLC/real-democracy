const { expect } = require('chai');
const hre = require('hardhat');

// Regression net for the 2026-07-02 prod anonymity-flip halt (ANON_BOX_RECOVERY_DECISION.md):
// `castVoteAnonymous` with `prevNullifierHash != 0` assumed the prior revision was applied
// IN-BOX. When the chain's earlier casts happened outside the box (verifier-direct gen-2
// cast, or a §5.3 mid-chain rebind to a fresh box), the revision's value entered the
// structure accumulator while voterCount stayed 0 — an invisible phantom entry that
// corrupts the tally the moment any fresh voter arrives. Fix: an unknown prev head is a
// real, not-yet-counted voter → voterCount += 1, nothing to decrement.
//
// Uses MockAnonymousVoteVerifier: real root/nullifier/prev-head policy, no pairing check,
// so revision chains are drivable without generating Groth16 proofs.
describe('BaseRuleBallotBox.castVoteAnonymous — cross-boundary revision recovery (fix + regressions)', () => {
  const Z = hre.ethers.ZeroAddress;
  const abi = hre.ethers.AbiCoder.defaultAbiCoder();
  const A = [0, 0];
  const B = [[0, 0], [0, 0]];
  const C = [0, 0];
  const ROOT = 12345n;
  const EXT = 777n;

  // rotating-nullifier chain for one identity: n(0), n(1), n(2)…
  const n = (id, rev) => BigInt(hre.ethers.solidityPackedKeccak256(['uint256', 'uint256'], [id, rev]));

  let deployer, av;

  const deployBox = async (name) =>
    (await hre.ethers.getContractFactory(name))
      .deploy(deployer.address /* voteToken placeholder */, 1, deployer.address, Z, 5000, Z)
      .then((x) => x.waitForDeployment().then(() => x));

  const wire = async (box, ruleKey, config, ext = EXT) => {
    await box.registerRule(ruleKey, hre.ethers.id('meta'), config);
    await box.setAnonymousVerifier(await av.getAddress());
    await box.setRuleExternalNullifier(ruleKey, ext);
  };

  const castViaBox = (box, ruleKey, ballot, nullifierHash, prevNullifierHash) =>
    box.castVoteAnonymous(ruleKey, A, B, C, ROOT, ballot, nullifierHash, prevNullifierHash);

  const castDirect = (choice, nullifierHash, prevNullifierHash, ext = EXT) =>
    av.castAnonymousVote(A, B, C, ROOT, ext, choice, nullifierHash, prevNullifierHash);

  beforeEach(async () => {
    [deployer] = await hre.ethers.getSigners();
    av = await (await hre.ethers.getContractFactory('MockAnonymousVoteVerifier')).deploy();
    await av.waitForDeployment();
    await av.registerBallotRoot(EXT, ROOT);
  });

  it('fresh cast (prev=0) counts — baseline unchanged', async () => {
    const box = await deployBox('MedianRuleBallotBox');
    const rk = hre.ethers.id('m');
    await wire(box, rk, abi.encode(['uint16'], [200]));
    await castViaBox(box, rk, [50], n(1n, 0), 0);
    const [value, total, quorumMet] = await box.currentResult(rk);
    expect(total).to.equal(1n);
    expect(value).to.equal(50n);
    expect(quorumMet).to.equal(true);
  });

  it('in-box revision keeps count at 1 and moves the value — baseline unchanged', async () => {
    const box = await deployBox('MedianRuleBallotBox');
    const rk = hre.ethers.id('m');
    await wire(box, rk, abi.encode(['uint16'], [200]));
    await castViaBox(box, rk, [50], n(1n, 0), 0);
    await castViaBox(box, rk, [80], n(1n, 1), n(1n, 0));
    const [value, total] = await box.currentResult(rk);
    expect(total).to.equal(1n);
    expect(value).to.equal(80n);
    expect(await box.hist(rk, 50)).to.equal(0n); // prior contribution decremented
    expect(await box.hist(rk, 80)).to.equal(1n);
  });

  it('THE PROD BUG: revision whose rev-0 was spent verifier-direct now COUNTS (median)', async () => {
    const box = await deployBox('MedianRuleBallotBox');
    const rk = hre.ethers.id('m');
    await wire(box, rk, abi.encode(['uint16'], [200]));
    // rev-0 spent OUTSIDE the box (the RULE_BALLOTBOX_FAMILY_ENABLED env-flag fallback)
    await castDirect(168, n(1n, 0), 0);
    // rev-1 arrives at the box as a revision — pre-fix: phantom (hist[168]=1, voterCount=0)
    await castViaBox(box, rk, [168], n(1n, 1), n(1n, 0));
    const [value, total, quorumMet] = await box.currentResult(rk);
    expect(total).to.equal(1n); // pre-fix: 0
    expect(value).to.equal(168n); // pre-fix: (0, 0, false)
    expect(quorumMet).to.equal(true);
    expect(await box.hist(rk, 168)).to.equal(1n); // exactly one entry, now visible
  });

  it('THE PROD BUG: boolean phantom no longer corrupts a later fresh voter (bps stays <= 10000)', async () => {
    const box = await deployBox('BooleanRuleBallotBox');
    const rk = hre.ethers.id('b');
    await wire(box, rk, '0x');
    // identity 1: rev-0 direct, rev-1 support via box (the phantom pattern)
    await castDirect(1, n(1n, 0), 0);
    await castViaBox(box, rk, [1], n(1n, 1), n(1n, 0));
    // identity 2: fresh support via box
    await castViaBox(box, rk, [1], n(2n, 0), 0);
    const [value, total] = await box.currentResult(rk);
    // pre-fix: support=2 / voterCount=1 → 20000 bps (corrupt). Fixed: 2/2 → 10000.
    expect(total).to.equal(2n);
    expect(value).to.equal(10000n);
  });

  it('mid-chain rebind to a FRESH box (§5.3 type-change / recovery rebind) counts the returning voter', async () => {
    const rk = hre.ethers.id('m');
    const cfg = abi.encode(['uint16'], [200]);
    const boxA = await deployBox('MedianRuleBallotBox');
    await wire(boxA, rk, cfg);
    await castViaBox(boxA, rk, [50], n(1n, 0), 0);
    // rule rebound to a fresh box; the voter's next revision lands there with an unknown prev
    const boxB = await deployBox('MedianRuleBallotBox');
    await wire(boxB, rk, cfg);
    await castViaBox(boxB, rk, [90], n(1n, 1), n(1n, 0));
    const [value, total] = await boxB.currentResult(rk);
    expect(total).to.equal(1n);
    expect(value).to.equal(90n);
  });

  it('recovery path: every polluted-epoch identity re-casts ONE revision into a fresh box and tallies exactly (average)', async () => {
    // three identities, all with rev-0 (and one with rev-1) spent outside the fresh box
    await castDirect(10, n(1n, 0), 0);
    await castDirect(20, n(2n, 0), 0);
    await castDirect(30, n(3n, 0), 0);
    await castDirect(40, n(3n, 1), n(3n, 0)); // identity 3 already revised once elsewhere
    const box = await deployBox('AverageRuleBallotBox');
    const rk = hre.ethers.id('a');
    await wire(box, rk, abi.encode(['uint16'], [100]));
    await castViaBox(box, rk, [10], n(1n, 1), n(1n, 0));
    await castViaBox(box, rk, [20], n(2n, 1), n(2n, 0));
    await castViaBox(box, rk, [30], n(3n, 2), n(3n, 1));
    const [value, total] = await box.currentResult(rk);
    expect(total).to.equal(3n);
    expect(value).to.equal(20n); // (10+20+30)/3 — exact
  });

  it('plurality: cross-boundary revision counts and the winner is exact', async () => {
    const box = await deployBox('PluralityRuleBallotBox');
    const rk = hre.ethers.id('p');
    await wire(box, rk, abi.encode(['uint16'], [4]));
    await castDirect(2, n(1n, 0), 0);
    await castViaBox(box, rk, [2], n(1n, 1), n(1n, 0));
    await castViaBox(box, rk, [1], n(2n, 0), 0);
    await castViaBox(box, rk, [2], n(3n, 0), 0);
    const [value, total] = await box.currentResult(rk);
    expect(total).to.equal(3n);
    expect(value).to.equal(2n); // choice 2: 2 votes (1 recovered revision + 1 fresh)
  });

  it('verifier policy still enforced through the box: replayed nullifier and stale prev-head revert', async () => {
    const box = await deployBox('MedianRuleBallotBox');
    const rk = hre.ethers.id('m');
    await wire(box, rk, abi.encode(['uint16'], [200]));
    await castViaBox(box, rk, [50], n(1n, 0), 0);
    await expect(castViaBox(box, rk, [60], n(1n, 0), 0))
      .to.be.revertedWith('AnonymousVoteVerifier: nullifier already spent');
    await castViaBox(box, rk, [60], n(1n, 1), n(1n, 0));
    // prev n(1,0) is no longer the live head
    await expect(castViaBox(box, rk, [70], n(1n, 2), n(1n, 0)))
      .to.be.revertedWith('AnonymousVoteVerifier: prev nullifier is not the live head');
  });

  it('KNOWN LIMIT (documented): a chain SPLIT across box and verifier-direct paths double-counts on return', async () => {
    // This is the operational invariant the backend flag-guard must enforce: all of a
    // rule's casts route through its bound box within an epoch. If violated (rev-0 in-box,
    // rev-1 direct, rev-2 back in-box), the box cannot know rev-0 was superseded: the
    // returning voter is counted again and the stale rev-0 ballot is never decremented.
    const box = await deployBox('MedianRuleBallotBox');
    const rk = hre.ethers.id('m');
    await wire(box, rk, abi.encode(['uint16'], [200]));
    await castViaBox(box, rk, [50], n(1n, 0), 0); // rev-0 in-box (counted)
    await castDirect(60, n(1n, 1), n(1n, 0)); // rev-1 escapes the box
    await castViaBox(box, rk, [70], n(1n, 2), n(1n, 1)); // rev-2 returns: unknown prev
    const [, total] = await box.currentResult(rk);
    expect(total).to.equal(2n); // one identity counted twice — the documented mixing hazard
    expect(await box.hist(rk, 50)).to.equal(1n); // stale rev-0 ballot still in the accumulator
    expect(await box.hist(rk, 70)).to.equal(1n);
  });
});
