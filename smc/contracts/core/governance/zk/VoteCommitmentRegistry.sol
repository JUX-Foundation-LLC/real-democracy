// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";

interface IVoteTokenOwnership {
    function ownerOf(uint256 tokenId) external view returns (address);
    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256);
    function isActive(uint256 tokenId) external view returns (bool);
}

/**
 * @title VoteCommitmentRegistry
 * @notice The §8c.4 trustless-eligibility bridge. Publishes each VoteToken's zk
 *         IDENTITY commitment — the Poseidon leaf the vote circuit proves membership of
 *         (`commitmentOf(deriveIdentity(custodySigner))`) — on-chain, bound to
 *         `(tokenId, jurisdictionId)`. With the commitments enumerable from chain, an
 *         auditor rebuilds a ballot's eligibility root from chain ALONE and checks it
 *         equals the registered `ballotRoot[externalNullifier]` — turning *"the backend
 *         says these are the eligible voters"* into *"anyone can prove it."*
 *
 *         NOT `VoteToken.stealthCommitment`: that is a stealth-address handover artifact
 *         (random, rotates on custody handover, consumed by CustodyHandoverOrchestrator).
 *         This is the STABLE circuit-identity commitment the eligibility tree is built from.
 *
 *         PRIVACY INVARIANT (load-bearing): the commitment is the *eligibility* primitive —
 *         it publishes WHO MAY vote. The vote path reveals `nullifierHash`, NEVER the
 *         commitment, so publishing `tokenId ↔ commitment` here never links a token to its
 *         vote. This holds ONLY while no vote-path artifact ever exposes the commitment.
 *         Preserve that invariant downstream.
 *
 *         AUTHORITY (mirrors the rest of the spine — backend-bootstrap → owner-sovereign):
 *           - REGISTRAR_ROLE (the backend signer) publishes during bootstrap / for custodial
 *             tokens, where the custodian holds the key and computes the commitment.
 *           - The token OWNER may (re)publish their OWN token's commitment (self-custody /
 *             key rotation / custody handover), gated via the optional VoteToken reference.
 *         History is event-sourced and append-only: a re-publish emits a fresh
 *         `CommitmentPublished` carrying the previous value; the enumerable truth is the
 *         event log, and the latest event for a tokenId is its live commitment.
 */
contract VoteCommitmentRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    /// BN254 scalar field order — a Poseidon commitment must be a field element.
    uint256 internal constant FIELD_PRIME =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// tokenId => current identity commitment (0 = unset)
    mapping(uint256 => uint256) public commitmentForToken;
    /// tokenId => jurisdiction the commitment was published under (rebuild scoping)
    mapping(uint256 => uint256) public jurisdictionForToken;

    /// Optional VoteToken used to gate owner self-publication. Zero = REGISTRAR-only.
    IVoteTokenOwnership public voteToken;

    event VoteTokenUpdated(address indexed voteToken);
    event CommitmentPublished(
        uint256 indexed tokenId,
        uint256 indexed jurisdictionId,
        uint256 commitment,
        uint256 previousCommitment,
        address indexed publisher
    );

    error TokenRequired();
    error CommitmentRequired();
    error CommitmentNotFieldElement();
    error JurisdictionRequired();
    error NotAuthorized(uint256 tokenId, address caller);
    error JurisdictionImmutable(uint256 tokenId, uint256 bound, uint256 attempted);

    constructor(address admin) {
        address initial = admin == address(0) ? msg.sender : admin;
        _grantRole(DEFAULT_ADMIN_ROLE, initial);
        _grantRole(REGISTRAR_ROLE, initial);
    }

    /// Wire (or clear) the VoteToken used to authorize owner self-publication.
    function setVoteToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        voteToken = IVoteTokenOwnership(token);
        emit VoteTokenUpdated(token);
    }

    /**
     * @notice Publish (or rotate) a token's zk identity commitment.
     * @dev Authorized for a REGISTRAR (bootstrap/custodial) OR the token's current owner
     *      (self-custody), the latter only when a VoteToken is wired. The `(tokenId →
     *      jurisdictionId)` binding is immutable once set — a token never migrates
     *      jurisdiction — while the commitment itself may rotate (key change / handover).
     */
    function publishCommitment(uint256 tokenId, uint256 jurisdictionId, uint256 commitment) external {
        if (tokenId == 0) revert TokenRequired();
        if (jurisdictionId == 0) revert JurisdictionRequired();
        if (commitment == 0) revert CommitmentRequired();
        if (commitment >= FIELD_PRIME) revert CommitmentNotFieldElement();

        if (!_authorized(tokenId)) revert NotAuthorized(tokenId, msg.sender);

        uint256 boundJur = jurisdictionForToken[tokenId];
        if (boundJur != 0 && boundJur != jurisdictionId) {
            revert JurisdictionImmutable(tokenId, boundJur, jurisdictionId);
        }

        uint256 previous = commitmentForToken[tokenId];
        commitmentForToken[tokenId] = commitment;
        jurisdictionForToken[tokenId] = jurisdictionId;

        emit CommitmentPublished(tokenId, jurisdictionId, commitment, previous, msg.sender);
    }

    function _authorized(uint256 tokenId) internal view returns (bool) {
        if (hasRole(REGISTRAR_ROLE, msg.sender)) return true;
        if (address(voteToken) != address(0)) {
            // Owner self-publication: only the live owner of an active token.
            try voteToken.ownerOf(tokenId) returns (address owner) {
                if (owner == msg.sender && voteToken.isActive(tokenId)) return true;
            } catch {
                return false;
            }
        }
        return false;
    }

    /// Convenience read: the live commitment + its jurisdiction (0,0 if never published).
    function commitmentInfo(uint256 tokenId)
        external
        view
        returns (uint256 commitment, uint256 jurisdictionId)
    {
        return (commitmentForToken[tokenId], jurisdictionForToken[tokenId]);
    }
}
