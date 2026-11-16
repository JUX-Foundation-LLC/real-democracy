// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IVoteToken.sol";
import "./ChainClock.sol";
import "./TagBallotBox.sol";
import "./Capabilities.sol"; // ICapabilityGate + Capabilities.PERMIT_JURISDICTION_CREATION

interface IJurisdictionPts1155Bank {
    function bootstrapJurisdictionFromFactory(
        uint256 jurisdictionId,
        address governor,
        address bootstrapOperator
    ) external;
}

/// #343 Step D (post-cut, additive): resolves a caller wallet → its on-chain `voterId` (the stable
/// identity `CapabilityRegistry`/`RoleCatalog` key by — NOT a raw address) for the Foundational
/// Jurisdiction, so democratic (non-owner) jurisdiction creation can be capability-gated. address(0)
/// ⇒ democratic creation disabled (owner-only — the re-genesis-cut behavior, unchanged).
interface ICreatorResolver {
    function voterIdOf(address account) external view returns (bytes32);
}

/**
 * @title JurisdictionFactory
 * @dev Templated deployer for jurisdiction governance primitives + the per-jurisdiction on-chain
 *      ballotbox DIRECTORY (#343): each jurisdiction's box addresses are enumerable on-chain via
 *      `jurisdictionBox[jid][kind]` so a third party / the ballotbox-DB mirror can discover ALL of a
 *      jurisdiction's boxes (tag / role / initiative / rule-registry) without an off-chain manifest.
 *
 *      Every jurisdiction receives a dedicated TagBallotBox kept in sync with ChainClock so checkpoints
 *      can be proven back to a specific tick. RULES are NO LONGER tallied by a factory-built box: the
 *      legacy per-jurisdiction `RuleBallotBox` is RETIRED (#343 item 4) — rules live in the B.2
 *      per-structure family indexed by `JurisdictionRuleRegistry`. The `JurisdictionRecord.ruleBallotBox`
 *      field is retained (always address(0)) only for ABI/return-shape continuity through the cut; read
 *      a rule's box via the registry, not here.
 */
