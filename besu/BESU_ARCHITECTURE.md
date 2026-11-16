# Besu Architecture Plan (Draft)

## Purpose
Define a permissioned Besu network for Read Democracy that supports:
- Public read access to chain state.
- Role-gated write access by jurisdiction participants.
- Validator participation by paid Admins.
- Auditable transparency via ballotbox database and optional public anchors.

## Roles (per jurisdiction)
- Admin
  - Runs validator node.
  - Mints and distributes VoteTokens.
  - Manages jurisdiction policy and membership.
- Proposer
  - Can create proposals in their jurisdiction.
  - May be gated by Admin approval or policy rules.
- Voter
  - Holds VoteToken and can vote in allowed jurisdictions.

## Network Layers
- Consensus access
  - Validator set is permissioned and controlled by Admins.
  - New validators join via explicit approval process.
- Execution access
  - Smart contracts enforce who can create proposals or vote.
  - VoteToken ownership and jurisdiction rules gate write actions.
- Network access
  - Public RPC read endpoint is open to anyone.
  - Write endpoint is restricted by contract rules and rate limiting.

## RPC Exposure Model
- Public read RPC
  - Anyone can query chain state.
  - Read-only APIs allowed.
- Write RPC
  - Transactions are allowed, but contract logic enforces role checks.
  - Additional protection via rate limiting and tx pool controls.

## Gas and Transaction Policy
- Goal: keep user actions free while preventing spam.
- Standard EVM requires the sender to pay gas.
- To sponsor user gas safely, use one of:
  - Relayer model: users sign messages off-chain, backend submits tx.
  - Account abstraction (EIP-4337): paymaster sponsors gas for eligible users.
- A centralized "gas wallet" cannot pay gas for arbitrary users unless a relayer
  or account abstraction flow is used.

## Account Abstraction (EIP-4337) Overview
- Replaces direct EOA transactions with a UserOperation sent to a bundler.
- A smart contract wallet validates the UserOperation (signature, rules).
- A paymaster can sponsor gas if the user meets eligibility checks.
- Bundlers submit the final transaction to the chain.

Practical implications for Read Democracy:
- Lets VoteToken holders submit transactions without holding native gas.
- Eligibility checks can be enforced by the paymaster (e.g., VoteToken ownership).
- Still has network hops (user -> bundler -> chain), but avoids your backend as a
  mandatory relay.

## Privacy and Anonymity Considerations
- Relayer flow: your backend sees signed payloads unless the vote is encrypted
  or zk-proved end-to-end.
- Account abstraction: bundlers can observe UserOperations, so privacy depends
  on how vote data is encoded.
- If vote intent must remain private, on-chain calldata should not reveal it.
  This typically requires zk-snark proofs or commit/reveal style flows.
- Passkey device binding should be treated as a privacy boundary: votes and
  custodial wallet actions must require a live passkey challenge so backend
  operators cannot act on behalf of users without their device.
- Provide explicit rebind flows (staff reset and user self-reset) to avoid
  weakening the binding while still supporting device loss and upgrades.

## Privacy-Preserving Vote Flows (Auditable + Anonymous)

Option A: Commit/Reveal (simpler, weaker privacy)
- Commit: user submits a hash of (vote + nonce). Chain records commitment.
- Reveal: user later reveals vote + nonce; contract verifies the hash.
- Pros: simple, cheap, auditable.
- Cons: reveal ties vote to address unless combined with mixers or ZK.

Option B: ZK-SNARK Proof of Valid Vote (preferred)
- User generates a proof that:
  - They are an eligible voter (possess VoteToken or membership proof).
  - Their vote is valid (within allowed options).
  - The vote is bound to a specific proposal and epoch.
- On-chain calldata contains only the proof + public inputs, not the vote.
- Pros: strong privacy, public verifiability.
- Cons: more complex circuits, heavier tooling.

Option C: Encrypted Votes + Threshold Decryption
- User submits encrypted vote; on-chain stores ciphertext.
- A committee performs threshold decryption at close.
- Pros: strong privacy, no ZK circuit.
- Cons: introduces trusted committee and key management risks.

Recommendation for Read Democracy:
- Use ZK-SNARK voting proofs for end-to-end privacy.
- Publish Merkle roots of eligible voters and vote commitments in ballotbox.
- Anchor those roots periodically to a public chain for tamper-evident audit.

