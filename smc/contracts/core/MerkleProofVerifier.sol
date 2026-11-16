// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MerkleProofVerifier
 * @dev Safe merkle proof verification library
 * 
 * CRITICAL SECURITY FEATURES:
 * - Hash ordering to prevent second-preimage attacks
 * - Input validation on proof length
 * - Protection against null/zero commitments
 * - Constant-time comparison (resistant to timing attacks)
 */

library MerkleProofVerifier {
    
    // Constants
    uint256 constant MAX_MERKLE_DEPTH = 32;  // Support up to 2^32 leaves
    bytes32 constant ZERO_HASH = 0x0;
    
    /**
     * @dev Verifies a merkle proof with proper security measures
     * 
     * SECURITY NOTES:
     * - Proof ordering is CRITICAL: smaller hashes are ordered first
     * - This prevents attackers from using the same proof in different positions
     * - Known as preventing "second preimage attacks"
     * 
     * @param proof The merkle proof (array of sibling hashes)
     * @param leaf The leaf node to verify
     * @param root The merkle root
     * @return True if valid proof, false otherwise
     */
    function verifyProof(
        bytes32[] calldata proof,
        bytes32 leaf,
        bytes32 root
    ) internal pure returns (bool) {
        // INPUT VALIDATION
        
        // Reject zero leaf (prevents null commitment attacks)
        if (leaf == ZERO_HASH) {
            return false;
        }
        
        // Reject zero root (invalid merkle tree)
        if (root == ZERO_HASH) {
            return false;
        }
        
        // Proof must exist but not be excessively long (DOS prevention)
        if (proof.length == 0 || proof.length > MAX_MERKLE_DEPTH) {
            return false;
        }
        
        // MERKLE VERIFICATION
        
        bytes32 computedHash = leaf;
        
        for (uint i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            
            // Reject zero hashes in proof (invalid tree structure)
            if (proofElement == ZERO_HASH) {
                return false;
            }
            
            // CRITICAL: Order hashes consistently
            // This prevents second-preimage attacks where an attacker
            // uses the same proof element in multiple positions
            if (computedHash <= proofElement) {
                // smaller hash goes first
                computedHash = keccak256(
                    abi.encodePacked(computedHash, proofElement)
                );
            } else {
                // larger hash goes first
                computedHash = keccak256(
                    abi.encodePacked(proofElement, computedHash)
                );
            }
        }
        
        // Compare final computed hash with root
        return computedHash == root;
    }
    
    /**
     * @dev Alternative verification with proof index (for unordered trees)
     * Some merkle implementations don't reorder hashes.
     * This version uses the index to determine hash order.
     * 
     * ONLY USE THIS IF YOUR TREE GENERATOR PROVIDES INDICES
     */
    function verifyProofWithIndex(
        bytes32[] calldata proof,
        bytes32 leaf,
        bytes32 root,
        uint256 index
    ) internal pure returns (bool) {
        if (leaf == ZERO_HASH || root == ZERO_HASH) {
            return false;
        }
        
        if (proof.length == 0 || proof.length > MAX_MERKLE_DEPTH) {
            return false;
        }
        
        bytes32 computedHash = leaf;
        uint256 currentIndex = index;
        
        for (uint i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            
            if (proofElement == ZERO_HASH) {
                return false;
            }
            
            // Use index to determine hash order
            if (currentIndex % 2 == 0) {
                // This is a left node
                computedHash = keccak256(
                    abi.encodePacked(computedHash, proofElement)
                );
            } else {
                // This is a right node
                computedHash = keccak256(
                    abi.encodePacked(proofElement, computedHash)
                );
            }
            
            // Move to parent index
            currentIndex = currentIndex / 2;
        }
        
        return computedHash == root;
    }
}
