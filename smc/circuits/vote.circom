pragma circom 2.1.6;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/mux1.circom";

// ---------------------------------------------------------------------------
// Poseidon Merkle inclusion proof (Semaphore-style).
// Proves a leaf sits in a tree of the given depth WITHOUT revealing which
// leaf it is — only the root is public.
// ---------------------------------------------------------------------------
template MerkleInclusion(depth) {
    signal input leaf;
    signal input pathElements[depth];
    signal input pathIndices[depth]; // 0 = current node is left, 1 = right
    signal output root;

    component hashers[depth];
    component mux[depth];

    signal hashes[depth + 1];
    hashes[0] <== leaf;

    for (var i = 0; i < depth; i++) {
        // pathIndices must be boolean
        pathIndices[i] * (1 - pathIndices[i]) === 0;

        mux[i] = MultiMux1(2);
        mux[i].c[0][0] <== hashes[i];
        mux[i].c[0][1] <== pathElements[i];
        mux[i].c[1][0] <== pathElements[i];
        mux[i].c[1][1] <== hashes[i];
        mux[i].s <== pathIndices[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== mux[i].out[0];
        hashers[i].inputs[1] <== mux[i].out[1];

        hashes[i + 1] <== hashers[i].out;
    }

    root <== hashes[depth];
}

// ---------------------------------------------------------------------------
// Anonymous vote circuit.
//
// Identity model (Semaphore-derived, VoteToken-bound):
//   The voter's `identityNullifier` and `identityTrapdoor` are derived
//   off-circuit from a DETERMINISTIC signature by the wallet holding the
//   VoteToken (e.g. sign(skVoteToken, "laive-vote-identity")). Only the
//   token holder can reproduce them, so producing a valid nullifier
//   requires actual VoteToken custody — the rotating/token-bound nullifier
//   property the design calls for, without ECDSA inside the circuit.
//
//   secret      = Poseidon(identityNullifier, identityTrapdoor)
//   commitment  = Poseidon(secret)              -> Merkle leaf (eligibility)
//   nullifierHash = Poseidon(externalNullifier, identityNullifier)
//
// Public signals: merkleRoot, nullifierHash, externalNullifier, voteChoice.
//   - externalNullifier scopes a nullifier to ONE ballot (proposal/rule), so
//     a leaked nullifier can't be replayed against a different ballot.
//   - voteChoice is bound into the proof (voteChoiceSquared constraint) so a
//     valid proof cannot be reused to cast a different choice.
// ---------------------------------------------------------------------------
// Rotating nullifier per revision:
//   nullifier(r) = Poseidon(externalNullifier, identityNullifier, r)
// Each vote change spends a FRESH nullifier (rev incremented), so a captured
// nullifier is already spent (replay-dead) and computing the next requires
// the secret identity (VoteToken-bound). The proof reveals both the current
// nullifier (being spent now) and the previous one (chaining anchor); the
// contract enforces that `prevNullifierHash` is the live head before
// accepting `nullifierHash` as the new head — preventing forks/replays.
template Vote(depth) {
    // Private
    signal input identityNullifier;
    signal input identityTrapdoor;
    signal input pathElements[depth];
    signal input pathIndices[depth];
    signal input revision;          // 0 for first cast, +1 per change

    // Public
    signal input merkleRoot;
    signal input externalNullifier;
    signal input voteChoice;
    signal input prevNullifierHash;  // 0 when revision == 0

    // Public outputs
    signal output nullifierHash;

    // secret + commitment (leaf)
    component secretHasher = Poseidon(2);
    secretHasher.inputs[0] <== identityNullifier;
    secretHasher.inputs[1] <== identityTrapdoor;

    component leafHasher = Poseidon(1);
    leafHasher.inputs[0] <== secretHasher.out;

    // Merkle inclusion against the public root
    component inclusion = MerkleInclusion(depth);
    inclusion.leaf <== leafHasher.out;
    for (var i = 0; i < depth; i++) {
        inclusion.pathElements[i] <== pathElements[i];
        inclusion.pathIndices[i] <== pathIndices[i];
    }
    inclusion.root === merkleRoot;

    // Current rotating nullifier = Poseidon(ext, id, revision)
    component nullifierHasher = Poseidon(3);
    nullifierHasher.inputs[0] <== externalNullifier;
    nullifierHasher.inputs[1] <== identityNullifier;
    nullifierHasher.inputs[2] <== revision;
    nullifierHash <== nullifierHasher.out;

    // Previous nullifier = Poseidon(ext, id, revision-1), enforced to match
    // the public prevNullifierHash. For revision 0, prev must be 0 and the
    // chaining check is skipped.
    component isFirst = IsZero();
    isFirst.in <== revision;

    component prevHasher = Poseidon(3);
    prevHasher.inputs[0] <== externalNullifier;
    prevHasher.inputs[1] <== identityNullifier;
    prevHasher.inputs[2] <== revision - 1;

    // When first (revision==0): require prevNullifierHash == 0.
    // Otherwise: require prevNullifierHash == Poseidon(ext, id, revision-1).
    signal expectedPrev;
    expectedPrev <== (1 - isFirst.out) * prevHasher.out;
    prevNullifierHash === expectedPrev;

    // Bind the choice into the proof (anti-malleability). 0..255 covers
    // boolean/slider/plurality.
    component choiceRange = LessThan(16);
    choiceRange.in[0] <== voteChoice;
    choiceRange.in[1] <== 256;
    choiceRange.out === 1;

    signal voteChoiceSquared;
    voteChoiceSquared <== voteChoice * voteChoice;
}

// depth 20 => up to ~1,048,576 eligible voters per ballot
component main { public [merkleRoot, externalNullifier, voteChoice, prevNullifierHash] } = Vote(20);
