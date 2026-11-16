const { expect } = require('chai');
const { ethers } = require('hardhat');

// JS reference for Winterfell's preimage layout: each Goldilocks element = 8 canonical LE bytes.
function leElementBytes(elements) {
  const out = new Uint8Array(elements.length * 8);
  elements.forEach((e, i) => {
    let v = BigInt(e);
    for (let j = 0; j < 8; j++) {
      out[i * 8 + j] = Number(v & 0xffn);
      v >>= 8n;
    }
  });
  return out;
}

describe('IHasher adapters', function () {
  let keccakHasher, blake3, mock;

  before(async function () {
    keccakHasher = await (await ethers.getContractFactory('KeccakHasher')).deploy();
    mock = await (await ethers.getContractFactory('MockBlake3Precompile')).deploy();
    blake3 = await (
      await ethers.getContractFactory('Blake3PrecompileHasher')
    ).deploy(await mock.getAddress());
  });

  describe('identity + construction', function () {
    it('hasherIds are the documented domain tags', async function () {
      expect(await keccakHasher.hasherId()).to.equal(
        ethers.keccak256(ethers.toUtf8Bytes('keccak-baseline'))
      );
      expect(await blake3.hasherId()).to.equal(
        ethers.keccak256(ethers.toUtf8Bytes('blake3-precompile'))
      );
    });

    it('Blake3PrecompileHasher rejects the zero precompile address', async function () {
      const F = await ethers.getContractFactory('Blake3PrecompileHasher');
      await expect(F.deploy(ethers.ZeroAddress)).to.be.revertedWith('Blake3: precompile required');
    });

    it('exposes the configured precompile address (the host swap point)', async function () {
      expect(await blake3.precompile()).to.equal(await mock.getAddress());
    });
  });

  describe('selfTest — V2 precompile attestation', function () {
    it('returns FALSE for a non-Blake3 (keccak) precompile — discriminates', async function () {
      // `blake3` here points at the keccak-only mock, so the Blake3 vectors must NOT match.
      expect(await blake3.selfTest()).to.equal(false);
    });

    it('returns TRUE when the precompile returns genuine winter-crypto Blake3 digests', async function () {
      const vmock = await (await ethers.getContractFactory('Blake3VectorMock')).deploy();
      const genuine = await (
        await ethers.getContractFactory('Blake3PrecompileHasher')
      ).deploy(await vmock.getAddress());
      expect(await genuine.selfTest()).to.equal(true);
    });
  });

  describe('keccak baseline matches the JS reference layout', function () {
    const elements = [0n, 1n, 7n, 0xdeadbeefn, 18446744069414584320n];

    it('hashElements == keccak256(LE element bytes)', async function () {
      const ref = ethers.keccak256(leElementBytes(elements));
      expect(await keccakHasher.hashElements(elements)).to.equal(ref);
    });

    it('merge == keccak256(a ‖ b)', async function () {
      const a = ethers.id('left');
      const b = ethers.id('right');
      const ref = ethers.keccak256(ethers.concat([a, b]));
      expect(await keccakHasher.merge(a, b)).to.equal(ref);
    });

    it('hashBytes == keccak256(data)', async function () {
      const data = '0x0011223344556677';
      expect(await keccakHasher.hashBytes(data)).to.equal(ethers.keccak256(data));
    });
  });

  describe('precompile adapter — plumbing + canonical preimage', function () {
    const elements = [0n, 1n, 7n, 0xdeadbeefn, 18446744069414584320n];

    // The mock returns keccak256(preimage); since both adapters use the SAME LE layout, the
    // precompile adapter (over the mock) must agree with KeccakHasher byte-for-byte. This proves
    // the adapter serializes + routes correctly; the real precompile swaps keccak->Blake3.
    it('hashElements routes through the precompile with the same layout', async function () {
      expect(await blake3.hashElements(elements)).to.equal(
        await keccakHasher.hashElements(elements)
      );
      expect(await blake3.hashElements(elements)).to.equal(
        ethers.keccak256(leElementBytes(elements))
      );
    });

    it('merge routes through the precompile (a ‖ b preimage)', async function () {
      const a = ethers.id('node-a');
      const b = ethers.id('node-b');
      expect(await blake3.merge(a, b)).to.equal(await keccakHasher.merge(a, b));
    });

    it('hashBytes routes the raw preimage unchanged', async function () {
      const data = '0xcafebabedeadbeef';
      expect(await blake3.hashBytes(data)).to.equal(await keccakHasher.hashBytes(data));
    });
  });
});
