const fs = require('fs');
const path = require('path');

async function dumpEvents(provider, contract, eventNames, outFile) {
  const fromBlock = 0;
  const toBlock = 'latest';
  const filter = {
    address: contract.address,
    fromBlock,
    toBlock,
  };
  const logs = await provider.send('eth_getLogs', [filter]);
  const out = logs || [];
  fs.writeFileSync(path.join(process.cwd(), outFile || 'test-output/events.json'), JSON.stringify(out, null, 2));
  return out;
}

module.exports = { dumpEvents };
