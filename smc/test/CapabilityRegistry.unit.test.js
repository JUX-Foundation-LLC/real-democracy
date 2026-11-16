const { expect } = require('chai');
const { ethers } = require('hardhat');

/**
 * The on-chain capability resolver. Proves the permissive-default model:
 * a plain voter inherits the jurisdiction's `voter` base-role capabilities (no per-member grant);
 * restriction = a capability absent from the voter role; elevation = an explicitly-granted role.
 */
describe('CapabilityRegistry', function () {
  const J = 3;
  const K = 9; // a different jurisdiction
  const VOTER_ROLE_ID = 1000; // Capabilities.VOTER_ROLE_ID
  const PROPOSER_ROLE_ID = 2;
  const CAP_RULE_VOTING = ethers.id('permit_rule_voting');
  const CAP_RULE_PROPOSAL = ethers.id('permit_rule_proposal');
  const alice = ethers.id('alice-voterId');
  const bob = ethers.id('bob-voterId');

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

    // permissive base: the voter role carries rule-voting (but NOT proposal-creation, to show restriction)
    await catalog.defineRole(J, VOTER_ROLE_ID, 'voter', 'Voter', ethers.ZeroHash);
    await catalog.addCapability(J, VOTER_ROLE_ID, CAP_RULE_VOTING, 'permit_rule_voting');
  });

  it('permissive base: a plain voter (no explicit roles) inherits the voter-role capabilities', async function () {
    expect(await capReg.hasCapability(J, alice, CAP_RULE_VOTING)).to.equal(true);
  });

  it('restriction: a capability NOT on the voter role is denied to a plain voter', async function () {
    expect(await capReg.hasCapability(J, alice, CAP_RULE_PROPOSAL)).to.equal(false);
  });

  it('elevation: an explicitly-granted role carries a capability the base lacks', async function () {
    await catalog.defineRole(J, PROPOSER_ROLE_ID, 'proposer', 'Proposer', ethers.ZeroHash);
    await catalog.addCapability(J, PROPOSER_ROLE_ID, CAP_RULE_PROPOSAL, 'permit_rule_proposal');
    await registry.grantRoles(J, alice, [PROPOSER_ROLE_ID]);

    expect(await capReg.hasCapability(J, alice, CAP_RULE_PROPOSAL)).to.equal(true); // elevated
    expect(await capReg.hasCapability(J, bob, CAP_RULE_PROPOSAL)).to.equal(false);  // not elevated
  });

  it('revoking the elevated role removes the capability', async function () {
    await catalog.defineRole(J, PROPOSER_ROLE_ID, 'proposer', 'Proposer', ethers.ZeroHash);
    await catalog.addCapability(J, PROPOSER_ROLE_ID, CAP_RULE_PROPOSAL, 'permit_rule_proposal');
    await registry.grantRoles(J, alice, [PROPOSER_ROLE_ID]);
    expect(await capReg.hasCapability(J, alice, CAP_RULE_PROPOSAL)).to.equal(true);

    await registry.revokeRoles(J, alice, [PROPOSER_ROLE_ID]);
    expect(await capReg.hasCapability(J, alice, CAP_RULE_PROPOSAL)).to.equal(false);
  });

  it('per-jurisdiction isolation: voter-role caps in J do not apply in K', async function () {
    expect(await capReg.hasCapability(K, alice, CAP_RULE_VOTING)).to.equal(false);
  });

  it('requireCapability reverts when denied', async function () {
    await expect(capReg.requireCapability(J, alice, CAP_RULE_PROPOSAL))
      .to.be.revertedWith('CapReg: capability denied');
  });
});
