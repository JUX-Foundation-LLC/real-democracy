const { expect } = require('chai');
const { ethers } = require('hardhat');
const fixtures = require('../fixtures/vote_stark_fixtures.json');

const P = 18446744069414584321n;
const toArr = (pi) => pi.map(BigInt);
const scalar = toArr(fixtures.scalar.publicInputs);
const ranked = toArr(fixtures.ranked.publicInputs);

// wire indices (VERIFIER_NOTES §1 / VoteStarkPublicInputs.sol)
const I = { extNull: 4, revision: 5, voteMode: 6, choiceCount: 7, voteChoice: 8 };
const tamper = (base, idx, val) => {
  const e = [...base];
  e[idx] = val;
  return e;
};

describe('VoteStarkPublicInputs — 17-element codec + audit bounds gate', function () {
  let h;

  before(async function () {
    h = await (await ethers.getContractFactory('VoteStarkPublicInputsHarness')).deploy();
  });

  it('the fixtures really are scalar (mode 0, N 0) and ranked (mode 1, N 4)', function () {
    expect(scalar[I.voteMode]).to.equal(0n);
    expect(scalar[I.choiceCount]).to.equal(0n);
    expect(ranked[I.voteMode]).to.equal(1n);
    expect(ranked[I.choiceCount]).to.equal(4n);
  });

  describe('codec', function () {
    it('round-trips real scalar inputs', async function () {
      const out = await h.roundTrip(scalar);
      expect(out.map((x) => BigInt(x))).to.deep.equal(scalar);
    });

    it('round-trips real ranked inputs', async function () {
      const out = await h.roundTrip(ranked);
      expect(out.map((x) => BigInt(x))).to.deep.equal(ranked);
    });

    it('parses fields into the documented positions', async function () {
      const p = await h.parse(ranked);
      expect(p.merkleRoot.map((x) => BigInt(x))).to.deep.equal(ranked.slice(0, 4));
      expect(BigInt(p.externalNullifier)).to.equal(ranked[I.extNull]);
      expect(BigInt(p.revision)).to.equal(ranked[I.revision]);
      expect(BigInt(p.voteMode)).to.equal(ranked[I.voteMode]);
      expect(BigInt(p.choiceCount)).to.equal(ranked[I.choiceCount]);
      expect(BigInt(p.voteChoice)).to.equal(ranked[I.voteChoice]);
      expect(p.nullifierHash.map((x) => BigInt(x))).to.deep.equal(ranked.slice(9, 13));
      expect(p.prevNullifierHash.map((x) => BigInt(x))).to.deep.equal(ranked.slice(13, 17));
    });
  });

  describe('validate — accepts real prover output', function () {
    it('accepts the real scalar proof public inputs', async function () {
      await h.validate(scalar); // does not revert
    });
    it('accepts the real ranked proof public inputs', async function () {
      await h.validate(ranked);
    });
  });

  describe('validate — rejects out-of-spec inputs (the audit gate)', function () {
    it('F3: voteMode = 2 (non-binary)', async function () {
      await expect(h.validate(tamper(scalar, I.voteMode, 2n))).to.be.revertedWith(
        'VotePI: voteMode not in {0,1}'
      );
    });

    it('F3: voteMode = huge', async function () {
      await expect(h.validate(tamper(scalar, I.voteMode, P - 1n))).to.be.revertedWith(
        'VotePI: voteMode not in {0,1}'
      );
    });

    it('F2/F8: ranked choiceCount = 0 (below range)', async function () {
      await expect(h.validate(tamper(ranked, I.choiceCount, 0n))).to.be.revertedWith(
        'VotePI: choiceCount out of range'
      );
    });

    it('F2/F8: ranked choiceCount = 9 (> N_MAX, the silent-clamp case)', async function () {
      await expect(h.validate(tamper(ranked, I.choiceCount, 9n))).to.be.revertedWith(
        'VotePI: choiceCount out of range'
      );
    });

    it('F2/F8: ranked choiceCount = N_MAX (8) is the inclusive upper bound — accepted', async function () {
      await h.validate(tamper(ranked, I.choiceCount, 8n));
    });

    it('scalar with choiceCount != 0 is rejected', async function () {
      await expect(h.validate(tamper(scalar, I.choiceCount, 1n))).to.be.revertedWith(
        'VotePI: scalar choiceCount must be 0'
      );
    });

    it('non-canonical element (== p) anywhere is rejected', async function () {
      await expect(h.validate(tamper(scalar, 0, P))).to.be.revertedWith(
        'VotePI: non-canonical element'
      );
      await expect(h.validate(tamper(scalar, 16, 2n ** 64n - 1n))).to.be.revertedWith(
        'VotePI: non-canonical element'
      );
    });
  });

  describe('requireScalarMax (F5 — ballotbox clamp)', function () {
    it('accepts scalar voteChoice <= maxValue', async function () {
      await h.requireScalarMax(scalar, scalar[I.voteChoice]); // exactly at bound
    });

    it('rejects scalar voteChoice > maxValue', async function () {
      await expect(h.requireScalarMax(scalar, scalar[I.voteChoice] - 1n)).to.be.revertedWith(
        'VotePI: scalar voteChoice exceeds ballot maxValue'
      );
    });

    it('is a no-op for ranked (voteChoice is a commitment, not a value)', async function () {
      await h.requireScalarMax(ranked, 0n); // does not revert despite huge voteChoice
    });
  });
});
