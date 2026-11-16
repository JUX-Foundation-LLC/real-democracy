# Local Besu network

This directory contains a single-validator QBFT network suitable for protocol
development. It is independent of `laive-app`: any Ethereum-compatible client
can connect to its JSON-RPC endpoint.

## Start the node

From this directory:

```bash
./scripts/generate-keys.sh
docker compose up -d
```

The generated validator key is local runtime material. Never commit it or reuse
it for a shared environment.

Check the node:

```bash
curl -fsS -X POST http://127.0.0.1:8545 \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Deploy the protocol

From the repository root:

```bash
cp .env.example .env
# Set BESU_RPC_URL and a freshly generated BLOCKCHAIN_SIGNER_PRIVATE_KEY.
cd smc
npm install
npx hardhat compile
npx hardhat run scripts/deploy.js --network besu
```

Deployment addresses are local artifacts and should not be committed.

## Directory boundary

- `config/` contains publishable genesis and node configuration.
- `scripts/generate-keys.sh` generates local validator material.
- `data/`, validator private keys, deployment maps, and operational runbooks are
  excluded from the published mirror.

For the sanitized walkthrough, see [QUICKSTART.md](./QUICKSTART.md). For protocol
architecture, see [BESU_ARCHITECTURE.md](./BESU_ARCHITECTURE.md).

## Security

The local profile exposes unauthenticated RPC for development. Do not expose it
to an untrusted network. A shared deployment needs independent key custody,
network access control, monitoring, backups, and a governed validator-admission
process; those operational choices are deliberately not embedded here.
