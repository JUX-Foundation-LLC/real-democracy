const { expect } = require('chai');
const { ethers } = require('hardhat');

// S2a — CheckpointRegistry carries subject identity on-chain, so the set of
// anchored checkpoints is enumerable + the ChainClock aggregate is rebuildable
// from chain (CHAINCLOCK_STANDUP §2 / AUDITABILITY_AND_RETENTION §4.1).
describe('CheckpointRegistry — subject-aware anchoring (S2a)', function () {
  let registry, owner, other;
  const abi = ethers.AbiCoder.defaultAbiCoder();

  // mirror of the contract's checkpointLeaf — what the backend aggregate builder
  // (and an external auditor) must compute to match byte-for-byte.
  const leafOf = (subjectType, subjectId, jid, root, leafCount) =>
    ethers.keccak256(abi.encode(
      ['bytes32', 'uint256', 'uint256', 'bytes32', 'uint256'],
      [subjectType, subjectId, jid, root, leafCount]));

  beforeEach(async function () {
    [owner, other] = await ethers.getSigners();
    registry = await (await ethers.getContractFactory('CheckpointRegistry')).deploy();
  });

  it('canonical anchor emits the full subject identity', async function () {
    const stype = await registry.SUBJECT_RULESET();
    const root = ethers.id('ruleset-root-1');
    await expect(registry.anchorCheckpoint(1, stype, 42, 7, root, 26, ethers.id('meta')))
      .to.emit(registry, 'CheckpointAnchored')
      .withArgs(1, stype, 7, 42, root, 26, ethers.id('meta'), owner.address, anyUint());
  });

  it('back-compat proposal anchor maps to (SUBJECT_PROPOSAL, proposalId, jid=0)', async function () {
    const sProposal = await registry.SUBJECT_PROPOSAL();
    const root = ethers.id('proposal-root');
    // the 5-arg overload the existing backend caller uses
    await expect(registry['anchorCheckpoint(uint256,uint256,bytes32,uint256,bytes32)'](9, 123, root, 3, ethers.ZeroHash))
      .to.emit(registry, 'CheckpointAnchored')
      .withArgs(9, sProposal, 0, 123, root, 3, ethers.ZeroHash, owner.address, anyUint());
  });

  it('checkpointLeaf == the off-chain encoding (backend ↔ contract agreement)', async function () {
    const stype = await registry.SUBJECT_TAG_REGISTRY();
    const root = ethers.id('tagreg-root');
    const onChain = await registry.checkpointLeaf(stype, 5, 7, root, 12);
    expect(onChain).to.equal(leafOf(stype, 5n, 7n, root, 12n));
  });

  it('rejects zero subjectId / zero root, and non-owner', async function () {
    const stype = await registry.SUBJECT_SHOW();
    await expect(registry.anchorCheckpoint(1, stype, 0, 1, ethers.id('r'), 1, ethers.ZeroHash))
      .to.be.revertedWith('CheckpointRegistry: subject id required');
    await expect(registry.anchorCheckpoint(1, stype, 1, 1, ethers.ZeroHash, 1, ethers.ZeroHash))
      .to.be.revertedWith('CheckpointRegistry: zero root');
    await expect(registry.connect(other).anchorCheckpoint(1, stype, 1, 1, ethers.id('r'), 1, ethers.ZeroHash))
      .to.be.revertedWith('CheckpointRegistry: only owner');
  });

  it('the anchored set is enumerable + latest-per-subject rebuildable from events', async function () {
    const R = await registry.SUBJECT_RULESET();
    const T = await registry.SUBJECT_TAG_REGISTRY();
    // two subjects, one revised (the later anchor must win)
    await registry.anchorCheckpoint(1, R, 100, 7, ethers.id('r100-v1'), 1, ethers.ZeroHash);
    await registry.anchorCheckpoint(2, T, 200, 7, ethers.id('t200'), 1, ethers.ZeroHash);
    await registry.anchorCheckpoint(3, R, 100, 7, ethers.id('r100-v2'), 2, ethers.ZeroHash); // revises subject (R,100)

    const evs = await registry.queryFilter(registry.filters.CheckpointAnchored());
    expect(evs.length).to.equal(3);

    // rebuild "latest per (subjectType, subjectId)" purely from chain events
    const latest = new Map();
    for (const e of evs) {
      const a = e.args;
      const key = `${a.subjectType}:${a.subjectId}`;
      const prev = latest.get(key);
      if (!prev || a.checkpointId > prev.args.checkpointId) latest.set(key, e);
    }
    expect(latest.size).to.equal(2); // (R,100) and (T,200)
    expect(latest.get(`${R}:100`).args.root).to.equal(ethers.id('r100-v2')); // the revision won

    // each survivor's canonical leaf is reproducible via the on-chain helper
    for (const e of latest.values()) {
      const a = e.args;
      const leaf = await registry.checkpointLeaf(a.subjectType, a.subjectId, a.jurisdictionId, a.root, a.leafCount);
      expect(leaf).to.equal(leafOf(a.subjectType, a.subjectId, a.jurisdictionId, a.root, a.leafCount));
    }
  });
});

// chai-matcher helper for the timestamp arg
function anyUint() {
  const { anyValue } = require('@nomicfoundation/hardhat-chai-matchers/withArgs');
  return anyValue;
}
