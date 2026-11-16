const { expect } = require('chai');
const { ethers } = require('hardhat');
const fixtures = require('../fixtures/vote_stark_fixtures.json');

const scalar = fixtures.scalar.publicInputs.map(BigInt);
const ranked = fixtures.ranked.publicInputs.map(BigInt);

// the locked ProofOptions (VERIFIER_NOTES §3) — struct order: blowup,queries,grind,ext,friFold,friRem
const PARAMS = [16, 40, 20, 2, 4, 31]; // numQueries re-pinned 96 → 40 (auditor)

// air.rs column/row layout (mirrors VoteStarkAir.sol)
const COL = { DIG: 4, RCA: 15 };
const ROW = { ROOT: 175, NULL_DIGEST: 183, COMMIT_DIGEST: 191, RC_FINAL: 16, ZERO: 0 };

// proof Context byte offsets (confirmed against the real proof; see VERIFIER_IMPL_NOTES §3.1)
const OFF = { mainWidth: 0, log2Len: 3, modulus0: 7, numQueries: 15, blowup: 16 };
const flip = (hex, idx, val) => {
  const b = ethers.getBytes(hex);
  b[idx] = val;
  return ethers.hexlify(b);
};

describe('StarkVerifier + VoteStarkAir (Phase 1 foundation, audit-fixed)', function () {
  let hasher, air, verifier;

  before(async function () {
    hasher = await (await ethers.getContractFactory('KeccakHasher')).deploy();
    air = await (await ethers.getContractFactory('VoteStarkAir')).deploy();
    verifier = await (
      await ethers.getContractFactory('StarkVerifier')
    ).deploy(await hasher.getAddress(), await air.getAddress(), PARAMS);
  });

  describe('wiring + construction (V2 pinned params)', function () {
    it('binds the pluggable hasher + AIR', async function () {
      expect(await verifier.hasher()).to.equal(await hasher.getAddress());
      expect(await verifier.air()).to.equal(await air.getAddress());
    });

    it('pins the soundness ProofOptions verifier-side (immutable)', async function () {
      expect(await verifier.expBlowup()).to.equal(16n);
      expect(await verifier.expNumQueries()).to.equal(40n);
      expect(await verifier.expGrinding()).to.equal(20n);
      expect(await verifier.expExtDegree()).to.equal(2n);
      expect(await verifier.expFriFolding()).to.equal(4n);
      expect(await verifier.expFriRemainderMaxDegree()).to.equal(31n);
    });

    it('rejects zero dependencies', async function () {
      const F = await ethers.getContractFactory('StarkVerifier');
      await expect(
        F.deploy(ethers.ZeroAddress, await air.getAddress(), PARAMS)
      ).to.be.revertedWith('StarkVerifier: zero dep');
      await expect(
        F.deploy(await hasher.getAddress(), ethers.ZeroAddress, PARAMS)
      ).to.be.revertedWith('StarkVerifier: zero dep');
    });

    it('rejects pinned params the AIR does not agree with (V2 cross-check)', async function () {
      const F = await ethers.getContractFactory('StarkVerifier');
      await expect(
        F.deploy(await hasher.getAddress(), await air.getAddress(), [8, 40, 20, 2, 4, 31])
      ).to.be.revertedWith('StarkVerifier: AIR params != pinned');
    });
  });

  describe('AIR parameters (the locked §3/§4 set)', function () {
    it('airParams matches the audited vote_stark shape', async function () {
      const p = await air.airParams();
      expect(p.traceLength).to.equal(256n);
      expect(p.mainWidth).to.equal(17n);
      expect(p.auxWidth).to.equal(1n);
      expect(p.numAuxRandElements).to.equal(1n);
      expect(p.numMainConstraints).to.equal(34n);
      expect(p.numAuxConstraints).to.equal(1n);
      expect(p.numPeriodicColumns).to.equal(31n);
    });

    it('proofParams matches the locked ProofOptions', async function () {
      const p = await air.proofParams();
      expect(p.blowupFactor).to.equal(16n);
      expect(p.numQueries).to.equal(40n);
      expect(p.grindingBits).to.equal(20n);
      expect(p.fieldExtensionDegree).to.equal(2n);
      expect(p.friFoldingFactor).to.equal(4n);
      expect(p.friRemainderMaxDegree).to.equal(31n);
    });
  });

  describe('requireAcceptableOptions — vs the verifier-side PINNED set (V2)', function () {
    it('accepts the exact pinned set', async function () {
      await verifier.requireAcceptableOptions(...PARAMS);
    });

    const deviations = [
      ['blowup', [8, 40, 20, 2, 4, 31], 'StarkVerifier: blowup'],
      ['numQueries', [16, 39, 20, 2, 4, 31], 'StarkVerifier: numQueries'],
      ['grinding', [16, 40, 16, 2, 4, 31], 'StarkVerifier: grinding'],
      ['extension', [16, 40, 20, 1, 4, 31], 'StarkVerifier: extension'],
      ['friFolding', [16, 40, 20, 2, 2, 31], 'StarkVerifier: friFolding'],
      ['friRemainder', [16, 40, 20, 2, 4, 63], 'StarkVerifier: friRemainder'],
    ];
    deviations.forEach(([name, args, msg]) => {
      it(`rejects a different ${name}`, async function () {
        await expect(verifier.requireAcceptableOptions(...args)).to.be.revertedWith(msg);
      });
    });
  });

  describe('checkPublicInputs — generic, behind the AIR boundary (V3)', function () {
    it('accepts real scalar + ranked inputs', async function () {
      await verifier.checkPublicInputs(scalar);
      await verifier.checkPublicInputs(ranked);
    });
    it('rejects a tampered voteMode (via air.validatePublicInputs)', async function () {
      const bad = [...scalar];
      bad[6] = 2n;
      await expect(verifier.checkPublicInputs(bad)).to.be.revertedWith(
        'VotePI: voteMode not in {0,1}'
      );
    });
    it('the AIR validates its own public inputs (length + bounds)', async function () {
      await air.validatePublicInputs(scalar);
      await expect(air.validatePublicInputs(scalar.slice(0, 16))).to.be.revertedWith(
        'VoteStarkAir: 17 inputs'
      );
    });
  });

  describe('parseProofOptions — Context parse (V7), §3.1 layout (V1)', function () {
    it('reads the locked options out of the REAL scalar + ranked proofs', async function () {
      for (const proof of [fixtures.scalar.proof, fixtures.ranked.proof]) {
        const o = await verifier.parseProofOptions(proof);
        expect(o.blowup).to.equal(16n);
        expect(o.numQueries).to.equal(40n);
        expect(o.grinding).to.equal(20n);
        expect(o.extDegree).to.equal(2n);
        expect(o.friFolding).to.equal(4n);
        expect(o.friRemainderMaxDegree).to.equal(31n);
      }
    });

    it('rejects a proof whose trace width != the AIR', async function () {
      await expect(
        verifier.parseProofOptions(flip(fixtures.scalar.proof, OFF.mainWidth, 16))
      ).to.be.revertedWith('StarkVerifier: trace main width');
    });

    it('rejects a proof whose trace length != the AIR', async function () {
      await expect(
        verifier.parseProofOptions(flip(fixtures.scalar.proof, OFF.log2Len, 7))
      ).to.be.revertedWith('StarkVerifier: trace length');
    });

    it('rejects a proof over a non-Goldilocks field', async function () {
      await expect(
        verifier.parseProofOptions(flip(fixtures.scalar.proof, OFF.modulus0, 2))
      ).to.be.revertedWith('StarkVerifier: not Goldilocks');
    });

    it('a truncated proof reverts in the bounds-checked reader', async function () {
      await expect(verifier.parseProofOptions('0x110101')).to.be.reverted;
    });

    it('C2: rejects a non-empty trace_meta (the seed builder assumes empty)', async function () {
      // TraceInfo: main 0x11, aux 0x01, auxRands 0x01, log2(len) 0x08, then metaLen u16-LE = 1.
      await expect(verifier.parseProofOptions('0x110101080100')).to.be.revertedWith(
        'StarkVerifier: trace_meta unsupported'
      );
    });
  });

  describe('boundaryAssertions — the real §4 layout for real public inputs', function () {
    const find = (arr, col, row) =>
      arr.find((a) => Number(a.column) === col && Number(a.row) === row && Number(a.segment) === 0);

    it('scalar: count == numMainAssertions == 51 (common 49 + 2 range)', async function () {
      expect(await air.numMainAssertions(scalar)).to.equal(51n);
      expect((await air.boundaryAssertions(scalar)).length).to.equal(51);
    });

    it('ranked (N=4): count == numMainAssertions == 54 (common 49 + 1 + (8-4) pad)', async function () {
      expect(await air.numMainAssertions(ranked)).to.equal(54n);
      expect((await air.boundaryAssertions(ranked)).length).to.equal(54);
    });

    it('scalar: merkleRoot + nullifierHash + range boundaries land at the right (col,row,value)', async function () {
      const a = await air.boundaryAssertions(scalar);
      for (let c = 0; c < 4; c++) {
        expect(BigInt(find(a, COL.DIG + c, ROW.ROOT).value.a0)).to.equal(scalar[c]);
        expect(BigInt(find(a, COL.DIG + c, ROW.NULL_DIGEST).value.a0)).to.equal(scalar[9 + c]);
      }
      expect(BigInt(find(a, COL.RCA, ROW.ZERO).value.a0)).to.equal(0n);
      expect(BigInt(find(a, COL.RCA, ROW.RC_FINAL).value.a0)).to.equal(scalar[8]);
    });

    it('ranked: voteChoice binds to the rank-commitment digest[0] @ row 191', async function () {
      const a = await air.boundaryAssertions(ranked);
      expect(BigInt(find(a, COL.DIG, ROW.COMMIT_DIGEST).value.a0)).to.equal(ranked[8]);
      for (let c = 0; c < 4; c++) {
        expect(BigInt(find(a, COL.DIG + c, ROW.ROOT).value.a0)).to.equal(ranked[c]);
      }
    });

    it('every boundary value has zero imaginary part (base-field targets)', async function () {
      const a = await air.boundaryAssertions(ranked);
      for (const as of a) expect(BigInt(as.value.a1)).to.equal(0n);
    });
  });

  describe('verify — Phase 1: gates run (incl. options), then the FRI core reverts honestly', function () {
    it('rejects bad public inputs BEFORE touching the proof (gate ordering)', async function () {
      const bad = [...scalar];
      bad[6] = 2n;
      await expect(verifier.verify(fixtures.scalar.proof, bad)).to.be.revertedWith(
        'VotePI: voteMode not in {0,1}'
      );
    });

    it('rejects a proof with downgraded options (V7 — wired into verify)', async function () {
      await expect(
        verifier.verify(flip(fixtures.scalar.proof, OFF.blowup, 8), scalar)
      ).to.be.revertedWith('StarkVerifier: blowup');
      await expect(
        verifier.verify(flip(fixtures.scalar.proof, OFF.numQueries, 95), scalar)
      ).to.be.revertedWith('StarkVerifier: numQueries');
    });

    it('passes ALL gates + Fiat-Shamir through z on a REAL proof, then reverts post-OOD', async function () {
      await expect(verifier.verify(fixtures.scalar.proof, scalar)).to.be.revertedWith(
        'StarkVerifier: FRI core pending post-OOD (DEEP/Merkle/FRI - see VERIFIER_IMPL_NOTES)'
      );
      await expect(verifier.verify(fixtures.ranked.proof, ranked)).to.be.revertedWith(
        'StarkVerifier: FRI core pending post-OOD (DEEP/Merkle/FRI - see VERIFIER_IMPL_NOTES)'
      );
    });

    it('never returns true in Phase 1 (cannot be mistaken for proof-accepting)', async function () {
      await expect(verifier.verify.staticCall(fixtures.scalar.proof, scalar)).to.be.reverted;
    });
  });
});
