// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./VoteToken.sol";
import "./ProposalBallotBox.sol";
import "./MerkleProofVerifier.sol";

using Counters for Counters.Counter;

/**
 * @title ProposalManager
 * @dev Manages proposal lifecycle: creation → seconding → voting → finalization
 *
 * ProposalManager: ProposalManager.sol:1-800 — creates ballot boxes and (legacy flows) 
 * mints tokens on seconding; integrates with vote token contract passed at constructor.
 * This seems like a huge vulnerability? #TODO -Coi
 *
 * Key principles:
 * - Proposals start PENDING_SECOND (spam prevention)
 * - Require "second" from another voter before activation
 * - Upon seconding: creates ballot box, mints vote tokens
 * - Voting window is configurable per proposal
 * - Tags are admin-configurable (Phase 1), governance-configurable (Phase 2+)
 */

contract ProposalManager is Ownable {
    // Proposal states
    enum ProposalState {
        PENDING_SECOND,  // 0 - Awaiting second
        ACTIVE,          // 1 - Voting in progress
        CLOSED,          // 2 - Voting ended
        FINALIZED        // 3 - Results finalized
    }

    // Proposal data
    struct Proposal {
        uint256 id;
        address creator;           // Public identity
        address seconder;          // Public identity (once seconded)
        string title;
        string description;
        bool forEnsemble;          // TRUE = ensemble governance proposal
        bytes32 forShow;           // Show jurisdiction hash (0x0 = not show-specific)
        bytes32[] tags;            // Category tags
        uint256 createdAt;
        uint256 votingWindowEnd;
        ProposalState state;
        address ballotBox;         // Ballot box contract address
        bool finalized;
    }

    // Fixed tags for Phase 1
    bytes32[] public validTags;
    mapping(bytes32 => bool) public isValidTag;

    // Proposal tracking
    Counters.Counter private _proposalIdCounter;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => bool) public proposalExists;

    // Anonymous voting: Merkle root storage (for voter eligibility proofs)
    mapping(uint256 => bytes32) public proposalMerkleRoot;

    // Anonymous voting: Nullifier tracking (prevents double-voting)
    mapping(uint256 => mapping(bytes32 => bool)) public usedNullifiers;

    struct AnonymousVoteRecord {
        bytes32 nullifier;
        bytes32 voteChoice;
        bool exists;
    }

    // Anonymous voting: Track latest vote per commitment so users can change votes
    mapping(uint256 => mapping(bytes32 => AnonymousVoteRecord)) private anonymousVoteRecords;

    // Jurisdiction tracking (for queries)
    uint256[] public ensembleProposals;
    mapping(bytes32 => uint256[]) public showProposals;  // showHash => proposalIds

    // Vote token contract
    VoteToken public voteTokenContract;

    // Voting window configuration
    uint256 public defaultVotingWindowDays = 7; // Default: 1 week

    // Events
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed creator,
        string title,
        bool forEnsemble,
        bytes32 forShow,
        uint256 createdAt
    );

    event ProposalSeconded(
        uint256 indexed proposalId,
        address indexed seconder,
        uint256 votingWindowEnd
    );

    event VotingStarted(
        uint256 indexed proposalId,
        address ballotBox,
        uint256 votingWindowEnd
    );

    event VotingEnded(
        uint256 indexed proposalId,
        uint256 proposedVotes,
        uint256 yayVotes,
        uint256 nayVotes,
        uint256 abstainVotes
    );

    event ProposalFinalized(
        uint256 indexed proposalId,
        ProposalState finalState
    );

    event TagAdded(bytes32 indexed tag);
    event TagRemoved(bytes32 indexed tag);

    // Anonymous voting events
    event MerkleRootSet(uint256 indexed proposalId, bytes32 merkleRoot);
    event AnonymousVoteCast(
        uint256 indexed proposalId,
        bytes32 indexed nullifier,
        uint256 timestamp
    );
    event AnonymousVoteChanged(
        uint256 indexed proposalId,
        bytes32 indexed previousNullifier,
        bytes32 indexed newNullifier,
        uint256 timestamp,
        bytes32 oldChoice,
        bytes32 newChoice
    );

    event AnonymousVoteCastWithCapability(
        uint256 indexed proposalId,
        uint256 indexed delegatorId,
        uint256 indexed delegateId,
        bytes32 nullifier,
        bytes32 voteChoice,
        address capabilityPubkey
    );

    modifier validJurisdiction(bool forEnsemble, bytes32 forShow) {
        // Exactly one jurisdiction must be set
        require(
            (forEnsemble && forShow == bytes32(0)) || (!forEnsemble && forShow != bytes32(0)),
            "Proposal must have exactly one jurisdiction"
        );
        _;
    }

    modifier validProposal(uint256 proposalId) {
        require(proposalExists[proposalId], "Proposal does not exist");
        _;
    }

    constructor(address _voteTokenContract) Ownable() {
        require(_voteTokenContract != address(0), "Invalid token contract");
        voteTokenContract = VoteToken(_voteTokenContract);

        // Initialize Phase 1 tags
        _initializeTags();
    }

    // ============ TAG MANAGEMENT ============

    function _initializeTags() internal {
        bytes32[] memory tags = new bytes32[](11);
        tags[0] = keccak256("video-design");
        tags[1] = keccak256("lighting-design");
        tags[2] = keccak256("sound-design");
        tags[3] = keccak256("costume-design");
        tags[4] = keccak256("scenic-design");
        tags[5] = keccak256("cast");
        tags[6] = keccak256("directorial");
        tags[7] = keccak256("box-office");
        tags[8] = keccak256("marketing");
        tags[9] = keccak256("accounting");
        tags[10] = keccak256("legal");

        for (uint256 i = 0; i < tags.length; i++) {
            validTags.push(tags[i]);
            isValidTag[tags[i]] = true;
        }
    }

    function addTag(bytes32 tag) external onlyOwner {
        require(!isValidTag[tag], "Tag already exists");
        validTags.push(tag);
        isValidTag[tag] = true;
        emit TagAdded(tag);
    }

    function removeTag(bytes32 tag) external onlyOwner {
        require(isValidTag[tag], "Tag does not exist");
        isValidTag[tag] = false;
        // Note: Not removing from array to preserve indices
        emit TagRemoved(tag);
    }

    function getValidTags() external view returns (bytes32[] memory) {
        return validTags;
    }

    // ============ PROPOSAL CREATION ============

    /**
     * @dev Create a new proposal
     * Requires second from another voter before activation
     * Creator and seconder identities are public
     *
     * @param title Proposal title
     * @param description Proposal description
     * @param forEnsemble TRUE if ensemble governance proposal
     * @param forShow Show jurisdiction hash (0x0 if not show-specific)
     * @param tags Category tags
     * @param votingWindowDays Voting window duration in days
     */
    function createProposal(
        string memory title,
        string memory description,
        bool forEnsemble,
        bytes32 forShow,
        bytes32[] memory tags,
        uint256 votingWindowDays
    ) external validJurisdiction(forEnsemble, forShow) returns (uint256) {
        require(bytes(title).length > 0, "Title cannot be empty");
        require(bytes(title).length <= 255, "Title too long");
        require(tags.length > 0, "Must have at least one tag");
        require(tags.length <= 5, "Too many tags");
        require(votingWindowDays > 0 && votingWindowDays <= 90, "Invalid voting window");

        // Tag validation removed - will be added in Phase 2 governance layer

        uint256 proposalId = _proposalIdCounter.current();
        _proposalIdCounter.increment();

        proposals[proposalId] = Proposal({
            id: proposalId,
            creator: msg.sender,
            seconder: address(0),
            title: title,
            description: description,
            forEnsemble: forEnsemble,
            forShow: forShow,
            tags: tags,
            createdAt: block.timestamp,
            votingWindowEnd: 0, // Set when seconded
            state: ProposalState.PENDING_SECOND,
            ballotBox: address(0),
            finalized: false
        });

        proposalExists[proposalId] = true;

        // Track by jurisdiction for queries
        if (forEnsemble) {
            ensembleProposals.push(proposalId);
        } else {
            showProposals[forShow].push(proposalId);
        }

        emit ProposalCreated(proposalId, msg.sender, title, forEnsemble, forShow, block.timestamp);

        return proposalId;
    }

    // ============ SECONDING ============

    /**
     * @dev Second a proposal, activating it and starting voting
     * Requires second from another voter (spam prevention)
     * Creates ballot box and mints tokens upon seconding
     */
    function secondProposal(
        uint256 proposalId,
        uint256 votingWindowDays
    ) external validProposal(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        require(
            proposal.state == ProposalState.PENDING_SECOND,
            "Proposal already seconded or closed"
        );
        require(msg.sender != proposal.creator, "Creator cannot second own proposal");
        require(votingWindowDays > 0 && votingWindowDays <= 90, "Invalid voting window");

        // Set voting window
        proposal.votingWindowEnd = block.timestamp + (votingWindowDays * 1 days);
        proposal.seconder = msg.sender;
        proposal.state = ProposalState.ACTIVE;

        // Create ballot box for this proposal
        ProposalBallotBox ballotBox = new ProposalBallotBox(
            proposalId,
            proposal.forEnsemble,
            proposal.forShow,
            address(voteTokenContract),
            address(this),
            proposal.votingWindowEnd
        );

        proposal.ballotBox = address(ballotBox);

        // Emit voting started event
        emit ProposalSeconded(proposalId, msg.sender, proposal.votingWindowEnd);
        emit VotingStarted(proposalId, address(ballotBox), proposal.votingWindowEnd);
    }

    // ============ VOTING WINDOW MANAGEMENT ============

    /**
     * @dev Check if voting is still active for a proposal
     */
    function isVotingActive(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (bool)
    {
        Proposal storage proposal = proposals[proposalId];
        return proposal.state == ProposalState.ACTIVE && block.timestamp < proposal.votingWindowEnd;
    }

    /**
     * @dev Get time remaining in voting window
     */
    function getTimeRemaining(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (int256)
    {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.state != ProposalState.ACTIVE) {
            return 0;
        }
        return int256(proposal.votingWindowEnd) - int256(block.timestamp);
    }

    /**
     * @dev Close voting on a proposal (after voting window)
     */
    function closeVoting(uint256 proposalId)
        external
        validProposal(proposalId)
    {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.state == ProposalState.ACTIVE, "Proposal not in voting state");
        require(block.timestamp >= proposal.votingWindowEnd, "Voting window still open");

        proposal.state = ProposalState.CLOSED;

        // Lock ballot box
        ProposalBallotBox ballotBox = ProposalBallotBox(proposal.ballotBox);
        ballotBox.lockBallotBox();
    }

    // ============ FINALIZATION ============

    /**
     * @dev Finalize proposal after voting and get final tallies
     */
    function finalizeProposal(uint256 proposalId)
        external
        validProposal(proposalId)
        returns (
            uint256 yayVotes,
            uint256 nayVotes,
            uint256 abstainVotes
        )
    {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.state == ProposalState.CLOSED, "Proposal not closed");
        require(!proposal.finalized, "Already finalized");

        ProposalBallotBox ballotBox = ProposalBallotBox(proposal.ballotBox);
        (yayVotes, nayVotes, abstainVotes) = ballotBox.getFinalTally();

        proposal.finalized = true;
        proposal.state = ProposalState.FINALIZED;

        emit VotingEnded(proposalId, 0, yayVotes, nayVotes, abstainVotes);
        emit ProposalFinalized(proposalId, proposal.state);

        return (yayVotes, nayVotes, abstainVotes);
    }

    // ============ QUERY FUNCTIONS ============

    /**
     * @dev Get proposal details
     */
    function getProposal(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (
            address creator,
            address seconder,
            string memory title,
            bool forEnsemble,
            bytes32 forShow,
            uint256 createdAt,
            uint256 votingWindowEnd,
            ProposalState state,
            address ballotBox,
            bool finalized
        )
    {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.creator,
            proposal.seconder,
            proposal.title,
            proposal.forEnsemble,
            proposal.forShow,
            proposal.createdAt,
            proposal.votingWindowEnd,
            proposal.state,
            proposal.ballotBox,
            proposal.finalized
        );
    }

    /**
     * @dev Get proposal tags
     */
    function getProposalTags(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (bytes32[] memory)
    {
        return proposals[proposalId].tags;
    }

    /**
     * @dev Get total proposals created
     */
    function getTotalProposals() external view returns (uint256) {
        return _proposalIdCounter.current();
    }

    /**
     * @dev Get all ensemble proposals
     */
    function getEnsembleProposals() external view returns (uint256[] memory) {
        return ensembleProposals;
    }

    /**
     * @dev Get proposals for a specific show
     */
    function getShowProposals(bytes32 showHash) external view returns (uint256[] memory) {
        return showProposals[showHash];
    }

    /**
     * @dev Get active proposals by jurisdiction (for retroactive minting)
     */
    function getActiveProposalsByJurisdiction(bool forEnsemble, bytes32 forShow)
        external
        view
        validJurisdiction(forEnsemble, forShow)
        returns (uint256[] memory)
    {
        uint256[] memory allProposals = forEnsemble ? ensembleProposals : showProposals[forShow];

        // Count active proposals
        uint256 activeCount = 0;
        for (uint256 i = 0; i < allProposals.length; i++) {
            if (proposals[allProposals[i]].state == ProposalState.ACTIVE) {
                activeCount++;
            }
        }

        // Build active proposals array
        uint256[] memory activeProposals = new uint256[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allProposals.length; i++) {
            if (proposals[allProposals[i]].state == ProposalState.ACTIVE) {
                activeProposals[index] = allProposals[i];
                index++;
            }
        }

        return activeProposals;
    }

    // ============ ANONYMOUS VOTING (V2) ============

    /**
     * @dev Set Merkle root for a proposal (called after seconding)
     * Backend generates commitments, builds tree, provides root
     * Can only be set once per proposal (immutable)
     *
     * @param proposalId The proposal ID
     * @param merkleRoot The Merkle root of voter commitments
     */
    function setProposalMerkleRoot(
        uint256 proposalId,
        bytes32 merkleRoot
    ) external onlyOwner validProposal(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        require(
            proposal.state == ProposalState.ACTIVE,
            "Proposal not active"
        );
        require(
            proposalMerkleRoot[proposalId] == bytes32(0),
            "Merkle root already set"
        );
        require(merkleRoot != bytes32(0), "Invalid merkle root");

        proposalMerkleRoot[proposalId] = merkleRoot;
        emit MerkleRootSet(proposalId, merkleRoot);
    }

    /**
     * @dev Cast anonymous vote with Merkle proof
     * Proves voter eligibility without revealing identity
     *
     * Security features:
     * - Verifies Merkle proof (voter is in eligibility tree)
     * - Checks nullifier not used (prevents double-voting)
     * - No voter identity stored on-chain
     *
     * @param proposalId The proposal ID
     * @param commitment The voter's commitment (public)
     * @param merkleProof Array of sibling hashes for proof
     * @param nullifier The nullifier (prevents double-voting)
     * @param voteChoice The vote choice as bytes32 (keccak256("YAY") or keccak256("NAY"))
     */
    function castAnonymousVote(
        uint256 proposalId,
        bytes32 commitment,
        bytes32[] calldata merkleProof,
        bytes32 nullifier,
        bytes32 voteChoice
    ) external validProposal(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        // Check proposal is active
        require(
            proposal.state == ProposalState.ACTIVE,
            "Proposal not active"
        );
        require(
            block.timestamp < proposal.votingWindowEnd,
            "Voting window closed"
        );

        // Get Merkle root
        bytes32 merkleRoot = proposalMerkleRoot[proposalId];
        require(merkleRoot != bytes32(0), "Merkle root not set");

        // Verify Merkle proof (proves voter eligibility)
        require(
            MerkleProofVerifier.verifyProof(merkleProof, commitment, merkleRoot),
            "Invalid Merkle proof"
        );

        // Check nullifier not used (prevents double-voting)
        require(
            !usedNullifiers[proposalId][nullifier],
            "Vote already cast with this nullifier"
        );

        // Ensure this commitment has not voted yet
        AnonymousVoteRecord storage record = anonymousVoteRecords[proposalId][commitment];
        require(!record.exists, "Vote already recorded; use changeAnonymousVote");

        // Validate vote choice
        require(
            voteChoice == keccak256("YAY") || voteChoice == keccak256("NAY"),
            "Invalid vote choice"
        );

        // Mark nullifier as used (BEFORE external call - CEI pattern)
        usedNullifiers[proposalId][nullifier] = true;

        // Update ballot box tally (external call)
        ProposalBallotBox ballotBox = ProposalBallotBox(proposal.ballotBox);
        ballotBox.recordAnonymousVote(voteChoice);

        // Persist vote record so voter can change later
        record.exists = true;
        record.nullifier = nullifier;
        record.voteChoice = voteChoice;

        emit AnonymousVoteCast(proposalId, nullifier, block.timestamp);
    }

    /**
     * @dev Change an existing anonymous vote
     * Requires Merkle proof (eligibility), previous nullifier, and new nullifier
     * Updates ballot box tally by decrementing old vote and incrementing new one
     */
    function changeAnonymousVote(
        uint256 proposalId,
        bytes32 commitment,
        bytes32[] calldata merkleProof,
        bytes32 previousNullifier,
        bytes32 newNullifier,
        bytes32 newVoteChoice
    ) external validProposal(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        require(
            proposal.state == ProposalState.ACTIVE,
            "Proposal not active"
        );
        require(
            block.timestamp < proposal.votingWindowEnd,
            "Voting window closed"
        );

        bytes32 merkleRoot = proposalMerkleRoot[proposalId];
        require(merkleRoot != bytes32(0), "Merkle root not set");

        require(
            MerkleProofVerifier.verifyProof(merkleProof, commitment, merkleRoot),
            "Invalid Merkle proof"
        );

        AnonymousVoteRecord storage record = anonymousVoteRecords[proposalId][commitment];
        require(record.exists, "No anonymous vote found");
        require(
            record.nullifier == previousNullifier,
            "Previous nullifier mismatch"
        );

        require(
            newVoteChoice == keccak256("YAY") || newVoteChoice == keccak256("NAY"),
            "Invalid vote choice"
        );
        require(
            newNullifier != previousNullifier,
            "New nullifier must differ"
        );
        require(newNullifier != bytes32(0), "Invalid new nullifier");
        require(
            !usedNullifiers[proposalId][newNullifier],
            "New nullifier already used"
        );

        usedNullifiers[proposalId][newNullifier] = true;

        ProposalBallotBox ballotBox = ProposalBallotBox(proposal.ballotBox);
        ballotBox.updateAnonymousVote(record.voteChoice, newVoteChoice);

        bytes32 oldChoice = record.voteChoice;
        record.voteChoice = newVoteChoice;
        record.nullifier = newNullifier;

        emit AnonymousVoteChanged(
            proposalId,
            previousNullifier,
            newNullifier,
            block.timestamp,
            oldChoice,
            newVoteChoice
        );
    }

    /**
     * @dev Check if a nullifier has been used
     * Allows backend to verify double-vote prevention
     *
     * @param proposalId The proposal ID
     * @param nullifier The nullifier to check
     * @return True if nullifier has been used
     */
    function isNullifierUsed(uint256 proposalId, bytes32 nullifier)
        external
        view
        returns (bool)
    {
        return usedNullifiers[proposalId][nullifier];
    }

    /**
     * @dev Cast anonymous vote with capability verification and permit proof
     * Verifies:
     *  - Proposal is active and within window
     *  - Voter inclusion proof for commitment
     *  - Nullifier uniqueness
     *  - Permit proof inclusion against provided permit root
     *  - Capability signature over (proposalId, delegatorId, delegateId, voteChoice string, commitment, nullifier)
     */
    function castAnonymousVoteWithCapability(
        uint256 proposalId,
        uint256 delegatorId,
        uint256 delegateId,
        bytes32 commitment,
        bytes32[] calldata merkleProof,
        bytes32 nullifier,
        bytes32 voteChoice,
        bytes32 permitRoot,
        bytes32[] calldata permitProof,
        bytes32 permitLeaf,
        bytes calldata capabilitySignature,
        address capabilityPubkey
    ) external validProposal(proposalId) {
        Proposal storage proposal = proposals[proposalId];

        require(proposal.state == ProposalState.ACTIVE, "Proposal not active");
        require(block.timestamp < proposal.votingWindowEnd, "Voting window closed");
        require(permitRoot != bytes32(0), "Permit root required");
        require(capabilityPubkey != address(0), "Invalid capability key");

        bytes32 merkleRoot = proposalMerkleRoot[proposalId];
        require(merkleRoot != bytes32(0), "Merkle root not set");

        require(MerkleProofVerifier.verifyProof(merkleProof, commitment, merkleRoot), "Invalid Merkle proof");
        require(!usedNullifiers[proposalId][nullifier], "Vote already cast with this nullifier");

        AnonymousVoteRecord storage record = anonymousVoteRecords[proposalId][commitment];
        require(!record.exists, "Vote already recorded; use changeAnonymousVote");

        // Validate vote choice and derive string label for signature domain
        require(voteChoice == keccak256("YAY") || voteChoice == keccak256("NAY"), "Invalid vote choice");
        string memory voteChoiceLabel = voteChoice == keccak256("YAY") ? "YAY" : "NAY";

        // Ensure permit leaf is bound to this exact vote payload.
        bytes32 expectedPermitLeaf = keccak256(
            abi.encodePacked(
                proposalId,
                delegatorId,
                delegateId,
                voteChoice,
                commitment,
                nullifier,
                capabilityPubkey
            )
        );
        require(permitLeaf == expectedPermitLeaf, "Permit leaf payload mismatch");

        // Verify permit proof
        require(MerkleProofVerifier.verifyProof(permitProof, permitLeaf, permitRoot), "Invalid permit proof");

        // Verify capability signature
        bytes32 digest = keccak256(
            abi.encodePacked(
                proposalId,
                delegatorId,
                delegateId,
                voteChoiceLabel,
                commitment,
                nullifier
            )
        );

        address recovered = ECDSA.recover(digest, capabilitySignature);
        require(recovered == capabilityPubkey, "Capability signature invalid");

        usedNullifiers[proposalId][nullifier] = true;

        ProposalBallotBox ballotBox = ProposalBallotBox(proposal.ballotBox);
        ballotBox.recordAnonymousVote(voteChoice);

        record.exists = true;
        record.nullifier = nullifier;
        record.voteChoice = voteChoice;

        emit AnonymousVoteCastWithCapability(proposalId, delegatorId, delegateId, nullifier, voteChoice, capabilityPubkey);
    }

    /**
     * @dev Get Merkle root for a proposal
     *
     * @param proposalId The proposal ID
     * @return The Merkle root (0x0 if not set)
     */
    function getProposalMerkleRoot(uint256 proposalId)
        external
        view
        validProposal(proposalId)
        returns (bytes32)
    {
        return proposalMerkleRoot[proposalId];
    }
}
