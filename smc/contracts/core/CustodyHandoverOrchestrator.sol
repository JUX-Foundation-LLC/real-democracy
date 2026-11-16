// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @dev Minimal views/actions the orchestrator needs from the deployed VoteToken.
 *      Mirrors IVoteToken.Secrets so we can forward a handover without importing
 *      the full token.
 */
interface IVoteTokenHandover {
    struct Secrets {
        bytes32 cryptoVote;
        bytes32 signKey;
        bytes32 userBiometric;
        uint256 biometricTypeMask;
    }

    function handoverCustody(
        uint256 tokenId,
        address newOwner,
        Secrets calldata secrets,
        bytes32 stealthCommitment
    ) external returns (uint256 newTokenId);

    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256);
    function isActive(uint256 tokenId) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @dev PTS bank surface. PTS is non-transferable, so moving a balance between
 *      wallets is burn-from-source + mint-to-destination, each gated by an
 *      active VoteToken binding.
 */
interface IPtsBankSweep {
    function balanceOf(address account, uint256 id) external view returns (uint256);

    function burnFromControllerToken(
        address from,
        uint256 jurisdictionId,
        uint256 amount,
        uint256 controllerVoteTokenId,
        uint256 sourceVoteTokenId,
        bytes32 contextHash
    ) external;

    function mintFromControllerToken(
        address to,
        uint256 jurisdictionId,
        uint256 amount,
        uint256 controllerVoteTokenId,
        uint256 recipientVoteTokenId,
        bytes32 contextHash
    ) external;
}

interface ISuccessorRegistryRecorder {
    // HandoverKind is encoded as its underlying uint8 in the ABI.
    function recordHandover(
        uint256 oldTokenId,
        uint256 successorTokenId,
        uint256 jurisdictionId,
        uint8 kind,
        string calldata reason
    ) external;
}

/**
 * @title CustodyHandoverOrchestrator
 * @notice Performs a complete, atomic VoteToken custody handover — the
 *         mechanical spine of both self-custody migration and trusted-authority
 *         key recovery. In a single transaction it:
 *
 *           1. snapshots the old wallet's PTS balance for the jurisdiction,
 *           2. burns that PTS from the old wallet WHILE the old token is still
 *              active (the bank rejects burns against an inactive token, and
 *              `handoverCustody` disables the old token — so the burn must
 *              happen first),
 *           3. calls `handoverCustody`, which disables the old (soulbound,
 *              non-burned, fully readable) token and mints a fresh one to a
 *              wallet the end-user controls,
 *           4. re-mints the exact PTS balance to the new wallet against the
 *              new active token, and
 *           5. records the old -> new link in the SuccessorRegistry.
 *
 *         The balance never lands anywhere in between, and the whole thing
 *         reverts as a unit if any step fails — so there is no window in which
 *         PTS is orphaned or double-counted (the on-chain fraud assurance).
 *
 *         This contract must hold: CUSTODIAN_ROLE on VoteToken, jurisdiction
 *         operator rights on the PTS bank, and RECORDER_ROLE on the
 *         SuccessorRegistry. It does NOT yet enforce a democratic authority
 *         gate — HANDOVER_OPERATOR_ROLE is held by the backend (and later by
 *         the PermissionedCustodian, which will add capability tiers and the
 *         on-chain endorsement check once self-custody distributes keys).
 */
contract CustodyHandoverOrchestrator is AccessControl {
    bytes32 public constant HANDOVER_OPERATOR_ROLE = keccak256("HANDOVER_OPERATOR_ROLE");

    // Mirrors SuccessorRegistry.HandoverKind.
    uint8 public constant KIND_VOLUNTARY = 1;
    uint8 public constant KIND_RECOVERY = 2;

    IVoteTokenHandover public immutable voteToken;
    IPtsBankSweep public immutable ptsBank;
    ISuccessorRegistryRecorder public immutable successorRegistry;

    event CustodyHandedOver(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        uint256 indexed jurisdictionId,
        address oldOwner,
        address newOwner,
        uint256 ptsMoved,
        uint8 kind
    );

    error InactiveSourceToken(uint256 tokenId);
    error InvalidNewOwner();

    constructor(
        address admin,
        address voteTokenAddress,
        address ptsBankAddress,
        address successorRegistryAddress
    ) {
        require(admin != address(0), "Orchestrator: admin required");
        require(voteTokenAddress != address(0), "Orchestrator: vote token required");
        require(ptsBankAddress != address(0), "Orchestrator: pts bank required");
        require(successorRegistryAddress != address(0), "Orchestrator: registry required");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(HANDOVER_OPERATOR_ROLE, admin);

        voteToken = IVoteTokenHandover(voteTokenAddress);
        ptsBank = IPtsBankSweep(ptsBankAddress);
        successorRegistry = ISuccessorRegistryRecorder(successorRegistryAddress);
    }

    /**
     * @notice Hand a token's custody (and its PTS) over to `newOwner`.
     * @param oldTokenId        the token being retired (must be active)
     * @param newOwner          wallet the end-user controls
     * @param secrets           fresh zk/identity secrets for the new token
     * @param stealthCommitment fresh stealth commitment for the new token
     * @param kind              KIND_VOLUNTARY or KIND_RECOVERY (audit context)
     * @param reason            human-auditable note recorded on-chain
     * @return newTokenId       the freshly minted successor token
     */
    function handover(
        uint256 oldTokenId,
        address newOwner,
        IVoteTokenHandover.Secrets calldata secrets,
        bytes32 stealthCommitment,
        uint8 kind,
        string calldata reason
    ) external onlyRole(HANDOVER_OPERATOR_ROLE) returns (uint256 newTokenId) {
        if (newOwner == address(0)) revert InvalidNewOwner();
        if (!voteToken.isActive(oldTokenId)) revert InactiveSourceToken(oldTokenId);

        uint256 jurisdictionId = voteToken.jurisdictionIdOf(oldTokenId);
        address oldOwner = voteToken.ownerOf(oldTokenId);

        bytes32 contextHash = keccak256(
            abi.encodePacked("CUSTODY_HANDOVER", oldTokenId, newOwner, block.chainid)
        );

        // 1 + 2. Snapshot and burn PTS from the old wallet while the old token
        // is still active. controller == source == oldTokenId (the authority
        // context here is the token's own active binding).
        uint256 balance = ptsBank.balanceOf(oldOwner, jurisdictionId);
        if (balance > 0) {
            ptsBank.burnFromControllerToken(
                oldOwner,
                jurisdictionId,
                balance,
                oldTokenId,
                oldTokenId,
                contextHash
            );
        }

        // 3. Disable the old token (non-burning, traceable) and mint the new one.
        newTokenId = voteToken.handoverCustody(oldTokenId, newOwner, secrets, stealthCommitment);

        // 4. Re-mint the exact balance to the new wallet against the new active token.
        if (balance > 0) {
            ptsBank.mintFromControllerToken(
                newOwner,
                jurisdictionId,
                balance,
                newTokenId,
                newTokenId,
                contextHash
            );
        }

        // 5. Record the unbroken old -> new link.
        successorRegistry.recordHandover(oldTokenId, newTokenId, jurisdictionId, kind, reason);

        emit CustodyHandedOver(
            oldTokenId,
            newTokenId,
            jurisdictionId,
            oldOwner,
            newOwner,
            balance,
            kind
        );
    }
}
