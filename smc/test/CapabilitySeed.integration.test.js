const { expect } = require('chai');
const { ethers } = require('hardhat');
const { VOTER_BASE_CAPABILITIES, VOTER_ROLE_ID, seedVoterCapabilities } = require('../scripts/lib/capabilitySeed');

/**
 * Proves the capability seed delivers the permissive default: after seeding the `voter` role,
 * ANY active token holder (resolved via CapabilityRegistry, no per-member grant) holds every
 * permit — and a jurisdiction can restrict by removing one from the voter role.
 */
describe('Capability seed — permissive voter base (re-genesis seed)', function () {
  const J = 3;
  let deployer, catalog, registry, capReg;

  beforeEach(async function () {
    [deployer] = await ethers.getSigners();
    catalog = await (await ethers.getContractFactory('RoleCatalog')).deploy(deployer.address);
    await catalog.waitForDeployment();
    registry = await (await ethers.getContractFactory('JurisdictionRoleRegistry')).deploy(await catalog.getAddress(), deployer.address);
    await registry.waitForDeployment();
    capReg = await (await ethers.getContractFactory('CapabilityRegistry')).deploy(
      await catalog.getAddress(), await registry.getAddress(), deployer.address,
    );
    await capReg.waitForDeployment();
  });

  it('after seeding, a plain member holds EVERY permit (no per-member grant)', async function () {
    const res = await seedVoterCapabilities(catalog, J, ethers);
    expect(res.capabilities).to.equal(VOTER_BASE_CAPABILITIES.length);

    const anyVoter = ethers.id('some-voter-id');
    for (const name of VOTER_BASE_CAPABILITIES) {
      expect(await capReg.hasCapability(J, anyVoter, ethers.id(name))).to.equal(true);
    }
  });

  it('is idempotent (re-run safe)', async function () {
    await seedVoterCapabilities(catalog, J, ethers);
    await seedVoterCapabilities(catalog, J, ethers); // no revert
    expect(await capReg.hasCapability(J, ethers.id('v'), ethers.id('permit_rule_voting'))).to.equal(true);
  });

  it('restriction: removing a permit from the voter role denies it to plain members', async function () {
    await seedVoterCapabilities(catalog, J, ethers);
    await catalog.removeCapability(J, VOTER_ROLE_ID, ethers.id('permit_rule_proposal'));
    expect(await capReg.hasCapability(J, ethers.id('v'), ethers.id('permit_rule_proposal'))).to.equal(false);
    // unrelated permits still held
    expect(await capReg.hasCapability(J, ethers.id('v'), ethers.id('permit_rule_voting'))).to.equal(true);
  });

  it('an unseeded capability is denied', async function () {
    await seedVoterCapabilities(catalog, J, ethers);
    expect(await capReg.hasCapability(J, ethers.id('v'), ethers.id('permit_made_up'))).to.equal(false);
  });
});