## ZK Voting Flow (Concrete Draft)

Public inputs (on-chain):
- proposalId
- epoch or vote window id
- eligibilityRoot (Merkle root of eligible voters)
- nullifier (prevents double voting)

Private inputs (off-chain):
- Vote choice
- Voter secret key
- Merkle proof of eligibility
- Random nonce

Proof guarantees:
- Voter is in the eligibility tree.
- Vote choice is valid for the proposal.
- Nullifier is derived from voter secret + proposal, ensuring one vote.

On-chain verification:
- Contract checks proof with public inputs.
- Rejects if nullifier already used.
- Records vote commitment or encrypted tally increment.

Audit loop:
- Ballotbox stores eligibility roots and proof metadata.
- Optional public chain anchors bind roots to timestamps.

## PWA-Friendly ZK-STARK Plan (Browser-Only)

Goal: generate proofs on the client without revealing vote intent or identity
to the backend, while keeping the chain permissioned.

Client (PWA):
- Loads circuit + proving key (cached, versioned).
- Builds a proof locally using WebAssembly and Web Workers.
- Sends only: proof, public inputs (proposalId, epoch, eligibilityRoot), and
  a nullifier. No plaintext vote leaves the device.

Backend:
- Verifies the proof off-chain.
- Submits a transaction to Besu with the proof + public inputs.
- Does not receive plaintext vote intent.

Chain:
- Verifies the proof and enforces nullifier uniqueness.
- Updates the proposal tally state.

Custodial wallet linkage:
- Use a wallet ownership proof that does not reveal identity (e.g., signature
  over a challenge, then turned into a zero-knowledge membership proof).
- EligibilityRoot is derived from the current authorized VoteToken holders.

Practical constraints:
- Proof generation on mobile can be slow; keep circuits minimal.
- Proof artifacts can be large; use versioned CDN delivery and cache.
- Backgrounded PWAs can be suspended; UX must handle long proofs.

## Phase 1 Implementation Plan (Draft)

Step 1: Minimal Circuit Design (vote privacy + eligibility)
- Public inputs:
  - proposalId
  - epoch (or vote window id)
  - eligibilityRoot (Merkle root of eligible voters)
  - nullifier (prevents double voting)
- Private inputs:
  - voteChoice
  - voterSecret (derived locally, never sent)
  - merkleProof (path proving membership in eligibilityRoot)
  - nonce (randomness to avoid linkage)
- Constraints:
  - merkleProof validates voterSecret membership in eligibilityRoot.
  - voteChoice is within allowed options.
  - nullifier = Hash(voterSecret, proposalId, epoch)
- On-chain rules:
  - Reject if nullifier already used.
  - Store vote commitment or tally increment.

Deliverable for Step 1:
- Circuit spec document listing inputs, constraints, and outputs.
- Test vectors for a single proposal with 2-3 vote options.

Current draft spec: [vote/circuits/vote_eligibility_spec.md](../circuits/vote_eligibility_spec.md)

## WebAuthn UX + Admin Ops (Planned)
- Staff-mediated rebind endpoint and UI status.
- Credential revocation UI with audit trail.
- Reusable WebAuthn modal hook for non-admin pages.

## Spam Control with "Free Gas" for VoteToken Holders
- Open RPC plus zero gas invites DoS even if contract writes revert.
- A paymaster can sponsor gas only for eligible VoteToken holders.
- Ineligible users still pay gas or are rejected by the paymaster.
- This gives "free" usage to verified users while keeping spam costly.

## Transparency and Auditability
- Ballotbox database
  - Public read access to Merkle roots and proposal data.
  - Enables independent verification.
- Optional public anchors
  - Periodic root anchoring to a public chain (e.g., Gnosis).
  - Batching reduces costs.

## Trust Model (Early Phase)
- Single-admin or small-admin validator set is expected initially.
- Trust and transparency come from:
  - Public ballotbox snapshots.
  - Deterministic Merkle proofs.
  - Optional public chain anchors.

## Open Questions
- Which public chain (if any) is used for anchors.
- Desired write flow: direct RPC vs relayer vs account abstraction.
- Validator admission process and revocation policy.

## Next Steps
- Specify RPC endpoints and reverse proxy rules.
- Define relayer or account abstraction design.
- Draft validator onboarding and governance process.
