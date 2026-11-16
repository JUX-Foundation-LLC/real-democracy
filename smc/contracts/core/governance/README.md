# On-Chain Role Authority

Modular, governable, on-chain role authority that mirrors the backend's
per-jurisdiction roles and is destined to be controlled entirely by democratic
on-chain votes. Built so the democracy can eventually run **without** access to
our backend: the chain is the source of truth, the backend becomes an indexer.

## The permanence tiering (why this exists)

Roles are split by how often they change, so we never overload the chain:

| Tier | Roles | Cadence | On-chain model |
|------|-------|---------|----------------|
| **Governance** | `admin`, `proposer`, `token_guardian` | rare, high-stakes | per-grant in `JurisdictionRoleRegistry`, granted by vote |
| **Operational / show** | `staff`, `rfid_writer`, `cashier`, `tech`, `emcee`, `stage_tools` | ephemeral (revoked at show end) | **one roster checkpoint per show** (merkle root via `checkpointRegistry`) — *designed next, not built here* |

The backend's safe fallbacks (`user_jurisdictions.role`, `user_show_role_assignments`)
remain authoritative until the chain loop is fully wired, and stay as the
liveness fallback when chain reads fail (by design).

## Contracts (this directory)

- **`RoleCatalog.sol`** — per-jurisdiction namespace: `(jurisdictionId, roleId) →
  { key, name, active }` plus a governable set of capability keys
  (`bytes32`, e.g. `keccak256("appoint_staff")`). The same numeric id can mean
  different things in different jurisdictions; capabilities are the on-chain
  truth of *what a role can do*. Human titles ultimately live in the backend.
  Edited by a per-jurisdiction governor or `CATALOG_ADMIN_ROLE` (backend signer
  during bootstrap).
- **`JurisdictionRoleRegistry.sol`** — the governance-tier grant ledger, keyed by
  the **stable** `(jurisdictionId, voterId)` (survives custody handover). Emits
  `RoleGranted`/`RoleRevoked` so any indexer can build a read-model (e.g.
  `user_role_token_bindings`). Grant authority per jurisdiction:
  `jurisdictionGovernor[jid]` (a `RoleBallotBox`/executor) **or** any
  `ROLE_MANAGER_ROLE` holder (backend signer, for bootstrap).
- **`RoleBallotBox.sol`** — democratic granting, mirroring `RuleBallotBox`. A
  ballot proposes "grant/revoke roleId R for voterId V"; active VoteToken
  holders vote; on simple-majority the governor publishes → calls the registry.
  Wired as the registry's per-jurisdiction governor.

## Grant authority & bootstrap

While the foundation holds custody of every wallet, the backend (the box's
governor) casts each custodial token's support vote to pass a grant, then
publishes — **role grants flow through the vote from day one**. As third parties
self-custody, they cast their own votes; the mechanism is unchanged. Authority
migrates from backend → governance per jurisdiction simply by reassigning the
governor (no redeploy). Governance can later vote *new* contracts onto the chain.

## Deploy & test (dev Besu)

Deployed as step **1b** of `scripts/deploy-all-dev.sh` (addresses written to
`deployments.dev.json`: `roleCatalog`, `jurisdictionRoleRegistry`,
`roleBallotBoxes` map). Manually:

```sh
docker exec vote_dev-smc sh -c 'cd /app && DEPLOYMENTS_FILE=deployments.dev.json \
  JURISDICTION_IDS=3,4 npx hardhat run scripts/deploy_role_registry.js --network besu'
docker exec vote_dev-smc sh -c 'cd /app && DEPLOYMENTS_FILE=deployments.dev.json \
  npx hardhat run scripts/test_role_registry.js --network besu'
```

`test_role_registry.js` proves: per-jurisdiction catalog isolation + capabilities,
the bootstrap direct-grant path with catalog validation, and a full
`RoleBallotBox` vote → publish → registry-grant in an isolated test jurisdiction.

## Backend indexing loop — DONE (proven on dev)

`backend/src/services/proposals/watchers/roleRegistryWatcher.js` indexes the
registry's `JurisdictionRoleGranted`/`JurisdictionRoleRevoked` and the catalog's
`RoleDefined`/`CapabilityAdded`/… into:
- the **public, identity-free mirror** in the ballotbox/crypto DB
  (`chain_role_grants` keyed by `voter_id`, `chain_role_catalog` with plaintext
  meaning), written via the `vote_ballotbox_writer` role
  (`BALLOTBOX_WRITER_DATABASE_URL`; tables in ballotbox migration 008);
- the **private read-model** `user_role_token_bindings` (resolving
  `voter_id → user` via `invitation_token_mints`).

`roleAuthorityService.holdsRole()` provides the fallback chain (live chain →
ballotbox mirror → core). `admin.js`'s grant endpoint mirrors grants on-chain
(`grantRoleOnChain`, bootstrap = ROLE_MANAGER direct grant).

> Note: registry events are `JurisdictionRoleGranted/Revoked` (the bare
> `RoleGranted/Revoked` names collide with inherited AccessControl events).

## Not built yet (next phases)

1. **Show-roster checkpoint tier** — ephemeral show/staff roles as one merkle
   root per show via `checkpointRegistry`, expiring with the show.
2. **Governance handoff** — reassign each `jurisdictionGovernor` from the backend
   signer to a vote-outcome executor; fold role ballots into the existing
   `RuleBallotBox`/zk-merkle anonymous voting path.
