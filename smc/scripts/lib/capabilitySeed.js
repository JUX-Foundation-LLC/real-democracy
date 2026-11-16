'use strict';

/**
 * Capability seed — the permissive `voter` base role + the full permit set.
 *
 * Mirrors contracts/core/governance/Capabilities.sol. The reserved `voter` role
 * (VOTER_ROLE_ID) is implicit to every active VoteToken holder via CapabilityRegistry, so
 * seeding it with ALL permits makes every member able to do everything BY DEFAULT (egalitarian).
 * A jurisdiction RESTRICTS by voting a capability off this role; ELEVATES via other roles.
 *
 * Dependency-injected (`catalog`, `ethers`) so it is the shared core of both the deploy script
 * (scripts/seed_capabilities.js) and the Hardhat test.
 */

const VOTER_ROLE_ID = 1000; // == Capabilities.VOTER_ROLE_ID

// The full permit set (keys == Capabilities.sol). Seeded onto the voter base role → permissive.
const VOTER_BASE_CAPABILITIES = Object.freeze([
  // authoring (per type — separate buckets)
  'permit_rule_proposal',
  'permit_tag_proposal',
  'permit_initiative_proposal',
  'permit_amendments',
  'permit_jurisdiction_creation',
  'permit_invitation_creation',
  // voting (per governance type)
  'permit_proposal_voting',
  'permit_rule_voting',
  'permit_initiative_voting',
  'permit_tag_voting',
  'permit_amendment_voting',
  // tags + delegation
  'permit_tag_change',
  'permit_delegate',
  // ⛔ DELIBERATELY EXCLUDED — do NOT add here: permit_role_voting,
  //    permit_capability_voting. See ADMIN_GATED_CAPABILITIES below.
]);

/**
 * The deliberate EXCEPTION to permissive-default (B1 / ADMIN_VOTING_ACTIVATION_BACKEND).
 * Admin/role + capability control must start OFF in every fresh jurisdiction — matching
 * `vote_on_administrators` default NAY (#295). The base voter role gets `permit_role_voting`
 * ONLY via the lever: a majority-YAY on `vote_on_administrators` crosses the threshold and the
 * backend (CATALOG_ADMIN) grants the capability to VOTER_ROLE_ID (B2). #301 adds these keys to
 * Capabilities.sol; without this guard a well-meaning "sync the seed to Capabilities.sol" would
 * re-add them to the permissive base and every jurisdiction would start with admin-voting ON —
 * the opposite of the design. The runtime assertion below prevents that regression.
 */
const ADMIN_GATED_CAPABILITIES = Object.freeze([
  'permit_role_voting',
  'permit_capability_voting',
]);

// Narrow executor lanes are opt-in jurisdiction policy, never an implicit right of every voter and
// never a universal Admin power. A jurisdiction assigns these to one of its roles deliberately.
const DELEGATED_OPERATION_CAPABILITIES = Object.freeze([
  'permit_labor_rule_registration',
  'permit_governance_tag_registration',
]);

// Regression guard: the admin-gated capabilities must NEVER be in the permissive base seed.
for (const gated of ADMIN_GATED_CAPABILITIES) {
  if (VOTER_BASE_CAPABILITIES.includes(gated)) {
    throw new Error(
      `capabilitySeed: '${gated}' must NOT be in VOTER_BASE_CAPABILITIES — admin/role control ` +
      `starts OFF (matches vote_on_administrators NAY) and is granted only via the lever (B2).`
    );
  }
}
for (const delegated of DELEGATED_OPERATION_CAPABILITIES) {
  if (VOTER_BASE_CAPABILITIES.includes(delegated)) {
    throw new Error(
      `capabilitySeed: '${delegated}' must NOT be in VOTER_BASE_CAPABILITIES — delegated executor ` +
      `operations require an explicit per-jurisdiction role grant.`
    );
  }
}

/**
 * Seed (idempotently) the permissive `voter` base role for one jurisdiction in RoleCatalog.
 * `defineRole` upserts; `addCapability` is set-add (no-op if present) — safe to re-run.
 * @param catalog ethers RoleCatalog (signer = catalog admin or the jurisdiction governor)
 * @param jurisdictionId number
 * @param ethers hardhat ethers
 * @param {{ metadataHash?: string, log?: (m:string)=>void }} [opts]
 */
async function seedVoterCapabilities(catalog, jurisdictionId, ethers, opts = {}) {
  const log = opts.log || (() => {});
  const metadataHash = opts.metadataHash || ethers.ZeroHash;

  await (await catalog.defineRole(jurisdictionId, VOTER_ROLE_ID, 'voter', 'Voter', metadataHash)).wait();
  for (const name of VOTER_BASE_CAPABILITIES) {
    await (await catalog.addCapability(jurisdictionId, VOTER_ROLE_ID, ethers.id(name), name)).wait();
  }
  log(`j${jurisdictionId}: voter role (${VOTER_ROLE_ID}) seeded with ${VOTER_BASE_CAPABILITIES.length} permits (permissive default)`);
  return { jurisdictionId, roleId: VOTER_ROLE_ID, capabilities: VOTER_BASE_CAPABILITIES.length };
}

module.exports = {
  VOTER_ROLE_ID,
  VOTER_BASE_CAPABILITIES,
  ADMIN_GATED_CAPABILITIES,
  DELEGATED_OPERATION_CAPABILITIES,
  seedVoterCapabilities,
};
