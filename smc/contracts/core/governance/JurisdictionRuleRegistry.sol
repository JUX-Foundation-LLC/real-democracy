// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./IRuleBallotBox.sol";

/// Minimal read surface a TagBallotBox exposes so the rule registry can validate, at bind time, that a
/// rule's delegation tag EXISTS on the rule's OWN jurisdiction — making the tag→jurisdiction binding
/// explicit on-chain rather than relying on implicit per-box scoping. (TagBallotBox implements both.)
interface ITagBox {
    function jurisdictionId() external view returns (uint256);
    function tagExists(bytes32 tagKey) external view returns (bool);
}

/**
 * @title JurisdictionRuleRegistry
 * @notice The per-rule on-chain governance INDEX (renamed from `RuleBallotBoxRegistry`, #343). For each
 *         `(jurisdiction, ruleKey)` it records BOTH:
 *           1. the structure-box that tallies the rule (boolean / average / median / plurality), and
 *           2. the SINGLE delegation tag the rule carries (one tag per rule — the multi-tag model was
 *              scrapped; many tags per rule caused delegation conflicts).
 *
 *         It is the single on-chain surface a consumer (a payment splitter, a lighting controller, the
 *         frontend, the watcher, an external auditor) reads a rule's live democratic outcome AND its
 *         delegation tag through. The tag itself (existence / metadata / jurisdiction) lives on the
 *         per-jurisdiction `TagBallotBox`; THIS contract binds which tag a given rule carries.
 *
 *         A jurisdiction deploys its structure boxes (each an IRuleBallotBox), then binds
 *         `(jurisdiction, ruleKey) → box`. Binding is authority-gated AND validated: the target MUST be
 *         an IRuleBallotBox (ERC-165) pinned to the SAME jurisdiction. The delegation tag is bound the
 *         same way and validated against that jurisdiction's TagBallotBox.
 *
 *         Authority is per-jurisdiction: a `jurisdictionGovernor[jid]` (the vote-outcome executor in
 *         production), OR any `REGISTRAR_ROLE` holder (the backend signer during bootstrap) — mirroring
 *         JurisdictionRoleRegistry so authority can migrate from backend to democracy per jurisdiction
 *         without redeploying.
 *
 *         §5.3 TYPE-CHANGE REUSE: re-registering a rule into a different structure box is exactly
 *         `bindRuleBox` (rebind) — the tag-switch (`bindRuleTag`) is its sibling on the same index, same
 *         `canRegister` authority, both mirror-able events.
 */