contract JurisdictionFactory {
    struct JurisdictionRecord {
        address ruleBallotBox; // RETIRED (#343): always address(0) — kept for ABI continuity; use JurisdictionRuleRegistry
        address tagBallotBox;
        bytes32 ruleSetHash;
        bytes32 tagRegistryHash;
        uint256 createdAt;
        bool exists;
    }

    // #343 box-directory kinds. The tag box is registered at creation; role / initiative / rule-registry
    // boxes are registered by their own deploy scripts via registerJurisdictionBox (at the cut).
    bytes32 public constant BOX_KIND_TAG = keccak256("tag");
    bytes32 public constant BOX_KIND_ROLE = keccak256("role");
    bytes32 public constant BOX_KIND_INITIATIVE = keccak256("initiative");
    bytes32 public constant BOX_KIND_RULE_REGISTRY = keccak256("ruleRegistry");

    IVoteToken public immutable voteToken;
    ChainClock public chainClock;
    IJurisdictionPts1155Bank public ptsBank;
    address public owner;
    address public ballotGovernor;
    bool public permissionlessJurisdictionCreation;
    // C2 follow-on: the on-chain capability gate bound onto every TagBallotBox this factory creates.
    // A TagBallotBox is born governed by `address(this)` and handed off to `governorTarget` at the end
    // of creation, so it has NO deployer-governed window AFTER creation — the only safe place to wire
    // its PERMIT_TAG_VOTING gate is here, while the factory still governs it (before updateGovernor).
    // Set once post-deploy via setCapabilityRegistry; address(0) ⇒ no binding (gate stays a no-op).
    address public capabilityRegistry;

    // #343 Step D (additive, post-cut, default OFF): democratic jurisdiction creation. When BOTH a
    // creatorResolver AND a foundationalJurisdictionId are set, a non-owner caller holding
    // PERMIT_JURISDICTION_CREATION on the Foundational Jurisdiction may create a jurisdiction. Until then
    // creation is owner-only (the re-genesis-cut behavior — unchanged).
    address public creatorResolver;
    uint256 public foundationalJurisdictionId;

    mapping(uint256 => JurisdictionRecord) public jurisdictions;
    // #343 box directory: jurisdictionId => kind (BOX_KIND_*) => box address.
    mapping(uint256 => mapping(bytes32 => address)) public jurisdictionBox;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ChainClockUpdated(address indexed previousClock, address indexed newClock);
    event BallotGovernorUpdated(address indexed previousGovernor, address indexed newGovernor);
    event PermissionlessJurisdictionCreationUpdated(bool enabled);
    event JurisdictionCreated(
        uint256 indexed jurisdictionId,
        address indexed ruleBallotBox,
        address indexed tagBallotBox,
        bytes32 ruleSetHash,
        bytes32 tagRegistryHash
    );
    event RuleSetHashUpdated(uint256 indexed jurisdictionId, bytes32 ruleSetHash);
    event TagRegistryHashUpdated(uint256 indexed jurisdictionId, bytes32 tagRegistryHash);
    event JurisdictionBoxRegistered(uint256 indexed jurisdictionId, bytes32 indexed kind, address box);
    event CreatorResolverUpdated(address indexed previousResolver, address indexed newResolver);
    event FoundationalJurisdictionIdUpdated(uint256 previousId, uint256 newId);

    modifier onlyOwner() {
        require(msg.sender == owner, "JurisdictionFactory: only owner");
        _;
    }

    /// #343 Step D: owner always passes (the bootstrap / re-genesis-cut path, unchanged). A non-owner
    /// passes ONLY when democratic creation is fully configured AND the caller resolves to a voterId that
    /// holds PERMIT_JURISDICTION_CREATION on the Foundational Jurisdiction. The `voterId != 0` guard is
    /// load-bearing: a zero/unknown voterId would fall through CapabilityRegistry to the permissive
    /// `voter` base role — so we reject it rather than let any wallet through.
    modifier canCreateJurisdiction() {
        if (msg.sender != owner) {
            require(
                creatorResolver != address(0)
                    && capabilityRegistry != address(0)
                    && foundationalJurisdictionId != 0,
                "JurisdictionFactory: democratic creation not configured"
            );
            bytes32 voterId = ICreatorResolver(creatorResolver).voterIdOf(msg.sender);
            require(voterId != bytes32(0), "JurisdictionFactory: caller has no FJ identity");
            require(
                ICapabilityGate(capabilityRegistry).hasCapability(
                    foundationalJurisdictionId, voterId, Capabilities.PERMIT_JURISDICTION_CREATION
                ),
                "JurisdictionFactory: not permitted to create"
            );
        }
        _;
    }

    constructor(address voteTokenAddress, address chainClockAddress, address initialGovernor, address ptsBankAddress) {
        require(voteTokenAddress != address(0), "JurisdictionFactory: vote token required");
        owner = msg.sender;
        voteToken = IVoteToken(voteTokenAddress);
        chainClock = ChainClock(chainClockAddress);
        ptsBank = IJurisdictionPts1155Bank(ptsBankAddress);
        ballotGovernor = initialGovernor == address(0) ? msg.sender : initialGovernor;
        emit OwnershipTransferred(address(0), owner);
        emit ChainClockUpdated(address(0), chainClockAddress);
        emit BallotGovernorUpdated(address(0), ballotGovernor);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "JurisdictionFactory: zero owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setBallotGovernor(address newGovernor) external onlyOwner {
        require(newGovernor != address(0), "JurisdictionFactory: zero governor");
        emit BallotGovernorUpdated(ballotGovernor, newGovernor);
        ballotGovernor = newGovernor;
    }

    function setChainClock(address newClock) external onlyOwner {
        emit ChainClockUpdated(address(chainClock), newClock);
        chainClock = ChainClock(newClock);
    }

    function setPermissionlessJurisdictionCreation(bool enabled) external onlyOwner {
        permissionlessJurisdictionCreation = enabled;
        emit PermissionlessJurisdictionCreationUpdated(enabled);
    }

    event CapabilityRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);
    /// Set the CapabilityRegistry bound onto every TagBallotBox created from here on. Does NOT
    /// retroactively bind already-created boxes (they're past their factory-governed window).
    function setCapabilityRegistry(address registry) external onlyOwner {
        emit CapabilityRegistryUpdated(capabilityRegistry, registry);
        capabilityRegistry = registry;
    }

    function createJurisdiction(
        uint256 jurisdictionId,
        bytes32 ruleSetHash,
        bytes32 tagRegistryHash,
        uint16 ruleQuorumBps,
        uint16 tagActivationBps,
        uint16 tagRetirementBps,
        bytes32[] calldata bootstrapTagKeys,
        bytes32[] calldata bootstrapTagMetadata
    ) external canCreateJurisdiction returns (address ruleBox, address tagBox) {
        address governorTarget = ballotGovernor == address(0) ? owner : ballotGovernor;
        return _createJurisdiction(
            jurisdictionId,
            ruleSetHash,
            tagRegistryHash,
            ruleQuorumBps,
            tagActivationBps,
            tagRetirementBps,
            bootstrapTagKeys,
            bootstrapTagMetadata,
            new bool[](0), // all bootstrap tags non-reserved (back-compat 8-arg path)
            governorTarget,
            governorTarget
        );
    }

    /// #343 edge #1: the reserved-aware create. `bootstrapTagReserved[i]` marks tag `i` as a reserved
    /// governance-domain tag (registered reserved=true → non-votable, never retired). The cut's
    /// publish_jurisdictions.js uses this so reserved tags from the DB are faithful on-chain. Same
    /// authority as createJurisdiction (`canCreateJurisdiction`).
    function createJurisdictionWithReserved(
        uint256 jurisdictionId,
        bytes32 ruleSetHash,
        bytes32 tagRegistryHash,
        uint16 ruleQuorumBps,
        uint16 tagActivationBps,
        uint16 tagRetirementBps,
        bytes32[] calldata bootstrapTagKeys,
        bytes32[] calldata bootstrapTagMetadata,
        bool[] calldata bootstrapTagReserved
    ) external canCreateJurisdiction returns (address ruleBox, address tagBox) {
        address governorTarget = ballotGovernor == address(0) ? owner : ballotGovernor;
        return _createJurisdiction(
            jurisdictionId,
            ruleSetHash,
            tagRegistryHash,
            ruleQuorumBps,
            tagActivationBps,
            tagRetirementBps,
            bootstrapTagKeys,
            bootstrapTagMetadata,
            bootstrapTagReserved,
            governorTarget,
            governorTarget
        );
    }

    function createJurisdictionPermissionless(
        uint256 jurisdictionId,
        bytes32 ruleSetHash,
        bytes32 tagRegistryHash,
        uint16 ruleQuorumBps,
        uint16 tagActivationBps,
        uint16 tagRetirementBps,
        bytes32[] calldata bootstrapTagKeys,
        bytes32[] calldata bootstrapTagMetadata
    ) external returns (address ruleBox, address tagBox) {
        require(permissionlessJurisdictionCreation, "JurisdictionFactory: permissionless disabled");
        return _createJurisdiction(
            jurisdictionId,
            ruleSetHash,
            tagRegistryHash,
            ruleQuorumBps,
            tagActivationBps,
            tagRetirementBps,
            bootstrapTagKeys,
            bootstrapTagMetadata,
            new bool[](0), // all bootstrap tags non-reserved
            msg.sender,
            msg.sender
        );
    }

    function _createJurisdiction(
        uint256 jurisdictionId,
        bytes32 ruleSetHash,
        bytes32 tagRegistryHash,
        uint16 ruleQuorumBps,
        uint16 tagActivationBps,
        uint16 tagRetirementBps,
        bytes32[] memory bootstrapTagKeys,
        bytes32[] memory bootstrapTagMetadata,
        bool[] memory bootstrapTagReserved,
        address governorTarget,
        address bootstrapOperator
    ) internal returns (address ruleBox, address tagBox) {
        require(governorTarget != address(0), "JurisdictionFactory: governor required");
        require(jurisdictionId > 0, "JurisdictionFactory: jurisdiction required");
        require(!jurisdictions[jurisdictionId].exists, "JurisdictionFactory: already exists");
        require(
            bootstrapTagKeys.length == bootstrapTagMetadata.length,
            "JurisdictionFactory: tag metadata mismatch"
        );
        // #343 edge #1: an empty reserved array ⇒ all bootstrap tags non-reserved (back-compat); a
        // provided one MUST align with the keys so reserved governance-domain tags register correctly.
        require(
            bootstrapTagReserved.length == 0 || bootstrapTagReserved.length == bootstrapTagKeys.length,
            "JurisdictionFactory: tag reserved mismatch"
        );
        require(tagActivationBps > tagRetirementBps, "JurisdictionFactory: invalid tag thresholds");

        // #343 item 4: the legacy per-jurisdiction RuleBallotBox is RETIRED — rules are tallied by the
        // B.2 per-structure family indexed by JurisdictionRuleRegistry (deployed separately + registered
        // in the box directory below). `ruleQuorumBps` is no longer consumed here (kept in the signature
        // for ABI continuity through the cut); the B.2 boxes carry their own quorum.
        ruleQuorumBps; // silence unused-parameter warning

        // TagBallotBox now extends BaseRuleBallotBox (anonymous spine): the constructor takes a
        // `address` vote token + an EIP-2771 trustedForwarder before the thresholds. The factory
        // wires no forwarder (meta-tx off for bootstrap; the anonymous path doesn't need it) → address(0).
        TagBallotBox tagBallot = new TagBallotBox(
            address(voteToken),
            jurisdictionId,
            address(this),
            address(chainClock),
            address(0),
            tagActivationBps,
            tagRetirementBps
        );

        jurisdictions[jurisdictionId] = JurisdictionRecord({
            ruleBallotBox: address(0), // RETIRED (#343) — read rule boxes via JurisdictionRuleRegistry
            tagBallotBox: address(tagBallot),
            ruleSetHash: ruleSetHash,
            tagRegistryHash: tagRegistryHash,
            createdAt: block.timestamp,
            exists: true
        });

        // #343 box directory: the tag box is the one box the factory itself builds.
        jurisdictionBox[jurisdictionId][BOX_KIND_TAG] = address(tagBallot);
        emit JurisdictionBoxRegistered(jurisdictionId, BOX_KIND_TAG, address(tagBallot));

        emit JurisdictionCreated(
            jurisdictionId,
            address(0), // ruleBallotBox retired (#343)
            address(tagBallot),
            ruleSetHash,
            tagRegistryHash
        );

        for (uint256 i = 0; i < bootstrapTagKeys.length; i++) {
            if (bootstrapTagKeys[i] == bytes32(0)) {
                continue;
            }
            // #343 edge #1: a reserved governance-domain tag (tag_governance/role_governance) is
            // registered reserved=true here — the ONLY deployer-governed window (registerTag is
            // onlyGovernor; the box hands off to `governorTarget` below). Reserved ⇒ exempt from the
            // existence vote, never retired, not votable. Topic tags register reserved=false.
            bool reserved = bootstrapTagReserved.length == 0 ? false : bootstrapTagReserved[i];
            tagBallot.registerTag(bootstrapTagKeys[i], bootstrapTagMetadata[i], true, reserved);
        }

        // C2 follow-on: bind the PERMIT_TAG_VOTING gate while the factory still governs the box —
        // this is the ONLY deployer-governed window the tag box ever has (the handoff is next).
        if (capabilityRegistry != address(0)) {
            tagBallot.setCapabilityRegistry(capabilityRegistry);
        }

        if (governorTarget != address(this)) {
            tagBallot.updateGovernor(governorTarget);
        }

        if (address(ptsBank) != address(0)) {
            ptsBank.bootstrapJurisdictionFromFactory(jurisdictionId, governorTarget, bootstrapOperator);
        }

        // ruleBox return is address(0) (#343 — legacy rule box retired); kept for ABI/return-shape continuity.
        return (address(0), address(tagBallot));
    }

    function updateRuleSetHash(uint256 jurisdictionId, bytes32 ruleSetHash) external onlyOwner {
        JurisdictionRecord storage record = _record(jurisdictionId);
        record.ruleSetHash = ruleSetHash;
        emit RuleSetHashUpdated(jurisdictionId, ruleSetHash);
    }

    function updateTagRegistryHash(uint256 jurisdictionId, bytes32 tagRegistryHash) external onlyOwner {
        JurisdictionRecord storage record = _record(jurisdictionId);
        record.tagRegistryHash = tagRegistryHash;
        emit TagRegistryHashUpdated(jurisdictionId, tagRegistryHash);
    }

    /// #343: only the TagBallotBox is factory-built now (rules live in the B.2 family). The B.2 boxes
    /// sync their own ChainClock via the rule-family deploy.
    function syncChainClock(uint256 jurisdictionId) external onlyOwner {
        JurisdictionRecord storage record = _record(jurisdictionId);
        if (record.tagBallotBox != address(0)) {
            TagBallotBox(record.tagBallotBox).setChainClock(address(chainClock));
        }
    }

    function reassignJurisdictionGovernor(uint256 jurisdictionId, address newGovernor) external onlyOwner {
        require(newGovernor != address(0), "JurisdictionFactory: zero governor");
        JurisdictionRecord storage record = _record(jurisdictionId);
        if (record.tagBallotBox != address(0)) {
            TagBallotBox(record.tagBallotBox).updateGovernor(newGovernor);
        }
    }

    // #343 box directory + Step D config -------------------------------------------------

    /// Register a jurisdiction's box of a given kind (BOX_KIND_*) in the on-chain directory. The role /
    /// initiative / rule-registry deploy scripts call this so all boxes are enumerable on-chain.
    /// Idempotent (overwrites on re-register). NOTE: intentionally does NOT require the factory record to
    /// pre-exist — the directory is a pure address enumeration, and in the cut pipeline the role +
    /// initiative boxes are deployed BEFORE `publish_jurisdictions` creates the factory record. The
    /// jurisdiction id set is the deployer-controlled `JURISDICTION_IDS`; `box == address(0)` clears.
    function registerJurisdictionBox(uint256 jurisdictionId, bytes32 kind, address box) external onlyOwner {
        require(jurisdictionId > 0, "JurisdictionFactory: jurisdiction required");
        require(kind != bytes32(0), "JurisdictionFactory: kind required");
        jurisdictionBox[jurisdictionId][kind] = box;
        emit JurisdictionBoxRegistered(jurisdictionId, kind, box);
    }

    /// Enumerate a jurisdiction's box of a given kind (address(0) if unset).
    function boxOfKind(uint256 jurisdictionId, bytes32 kind) external view returns (address) {
        return jurisdictionBox[jurisdictionId][kind];
    }

    /// #343 Step D: set the wallet→voterId resolver for democratic creation. address(0) ⇒ owner-only.
    function setCreatorResolver(address resolver) external onlyOwner {
        emit CreatorResolverUpdated(creatorResolver, resolver);
        creatorResolver = resolver;
    }

    /// #343 Step D: set the Foundational Jurisdiction whose PERMIT_JURISDICTION_CREATION gates democratic
    /// creation. 0 ⇒ owner-only.
    function setFoundationalJurisdictionId(uint256 jid) external onlyOwner {
        emit FoundationalJurisdictionIdUpdated(foundationalJurisdictionId, jid);
        foundationalJurisdictionId = jid;
    }

    function _record(uint256 jurisdictionId) internal view returns (JurisdictionRecord storage record) {
        record = jurisdictions[jurisdictionId];
        require(record.exists, "JurisdictionFactory: unknown jurisdiction");
    }
}
