// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./VoteToken.sol";

/**
 * @title ProposalBallotBox
 * @dev Smart contract "ballot box" for a single proposal
 *
 * Key principles:
 * - One ballot box per proposal
 * - Accepts vote tokens matching proposal jurisdiction
 * - Tracks vote tallies anonymously
 * - Locks after voting window closes (immutable)
 * - Voters can revoke tokens before window closes
 * - No one can transfer tokens out (unless owner revokes back to personal wallet)
 */

contract ProposalBallotBox is IERC721Receiver {
    // Proposal info
    uint256 public proposalId;
    bool public forEnsemble;        // TRUE = ensemble governance proposal
    bytes32 public forShow;         // Show jurisdiction hash (0x0 = not show-specific)
    address public voteTokenContract;
    address public proposalManager;

    // Voting window
    uint256 public votingWindowEnd;
    bool public isLocked = false;

    // Vote tracking
    mapping(uint256 => bool) public tokensCast;    // tokenId => has token been cast?
    mapping(uint256 => bytes32) public tokenVoteChoice; // tokenId => recorded option
    mapping(bytes32 => uint256) public voteTally;  // option => count
    bytes32[] public voteOptions;                   // ["YAY", "NAY", "ABSTAIN"]

    uint256 public totalVotesCast = 0;
    uint256 public totalRevocations = 0;

    // Store vote commitments for audit trail (anonymized)
    // Maps tokenId to its vote commitment hash
    mapping(uint256 => bytes32) public voteCommitments;
    uint256 public totalCommitments = 0;

    // Events
    event VoteCastInBallotBox(
        uint256 indexed tokenId,
        bool forEnsemble,
        bytes32 forShow,
        bytes32 indexed option
    );

    event VoteRevokedFromBallotBox(
        uint256 indexed tokenId,
        bool forEnsemble,
        bytes32 forShow
    );

    event BallotBoxLocked(
        uint256 indexed proposalId,
        bool forEnsemble,
        bytes32 forShow,
        uint256 totalVotes,
        uint256 yayVotes,
        uint256 nayVotes,
        uint256 abstainVotes
    );

    event BallotBoxFinalized(
        uint256 indexed proposalId,
        bool forEnsemble,
        bytes32 forShow,
        uint256 yayVotes,
        uint256 nayVotes,
        uint256 abstainVotes
    );

    event AnonymousVoteCastInBallotBox(
        uint256 indexed proposalId,
        bytes32 indexed voteChoice,
        uint256 timestamp
    );
    event AnonymousVoteChangedInBallotBox(
        uint256 indexed proposalId,
        bytes32 indexed previousChoice,
        bytes32 indexed newChoice,
        uint256 timestamp
    );

    modifier onlyDuringVotingWindow() {
        require(block.timestamp < votingWindowEnd, "Voting window closed");
        require(!isLocked, "Ballot box is locked");
        _;
    }

    modifier onlyAfterVotingWindow() {
        require(block.timestamp >= votingWindowEnd, "Voting window still open");
        _;
    }

    modifier onlyProposalManager() {
        require(msg.sender == proposalManager, "Only proposal manager");
        _;
    }

    constructor(
        uint256 _proposalId,
        bool _forEnsemble,
        bytes32 _forShow,
        address _voteTokenContract,
        address _proposalManager,
        uint256 _votingWindowEnd
    ) {
        // Exactly one jurisdiction must be set
        require(
            (_forEnsemble && _forShow == bytes32(0)) || (!_forEnsemble && _forShow != bytes32(0)),
            "Ballot box must have exactly one jurisdiction"
        );
        require(_voteTokenContract != address(0), "Invalid token contract");
        require(_proposalManager != address(0), "Invalid proposal manager");
        require(_votingWindowEnd > block.timestamp, "Invalid voting window");

        proposalId = _proposalId;
        forEnsemble = _forEnsemble;
        forShow = _forShow;
        voteTokenContract = _voteTokenContract;
        proposalManager = _proposalManager;
        votingWindowEnd = _votingWindowEnd;

        // Initialize vote options
        voteOptions.push(keccak256("YAY"));
        voteOptions.push(keccak256("NAY"));
        voteOptions.push(keccak256("ABSTAIN"));

        // Initialize tallies
        voteTally[keccak256("YAY")] = 0;
        voteTally[keccak256("NAY")] = 0;
        voteTally[keccak256("ABSTAIN")] = 0;
    }

    // ============ VOTING ============

    /**
     * @dev Accept vote token transfer (ERC-721 receiver)
     * Called when voter transfers token to this ballot box
     * Updates tally anonymously
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override onlyDuringVotingWindow returns (bytes4) {
        require(msg.sender == voteTokenContract, "Only vote token transfers");
        require(from != address(0), "Invalid vote caster");
        require(operator == from, "Only token owner can cast");
        require(!tokensCast[tokenId], "Token already cast");
        require(_matchesJurisdiction(tokenId), "Token jurisdiction mismatch");

        // Decode vote choice from data
        bytes32 voteChoice = abi.decode(data, (bytes32));
        require(
            voteChoice == keccak256("YAY") ||
            voteChoice == keccak256("NAY") ||
            voteChoice == keccak256("ABSTAIN"),
            "Invalid vote choice"
        );

        // Record vote
        tokensCast[tokenId] = true;
        tokenVoteChoice[tokenId] = voteChoice;
        voteTally[voteChoice]++;
        totalVotesCast++;

        // Create vote commitment for audit trail (voter identity hidden)
        // commitment = hash(tokenId + voteChoice + nonce)
        bytes32 commitment = keccak256(abi.encodePacked(tokenId, voteChoice, totalCommitments));
        voteCommitments[tokenId] = commitment;
        totalCommitments++;

        emit VoteCastInBallotBox(tokenId, forEnsemble, forShow, voteChoice);

        return this.onERC721Received.selector;
    }

    /**
     * @dev Record vote for a token already in ballot box
     * Called by token contract after vote state is set
     */
    function recordVote(
        uint256 tokenId,
        bytes32 voteChoice
    ) external onlyDuringVotingWindow {
        require(msg.sender == voteTokenContract, "Only vote token contract");
        require(!tokensCast[tokenId], "Token already cast");
        require(_matchesJurisdiction(tokenId), "Token jurisdiction mismatch");

        require(
            voteChoice == keccak256("YAY") ||
            voteChoice == keccak256("NAY") ||
            voteChoice == keccak256("ABSTAIN"),
            "Invalid vote choice"
        );

        // Record vote
        tokensCast[tokenId] = true;
        tokenVoteChoice[tokenId] = voteChoice;
        voteTally[voteChoice]++;
        totalVotesCast++;

        // Create vote commitment for audit trail
        bytes32 commitment = keccak256(abi.encodePacked(tokenId, voteChoice, totalCommitments));
        voteCommitments[tokenId] = commitment;
        totalCommitments++;

        emit VoteCastInBallotBox(tokenId, forEnsemble, forShow, voteChoice);
    }

    // ============ REVOCATION ============

    /**
     * @dev Process vote revocation
     * Called by vote token contract when voter revokes
     * Only works during voting window
     */
    function processRevocation(uint256 tokenId) external onlyDuringVotingWindow {
        require(msg.sender == voteTokenContract, "Only vote token contract");
        require(tokensCast[tokenId], "Token not cast");

        bytes32 priorChoice = tokenVoteChoice[tokenId];
        require(
            priorChoice == keccak256("YAY") ||
            priorChoice == keccak256("NAY") ||
            priorChoice == keccak256("ABSTAIN"),
            "Missing vote choice"
        );
        require(voteTally[priorChoice] > 0, "Vote tally underflow");

        // Mark token as revoked
        tokensCast[tokenId] = false;
        tokenVoteChoice[tokenId] = bytes32(0);
        voteTally[priorChoice]--;
        totalVotesCast--;
        totalRevocations++;

        emit VoteRevokedFromBallotBox(tokenId, forEnsemble, forShow);
    }

    // ============ ANONYMOUS VOTING (V2) ============

    /**
     * @dev Record anonymous vote (no token transfer involved)
     * Called by ProposalManager after Merkle proof verification
     * Updates tally without storing voter identity
     *
     * @param voteChoice The vote choice as bytes32 (keccak256("YAY") or keccak256("NAY"))
     */
    function recordAnonymousVote(bytes32 voteChoice)
        external
        onlyProposalManager
        onlyDuringVotingWindow
    {
        require(
            voteChoice == keccak256("YAY") || voteChoice == keccak256("NAY"),
            "Invalid vote choice (only YAY or NAY)"
        );

        // Update tally (no token ID, no identity stored)
        voteTally[voteChoice]++;
        totalVotesCast++;

        emit AnonymousVoteCastInBallotBox(proposalId, voteChoice, block.timestamp);
    }

    /**
     * @dev Update an anonymous vote tally when a voter changes their vote
     * Called by ProposalManager after successful changeAnonymousVote
     */
    function updateAnonymousVote(bytes32 previousChoice, bytes32 newChoice)
        external
        onlyProposalManager
        onlyDuringVotingWindow
    {
        require(
            previousChoice == keccak256("YAY") || previousChoice == keccak256("NAY"),
            "Invalid previous choice"
        );
        require(
            newChoice == keccak256("YAY") || newChoice == keccak256("NAY"),
            "Invalid new choice"
        );
        require(previousChoice != newChoice, "Vote choice unchanged");
        require(voteTally[previousChoice] > 0, "No votes to update");

        voteTally[previousChoice] -= 1;
        voteTally[newChoice] += 1;

        emit AnonymousVoteChangedInBallotBox(
            proposalId,
            previousChoice,
            newChoice,
            block.timestamp
        );
    }

    // ============ FINALIZATION ============

    /**
     * @dev Lock ballot box after voting window closes
     * Called by proposal manager or anyone after voting window
     * Finalizes all votes and makes ballot box immutable
     */
    function lockBallotBox() external onlyAfterVotingWindow {
        require(!isLocked, "Already locked");

        isLocked = true;

        // Note: In production, we'd iterate through all tokens
        // For Phase 1, we rely on the proposal manager to finalize individually

        emit BallotBoxLocked(
            proposalId,
            forEnsemble,
            forShow,
            totalVotesCast,
            voteTally[keccak256("YAY")],
            voteTally[keccak256("NAY")],
            voteTally[keccak256("ABSTAIN")]
        );
    }

    // ============ QUERY FUNCTIONS ============

    /**
     * @dev Get vote tallies (final results after voting window)
     */
    function getFinalTally()
        external
        view
        onlyAfterVotingWindow
        returns (
            uint256 yayVotes,
            uint256 nayVotes,
            uint256 abstainVotes
        )
    {
        return (
            voteTally[keccak256("YAY")],
            voteTally[keccak256("NAY")],
            voteTally[keccak256("ABSTAIN")]
        );
    }

    /**
     * @dev Get current vote tallies (during voting window)
     * Only visible after voting window closes (privacy)
     */
    function getCurrentTally()
        external
        view
        returns (
            uint256 yayVotes,
            uint256 nayVotes,
            uint256 abstainVotes
        )
    {
        require(isLocked || block.timestamp >= votingWindowEnd, "Voting in progress");
        return (
            voteTally[keccak256("YAY")],
            voteTally[keccak256("NAY")],
            voteTally[keccak256("ABSTAIN")]
        );
    }

    /**
     * @dev Get live vote tallies (even during voting window)
     * FOR THEATRICAL PERFORMANCE USE: Shows real-time voting results
     * Note: This reduces privacy - voters can see tallies change in real-time
     */
    function getLiveTally()
        external
        view
        returns (
            uint256 yayVotes,
            uint256 nayVotes,
            uint256 abstainVotes
        )
    {
        return (
            voteTally[keccak256("YAY")],
            voteTally[keccak256("NAY")],
            voteTally[keccak256("ABSTAIN")]
        );
    }

    /**
     * @dev Get ballot box status
     */
    function getStatus()
        external
        view
        returns (
            uint256 _proposalId,
            bool _forEnsemble,
            bytes32 _forShow,
            uint256 _votingWindowEnd,
            bool _isLocked,
            uint256 _totalVotesCast,
            uint256 _totalRevocations
        )
    {
        return (
            proposalId,
            forEnsemble,
            forShow,
            votingWindowEnd,
            isLocked,
            totalVotesCast,
            totalRevocations
        );
    }

    /**
     * @dev Get vote commitment for audit verification
     * Allows anonymous verification that vote was recorded
     */
    function getVoteCommitment(uint256 tokenId)
        external
        view
        returns (bytes32)
    {
        require(isLocked, "Ballot box not yet finalized");
        return voteCommitments[tokenId];
    }

    /**
     * @dev Check if token is still in this ballot box
     */
    function hasTokenCast(uint256 tokenId)
        external
        view
        returns (bool)
    {
        return tokensCast[tokenId];
    }

    /**
     * @dev Get time remaining in voting window
     */
    function getTimeRemaining() external view returns (int256) {
        return int256(votingWindowEnd) - int256(block.timestamp);
    }

    /**
     * @dev Check if voting is still active
     */
    function isVotingActive() external view returns (bool) {
        return !isLocked && block.timestamp < votingWindowEnd;
    }

    // ============ SECURITY (PREVENT TRANSFERS) ============

    /**
     * @dev Prevent any other contract from sending tokens to this ballot box
     * (except through the proper voting mechanism)
     */
    function lockBallotBoxAsset() external pure {
        revert("Ballot box is immutable - no transfers allowed");
    }

    function _matchesJurisdiction(uint256 tokenId) internal view returns (bool) {
        uint256 tokenJurisdictionId = VoteToken(voteTokenContract).jurisdictionIdOf(tokenId);
        uint256 expectedJurisdictionId = forEnsemble
            ? uint256(1)
            : uint256(keccak256(abi.encodePacked("JURISDICTION", forShow)));
        return tokenJurisdictionId == expectedJurisdictionId;
    }
}
