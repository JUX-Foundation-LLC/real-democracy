const { expect } = require('chai');
const hre = require('hardhat');

// INDEPENDENT AUDIT of the #414 fix (BaseRuleBallotBox.castVoteAnonymous unknown-prev-head =>
// count-as-fresh). Audit-independence doctrine: break it, don't trust the author's 9 tests.
//
// These tests probe the boundary of the fix's soundness:
//   - honest single-box path never over-counts (positive control for voterCount integrity)
//   - the double-count generalizes from box<->verifier-direct to box<->box<->box rebind churn
//   - the "double count" is really a STALE-BALLOT retention that can FALSELY MEET boolean quorum
//     (retracted YES persists) — the operational severity is a wrong governance outcome, not cosmetics
//   - Fork A recast is exact for a PURELY verifier-direct chain (no prior in-box record at all)
//   - per-rule / per-ext isolation holds under the fix
//   - the box has NO identity-level dedup: voterCount integrity is 100% delegated to the
//     circuit's rev-0 determinism + the verifier's spent-set. The MOCK does not enforce that,
//     so this pins the trust boundary the real verifier must uphold.
//
// All tests are GREEN when the fix behaves as documented. A red test = a finding.
describe('Audit414 — adversarial: BaseRuleBallotBox.castVoteAnonymous unknown-prev-head fix', () => {
  const Z = hre.ethers.ZeroAddress;
  const abi = hre.ethers.AbiCoder.defaultAbiCoder();
  const A = [0, 0];
  const B = [[0, 0], [0, 0]];
  const C = [0, 0];
  const ROOT = 12345n;
  const EXT = 777n;
  const EXT2 = 888n;

  // rotating-nullifier chain for one identity within one ext: n(ext, id, rev)
  const n = (ext, id, rev) =>
    BigInt(hre.ethers.solidityPackedKeccak256(['uint256', 'uint256', 'uint256'], [ext, id, rev]));

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
    await av.registerBallotRoot(EXT2, ROOT);
  });

  // ------------------------------------------------------------------ positive controls
  it('F-CONTROL: honest single-box, N distinct identities + revisions => voterCount == N exactly (no inflation)', async () => {
    const box = await deployBox('MedianRuleBallotBox');
    const rk = hre.ethers.id('m');
    await wire(box, rk, abi.encode(['uint16'], [200]));
    // 4 identities, each casts fresh then revises twice, all in-box
    for (let id = 1; id <= 4; id++) {
      await castViaBox(box, rk, [10 * id], n(EXT, BigInt(id), 0), 0);
      await castViaBox(box, rk, [10 * id + 1], n(EXT, BigInt(id), 1), n(EXT, BigInt(id), 0));
      await castViaBox(box, rk, [10 * id + 2], n(EXT, BigInt(id), 2), n(EXT, BigInt(id), 1));
    }
    const [, total] = await box.currentResult(rk);
    expect(total).to.equal(4n); // fix must NOT count revisions as fresh voters in the honest path
  });

  it('F-CONTROL: per-rule / per-ext isolation — one identity voting two rules counts once on each', async () => {
    const box = await deployBox('MedianRuleBallotBox');
    const rkA = hre.ethers.id('rA');
    const rkB = hre.ethers.id('rB');
    await wire(box, rkA, abi.encode(['uint16'], [200]), EXT);
    await wire(box, rkB, abi.encode(['uint16'], [200]), EXT2);
    // same identity index, different ext => different nullifier space
    await castViaBox(box, rkA, [50], n(EXT, 1n, 0), 0);
    await castViaBox(box, rkB, [60], n(EXT2, 1n, 0), 0);
    expect((await box.currentResult(rkA))[1]).to.equal(1n);
    expect((await box.currentResult(rkB))[1]).to.equal(1n);
  });

  // ------------------------------------------------------------------ the fix's new risk surface
  it('F1: double-count generalizes to box->box->box rebind churn (X->Y->X), NOT just box<->verifier-direct', async () => {
    // The author's KNOWN LIMIT test only weaves box<->verifier-direct. A rule rebound
    // X -> Y (fresh) -> back to X exhibits the SAME inflation: X still holds the stale rev-0
    // _lastBallot AND its voterCount from before, and the returning revision lands as "fresh".
    const rk = hre.ethers.id('m');
    const cfg = abi.encode(['uint16'], [200]);
    const boxX = await deployBox('MedianRuleBallotBox');
    const boxY = await deployBox('MedianRuleBallotBox');
    await wire(boxX, rk, cfg);
    await wire(boxY, rk, cfg);

    await castViaBox(boxX, rk, [50], n(EXT, 1n, 0), 0); // rev0 in X: voterCount_X=1, _lastBallot_X[n0]=50
    await castViaBox(boxY, rk, [60], n(EXT, 1n, 1), n(EXT, 1n, 0)); // rev1 in Y (rebind away)
    await castViaBox(boxX, rk, [70], n(EXT, 1n, 2), n(EXT, 1n, 1)); // rev2 back in X: unknown prev

    const [, totalX] = await boxX.currentResult(rk);
    expect(totalX).to.equal(2n); // ONE identity counted twice in X — same hazard, new trigger
    expect(await boxX.hist(rk, 50)).to.equal(1n); // stale rev0 never decremented in X
    expect(await boxX.hist(rk, 70)).to.equal(1n);
    // NOTE FOR RECOVERY: Fork A deploys FRESH boxes and rebinds ONCE (never back to an old box),
    // so this X->Y->X pattern does NOT occur in the ratified sequence. Latent hazard, mitigated
    // by recovery discipline + the backend family-flag routing guard.
  });

  it('F2: the KNOWN LIMIT is quorum-critical — a RETRACTED boolean YES survives and FALSELY meets quorum', async () => {
    // Framing the mixing hazard as merely "+1 to voterCount" understates it. On boolean, the
    // stale, un-decremented prior ballot keeps a *withdrawn* opinion alive in the accumulator.
    const box = await deployBox('BooleanRuleBallotBox');
    const rk = hre.ethers.id('b');
    await wire(box, rk, '0x'); // quorum threshold 5000 bps (constructor)

    // identity 1 votes YES in-box (rev0), then changes mind to NO — but the NO revision escapes
    // the box (verifier-direct), then a later revision returns in-box.
    await castViaBox(box, rk, [1], n(EXT, 1n, 0), 0); // YES, counted: support=1, voterCount=1
    await castDirect(0, n(EXT, 1n, 1), n(EXT, 1n, 0)); // NO revision escapes the box
    await castViaBox(box, rk, [0], n(EXT, 1n, 2), n(EXT, 1n, 1)); // NO returns in-box: unknown prev -> fresh

    const [value, total, quorumMet] = await box.currentResult(rk);
    // Truth: the sole voter now says NO => support should be 0 / 1 => 0 bps, quorum NOT met.
    // Actual under the mixing hazard: support=1 (stale YES) + fresh NO(0) => support=1,
    // voterCount=2 => 5000 bps == threshold => quorum FALSELY met on a retracted YES.
    expect(total).to.equal(2n);
    expect(value).to.equal(5000n);
    expect(quorumMet).to.equal(true); // a withdrawn YES carries a rule to quorum — governance-wrong
    // This is the documented KNOWN LIMIT; the test pins its true blast radius (wrong outcome, not
    // just a miscount) so the operational invariant is treated as SECURITY-critical, not cosmetic.
  });

  // ------------------------------------------------------------------ Fork A recovery fidelity
  it('F-CONTROL: Fork A recast of a PURELY verifier-direct chain (no prior in-box record) tallies exactly once', async () => {
    // A chain whose rev0 AND rev1 were both verifier-direct (the box never saw either) — the
    // pure-direct case the author tests only partially. The recast casts ONE revision into the
    // fresh box with prev = current live head; the fix counts it fresh, exactly once.
    await castDirect(10, n(EXT, 1n, 0), 0); // rev0 direct
    await castDirect(11, n(EXT, 1n, 1), n(EXT, 1n, 0)); // rev1 direct (head now n(1,1))
    const box = await deployBox('AverageRuleBallotBox');
    const rk = hre.ethers.id('a');
    await wire(box, rk, abi.encode(['uint16'], [100]));
    await castViaBox(box, rk, [42], n(EXT, 1n, 2), n(EXT, 1n, 1)); // recast one revision, prev=live head
    const [value, total] = await box.currentResult(rk);
    expect(total).to.equal(1n);
    expect(value).to.equal(42n);
  });

  it('F-CONTROL: erroneous DOUBLE-recast of the same identity does NOT double-count (chains through _lastBallot)', async () => {
    // Defensive: if the recast backend accidentally casts a second revision for an identity, and
    // it chains correctly (prev = the first recast nullifier, now in-box), the box decrements —
    // no inflation. (A second recast reusing the OLD retired head reverts at the verifier.)
    await castDirect(10, n(EXT, 1n, 0), 0);
    const box = await deployBox('MedianRuleBallotBox');
    const rk = hre.ethers.id('m');
    await wire(box, rk, abi.encode(['uint16'], [200]));
    await castViaBox(box, rk, [40], n(EXT, 1n, 1), n(EXT, 1n, 0)); // recast #1: fresh -> voterCount=1
    await castViaBox(box, rk, [45], n(EXT, 1n, 2), n(EXT, 1n, 1)); // recast #2 chains in-box -> decrement
    const [value, total] = await box.currentResult(rk);
    expect(total).to.equal(1n); // still one voter
    expect(value).to.equal(45n);
    // reusing the retired head reverts (verifier prev-head enforcement)
    await expect(castViaBox(box, rk, [99], n(EXT, 1n, 3), n(EXT, 1n, 0)))
      .to.be.revertedWith('AnonymousVoteVerifier: prev nullifier is not the live head');
  });

  // ------------------------------------------------------------------ trust boundary / mock fidelity
  it('F3: the box has NO identity dedup — voterCount integrity is fully delegated to the circuit rev-0 determinism', async () => {
    // The box counts EVERY prev=0 cast with a distinct unspent nullifier as a new voter. It cannot
    // tell that two different rev-0 nullifiers belong to the SAME identity — only the circuit's
    // deterministic nullifier(0) = Poseidon(ext, id, 0) + the verifier's spent-set guarantee
    // one-fresh-per-identity. The MOCK does not enforce that binding, so this passes — which is
    // precisely the point: a real prod deploy MUST use the real AnonymousVoteVerifier + circuit.
    const box = await deployBox('MedianRuleBallotBox');
    const rk = hre.ethers.id('m');
    await wire(box, rk, abi.encode(['uint16'], [200]));
    await castViaBox(box, rk, [50], 111n, 0); // "identity" A fresh
    await castViaBox(box, rk, [50], 222n, 0); // a SECOND fresh nullifier — box happily counts it
    const [, total] = await box.currentResult(rk);
    expect(total).to.equal(2n);
    // FINDING (INFO/assumption, NOT a box bug): the 9 author tests + these run against a mock that
    // omits the pairing check, so NONE of them would catch a circuit regression that lets one
    // identity mint two rev-0 nullifiers. That property is out of Solidity scope; it is the
    // external zk audit's charge. Documented here so the trust boundary is explicit pre-deploy.
  });
});
