const { expect } = require('chai');
const { ethers } = require('hardhat');
const ref = require('../fixtures/transition_ref.json');

const fp2 = (arr) => arr.map(([a0, a1]) => [BigInt(a0), BigInt(a1)]);

// constraint index → label (air.rs evaluate_transition / evaluate_aux_transition)
const LABEL = (i) => {
  if (i < 12) return `RPO round [${i}]`;
  if (i < 24) return `merge gadget [${i}]`;
  if (i === 24) return 'bit binary';
  if (i === 25) return 'id-carry copy';
  if (i === 26) return 'f_bind0';
  if (i === 27) return 'f_null';
  if (i === 28) return 'range acc';
  if (i === 29) return 'range bit';
  if (i < 34) return `F1 prev-mask [${i}]`;
  return 'aux grand-product';
};

describe('VoteStarkAir.evaluateTransition — 34 main + 1 aux, byte-exact vs winterfell (part 6)', function () {
  let air;

  before(async function () {
    air = await (await ethers.getContractFactory('VoteStarkAir')).deploy();
  });

  it('returns 34 main + 1 aux = 35 evaluations', async function () {
    const out = await air.evaluateTransition(
      fp2(ref.mainCur), fp2(ref.mainNxt), fp2(ref.auxCur), fp2(ref.auxNxt),
      fp2(ref.periodic), [ref.gamma.map(BigInt)], ref.publicInputs.map(BigInt)
    );
    expect(out.length).to.equal(35);
  });

  it('every constraint evaluation matches the circuit byte-for-byte', async function () {
    const out = await air.evaluateTransition(
      fp2(ref.mainCur), fp2(ref.mainNxt), fp2(ref.auxCur), fp2(ref.auxNxt),
      fp2(ref.periodic), [ref.gamma.map(BigInt)], ref.publicInputs.map(BigInt)
    );
    for (let i = 0; i < 35; i++) {
      expect(BigInt(out[i].a0), `${LABEL(i)} a0`).to.equal(BigInt(ref.evaluations[i][0]));
      expect(BigInt(out[i].a1), `${LABEL(i)} a1`).to.equal(BigInt(ref.evaluations[i][1]));
    }
  });
});
