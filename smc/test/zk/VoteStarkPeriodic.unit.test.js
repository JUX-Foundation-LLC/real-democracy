const { expect } = require('chai');
const { ethers } = require('hardhat');
const ref = require('../fixtures/periodic_ref.json');

// air.rs periodic-column layout (the order periodicValuesAt must emit)
const LABELS = [
  'hash_flag',
  ...Array.from({ length: 12 }, (_, i) => `ark1[${i}]`),
  ...Array.from({ length: 12 }, (_, i) => `ark2[${i}]`),
  'f_bind0',
  'f_null',
  'rc_active',
  'f_break',
  'f_perm',
  'f_prevbind',
];

describe('VoteStarkPeriodic — periodicValuesAt(z) byte-exact vs winterfell (part 5)', function () {
  let air;
  const z = ref.z.map(BigInt);

  before(async function () {
    air = await (await ethers.getContractFactory('VoteStarkAir')).deploy();
  });

  it('returns all 31 periodic columns', async function () {
    const out = await air.periodicValuesAt(z);
    expect(out.length).to.equal(31);
  });

  it('every periodic column at z matches winterfell `eval(poly, z^num_cycles)` byte-for-byte', async function () {
    const out = await air.periodicValuesAt(z);
    for (let i = 0; i < 31; i++) {
      expect(BigInt(out[i].a0), `${LABELS[i]} a0`).to.equal(BigInt(ref.values[i][0]));
      expect(BigInt(out[i].a1), `${LABELS[i]} a1`).to.equal(BigInt(ref.values[i][1]));
    }
  });

  it('period-8 (hash_flag + ARK) and period-256 (selectors) regimes both verified', async function () {
    const out = await air.periodicValuesAt(z);
    // spot-check one of each regime explicitly
    expect(BigInt(out[0].a0)).to.equal(BigInt(ref.values[0][0])); // hash_flag (period 8)
    expect(BigInt(out[27].a0)).to.equal(BigInt(ref.values[27][0])); // rc_active (period 256, 16 rows)
    expect(BigInt(out[27].a1)).to.equal(BigInt(ref.values[27][1]));
  });
});
