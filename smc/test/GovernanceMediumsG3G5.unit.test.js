const { expect } = require('chai');
const { ethers } = require('hardhat');

// Governance audit mediums: G3 (S9 externalNullifier uniqueness), G4 (S4 governed registry rebind),
// G5 (S8 anonymous jurisdiction-wide capability gate).
describe('Governance mediums — G3/G4/G5', function () {
  let deployer, gov, other;
  const J = 7n;
  const Z = ethers.ZeroAddress;

  beforeEach(async function () {
    [deployer, gov, other] = await ethers.getSigners();
  });

  // ── G3 (S9): an externalNullifier may belong to at most one rule ──────────────────────────
  describe('G3 — externalNullifier uniqueness', function () {
    let box; const r1 = ethers.id('rule-1'); const r2 = ethers.id('rule-2');
    beforeEach(async function () {
      box = await (await ethers.getContractFactory('BooleanRuleBallotBox'))
        .deploy(deployer.address, J, deployer.address, Z, 6000, Z);
      await box.registerRule(r1, ethers.id('m1'), '0x');
      await box.registerRule(r2, ethers.id('m2'), '0x');
    });
    it('rejects binding the same ext to a second rule, allows rebinding the same rule', async function () {
      await box.setRuleExternalNullifier(r1, 12345);
      await expect(box.setRuleExternalNullifier(r2, 12345)).to.be.revertedWith('RuleBox: externalNullifier already used');
      await box.setRuleExternalNullifier(r1, 12345); // re-bind same rule → ok (idempotent)
      await box.setRuleExternalNullifier(r1, 67890); // move r1 to a new scope → releases 12345
      await box.setRuleExternalNullifier(r2, 12345); // now r2 may take the freed scope
      expect(await box.ruleExternalNullifier(r2)).to.equal(12345n);
    });
    it('rejects a zero externalNullifier', async function () {
      await expect(box.setRuleExternalNullifier(r1, 0)).to.be.revertedWith('RuleBox: externalNullifier required');
    });
  });

  // ── G4 (S4): once governed, only the governor binds — REGISTRAR is locked out ──────────────
  describe('G4 — governed registry rebind', function () {
    let registry, box; const rk = ethers.id('rk');
    beforeEach(async function () {
      registry = await (await ethers.getContractFactory('JurisdictionRuleRegistry')).deploy(deployer.address);
      box = await (await ethers.getContractFactory('BooleanRuleBallotBox'))
        .deploy(deployer.address, J, deployer.address, Z, 6000, Z);
    });
    it('REGISTRAR may bind before a governor is set; is locked out after', async function () {
      await registry.bindRuleBox(J, rk, await box.getAddress()); // deployer = REGISTRAR, no governor yet
      await registry.setJurisdictionGovernor(J, gov.address);
      await expect(registry.bindRuleBox(J, rk, await box.getAddress())) // deployer is REGISTRAR, not governor
        .to.be.revertedWithCustomError(registry, 'NotAuthorized');
      await registry.connect(gov).bindRuleBox(J, rk, await box.getAddress()); // governor may
    });
  });

  // ── G5 (S8): the anonymous path honors the jurisdiction-wide PERMIT_RULE_VOTING gate ──────
  describe('G5 — anonymous capability gate', function () {
    it('reverts an anonymous vote when the capability gate denies (before proof verification)', async function () {
      const box = await (await ethers.getContractFactory('BooleanRuleBallotBox'))
        .deploy(deployer.address, J, deployer.address, Z, 6000, Z);
      const rk = ethers.id('gated-rule');
      await box.registerRule(rk, ethers.id('m'), '0x');
      await box.setAnonymousVerifier(other.address); // any non-zero (we revert before calling it)
      await box.setRuleExternalNullifier(rk, 999);
      const gate = await (await ethers.getContractFactory('MockCapabilityGate')).deploy();
      await gate.setAllow(false); // jurisdiction has voted rule-voting OFF the base role
      await box.setCapabilityRegistry(await gate.getAddress());

      await expect(
        box.castVoteAnonymous(rk, [0, 0], [[0, 0], [0, 0]], [0, 0], 0, [1], 1, 0)
      ).to.be.revertedWith('RuleBox: rule voting not permitted');
    });
  });
});
