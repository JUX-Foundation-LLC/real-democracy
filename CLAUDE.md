# CLAUDE.md — real-democracy

Guidance for AI coding agents (and a fast orientation for humans) working in this repository.

## What this repository is

**real-democracy** is the chain layer of the JUX Foundation's liquid-democracy voting system:
a private Hyperledger Besu network, the governance smart contracts, and the zero-knowledge
anonymity layer. It is published as a snapshot mirror of a private monorepo — see
`CONTRIBUTING.md` for how changes flow back upstream.

There is no application backend or frontend here; this repo is the on-chain substrate they run on.

## Layout

| Path | What it is |
|---|---|
| `besu/` | Besu network configs (IBFT2), docker-compose, architecture docs. Start here to run a chain. |
| `smc/` | Solidity contracts (Hardhat project). `contracts/core/` is the forkable reference set: VoteToken, ballot boxes (Rule/Role/Initiative), registries, PTS. |
| `circuits/` | ZK circuit sources for anonymous voting. |
| `zk/` | The STARK verifier work (Rust/Winterfell) and proof tooling. Also published standalone as `vote-stark` for audit. |

## Dev environment stand-up (fresh machine)

1. **Prereqs:** Docker + docker-compose, Node 20+, and (for `zk/`) a Rust toolchain.
2. **Chain up:** follow `besu/QUICKSTART.md` — it boots a single-validator IBFT2 Besu node with
   free gas on `http://localhost:8545`. Config templates live under `besu/config/`.
3. **Contracts:**
   ```bash
   cd smc
   npm install
   # Signer is env-only by design — no key literals in the repo. For a local dev chain:
   export BESU_PRIVATE_KEY=<a dev key you generated / the tutorial key from QUICKSTART>
   npx hardhat compile
   npx hardhat test
   ```
4. **Verify:** `npx hardhat test` green + `curl -s -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8545` returns a block number.

## Rules of the road

- **Never commit key material.** Signers come from environment variables only. If a change needs
  a key literal to work, the change is wrong.
- **Never commit deploy artifacts** (`deployments*.json`, chain `data/`, exports) — they are
  per-environment, not source.
- **Anonymity is a contract-level invariant.** Vote provenance must not be traceable through
  anything you add — no name↔address mappings, no plaintext vote↔voter links, in code, tests,
  fixtures, or comments.
- **`smc/contracts/core/` is the reference.** Prefer extending it over forking siblings; keep
  storage layouts append-only on anything already deployed.
- **Tests before PR:** `npx hardhat compile && npx hardhat test` for contracts; `cargo test` under
  `zk/` if you touched it.

## Contributing

Public PRs are welcome — see `CONTRIBUTING.md`. This mirror is force-push-published from the
private monorepo on a cadence; maintainers port accepted public PRs upstream before each publish
so nothing is orphaned. Security findings: see `SECURITY.md` in the `vote-stark` repo or open a
private vulnerability report here.
