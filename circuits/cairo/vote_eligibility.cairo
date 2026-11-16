// Vote eligibility circuit (draft)
// TODO: Implement in Cairo once hashing + Merkle proof helpers are chosen.

// Public inputs:
// - proposal_id
// - eligibility_root
// - nullifier

// Private inputs:
// - voter_secret
// - merkle_proof[]
// - merkle_index
// - vote_choice (0 or 1)

// Constraints:
// 1) merkle_proof validates voter_secret in eligibility_root
// 2) vote_choice in {0,1}
// 3) nullifier = Hash(voter_secret, proposal_id)
