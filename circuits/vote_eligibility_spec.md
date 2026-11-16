# Vote Eligibility Circuit Spec (Draft)

## Scope
Minimal binary vote circuit for a single proposal with private eligibility.

## Proof System
Target: STARK
Language: Cairo (Starknet toolchain)

## Public Inputs
- proposal_id
- eligibility_root (Merkle root of voter secrets)
- nullifier (prevents double voting)

## Private Inputs
- voter_secret
- merkle_proof[] (path for eligibility_root)
- merkle_index
- vote_choice (0 or 1)

## Constraints
1. Merkle proof validates voter_secret is in eligibility_root.
2. vote_choice is in {0,1}.
3. nullifier = Hash(voter_secret, proposal_id).

## Outputs
- Proof + public inputs only (no plaintext identity or vote intent beyond vote_choice).

## Notes
- vote_choice is private; proof validates it without revealing the value.
- Hash function must be consistent across circuit and verifier (e.g., Poseidon
  or a STARK-friendly hash).

## Hash + Merkle Layout (Concrete Draft)

Hash function:
- Use a STARK-friendly hash (e.g., Poseidon or Rescue-Prime).
- Notation: H(a, b) for a 2-to-1 hash.

Leaf format:
- leaf = H(voter_secret, 0)
- voter_secret is a random field element generated on the client.

Merkle tree:
- Binary Merkle tree with fixed depth D.
- Each internal node = H(left, right).
- eligibility_root is the root after hashing all leaves.

Merkle proof format:
- merkle_proof[] is an array of sibling nodes of length D.
- merkle_index is the leaf index (0..2^D-1) used to order siblings.

Nullifier format:
- nullifier = H(voter_secret, proposal_id)

## Client Secret Handling
- Derive voter_secret locally using WebAuthn.
- The client never sends voter_secret to the backend or chain.
- The client sends only the proof and public inputs.

## WebAuthn-Based Secret Lifecycle
- Enrollment: user registers a passkey (WebAuthn) on their device.
- Derivation: user signs a challenge; client derives voter_secret from the
  signature using a KDF.
- Use: voter_secret is used only to build proofs on the client.
- Backend: receives proof + public inputs only, never the secret or vote.

## Binding WebAuthn Keys to VoteTokens (Draft)
- During enrollment, the client registers a WebAuthn credential and sends the
  public key (or credential id) to the backend.
- Backend ties the credential id to the user account and its VoteToken id.
- EligibilityRoot includes the hashed credential id (or a hash of the public
  key) instead of a wallet address.
- The client proves membership using the WebAuthn-derived voter_secret.

Preference: strict device binding
- Use credential id hash for eligibility leaves.
- Device rebinds require manual reauthentication and staff review.
- Users can log in without a bound device, but voting and delegation require
  a bound credential.

Leaf format (updated):
- leaf = H(credential_id_hash, voter_secret)
- credential_id_hash is stored server-side and included in eligibility tree.

## PWA + WebAuthn Infrastructure (Draft)
- PWA registers a WebAuthn credential using `navigator.credentials.create`.
- Store credential id and public key in backend (never the private key).
- For proof generation, prompt `navigator.credentials.get` to sign a challenge.
- Derive voter_secret = KDF(signature, proposal_id) to avoid cross-proposal
  linkage while keeping a stable identity root.
- Cache eligibility_root in the PWA for the current proposal window.

## Test Vectors (Placeholder)
- proposal_id: 1
- eligibility_root: <to be generated>
- voter_secret: <to be generated>
- nullifier: Hash(voter_secret, proposal_id)
- vote_choice: 1
