Tests: running and notes

This folder contains unit and integration tests for the core smart contracts.

Quick run (from repo root):

1) Install JS deps (project-level):

```bash
cd vote/smc
npm install
```

2) Run tests (uses Hardhat network in-process):

```bash
npx hardhat test
```

Notes and important checks:
- The `deployCoreContracts` fixture under `test/helpers/fixture.js` deploys `VoteToken`, `ProposalManager` and `VoteTokenMinter` and grants roles as `scripts/deploy.js` would. It writes a `test/deployments.json` file for inspection.
- Tests include a `MockReceiver` contract used to exercise an `onERC721Received` callback to surface potential reentrancy issues in `_issueTokenInternal` (see `VoteToken.sol` lines ~311-352).
- Some integration tests are scaffolding and may require adding a Merkle helper to fully exercise `castAnonymousVote` flows.

CI:
- Add a GitHub Actions job that runs `cd vote/smc && npm ci && npx hardhat test`.
