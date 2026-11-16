# Real Democracy

**An on-chain liquid-democracy voting protocol** — the chain, smart contracts, and
zero-knowledge circuits that power [JUX Foundation](https://juxfoundation.com)'s voting
system. Fork it, run it, and build your own governance surfaces against it.

> **This repository is a published mirror.** It is generated from a private mono-repo by an
> automated export that strips secrets, operational runbooks, and internal history. It has
> **no long-form git history by design** and is **force-pushed on each release** (see
> [CONTRIBUTING.md](./CONTRIBUTING.md)). It is a faithful snapshot of the protocol layer — not
> the day-to-day development repo.

---

## What's in here

| Path | What it is |
|------|-----------|
| `besu/` | [Hyperledger Besu](https://besu.hyperledger.org/) network config — a QBFT proof-of-authority chain. Genesis, validator config template, and node scripts. |
| `smc/` | Solidity smart contracts (the voting, delegation, token, and role machinery) + a Hardhat project. |
| `smc/circuits/`, `circuits/` | Circuit sources (Circom + [Cairo](https://www.cairo-lang.org/)) for eligibility and vote proofs. |
| `zk/vote_stark/` | STARK proving/verification for anonymous vote tallies. **Audited standalone** — see below. |

> **🔬 The zk-STARK verifier is published as its own audit repo:
> [github.com/JUX-Foundation-LLC/vote-stark](https://github.com/JUX-Foundation-LLC/vote-stark).**
> That repo (Rust/Winterfell) carries the crate plus its full adversarial-audit trail and is
> **open for external cryptographer review** — the canonical home for auditing the verifier. The
> copy here mirrors the same code in the context of the chain.

## What is *not* here (and why)

This mirror deliberately excludes: validator **private keys**, chain **state/data**,
operational **runbooks** (prod cut, node onboarding), internal design docs, prod data exports,
and build artifacts. A forker generates their own keys and their own chain — see `.env.example`.

Validator admission is governed separately from application membership. Operators
should provide their own private networking, key custody, monitoring, and host
hardening; those operational systems are intentionally outside this source export.

## Quick start (run against a local chain)

```bash
# 1. Configuration
cp .env.example .env      # then edit — set your own RPC + a freshly generated signer key

# 2. Stand up a local Besu node (dev)
cd besu && ./scripts/generate-keys.sh   # generates YOUR validator key (never commit it)
docker compose up -d

# 3. Compile + deploy the contracts
cd ../smc && npm install
npx hardhat compile
npx hardhat run scripts/deploy.js --network besu
```

The included `smc/hardhat.config.js` reads the RPC endpoint and signer from the
environment. The export contains no signer or validator private key.

## Build *on* the chain, not just in this repo

The whole point of the clean split: **you do not need JUX's application code to build against this
protocol.** Point any client — your own frontend, a bot, another DAO — at a node running this
chain config and interact with the deployed contracts. This repo is the substrate; what you build
on top is yours.

## License

[GNU AGPL-3.0](./LICENSE). If you run a modified version of this software as a network service, you
must make your modified source available to its users. Democracy stays open.
