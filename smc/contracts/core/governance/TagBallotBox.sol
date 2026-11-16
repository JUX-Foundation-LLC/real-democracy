// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseRuleBallotBox.sol";

/**
 * @title TagBallotBox
 * @notice ANONYMOUS, STANDING support tally for a Tag's EXISTENCE. Rides the shared
 *         `BaseRuleBallotBox` anonymous spine — WHO signals support/withdraw is anonymous; only the
 *         SUBJECT (which `tagKey`) is public. A "withdraw" is an oppose `[0]` vote, so
 *         `supportBps = supporters / participants` (BaseRuleBallotBox's distinct-voter count is the
 *         denominator). Hysteresis: a tag ACTIVATES when support ≥ activation and RETIRES when
 *         support < retirement (activation > retirement), auto-evaluated on every vote.
 *
 *         RESERVED governance-domain tags (`tag_governance` / `role_governance`) are EXEMPT — they
 *         exist by fiat, are NOT votable, and NEVER retire; only topic tags go through the existence
 *         vote. Gated by `PERMIT_TAG_VOTING`. (Replaces the retired tokenId-public `castTagSignal`
 *         design: per Coi, ALL ballotboxes are anonymous; the only revealed fact is the subject.)
 */
contract TagBallotBox is BaseRuleBallotBox {
    struct Tally {
        uint256 support;
        uint256 oppose; // a "withdraw" — keeps the participant in the denominator
    }
    mapping(bytes32 => Tally) public tallies;

    struct TagState {
        uint16 activationThresholdBps;
        uint16 retirementThresholdBps;
        bool active;
        bool reserved; // governance-domain tag — not votable, never retired
        bool exists;
        uint256 lastEvaluatedTick;
    }
    mapping(bytes32 => TagState) public tags;

    uint16 public defaultActivationThresholdBps;
    uint16 public defaultRetirementThresholdBps;

    event DefaultsUpdated(uint16 activationBps, uint16 retirementBps);
    event TagRegistered(bytes32 indexed tagKey, bytes32 metadataHash, bool active, bool reserved);
    event TagMetadataUpdated(bytes32 indexed tagKey, bytes32 metadataHash);
    event TagThresholdsUpdated(bytes32 indexed tagKey, uint16 activationBps, uint16 retirementBps);
    event TagActivated(bytes32 indexed tagKey, uint256 tick);
    event TagRetired(bytes32 indexed tagKey, uint256 tick);

    constructor(
        address voteTokenAddress,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        address trustedForwarder,
        uint16 activationBps,
        uint16 retirementBps
    )
        // The base's single quorum is unused here (tags carry per-tag activation/retirement); pass a
        // fixed valid value so the base doesn't intercept the activation bound check below.
        BaseRuleBallotBox(voteTokenAddress, _jurisdictionId, _governor, _chainClock, 6000, trustedForwarder)
    {
        require(activationBps <= MAX_BPS, "TagBox: activation too high");
        require(retirementBps <= MAX_BPS, "TagBox: retirement too high");
        require(activationBps > retirementBps, "TagBox: invalid thresholds");
        defaultActivationThresholdBps = activationBps;
        defaultRetirementThresholdBps = retirementBps;
        emit DefaultsUpdated(activationBps, retirementBps);
    }

    function structureId() external pure override returns (bytes32) {
        return keccak256("tag_support");
    }

    /// Whether a tag has been registered on this box. Lets the JurisdictionRuleRegistry validate, at
    /// `bindRuleTag`, that a rule's delegation tag actually exists on this (its own) jurisdiction —
    /// the explicit tag→jurisdiction binding (#343). Satisfies `ITagBox`.
    function tagExists(bytes32 tagKey) external view returns (bool) {
        return tags[tagKey].exists;
    }

    /// Tag voting requires PERMIT_TAG_VOTING — NOT PERMIT_RULE_VOTING (the shared base default).
    function _votingCapability() internal pure override returns (bytes32) {
        return Capabilities.PERMIT_TAG_VOTING;
    }

    /// INFO-2 (#310): accurate capability-denied message for this box.
    function _votingDeniedMessage() internal pure override returns (string memory) {
        return "TagBallotBox: tag voting not permitted";
    }

    /// #310 HIGH-1: tag votes are anonymous-only — close the transparent tokenId path by construction.
    function _transparentVotingDisabledByDefault() internal pure override returns (bool) {
        return true;
    }

    function setDefaultThresholds(uint16 activationBps, uint16 retirementBps) external onlyGovernor {
        require(activationBps <= MAX_BPS, "TagBox: activation too high");
        require(retirementBps <= MAX_BPS, "TagBox: retirement too high");
        require(activationBps > retirementBps, "TagBox: invalid thresholds");
        defaultActivationThresholdBps = activationBps;
        defaultRetirementThresholdBps = retirementBps;
        emit DefaultsUpdated(activationBps, retirementBps);
    }

    /// Open a tag for the existence vote (or update its metadata). `reserved` marks a governance-domain
    /// tag exempt from the vote (not votable, never retired). Governor-only.
    function registerTag(bytes32 tagKey, bytes32 metadataHash, bool activeInitially, bool reserved)
        external
        onlyGovernor
    {
        require(tagKey != bytes32(0), "TagBox: tag key required");
        TagState storage tag = tags[tagKey];
        bool isNew = !tag.exists;
        if (isNew) {
            tag.activationThresholdBps = defaultActivationThresholdBps;
            tag.retirementThresholdBps = defaultRetirementThresholdBps;
            tag.active = activeInitially;
            tag.reserved = reserved;
            tag.exists = true;
        }
        tag.lastEvaluatedTick = _currentTick();

        // Register the votable key in the base so the anonymous-vote machinery applies.
        RuleMeta storage m = ruleMeta[tagKey];
        m.metadataHash = metadataHash;
        if (!m.exists) {
            m.exists = true;
            emit RuleRegistered(tagKey, metadataHash);
        } else {
            emit RuleConfigUpdated(tagKey, metadataHash);
        }
        if (isNew) emit TagRegistered(tagKey, metadataHash, activeInitially, reserved);
        else emit TagMetadataUpdated(tagKey, metadataHash);
    }

    function setTagThresholds(bytes32 tagKey, uint16 activationBps, uint16 retirementBps) external onlyGovernor {
        require(activationBps <= MAX_BPS, "TagBox: activation too high");
        require(retirementBps <= MAX_BPS, "TagBox: retirement too high");
        require(activationBps > retirementBps, "TagBox: invalid thresholds");
        TagState storage tag = tags[tagKey];
        require(tag.exists, "TagBox: unknown tag");
        tag.activationThresholdBps = activationBps;
        tag.retirementThresholdBps = retirementBps;
        emit TagThresholdsUpdated(tagKey, activationBps, retirementBps);
        _evaluateTag(tagKey);
    }

    /// Permissionless re-evaluation (deterministic from the on-chain tally — votes auto-evaluate via
    /// `_applyVote`; this is for an explicit nudge, e.g. after a threshold change off the vote path).
    function evaluateTag(bytes32 tagKey) external {
        require(tags[tagKey].exists, "TagBox: unknown tag");
        _evaluateTag(tagKey);
    }

    // ── boolean support/withdraw tally + auto-hysteresis ───────────────────────────────────────
    function _configureRule(bytes32, bytes calldata) internal pure override {
        // tags carry no structure-specific config (support/withdraw)
    }

    function _validateBallot(bytes32 tagKey, uint16[] calldata ballot) internal view override {
        require(tags[tagKey].exists, "TagBox: unknown tag");
        require(!tags[tagKey].reserved, "TagBox: reserved tag not votable");
        require(ballot.length == 1 && ballot[0] <= 1, "TagBox: ballot must be [0] or [1]");
    }

    function _applyVote(bytes32 tagKey, uint16[] memory prev, uint16[] calldata next) internal override {
        Tally storage t = tallies[tagKey];
        if (prev.length == 1) {
            if (prev[0] == 1) t.support -= 1;
            else t.oppose -= 1;
        }
        if (next[0] == 1) t.support += 1;
        else t.oppose += 1;
        _evaluateTag(tagKey); // auto activate/retire on the new tally
    }

    function _resultValue(bytes32 tagKey, uint256 totalVotes)
        internal
        view
        override
        returns (int256 value, bool quorumMet)
    {
        uint256 supportBps = (tallies[tagKey].support * uint256(MAX_BPS)) / totalVotes;
        value = int256(supportBps);
        quorumMet = supportBps >= tags[tagKey].activationThresholdBps; // "would activate"
    }

    function _evaluateTag(bytes32 tagKey) internal {
        TagState storage tag = tags[tagKey];
        uint256 total = voterCount[tagKey];
        if (total == 0) {
            if (tag.active && !tag.reserved) {
                tag.active = false;
                tag.lastEvaluatedTick = _currentTick();
                emit TagRetired(tagKey, tag.lastEvaluatedTick);
            }
            return;
        }
        uint256 supportBps = (tallies[tagKey].support * uint256(MAX_BPS)) / total;
        if (!tag.active && supportBps >= tag.activationThresholdBps) {
            tag.active = true;
            tag.lastEvaluatedTick = _currentTick();
            emit TagActivated(tagKey, tag.lastEvaluatedTick);
        } else if (tag.active && !tag.reserved && supportBps < tag.retirementThresholdBps) {
            tag.active = false;
            tag.lastEvaluatedTick = _currentTick();
            emit TagRetired(tagKey, tag.lastEvaluatedTick);
        }
    }
}
