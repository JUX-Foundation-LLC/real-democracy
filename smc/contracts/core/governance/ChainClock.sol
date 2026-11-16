// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../interfaces/IVoteToken.sol";

/**
 * @title ChainClock
 * @dev Anchors a hash-linked chain of checkpoints and issues VoteToken-bound
 *      document signatures. Inspired by the KSI blockchain pattern where every
 *      proof eventually collapses into a single publicly-auditable root. The
 *      backend feeds Merkle checkpoints into CheckpointRegistry; this contract
 *      hashes those roots with block metadata so auditors can tie any vote,
 *      rule change, or document signature to an immutable moment in time.
 */
contract ChainClock {
    IVoteToken public immutable voteToken;
    IERC721 private immutable voteTokenNft;

    address public owner;
    address public checkpointRegistry;

    uint256 public currentTick;
    bytes32 public latestRoot;

    mapping(uint256 => bytes32) public tickRoots;
    mapping(bytes32 => bool) public consumedTickets;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event CheckpointRegistryLinked(address indexed registry);
    event TickAnchored(
        uint256 indexed tick,
        bytes32 previousRoot,
        bytes32 checkpointRoot,
        bytes32 jurisdictionRoot,
        bytes32 memoHash,
        bytes32 newRoot,
        uint256 timestamp
    );
    event DocumentSigned(
        uint256 indexed tokenId,
        bytes32 indexed voterId,
        bytes32 documentHash,
        bytes32 ticket,
        bytes32 signature,
        uint256 tick,
        uint256 timestamp
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "ChainClock: only owner");
        _;
    }

    constructor(address voteTokenAddress, address checkpointRegistryAddress) {
        require(voteTokenAddress != address(0), "ChainClock: vote token required");
        owner = msg.sender;
        voteToken = IVoteToken(voteTokenAddress);
        voteTokenNft = IERC721(voteTokenAddress);
        checkpointRegistry = checkpointRegistryAddress;
        emit OwnershipTransferred(address(0), owner);
        if (checkpointRegistryAddress != address(0)) {
            emit CheckpointRegistryLinked(checkpointRegistryAddress);
        }
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ChainClock: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setCheckpointRegistry(address registry) external onlyOwner {
        checkpointRegistry = registry;
        emit CheckpointRegistryLinked(registry);
    }

    function recordTick(
        bytes32 checkpointRoot,
        bytes32 jurisdictionRoot,
        bytes32 memoHash
    ) external onlyOwner returns (bytes32 newRoot) {
        bytes32 prev = latestRoot;
        bytes32 derived = keccak256(
            abi.encodePacked(
                prev,
                checkpointRoot,
                jurisdictionRoot,
                memoHash,
                block.timestamp,
                block.chainid,
                currentTick + 1
            )
        );
        latestRoot = derived;
        currentTick += 1;
        tickRoots[currentTick] = derived;
        emit TickAnchored(currentTick, prev, checkpointRoot, jurisdictionRoot, memoHash, derived, block.timestamp);
        return derived;
    }

    function rootAt(uint256 tick) external view returns (bytes32) {
        return tickRoots[tick];
    }

    function deriveDocumentTicket(
        uint256 tokenId,
        bytes32 documentHash,
        bytes32 nonce
    ) public view returns (bytes32 ticket, bytes32 signature) {
        require(latestRoot != bytes32(0), "ChainClock: no ticks recorded");
        require(documentHash != bytes32(0), "ChainClock: document hash required");
        require(nonce != bytes32(0), "ChainClock: nonce required");
        bytes32 voterNullifier = keccak256(
            abi.encodePacked(tokenId, voteToken.revocationNonceOf(tokenId))
        );
        bytes32 docTicket = keccak256(abi.encodePacked(voterNullifier, documentHash, nonce));
        bytes32 docSignature = keccak256(
            abi.encodePacked(docTicket, latestRoot, block.chainid)
        );
        return (docTicket, docSignature);
    }

    function signDocument(
        uint256 tokenId,
        bytes32 documentHash,
        bytes32 nonce
    ) external returns (bytes32 signature) {
        require(voteToken.isActive(tokenId), "ChainClock: inactive token");
        require(voteTokenNft.ownerOf(tokenId) == msg.sender, "ChainClock: not token owner");
        (bytes32 ticket, bytes32 docSignature) = deriveDocumentTicket(tokenId, documentHash, nonce);
        require(!consumedTickets[ticket], "ChainClock: ticket consumed");
        consumedTickets[ticket] = true;
        emit DocumentSigned(
            tokenId,
            voteToken.voterIdOf(tokenId),
            documentHash,
            ticket,
            docSignature,
            currentTick,
            block.timestamp
        );
        return docSignature;
    }
}
