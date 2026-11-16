const { expect } = require('chai');
const { ethers } = require('hardhat');
const ref = require('../fixtures/seed_draw_ref.json');

const PARAMS = [16, 40, 20, 2, 4, 31]; // numQueries re-pinned 96 → 40 (auditor)

// Deploy a StarkVerifier whose Blake3 host is backed by the genuine (preimage→digest) table this
// proof's coin replay produced — so the on-chain Fiat-Shamir runs on TRUE Blake3 and must match
// winterfell's seed/γ/z byte-for-byte (a wrong preimage misses the table → revert).
async function deployFor(entry) {
  const keys = entry.table.map((t) => ethers.keccak256(t.pre));
  const digests = entry.table.map((t) => t.dig);
  const mock = await (await ethers.getContractFactory('Blake3LookupMock')).deploy(keys, digests);
  const blake3 = await (
    await ethers.getContractFactory('Blake3PrecompileHasher')
  ).deploy(await mock.getAddress());
  const air = await (await ethers.getContractFactory('VoteStarkAir')).deploy();
  const verifier = await (
    await ethers.getContractFactory('StarkVerifier')
  ).deploy(await blake3.getAddress(), await air.getAddress(), PARAMS);
  return verifier;
}

describe('FRI core part 2 — seed-from-Context + γ/z, byte-exact vs winterfell (real proofs)', function () {
  for (const name of ['scalar', 'ranked']) {
    describe(name, function () {
      const entry = ref[name];
      const pub = entry.publicInputs.map(BigInt);
      let verifier;

      before(async function () {
        verifier = await deployFor(entry);
      });

      it('context.to_elements() parses byte-exact (trace layout, modulus split, num_constraints, options)', async function () {
        const got = await verifier.contextToElements(entry.proof);
        expect(got.map((x) => x.toString())).to.deep.equal(entry.contextElems);
      });

      it('initial coin seed = hash_elements(context.to_elements ‖ pub) matches winterfell', async function () {
        expect(await verifier.initialSeed(entry.proof, pub)).to.equal(entry.seed);
      });

      it('derives γ (RAP) and z (OOD point) byte-exact through the real commitment chain', async function () {
        const [seed, gamma, z] = await verifier.deriveChallengesThroughZ(entry.proof, pub);
        expect(seed, 'seed').to.equal(entry.seed);
        expect(gamma.a0, 'γ a0').to.equal(BigInt(entry.gamma[0]));
        expect(gamma.a1, 'γ a1').to.equal(BigInt(entry.gamma[1]));
        expect(z.a0, 'z a0').to.equal(BigInt(entry.z[0]));
        expect(z.a1, 'z a1').to.equal(BigInt(entry.z[1]));
      });

      it('verify() runs the full path through z on TRUE Blake3, then reverts post-OOD', async function () {
        await expect(verifier.verify(entry.proof, pub)).to.be.revertedWith(
          'StarkVerifier: FRI core pending post-OOD (DEEP/Merkle/FRI - see VERIFIER_IMPL_NOTES)'
        );
      });
    });
  }

  // AUDIT C1 (MEDIUM/consensus): the constraint-coeff draw count is recomputed from the AIR and the
  // proof's context.num_constraints is asserted to match — a malicious under-count is rejected, so it
  // cannot leave constraints unenforced once OOD composition consumes the coeffs.
  describe('C1 — rejects a proof that under-states num_constraints', function () {
    // context byte layout: 6 (TraceInfo) + 9 (modulus) + 10 (options) ⇒ byte 25 is the num_constraints
    // varint (0xAF = 87 for the scalar proof; flip → 0xAD = 86 ≠ the AIR's recomputed 87).
    const tamper = (hex) => {
      const b = ethers.getBytes(hex);
      b[25] = 0xad;
      return ethers.hexlify(b);
    };

    it('deriveChallengesThroughZ reverts on a tampered num_constraints', async function () {
      const v = await deployFor(ref.scalar);
      const pub = ref.scalar.publicInputs.map(BigInt);
      // sanity: the untampered proof passes the assert (reaches z)
      await v.deriveChallengesThroughZ(ref.scalar.proof, pub);
      await expect(v.deriveChallengesThroughZ(tamper(ref.scalar.proof), pub)).to.be.revertedWith(
        'StarkVerifier: num_constraints mismatch'
      );
    });

    it('deriveQueryPositions reverts on a tampered num_constraints', async function () {
      const v = await deployFor(ref.scalar);
      const pub = ref.scalar.publicInputs.map(BigInt);
      await expect(v.deriveQueryPositions(tamper(ref.scalar.proof), pub)).to.be.revertedWith(
        'StarkVerifier: num_constraints mismatch'
      );
    });
  });
});
