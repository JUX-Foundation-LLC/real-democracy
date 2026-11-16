// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGroth16VoteVerifier {
    function verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[5] calldata publicSignals
    ) external view returns (bool);
}

/**
 * @title AnonymousVoteVerifier
 * @notice On-chain gate for Groth16 anonymous votes. Wraps the snarkjs-
 *         generated VoteVerifier (pairing check) and enforces the ballot
 *         policy around it: a per-ballot Merkle root must be registered, and
 *         each nullifier may be spent at most once per ballot. The vote
 *         choice is a public signal of the proof, so a valid proof cannot be
 *         replayed to cast a different choice, and a leaked nullifier cannot
 *         be replayed against a different ballot (externalNullifier scoping).
 *
 *         This is the SNARK successor to ProposalManager's transparent
 *         merkle-proof path. It is intentionally standalone so it can be
 *         adopted ballot-by-ballot (proposals, then rules) without migrating
 *         the existing contract.
 *
 *         publicSignals layout (must match circuits/vote.circom main):
 *           [0] merkleRoot
 *           [1] externalNullifier  (ballot scope: proposal/rule id hash)
 *           [2] voteChoice
 *         nullifierHash is the circuit's public OUTPUT, passed separately.
 */
contract AnonymousVoteVerifier {
    IGroth16VoteVerifier public immutable verifier;
    address public governor;

    // externalNullifier => registered merkle root
    mapping(uint256 => uint256) public ballotRoot;
    // externalNullifier => nullifierHash => spent (replay-dead once spent)
    mapping(uint256 => mapping(uint256 => bool)) public nullifierSpent;
    // externalNullifier => nullifierHash => is the LIVE head of a vote chain
    mapping(uint256 => mapping(uint256 => bool)) public nullifierHead;

    event GovernorUpdated(address indexed previousGovernor, address indexed newGovernor);
    event BallotRootRegistered(uint256 indexed externalNullifier, uint256 merkleRoot);
    event AnonymousVoteVerified(
        uint256 indexed externalNullifier,
        uint256 indexed nullifierHash,
        uint256 prevNullifierHash,
        uint256 voteChoice
    );

    modifier onlyGovernor() {
        require(msg.sender == governor, "AnonymousVoteVerifier: only governor");
        _;
    }

    constructor(address verifierAddress, address initialGovernor) {
        require(verifierAddress != address(0), "AnonymousVoteVerifier: verifier required");
        verifier = IGroth16VoteVerifier(verifierAddress);
        governor = initialGovernor == address(0) ? msg.sender : initialGovernor;
        emit GovernorUpdated(address(0), governor);
    }

    function updateGovernor(address newGovernor) external onlyGovernor {
        require(newGovernor != address(0), "AnonymousVoteVerifier: zero governor");
        emit GovernorUpdated(governor, newGovernor);
        governor = newGovernor;
    }

    /// Register (or rotate) the eligibility root for a ballot. Rotating the
    /// root is how the voter set is updated between voting sessions.
    function registerBallotRoot(uint256 externalNullifier, uint256 merkleRoot) external onlyGovernor {
        require(merkleRoot != 0, "AnonymousVoteVerifier: invalid root");
        ballotRoot[externalNullifier] = merkleRoot;
        emit BallotRootRegistered(externalNullifier, merkleRoot);
    }

    /**
     * @notice Verify and record an anonymous vote, with rotating-nullifier
     *         vote-change support. Permissionless: the voter, their custodian,
     *         or a blind relayer may submit.
     *
     *         First cast: prevNullifierHash == 0 — fresh nullifier spent and
     *         set as the live head. Vote change: prevNullifierHash must be the
     *         current live head (proving the same chained identity), it is
     *         retired, and the new nullifier becomes the head. Because each
     *         revision spends a different nullifier, a captured nullifier is
     *         already spent and cannot be replayed; computing the next one
     *         requires the secret identity (VoteToken-bound).
     */
    function castAnonymousVote(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256 merkleRoot,
        uint256 externalNullifier,
        uint256 voteChoice,
        uint256 nullifierHash,
        uint256 prevNullifierHash
    ) external {
        require(ballotRoot[externalNullifier] == merkleRoot, "AnonymousVoteVerifier: unknown ballot root");
        require(!nullifierSpent[externalNullifier][nullifierHash], "AnonymousVoteVerifier: nullifier already spent");

        if (prevNullifierHash == 0) {
            // First cast in this voter's chain — nothing to retire.
        } else {
            require(
                nullifierHead[externalNullifier][prevNullifierHash],
                "AnonymousVoteVerifier: prev nullifier is not the live head"
            );
            nullifierHead[externalNullifier][prevNullifierHash] = false;
        }

        // snarkjs public-signal order: outputs first, then public inputs:
        // [nullifierHash, merkleRoot, externalNullifier, voteChoice, prevNullifierHash]
        bool ok = verifier.verifyProof(
            a, b, c,
            [nullifierHash, merkleRoot, externalNullifier, voteChoice, prevNullifierHash]
        );
        require(ok, "AnonymousVoteVerifier: invalid proof");

        nullifierSpent[externalNullifier][nullifierHash] = true;
        nullifierHead[externalNullifier][nullifierHash] = true;
        emit AnonymousVoteVerified(externalNullifier, nullifierHash, prevNullifierHash, voteChoice);
    }

    function isNullifierSpent(uint256 externalNullifier, uint256 nullifierHash) external view returns (bool) {
        return nullifierSpent[externalNullifier][nullifierHash];
    }

    function isLiveHead(uint256 externalNullifier, uint256 nullifierHash) external view returns (bool) {
        return nullifierHead[externalNullifier][nullifierHash];
    }
}
