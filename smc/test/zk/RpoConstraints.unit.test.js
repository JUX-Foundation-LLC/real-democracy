const { expect } = require('chai');
const { ethers } = require('hardhat');
const ref = require('../fixtures/rpo_round_ref.json');

const big = (a) => a.map(BigInt);
const zeros24 = Array(24).fill(0n);

describe('RpoConstraints — RPO round constraint over GF(p^2), byte-exact vs the circuit (rpo.rs)', function () {
  let h;

  before(async function () {
    h = await (await ethers.getContractFactory('RpoConstraintsHarness')).deploy();
  });

  it('pow7 (degree-7 S-box) matches', async function () {
    const r = await h.pow7(big(ref.pow7In));
    expect(r.map((x) => x.toString())).to.deep.equal(ref.pow7Out);
  });

  it('applyMds (12×12 left-circulant MDS) matches', async function () {
    const r = await h.applyMds(big(ref.current));
    expect(r.map((x) => x.toString())).to.deep.equal(ref.mdsOut);
  });

  it('enforceRound matches the circuit (zero accumulator)', async function () {
    const r = await h.enforceRound(
      zeros24,
      big(ref.current),
      big(ref.next),
      big(ref.ark1),
      big(ref.ark2),
      big(ref.flag)
    );
    expect(r.map((x) => x.toString())).to.deep.equal(ref.result);
  });

  it('enforceRound ACCUMULATES into the result buffer (nonzero start)', async function () {
    const r = await h.enforceRound(
      big(ref.accStart),
      big(ref.current),
      big(ref.next),
      big(ref.ark1),
      big(ref.ark2),
      big(ref.flag)
    );
    expect(r.map((x) => x.toString())).to.deep.equal(ref.resultAcc);
  });

  it('flag = 0 contributes nothing (the round is gated off)', async function () {
    const r = await h.enforceRound(
      zeros24,
      big(ref.current),
      big(ref.next),
      big(ref.ark1),
      big(ref.ark2),
      [0n, 0n]
    );
    expect(r.map((x) => x)).to.deep.equal(zeros24);
  });
});
