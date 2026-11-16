const fs = require('fs');

// Try every token, retain unresolved keys, and never let partial cleanup look successful.
async function cleanupHandoverOperators({ token, operators, electorates, log = console.log, removeKey = fs.unlinkSync }) {
  const failures = [];
  for (const op of operators) {
    try {
      await (await token.connect(op.wallet).selfDisable(op.tokenId)).wait();
      if (await token.isActive(op.tokenId)) throw new Error('token remains active after disable receipt');
      removeKey(op.keyFile);
      log(`operator token #${op.tokenId} verified inactive (j${op.jurisdictionId})`);
    } catch (_) {
      failures.push(`token #${op.tokenId} in j${op.jurisdictionId}; recovery key: ${op.keyFile}`);
    }
  }
  for (const [jid, before] of electorates) {
    try {
      const after = await token.activeTokenCount(jid);
      if (after !== before) failures.push(`j${jid} electorate ${after}, expected ${before}`);
    } catch (_) {
      failures.push(`j${jid} electorate could not be verified`);
    }
  }
  if (failures.length) throw new Error(`Handover cleanup unresolved; STOP before any further step. ${failures.join('; ')}. Reconcile Transfer logs and disable unresolved tokens before resuming.`);
}
module.exports = { cleanupHandoverOperators };