contract JurisdictionRuleRegistry is AccessControl {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    /// jurisdiction => binding authority (e.g. the vote-outcome executor)
    mapping(uint256 => address) public jurisdictionGovernor;
    /// (jurisdiction, ruleKey) => the IRuleBallotBox that tallies it
    mapping(uint256 => mapping(bytes32 => address)) public ruleBox;
    /// (jurisdiction, ruleKey) => the SINGLE delegation tag the rule carries (bytes32(0) = none).
    /// Single-valued by construction — the on-chain enforcement of the one-tag-per-rule invariant.
    mapping(uint256 => mapping(bytes32 => bytes32)) public ruleDelegationTag;
    /// Optional, democratically-authorized coordinator for fail-closed shadow-box activation.
    /// The coordinator never gains arbitrary binding authority: it may only perform a verified,
    /// compare-and-swap replacement of an existing box with the same structure.
    mapping(uint256 => address) public reprojectionCoordinator;

    event JurisdictionGovernorUpdated(uint256 indexed jurisdictionId, address governor);
    event RuleBoxBound(
        uint256 indexed jurisdictionId,
        bytes32 indexed ruleKey,
        address indexed box,
        bytes32 structureId
    );
    event RuleBoxCleared(uint256 indexed jurisdictionId, bytes32 indexed ruleKey, address previousBox);
    event RuleTagBound(
        uint256 indexed jurisdictionId,
        bytes32 indexed ruleKey,
        bytes32 indexed tagKey,
        address tagBallotBox
    );
    event RuleTagCleared(uint256 indexed jurisdictionId, bytes32 indexed ruleKey, bytes32 previousTagKey);
    event ReprojectionCoordinatorUpdated(uint256 indexed jurisdictionId, address indexed coordinator);

    error NotAuthorized(uint256 jurisdictionId, address caller);

    constructor(address admin) {
        address initial = admin == address(0) ? msg.sender : admin;
        _grantRole(DEFAULT_ADMIN_ROLE, initial);
        _grantRole(REGISTRAR_ROLE, initial);
    }

    /// G4 (audit S4): once a jurisdiction has a governor (the vote-outcome executor, set at democratic
    /// migration), ONLY that governor may bind/rebind its rule boxes — the bootstrap `REGISTRAR_ROLE` is
    /// locked out, so the backend can no longer swap the outcome the executor reads after handover. Only
    /// before a governor is set (pure bootstrap) may a REGISTRAR bind.
    modifier canRegister(uint256 jurisdictionId) {
        address gov = jurisdictionGovernor[jurisdictionId];
        if (gov != address(0)) {
            if (msg.sender != gov) revert NotAuthorized(jurisdictionId, msg.sender);
        } else if (!hasRole(REGISTRAR_ROLE, msg.sender)) {
            revert NotAuthorized(jurisdictionId, msg.sender);
        }
        _;
    }

    /// Hand a jurisdiction's binding authority to a governor (the vote-outcome executor).
    function setJurisdictionGovernor(uint256 jurisdictionId, address governor)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        jurisdictionGovernor[jurisdictionId] = governor;
        emit JurisdictionGovernorUpdated(jurisdictionId, governor);
    }

    /// @notice Allow the jurisdiction's existing democratic authority to opt into (or remove)
    ///         a shadow reprojection coordinator. After handoff only the governor can do this.
    function setReprojectionCoordinator(uint256 jurisdictionId, address coordinator)
        external
        canRegister(jurisdictionId)
    {
        require(jurisdictionId > 0, "Registry: jurisdiction required");
        reprojectionCoordinator[jurisdictionId] = coordinator;
        emit ReprojectionCoordinatorUpdated(jurisdictionId, coordinator);
    }

    /// @notice Narrow callback used by the authorized coordinator. All ordinary binding authority
    ///         remains governed by `canRegister`; this route can only replace an existing Rule box
    ///         with the same structure in the same jurisdiction.
    function activateReprojectedRuleBox(uint256 jurisdictionId, bytes32 ruleKey, address expectedCurrent, address box)
        external
    {
        require(msg.sender == reprojectionCoordinator[jurisdictionId], "Registry: not reprojection coordinator");
        require(expectedCurrent != address(0) && ruleBox[jurisdictionId][ruleKey] == expectedCurrent,
            "Registry: current box changed");
        _validateRuleBox(jurisdictionId, ruleKey, box);
        require(
            IRuleBallotBox(expectedCurrent).structureId() == IRuleBallotBox(box).structureId(),
            "Registry: structure mismatch"
        );
        ruleBox[jurisdictionId][ruleKey] = box;
        emit RuleBoxBound(jurisdictionId, ruleKey, box, IRuleBallotBox(box).structureId());
    }

    /**
     * @notice Bind a rule to the structure-box that tallies it. Validated: `box` must be
     *         an IRuleBallotBox (ERC-165) pinned to `jurisdictionId`.
     */
    function bindRuleBox(uint256 jurisdictionId, bytes32 ruleKey, address box)
        external
        canRegister(jurisdictionId)
    {
        _validateRuleBox(jurisdictionId, ruleKey, box);
        ruleBox[jurisdictionId][ruleKey] = box;
        emit RuleBoxBound(jurisdictionId, ruleKey, box, IRuleBallotBox(box).structureId());
    }

    function _validateRuleBox(uint256 jurisdictionId, bytes32 ruleKey, address box) private view {
        require(jurisdictionId > 0, "Registry: jurisdiction required");
        require(ruleKey != bytes32(0), "Registry: rule key required");
        require(box != address(0), "Registry: box required");
        require(IERC165(box).supportsInterface(type(IRuleBallotBox).interfaceId), "Registry: not a rule ballotbox");
        require(IRuleBallotBox(box).jurisdictionId() == jurisdictionId, "Registry: box jurisdiction mismatch");
    }

    function clearRuleBox(uint256 jurisdictionId, bytes32 ruleKey) external canRegister(jurisdictionId) {
        address previous = ruleBox[jurisdictionId][ruleKey];
        delete ruleBox[jurisdictionId][ruleKey];
        emit RuleBoxCleared(jurisdictionId, ruleKey, previous);
    }

    /**
     * @notice Bind / reassign the SINGLE delegation tag a rule carries (the on-chain home for the
     *         tag-switch amendment, #343). Single-valued: each `(jurisdiction, ruleKey)` maps to exactly
     *         one `tagKey`, overwriting any prior — the one-tag invariant by construction.
     *
     *         Validated jurisdiction-explicitly: the rule must already be bound to a box here, and the
     *         supplied `tagBallotBox` must (a) be pinned to the SAME `jurisdictionId` and (b) actually
     *         hold `tagKey` — so a rule can only carry a tag that EXISTS on its own jurisdiction, and an
     *         auditor reading this event sees the tag, the rule, the jurisdiction, and the tag's box.
     */
    function bindRuleTag(uint256 jurisdictionId, bytes32 ruleKey, bytes32 tagKey, address tagBallotBox)
        external
        canRegister(jurisdictionId)
    {
        require(ruleBox[jurisdictionId][ruleKey] != address(0), "Registry: rule not bound");
        require(tagKey != bytes32(0), "Registry: tag key required");
        require(tagBallotBox != address(0), "Registry: tag box required");
        require(
            ITagBox(tagBallotBox).jurisdictionId() == jurisdictionId,
            "Registry: tag jurisdiction mismatch"
        );
        require(ITagBox(tagBallotBox).tagExists(tagKey), "Registry: unknown tag");
        ruleDelegationTag[jurisdictionId][ruleKey] = tagKey;
        emit RuleTagBound(jurisdictionId, ruleKey, tagKey, tagBallotBox);
    }

    function clearRuleTag(uint256 jurisdictionId, bytes32 ruleKey) external canRegister(jurisdictionId) {
        bytes32 previous = ruleDelegationTag[jurisdictionId][ruleKey];
        delete ruleDelegationTag[jurisdictionId][ruleKey];
        emit RuleTagCleared(jurisdictionId, ruleKey, previous);
    }

    // --- the consumer read surface ------------------------------------------------------

    /// The box that tallies a rule (address(0) if unbound).
    function boxFor(uint256 jurisdictionId, bytes32 ruleKey) external view returns (address) {
        return ruleBox[jurisdictionId][ruleKey];
    }

    /// The single delegation tag a rule carries (bytes32(0) if unbound).
    function tagFor(uint256 jurisdictionId, bytes32 ruleKey) external view returns (bytes32) {
        return ruleDelegationTag[jurisdictionId][ruleKey];
    }

    /// Read a rule's live democratic result in one call, through whatever structure it uses.
    function resultFor(uint256 jurisdictionId, bytes32 ruleKey)
        external
        view
        returns (int256 value, uint256 totalVotes, bool quorumMet)
    {
        address box = ruleBox[jurisdictionId][ruleKey];
        require(box != address(0), "Registry: rule not bound");
        return IRuleBallotBox(box).currentResult(ruleKey);
    }
}
