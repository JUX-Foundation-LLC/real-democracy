'use strict';

/**
 * Capability-registry wiring — the deploy-time counterpart to capabilitySeed.js.
 *
 * THE BUG THIS FIXES (deployed-contracts audit #315, finding C2): CapabilityRegistry was fully
 * built but NEVER deployed or wired, so every ballotbox + PublicDelegateVoteRegistry had
 * `capabilityRegistry == address(0)` and BaseRuleBallotBox._assertCapability /
 * _assertAnonymousCapability (and the TagBallotBox / delegate equivalents) were on-chain NO-OPS —
 * the entire on-chain permission model silently passed. Binding the registry is what turns
 * enforcement ON (the gates early-return while the address is zero).
 *
 * Every consumer (BaseRuleBallotBox subclasses, TagBallotBox, PublicDelegateVoteRegistry) exposes
 * the IDENTICAL pair `capabilityRegistry()` view + `setCapabilityRegistry(address)` (onlyGovernor /
 * onlyOwner). So one idempotent helper wires them all; the CALLER must hold each consumer's
 * governor/owner role (this helper does not change ownership).
 *
 * Dependency-injected (`consumer` is any ethers contract handle connected to the right signer) so it
 * is shared by the deploy scripts and the Hardhat wiring test — same code path proves enforcement.
 */

/**
 * Idempotently bind a CapabilityRegistry into one consumer. No tx if already bound to the same
 * address. The connected signer MUST be the consumer's governor/owner or the setter reverts.
 * @param consumer ethers contract handle (BaseRuleBallotBox subclass | TagBallotBox | PublicDelegateVoteRegistry)
 * @param {string} capRegAddress deployed CapabilityRegistry address
 * @param {{ label?: string, log?: (m:string)=>void }} [opts]
 * @returns {Promise<boolean>} true if a tx was sent (newly wired), false if already correct
 */
async function ensureCapabilityRegistry(consumer, capRegAddress, opts = {}) {
  const log = opts.log || (() => {});
  const label = opts.label || 'consumer';
  if (!capRegAddress) throw new Error('ensureCapabilityRegistry: capRegAddress required');

  const current = String(await consumer.capabilityRegistry());
  if (current.toLowerCase() === String(capRegAddress).toLowerCase()) {
    log(`${label}: capabilityRegistry already ${capRegAddress}`);
    return false;
  }
  await (await consumer.setCapabilityRegistry(capRegAddress)).wait();
  log(`${label}: capabilityRegistry -> ${capRegAddress}`);
  return true;
}

module.exports = { ensureCapabilityRegistry };
