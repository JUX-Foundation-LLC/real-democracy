// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./Capabilities.sol";

interface IVoteTokenDelegateView {
    function isActive(uint256 tokenId) external view returns (bool);
    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256);
    function voterIdOf(uint256 tokenId) external view returns (bytes32);
}

/**
 * @title PublicDelegateVoteRegistry
 * @notice Delegates vote in the open — that is the deal of delegation: their delegators'
 *         ballots stay anonymous, but the delegate's own signal is public, attributable,
 *         and followable directly on-chain. Any wallet, media org, or audit tool can watch
 *         `PublicDelegateVoteCast` (or read `votes`) to follow a delegate without our backend.
 *
 *         GENERALIZED (GOVERNANCE_SPINE §8.2 — FOLLOW layer): an open delegate vote is keyed
 *         by the SAME `externalNullifier` as the anonymous ballot (the unified ballot-key
 *         scheme: keccak("proposal:id"), keccak("rule:jur:key"), tag:, role:, the reserved
 *         governance domains, ... each mod the field prime). So a delegate can openly vote on
 *         EVERY family/domain, and a follower querying the ballot's externalNullifier reads
 *         the delegate's position with one uniform call.
 *
 *         The `choice` is a `uint256` matching the ballot's `voteChoice` domain (boolean:
 *         1=support/0=oppose; average/median: the value; plurality: the choice index) — so the
 *         open signal mirrors exactly what the delegate would prove anonymously. `cast=false`
 *         is the withdrawn/never-cast state (the old CHOICE_UNCAST).
 *
 *         This registry deliberately does NOT tally: the binding count lives in the anonymous
 *         ballot. It is the open attestation layer tying a delegate identity (VoteToken) to a
 *         declared position on a ballot.
 */
contract PublicDelegateVoteRegistry {
    // Boolean convention (documented, not enforced — choice is structure-defined):
    uint256 public constant CHOICE_OPPOSE = 0; // NAY
    uint256 public constant CHOICE_SUPPORT = 1; // YAY

    IVoteTokenDelegateView public immutable voteToken;
    IERC721 public immutable voteTokenNft;

    address public owner;
    /// optional on-chain capability gate (CapabilityRegistry); address(0) = no on-chain check.
    /// When set, casting requires PERMIT_DELEGATE — gating self-custody delegates.
    address public capabilityRegistry;

    struct PublicVote {
        uint256 choice; // the delegate's open position (= the ballot's voteChoice domain)
        uint64 castAt;
        uint32 revision;
        bool cast; // false = withdrawn / never cast (replaces CHOICE_UNCAST)
    }

    /// externalNullifier (the unified ballot key) => delegate VoteToken id => latest open vote
    mapping(uint256 => mapping(uint256 => PublicVote)) public votes;

    event PublicDelegateVoteCast(
        uint256 indexed externalNullifier,
        uint256 indexed delegateTokenId,
        address indexed delegate,
        uint256 jurisdictionId,
        uint256 choice,
        uint32 revision,
        bool cast
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event CapabilityRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);

    constructor(address voteTokenAddress) {
        require(voteTokenAddress != address(0), "Registry: vote token required");
        voteToken = IVoteTokenDelegateView(voteTokenAddress);
        voteTokenNft = IERC721(voteTokenAddress);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Registry: only owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Registry: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// Bind (or clear) the on-chain capability gate. Binding makes delegate voting permission-checked
    /// on-chain for ALL callers (self-custody included). Bind AFTER the voter role is seeded.
    function setCapabilityRegistry(address registry) external onlyOwner {
        emit CapabilityRegistryUpdated(capabilityRegistry, registry);
        capabilityRegistry = registry;
    }

    /// Shared eligibility + capability gate for a delegate acting on their token.
    function _assertDelegate(uint256 delegateTokenId) internal view {
        require(voteToken.isActive(delegateTokenId), "Registry: vote token inactive");
        require(voteTokenNft.ownerOf(delegateTokenId) == msg.sender, "Registry: not token owner");
        address gate = capabilityRegistry;
        if (gate != address(0)) {
            require(
                ICapabilityGate(gate).hasCapability(
                    voteToken.jurisdictionIdOf(delegateTokenId),
                    voteToken.voterIdOf(delegateTokenId),
                    Capabilities.PERMIT_DELEGATE
                ),
                "Registry: delegate voting not permitted"
            );
        }
    }

    /**
     * @notice Publish (or revise) an open delegate vote on ANY ballot, scoped by its
     *         `externalNullifier`. Must be signed by the wallet holding the delegate's active
     *         VoteToken — no backend required; self-custody delegates call this directly.
     */
    function castPublicDelegateVote(
        uint256 externalNullifier,
        uint256 delegateTokenId,
        uint256 choice
    ) external {
        _assertDelegate(delegateTokenId);
        PublicVote storage vote = votes[externalNullifier][delegateTokenId];
        vote.choice = choice;
        vote.castAt = uint64(block.timestamp);
        vote.revision += 1;
        vote.cast = true;
        emit PublicDelegateVoteCast(
            externalNullifier,
            delegateTokenId,
            msg.sender,
            voteToken.jurisdictionIdOf(delegateTokenId),
            choice,
            vote.revision,
            true
        );
    }

    /**
     * @notice Withdraw an open delegate vote (the old UNCAST). Followers reading `cast=false`
     *         know the delegate has no live position on this ballot. Revisioned like a cast.
     */
    function withdrawPublicDelegateVote(uint256 externalNullifier, uint256 delegateTokenId) external {
        _assertDelegate(delegateTokenId);
        PublicVote storage vote = votes[externalNullifier][delegateTokenId];
        require(vote.cast, "Registry: nothing to withdraw");
        vote.cast = false;
        vote.castAt = uint64(block.timestamp);
        vote.revision += 1;
        emit PublicDelegateVoteCast(
            externalNullifier,
            delegateTokenId,
            msg.sender,
            voteToken.jurisdictionIdOf(delegateTokenId),
            vote.choice,
            vote.revision,
            false
        );
    }

    function getPublicVote(uint256 externalNullifier, uint256 delegateTokenId)
        external
        view
        returns (uint256 choice, uint64 castAt, uint32 revision, bool cast)
    {
        PublicVote storage vote = votes[externalNullifier][delegateTokenId];
        return (vote.choice, vote.castAt, vote.revision, vote.cast);
    }
}
