const { expect } = require('chai');
const { ethers } = require('hardhat');
const ref = require('../fixtures/seed_draw_ref.json');

const PARAMS = [16, 40, 20, 2, 4, 31]; // numQueries re-pinned 96 → 40 (auditor)

async function deployFor(entry) {
  const keys = entry.table.map((t) => ethers.keccak256(t.pre));
  const digests = entry.table.map((t) => t.dig);
  const mock = await (await ethers.getContractFactory('Blake3LookupMock')).deploy(keys, digests);
  const blake3 = await (
    await ethers.getContractFactory('Blake3PrecompileHasher')
  ).deploy(await mock.getAddress());
  const air = await (await ethers.getContractFactory('VoteStarkAir')).deploy();
  return (await ethers.getContractFactory('StarkVerifier')).deploy(
    await blake3.getAddress(),
    await air.getAddress(),
    PARAMS
  );
}

describe('FRI core part 3 — full Fiat-Shamir chain through query positions (real proofs)', function () {
  for (const name of ['scalar', 'ranked']) {
    describe(name, function () {
      const entry = ref[name];
      const pub = entry.publicInputs.map(BigInt);
      let verifier;

      before(async function () {
        verifier = await deployFor(entry);
      });

      it('derives z, the FRI αs, and all query positions byte-exact (OOD reseed + DEEP + FRI + grinding)', async function () {
        const [z, alphas, positions] = await verifier.deriveQueryPositions(entry.proof, pub);

        expect(z.a0, 'z a0').to.equal(BigInt(entry.z[0]));
        expect(z.a1, 'z a1').to.equal(BigInt(entry.z[1]));

        expect(alphas.length, 'num FRI layer αs').to.equal(entry.alphas.length);
        alphas.forEach((a, i) => {
          expect(a.a0, `α${i} a0`).to.equal(BigInt(entry.alphas[i][0]));
          expect(a.a1, `α${i} a1`).to.equal(BigInt(entry.alphas[i][1]));
        });

        expect(positions.length, 'num query positions').to.equal(entry.positions.length);
        expect(positions.map((p) => p.toString())).to.deep.equal(entry.positions);
      });

      it('the grinding (proof-of-work) check passes for the real pow_nonce', async function () {
        // deriveQueryPositions reverts "insufficient grinding" if check_leading_zeros < 20; a
        // successful return (above) already proves the real pow_nonce satisfies the 20-bit factor.
        await verifier.deriveQueryPositions(entry.proof, pub); // does not revert
      });
    });
  }

  it('all query positions are within the LDE domain [0, 4096)', async function () {
    const v = await deployFor(ref.scalar);
    const [, , positions] = await v.deriveQueryPositions(ref.scalar.proof, ref.scalar.publicInputs.map(BigInt));
    for (const p of positions) expect(p).to.be.lessThan(4096n);
    expect(positions.length).to.equal(40); // numQueries re-pinned 96 → 40
  });
});
