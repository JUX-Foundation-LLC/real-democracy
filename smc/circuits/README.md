# Anonymous Vote ZK Circuit (Groth16)

Post-quantum-**ready ballot anonymity** for laive voting. This is the
SNARK-native successor to the transparent keccak merkle-proof path in
`ProposalManager`. A voter proves *I am in the eligible set and my nullifier
is correctly derived* without revealing **which** voter they are.

## Why this and not the legacy path

The legacy path (`cryptographyService.js`) reveals a keccak commitment on
chain — a chain observer who watched credential issuance can correlate it back
to an identity. This path uses **Poseidon** (SNARK-friendly) inside a Groth16
proof, so nothing identity-linking touches the chain. The vote choice is bound
into the proof (can't be replayed with a different choice) and the nullifier is
scoped per-ballot via `externalNullifier` (a leaked nullifier can't be replayed
against another ballot).

## The honest quantum claim

- **Ballot anonymity is post-quantum-ready**: Poseidon + keccak Merkle trees +
  STARK-swappable proof interface. A future quantum adversary still cannot
  unmask who voted for what.
- **Account signatures are NOT post-quantum** (ECDSA — true of all EVM chains).
  End-to-end quantum-proof is not claimable by anyone on an EVM today.
- Groth16 today; the verifier interface (`verifyProof(a,b,c,publicSignals)`)
  is identical for a STARK swap-in later.

## VoteToken-bound identity

`identityNullifier` / `identityTrapdoor` are derived off-circuit from a
**deterministic signature** by the wallet holding the VoteToken
(`sign(skVoteToken, "laive-vote-identity-v1")`). Only the token holder can
reproduce them, so producing a valid nullifier requires actual custody — the
rotating/token-bound nullifier property, without ECDSA inside the circuit.

## Build (run once on the host)

Prereqs: [`circom` 2.x](https://docs.circom.io/getting-started/installation/),
then `npm i` in `smc/` (snarkjs + circomlib are in devDependencies).

```bash
cd vote/smc
./scripts/build_zk_circuit.sh
```

Outputs in `circuits/build/`: `vote.wasm` + `vote_final.zkey` (proving — copy
to the backend), `vote_verification_key.json` (JS verify), and
`contracts/core/governance/VoteVerifier.sol` (the on-chain pairing verifier).

> The script downloads a Powers-of-Tau file and runs a phase-2 contribution.
> For production, replace the single contribution with a multi-party ceremony.

## Wire-up after building

1. Copy `circuits/build/vote.wasm`, `vote_final.zkey`,
   `vote_verification_key.json` to the backend ZK artifact dir (default
   `smc/circuits/build`, override with `ZK_ARTIFACT_DIR`). `zkVoteService`
   auto-detects them; until present it reports `isAvailable() === false` and
   the legacy path stays active.
2. Deploy `VoteVerifier.sol`, then `AnonymousVoteVerifier.sol` pointing at it.
3. Per ballot: `registerBallotRoot(externalNullifier, poseidonRoot)` from the
   eligibility set, then relay proofs via `castAnonymousVote(...)`.

## Pieces

| File | Role |
|---|---|
| `circuits/vote.circom` | the circuit (depth-20 tree, ≤~1M voters/ballot) |
| `scripts/build_zk_circuit.sh` | compile + Groth16 setup + export verifier |
| `backend/.../zkVoteService.js` | Poseidon identity, proof gen/verify, calldata |
| `contracts/.../AnonymousVoteVerifier.sol` | on-chain policy: roots + nullifier spend |
| `contracts/.../VoteVerifier.sol` | generated pairing verifier (after build) |

## Ballotbox mirror

Yes — the same Poseidon commitments + a root can be stored in the ballotbox
mirror DB, giving an auditable off-chain record using the *same* cryptographic
objects as the chain. Build it once the circuit artifacts exist; the
`buildTreeAndProof` root is the value to mirror.
