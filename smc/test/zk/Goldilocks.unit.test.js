const { expect } = require('chai');
const { ethers } = require('hardhat');
const fixtures = require('../fixtures/vote_stark_fixtures.json');

// Goldilocks prime p = 2^64 - 2^32 + 1
const P = 18446744069414584321n;

describe('Goldilocks field library', function () {
  let h;

  before(async function () {
    h = await (await ethers.getContractFactory('GoldilocksHarness')).deploy();
  });

  describe('base field — matches winter-math reference values', function () {
    const f = fixtures.field;
    const a = BigInt(f.a);
    const b = BigInt(f.b);

    it('add', async function () {
      expect(await h.add(a, b)).to.equal(BigInt(f.add));
    });

    it('mul', async function () {
      expect(await h.mul(a, b)).to.equal(BigInt(f.mul));
    });

    it('inv', async function () {
      expect(await h.inv(a)).to.equal(BigInt(f.inv));
    });

    it('exp7 (RPO S-box)', async function () {
      expect(await h.exp7(a)).to.equal(BigInt(f.exp7));
    });
  });

  describe('base field — algebraic invariants', function () {
    const samples = [1n, 2n, 7n, 0xdeadbeefn, P - 1n, 0xffffffffn, 0x100000000n];

    it('a * inv(a) == 1', async function () {
      for (const a of samples) {
        const ai = await h.inv(a);
        expect(await h.mul(a, ai)).to.equal(1n);
      }
    });

    it('add then sub is identity', async function () {
      for (const a of samples) {
        for (const b of samples) {
          expect(await h.sub(await h.add(a, b), b)).to.equal(a % P);
        }
      }
    });

    it('exp7(a) == a^7 via pow', async function () {
      for (const a of samples) {
        expect(await h.exp7(a)).to.equal(await h.pow(a, 7n));
      }
    });

    it('inv(0) reverts', async function () {
      await expect(h.inv(0n)).to.be.revertedWith('Goldilocks: inverse of zero');
    });

    it('isValid rejects the non-canonical [p, 2^64) gap', async function () {
      expect(await h.isValid(P - 1n)).to.equal(true);
      expect(await h.isValid(P)).to.equal(false);
      expect(await h.isValid(2n ** 64n - 1n)).to.equal(false);
    });
  });

  describe('GF(p^2) — matches winter-math reference values (irreducible x^2 - x + 2)', function () {
    const f = fixtures.field;
    const [a0, a1] = f.ext_a.map(BigInt);
    const [b0, b1] = f.ext_b.map(BigInt);

    it('extMul', async function () {
      const r = await h.extMul(a0, a1, b0, b1);
      expect(r[0]).to.equal(BigInt(f.ext_mul[0]));
      expect(r[1]).to.equal(BigInt(f.ext_mul[1]));
    });

    it('extSquare', async function () {
      const r = await h.extSquare(a0, a1);
      expect(r[0]).to.equal(BigInt(f.ext_square[0]));
      expect(r[1]).to.equal(BigInt(f.ext_square[1]));
    });

    it('extInv', async function () {
      const r = await h.extInv(a0, a1);
      expect(r[0]).to.equal(BigInt(f.ext_inv[0]));
      expect(r[1]).to.equal(BigInt(f.ext_inv[1]));
    });
  });

  describe('GF(p^2) — algebraic invariants', function () {
    const samples = [
      [3n, 5n],
      [1n, 0n],
      [0n, 1n],
      [0xdeadn, 0xbeefn],
      [P - 1n, P - 2n],
    ];

    it('x * inv(x) == 1 (on-chain)', async function () {
      for (const [x0, x1] of samples) {
        expect(await h.extMulInvIsOne(x0, x1)).to.equal(true);
      }
    });

    it('extSquare(x) == extMul(x, x)', async function () {
      for (const [x0, x1] of samples) {
        const sq = await h.extSquare(x0, x1);
        const mm = await h.extMul(x0, x1, x0, x1);
        expect(sq[0]).to.equal(mm[0]);
        expect(sq[1]).to.equal(mm[1]);
      }
    });

    it('frobenius is the conjugate (x0 + x1, -x1) and frob(frob(x)) == x', async function () {
      for (const [x0, x1] of samples) {
        const fr = await h.frobenius(x0, x1);
        expect(fr[0]).to.equal((x0 + x1) % P);
        expect(fr[1]).to.equal(x1 === 0n ? 0n : P - x1);
        const ff = await h.frobenius(fr[0], fr[1]);
        expect(ff[0]).to.equal(x0 % P);
        expect(ff[1]).to.equal(x1 % P);
      }
    });
  });
});
