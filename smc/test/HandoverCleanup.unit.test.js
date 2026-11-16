const { expect } = require('chai');
const { cleanupHandoverOperators } = require('../scripts/lib/cleanupHandoverOperators');

describe('Handover temporary membership cleanup', function () {
  function fixture(fail = [], staysActive = []) {
    const active = new Set([1n, 2n]);
    const attempted = [], removed = [];
    const token = {
      connect: () => ({ selfDisable: async id => {
        attempted.push(id);
        if (fail.includes(id)) throw Error('simulated failed transaction');
        return { wait: async () => { if (!staysActive.includes(id)) active.delete(id); } };
      } }),
      isActive: async id => active.has(id),
      activeTokenCount: async () => BigInt(active.size),
    };
    const operators = [1n, 2n].map(tokenId => ({ tokenId, jurisdictionId: 10, wallet: {}, keyFile: `key-${tokenId}` }));
    return { token, operators, electorates: new Map([[10, 0n]]), log: () => {}, removeKey: key => removed.push(key), attempted, removed };
  }
  it('tries all operators, retains the failed key, and blocks continuation on disable failure', async function () {
    const f = fixture([1n]);
    let continued = false, error;
    try { await cleanupHandoverOperators(f); continued = true; } catch (e) { error = e; }
    expect(continued).to.equal(false);
    expect(error.message).to.include('cleanup unresolved').and.include('key-1').and.include('electorate 1, expected 0');
    expect(f.attempted).to.deep.equal([1n, 2n]);
    expect(f.removed).to.deep.equal(['key-2']);
  });
  it('does not trust a successful receipt when the token remains active', async function () {
    const f = fixture([], [1n]);
    let error;
    try { await cleanupHandoverOperators(f); } catch (e) { error = e; }
    expect(error.message).to.include('cleanup unresolved');
    expect(f.removed).to.deep.equal(['key-2']);
  });
  it('requires the original electorate even when every known token is disabled', async function () {
    const f = fixture(); f.electorates.set(10, 1n);
    let error;
    try { await cleanupHandoverOperators(f); } catch (e) { error = e; }
    expect(error.message).to.include('electorate 0, expected 1');
  });
  it('allows continuation only after all tokens are inactive and electorate restored', async function () {
    const f = fixture(); await cleanupHandoverOperators(f);
    expect(f.removed).to.deep.equal(['key-1', 'key-2']);
  });
});
