const { expect } = require('chai');
const { ethers } = require('hardhat');
const ref = require('../fixtures/transcript_ref.json');

// canonical 8-LE bytes per base element — the winter-crypto hash_elements / IHasher layout.
function leBytes(elements) {
  const out = new Uint8Array(elements.length * 8);
  elements.forEach((e, i) => {
    let v = BigInt(e);
    for (let j = 0; j < 8; j++) {
      out[i * 8 + j] = Number(v & 0xffn);
      v >>= 8n;
    }
  });
  return ethers.hexlify(out);
}

describe('Transcript — Fiat-Shamir spine, byte-exact vs winter-crypto DefaultRandomCoin<Blake3_256>', function () {
  let blake3, harness, digestByPreKey;

  before(async function () {
    // Back Blake3 with the genuine digests winterfell computed (captured in the fixture), keyed by
    // keccak256(preimage). The Solidity transcript must compute identical preimages to hit them.
    const keys = ref.table.map((t) => ethers.keccak256(t.pre));
    const digests = ref.table.map((t) => t.dig);
    digestByPreKey = new Map(keys.map((k, i) => [k, digests[i]]));

    const mock = await (await ethers.getContractFactory('Blake3LookupMock')).deploy(keys, digests);
    blake3 = await (
      await ethers.getContractFactory('Blake3PrecompileHasher')
    ).deploy(await mock.getAddress());
    harness = await (await ethers.getContractFactory('TranscriptHarness')).deploy(
      await blake3.getAddress()
    );
  });

  it('hashElements matches winter-crypto Blake3 hash_elements (element layout — audit residual #2)', async function () {
    const seedElems = ref.seedElems.map(BigInt);
    const expected = digestByPreKey.get(ethers.keccak256(leBytes(ref.seedElems)));
    expect(expected, 'seed hash_elements preimage present in table').to.not.equal(undefined);
    expect(await blake3.hashElements(seedElems)).to.equal(expected);
  });

  it('merge matches winter-crypto Blake3 merge (a‖b)', async function () {
    const seedDigest = await blake3.hashElements(ref.seedElems.map(BigInt));
    const pre = ethers.concat([seedDigest, ref.reseedData]);
    const expected = digestByPreKey.get(ethers.keccak256(pre));
    expect(expected, 'merge(seed,reseed) preimage present in table').to.not.equal(undefined);
    expect(await blake3.merge(seedDigest, ref.reseedData)).to.equal(expected);
  });

  it('the full scripted sequence reproduces winterfell draws byte-for-byte', async function () {
    const r = await harness.runSequence(
      ref.seedElems.map(BigInt),
      ref.reseedData,
      BigInt(ref.nonce),
      ref.numInts,
      ref.domainSize
    );

    expect(r.b1, 'draw base #1').to.equal(BigInt(ref.b1));
    expect(r.b2, 'draw base #2').to.equal(BigInt(ref.b2));
    expect(r.q1a0, 'draw quad #1 a0').to.equal(BigInt(ref.q1[0]));
    expect(r.q1a1, 'draw quad #1 a1').to.equal(BigInt(ref.q1[1]));
    expect(r.q2a0, 'draw quad #2 (post-reseed) a0').to.equal(BigInt(ref.q2[0]));
    expect(r.q2a1, 'draw quad #2 (post-reseed) a1').to.equal(BigInt(ref.q2[1]));
    expect(r.lz, 'check_leading_zeros').to.equal(BigInt(ref.lz));
    expect(r.ints.map((x) => x.toString())).to.deep.equal(ref.ints);
  });

  it('rejects a non-power-of-two / oversized domain (mirrors winter asserts)', async function () {
    await expect(
      harness.runSequence(ref.seedElems.map(BigInt), ref.reseedData, BigInt(ref.nonce), 12, 4095)
    ).to.be.revertedWith('Transcript: domain !pow2');
    await expect(
      harness.runSequence(ref.seedElems.map(BigInt), ref.reseedData, BigInt(ref.nonce), 4096, 4096)
    ).to.be.revertedWith('Transcript: num >= domain');
  });
});
