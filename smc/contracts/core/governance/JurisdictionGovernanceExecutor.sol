// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./Capabilities.sol";

interface IVoteTokenEligibilityView {
    function isActive(uint256 tokenId) external view returns (bool);
    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256);
    function voterIdOf(uint256 tokenId) external view returns (bytes32);
    /// Live count of active tokens in a jurisdiction: the electorate size the turnout gate divides by.
    function activeTokenCount(uint256 jurisdictionId) external view returns (uint256);
}

interface IDelegatedAverageRuleBox {
    function governor() external view returns (address);
    function jurisdictionId() external view returns (uint256);
    function structureId() external view returns (bytes32);
    function registerRule(bytes32 ruleKey, bytes32 metadataHash, bytes calldata config) external;
    function setRuleExternalNullifier(bytes32 ruleKey, uint256 externalNullifier) external;
}

interface IDelegatedRuleRegistry {
    function jurisdictionGovernor(uint256 jurisdictionId) external view returns (address);
    function boxFor(uint256 jurisdictionId, bytes32 ruleKey) external view returns (address);
    function bindRuleBox(uint256 jurisdictionId, bytes32 ruleKey, address box) external;
    function bindRuleTag(uint256 jurisdictionId, bytes32 ruleKey, bytes32 tagKey, address tagBallotBox) external;
}

interface IDelegatedTagBox {
    function governor() external view returns (address);
    function jurisdictionId() external view returns (uint256);
    function tagExists(bytes32 tagKey) external view returns (bool);
    function registerTag(bytes32 tagKey, bytes32 metadataHash, bool activeInitially, bool reserved) external;
}

/// The decision-ballot surface JGE reads — the B.2 `IRuleBallotBox` subset. JGE gates execution on
/// `currentResult` (the uniform on-chain tally that ANONYMOUS votes feed identically), so it no
/// longer depends on the transparent `submitRuleVote`/`ruleSupportBps`/`publishRule` path.
/// The box may be a `BooleanRuleBallotBox` whose votes are anonymous (`castVoteAnonymous`).
/// (GOVERNANCE_SPINE §8.3 — APPLY decoupled from the transparent DECIDE path.)
interface IDecisionBallotBox {
    function governor() external view returns (address);
    function jurisdictionId() external view returns (uint256);
    function structureId() external view returns (bytes32);
    function registerRule(bytes32 ruleKey, bytes32 metadataHash, bytes calldata config) external;
    function currentResult(bytes32 ruleKey) external view returns (int256 value, uint256 totalVotes, bool quorumMet);
}

interface IJurisdictionFactoryRegistry {
    function jurisdictions(uint256 jurisdictionId)
        external
        view
        returns (
            address ruleBallotBox,
            address tagBallotBox,
            bytes32 ruleSetHash,
            bytes32 tagRegistryHash,
            uint256 createdAt,
            bool exists
        );
}

/**
 * @title JurisdictionGovernanceExecutor
 * @notice Vote-driven executive for jurisdiction governance. The executor is
 *         installed as the governor of each jurisdiction's RuleBallotBox and
 *         of the JurisdictionPts1155Bank, so no single account can act on
 *         critical structures: actions are proposed by VoteToken holders,
 *         voted on through the jurisdiction's existing RuleBallotBox
 *         (`submitRuleVote`), and ANYONE may execute the action permissionlessly
 *         once all four gates hold (audit S1/S2/S12, GOVERNANCE G1 parts 2-3):
 *           1. waiting time: `executionDelay` has passed since the proposal, so the
 *              electorate has time to see the action and vote against it;
 *           2. lifetime: the action is not older than delay + `ACTION_LIFETIME`;
 *           3. turnout: participating votes are at least `participationBps` of the
 *              jurisdiction's ACTIVE VoteTokens (and at least `minTotalVotes`);
 *           4. support: the ballot box reports `quorumMet` (support among participants).
 *         Tallies are continuous (no snapshot), so one waiting time replaces a separate
 *         voting window + time-lock: the result must hold at the moment of execution.
 *
 *         Known limits (unaudited by a human; see WO_EXECUTOR_TURNOUT_GATE.md):
 *           - `totalVotes` is the box's count of tokens that ever voted on the decision. A vote
 *             cast by a token that is later disabled still counts, and the anonymous path trusts
 *             the eligibility root the backend publishes. Turnout is as honest as the issuer.
 *           - Scope limits which jurisdiction id this executor accepts, NOT what a passed action
 *             may call. Never make a scoped executor governor of another jurisdiction's
 *             structures or of anything shared.
 *
 *         A renounceable bootstrapSteward exists only for initial wiring
 *         (registering replacement ballot boxes for legacy jurisdictions and
 *         setting participation floors). Once renounced, those knobs are only
 *         reachable through the democratic process itself (self-call actions).
 */
contract JurisdictionGovernanceExecutor {
    uint16 public constant LABOR_RULE_MAX_VALUE = 1000;
    bytes32 public constant AVERAGE_STRUCTURE_ID = keccak256("average");
    /// Decision boxes must be Boolean: the other structures report `quorumMet` unconditionally.
    bytes32 public constant BOOLEAN_STRUCTURE_ID = keccak256("boolean");

    /// An **Executive Action** (GOVERNANCE_SPINE vocabulary lock): the on-chain APPLY of a passed
    /// decision — NOT a "Proposal" (the democratic decision artifact) and NOT a jurisdiction "Rule".
    /// `ruleKey` here is the *decision ballot's* key on the box (a boolean "should we execute this
    /// action?"), distinct from a governable Rule value like `quorum_threshold`.
    struct Action {
        uint256 jurisdictionId;
        address proposer;
        uint256 proposerTokenId;
        address target;
        bytes callData;
        bytes32 ruleKey;
        uint64 proposedAt;
        bool executed;
        bool cancelled;
    }

    IVoteTokenEligibilityView public immutable voteToken;
    IERC721 public immutable voteTokenNft;
    IJurisdictionFactoryRegistry public immutable factory;

    /// The ONE jurisdiction this executor serves (0 = unscoped, legacy/global). An executed action
    /// is an arbitrary call made as the executor, so an executor that governs several jurisdictions
    /// lets the smallest one act on all of them (see test/ExecutorCrossJurisdiction.poc.test.js).
    /// A scoped executor refuses every other jurisdiction id; deployment must make it governor of
    /// that jurisdiction's structures only.
    uint256 public immutable scopeJurisdictionId;

    /// Capability resolver used by narrow delegated-operation lanes. Unlike ordinary ballot-box
    /// capability wiring, address(0) is fail-CLOSED here: no one may use a delegated lane until the
    /// jurisdiction's governed role/capability sources are explicitly connected.
    ICapabilityGate public capabilityRegistry;
    /// Shared EIP-2771 forwarder accepted only by delegated-operation identity checks. This keeps
    /// capable VoteToken wallets gasless without changing the ordinary proposal lifecycle.
    address public delegatedTrustedForwarder;

    struct LaborRuleRegistrationPolicy {
        address averageRuleBox;
        address ruleRegistry;
        address tagBallotBox;
        bool enabled;
    }

    struct GovernanceTagRegistrationPolicy {
        address tagBallotBox;
        bool enabled;
    }

    /// Infrastructure is jurisdiction-scoped and can only be configured by bootstrap stewardship or
    /// an executor self-call after a passed vote. The operational caller cannot choose these targets.
    mapping(uint256 => LaborRuleRegistrationPolicy) public laborRuleRegistrationPolicy;
    /// Non-zero fingerprint means the executor completed this exact registration atomically.
    mapping(uint256 => mapping(bytes32 => bytes32)) public laborRuleRegistrationFingerprint;
    mapping(uint256 => GovernanceTagRegistrationPolicy) public governanceTagRegistrationPolicy;
    mapping(uint256 => mapping(bytes32 => bytes32)) public governanceTagRegistrationFingerprint;

    address public bootstrapSteward;

    /// Legacy jurisdictions whose factory-recorded RuleBallotBox is governor-
    /// locked get a replacement box registered here; it takes precedence over
    /// the factory lookup.
    mapping(uint256 => address) public ruleBallotBoxOverride;

    /// Optional ABSOLUTE floor on participating votes, applied on top of the turnout share
    /// (`requiredVotes`). The turnout share is what guards against a single early voter.
    mapping(uint256 => uint256) public minTotalVotes;

    /// Turnout gate defaults. A jurisdiction with no explicit policy gets these, so there is no
    /// "unset means one vote is enough" state.
    uint16 public constant DEFAULT_PARTICIPATION_BPS = 3000; // 30% of active VoteTokens must vote
    uint64 public constant DEFAULT_EXECUTION_DELAY = 72 hours;
    uint64 public constant MAX_EXECUTION_DELAY = 30 days;
    /// Upper bound on the turnout share. Frozen VoteTokens stay in the electorate count but cannot
    /// vote, so a 100% requirement could become unreachable and lock governance for good.
    uint16 public constant MAX_PARTICIPATION_BPS = 7500;
    /// How long a passed action stays executable after its waiting time ends. Stops a stale action
    /// from being executed long after the vote that carried it.
    uint64 public constant ACTION_LIFETIME = 30 days;

    struct TurnoutPolicy {
        uint16 participationBps; // 1..10000 once configured
        uint64 executionDelay;   // seconds; 0 allowed only as an explicit choice
        bool configured;
    }
    mapping(uint256 => TurnoutPolicy) private _turnoutPolicy;
    /// Earliest execution time per action, FIXED when the action is proposed. A later change to the
    /// waiting time never rushes, delays or expires an action that is already pending.
    mapping(uint256 => uint64) public actionExecutableAt;

    uint256 public actionCount;
    mapping(uint256 => Action) public actions;

    event BootstrapStewardUpdated(address indexed previousSteward, address indexed newSteward);
    event RuleBallotBoxOverrideUpdated(uint256 indexed jurisdictionId, address indexed ballotBox);
    event MinTotalVotesUpdated(uint256 indexed jurisdictionId, uint256 minVotes);
    event TurnoutPolicyUpdated(uint256 indexed jurisdictionId, uint16 participationBps, uint64 executionDelay);
    event CapabilityRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);
    event DelegatedTrustedForwarderUpdated(address indexed previousForwarder, address indexed newForwarder);
    event LaborRuleRegistrationPolicyUpdated(
        uint256 indexed jurisdictionId,
        address indexed averageRuleBox,
        address indexed ruleRegistry,
        address tagBallotBox,
        bool enabled
    );
    event LaborRuleRegistered(
        uint256 indexed jurisdictionId,
        bytes32 indexed ruleKey,
        bytes32 indexed voterId,
        uint256 tokenId,
        bytes32 metadataHash,
        bytes32 tagKey,
        uint256 externalNullifier,
        bytes32 registrationFingerprint
    );
    event GovernanceTagRegistrationPolicyUpdated(
        uint256 indexed jurisdictionId,
        address indexed tagBallotBox,
        bool enabled
    );
    event GovernanceTagRegistered(
        uint256 indexed jurisdictionId,
        bytes32 indexed tagKey,
        bytes32 indexed voterId,
        uint256 tokenId,
        bytes32 metadataHash,
        bytes32 registrationFingerprint
    );
    event ActionProposed(
        uint256 indexed actionId,
        uint256 indexed jurisdictionId,
        address indexed proposer,
        uint256 proposerTokenId,
        address target,
        bytes32 ruleKey,
        bytes callData
    );
    event ActionCancelled(uint256 indexed actionId, address indexed actor);
    event ActionExecuted(
        uint256 indexed actionId,
        uint256 indexed jurisdictionId,
        address indexed executor,
        uint256 supportBps,
        uint256 totalVotes
    );

    modifier onlySelfOrSteward() {
        require(
            msg.sender == address(this) || (bootstrapSteward != address(0) && msg.sender == bootstrapSteward),
            "Executor: steward or vote required"
        );
        _;
    }

    constructor(address voteTokenAddress, address factoryAddress, uint256 scopeJurisdictionId_) {
        require(voteTokenAddress != address(0), "Executor: vote token required");
        require(factoryAddress != address(0), "Executor: factory required");
        voteToken = IVoteTokenEligibilityView(voteTokenAddress);
        voteTokenNft = IERC721(voteTokenAddress);
        factory = IJurisdictionFactoryRegistry(factoryAddress);
        scopeJurisdictionId = scopeJurisdictionId_;
        bootstrapSteward = msg.sender;
        emit BootstrapStewardUpdated(address(0), msg.sender);
    }

    // ------------------------------------------------------------------
    // Bootstrap configuration (steward until renounced, then vote-only)
    // ------------------------------------------------------------------

    function setRuleBallotBoxOverride(uint256 jurisdictionId, address ballotBox) external onlySelfOrSteward {
        _requireJurisdictionInScope(jurisdictionId);
        if (ballotBox != address(0)) {
            // A decision box that is not ours, not this jurisdiction's, or not Boolean would either
            // brick `propose` or let support/turnout be reported by something that does not count
            // this jurisdiction's votes.
            IDecisionBallotBox box = IDecisionBallotBox(ballotBox);
            require(box.jurisdictionId() == jurisdictionId, "Executor: decision box jurisdiction mismatch");
            require(box.governor() == address(this), "Executor: decision box not governed");
            require(box.structureId() == BOOLEAN_STRUCTURE_ID, "Executor: decision box must be boolean");
        }
        ruleBallotBoxOverride[jurisdictionId] = ballotBox;
        emit RuleBallotBoxOverrideUpdated(jurisdictionId, ballotBox);
    }

    function setMinTotalVotes(uint256 jurisdictionId, uint256 minVotes) external onlySelfOrSteward {
        _requireJurisdictionInScope(jurisdictionId);
        minTotalVotes[jurisdictionId] = minVotes;
        emit MinTotalVotesUpdated(jurisdictionId, minVotes);
    }

    /// @notice Set a jurisdiction's turnout gate: the share of active VoteTokens that must vote and
    ///         the waiting time between proposal and execution. Steward during bootstrap (for
    ///         example a short delay for a small practice electorate); after renunciation only a
    ///         passed action can change it, and that action itself waits out the current delay.
    function setTurnoutPolicy(uint256 jurisdictionId, uint16 participationBps_, uint64 executionDelay_)
        external
        onlySelfOrSteward
    {
        _requireJurisdictionInScope(jurisdictionId);
        require(
            participationBps_ > 0 && participationBps_ <= MAX_PARTICIPATION_BPS,
            "Executor: participation bps out of range"
        );
        require(executionDelay_ <= MAX_EXECUTION_DELAY, "Executor: delay too long");
        _turnoutPolicy[jurisdictionId] =
            TurnoutPolicy({participationBps: participationBps_, executionDelay: executionDelay_, configured: true});
        emit TurnoutPolicyUpdated(jurisdictionId, participationBps_, executionDelay_);
    }

    /// @notice Effective turnout gate for a jurisdiction (defaults when never configured).
    function turnoutPolicyFor(uint256 jurisdictionId)
        public
        view
        returns (uint16 participationBps_, uint64 executionDelay_)
    {
        TurnoutPolicy storage policy = _turnoutPolicy[jurisdictionId];
        if (!policy.configured) return (DEFAULT_PARTICIPATION_BPS, DEFAULT_EXECUTION_DELAY);
        return (policy.participationBps, policy.executionDelay);
    }

    /// @notice Votes an action needs right now: the turnout share of active VoteTokens (rounded
    ///         up), raised to the absolute `minTotalVotes` floor, and never fewer than 2 unless the
    ///         electorate is a single token (nobody acts alone unless they are alone). The result
    ///         is capped at the electorate size, so no setting can demand more votes than exist.
    function requiredVotes(uint256 jurisdictionId) public view returns (uint256 required) {
        (uint16 bps, ) = turnoutPolicyFor(jurisdictionId);
        uint256 electorate = voteToken.activeTokenCount(jurisdictionId);
        required = (electorate * bps + 9999) / 10000;
        uint256 floor = minTotalVotes[jurisdictionId];
        if (required < floor) required = floor;
        if (required < 2) required = 2;
        if (required > electorate) required = electorate;
        if (required == 0) required = 1;
    }

    /// @notice Wire the shared on-chain role/capability resolver. After bootstrap renunciation this
    ///         is changeable only by a passed action targeting the executor itself.
    function setCapabilityRegistry(address registry) external onlySelfOrSteward {
        emit CapabilityRegistryUpdated(address(capabilityRegistry), registry);
        capabilityRegistry = ICapabilityGate(registry);
    }

    function setDelegatedTrustedForwarder(address forwarder) external onlySelfOrSteward {
        emit DelegatedTrustedForwarderUpdated(delegatedTrustedForwarder, forwarder);
        delegatedTrustedForwarder = forwarder;
    }

    /// @notice Configure the governed envelope within which capability holders may register Labor
    ///         scoring Rules. This does not grant the capability; RoleCatalog policy does that.
    function setLaborRuleRegistrationPolicy(
        uint256 jurisdictionId,
        address averageRuleBox,
        address ruleRegistry,
        address tagBallotBox,
        bool enabled
    ) external onlySelfOrSteward {
        _requireJurisdictionInScope(jurisdictionId);
        require(averageRuleBox != address(0), "Executor: average box required");
        require(ruleRegistry != address(0), "Executor: rule registry required");
        require(tagBallotBox != address(0), "Executor: tag box required");
        require(
            IDelegatedAverageRuleBox(averageRuleBox).jurisdictionId() == jurisdictionId,
            "Executor: average box jurisdiction mismatch"
        );
        require(
            IDelegatedAverageRuleBox(averageRuleBox).structureId() == AVERAGE_STRUCTURE_ID,
            "Executor: labor box must be average"
        );
        require(
            IDelegatedAverageRuleBox(averageRuleBox).governor() == address(this),
            "Executor: average box not governed"
        );
        require(
            IDelegatedRuleRegistry(ruleRegistry).jurisdictionGovernor(jurisdictionId) == address(this),
            "Executor: rule registry not governed"
        );
        require(
            IDelegatedTagBox(tagBallotBox).jurisdictionId() == jurisdictionId,
            "Executor: tag box jurisdiction mismatch"
        );

        laborRuleRegistrationPolicy[jurisdictionId] = LaborRuleRegistrationPolicy({
            averageRuleBox: averageRuleBox,
            ruleRegistry: ruleRegistry,
            tagBallotBox: tagBallotBox,
            enabled: enabled
        });
        emit LaborRuleRegistrationPolicyUpdated(
            jurisdictionId,
            averageRuleBox,
            ruleRegistry,
            tagBallotBox,
            enabled
        );
    }

    /// @notice Configure the sole Tag box a capable registrar may write. Registration is always
    ///         inactive + non-reserved; activation, metadata edits, thresholds and retirement stay
    ///         on their independent governance paths.
    function setGovernanceTagRegistrationPolicy(
        uint256 jurisdictionId,
        address tagBallotBox,
        bool enabled
    ) external onlySelfOrSteward {
        _requireJurisdictionInScope(jurisdictionId);
        require(tagBallotBox != address(0), "Executor: tag box required");
        IDelegatedTagBox box = IDelegatedTagBox(tagBallotBox);
        require(box.jurisdictionId() == jurisdictionId, "Executor: tag box jurisdiction mismatch");
        require(box.governor() == address(this), "Executor: tag box not governed");

        governanceTagRegistrationPolicy[jurisdictionId] = GovernanceTagRegistrationPolicy({
            tagBallotBox: tagBallotBox,
            enabled: enabled
        });
        emit GovernanceTagRegistrationPolicyUpdated(jurisdictionId, tagBallotBox, enabled);
    }

    /**
     * @notice Capability-gated operational registration of one Labor scoring Rule. The caller may
     *         supply content identity, an existing jurisdiction Tag, and a unique anonymous-vote
     *         scope, but cannot select contracts, voting structure, or the fixed 0..1000 range.
     *
     *         Exact retries are no-ops. Any conflicting retry or pre-existing registry binding fails
     *         closed. All downstream writes are one EVM transaction and therefore atomic.
     * @return created true only when this call performed the first registration.
     */
    function registerLaborRule(
        uint256 jurisdictionId,
        uint256 registrarTokenId,
        bytes32 ruleKey,
        bytes32 metadataHash,
        bytes32 tagKey,
        uint256 externalNullifier
    ) external returns (bool created) {
        require(ruleKey != bytes32(0), "Executor: rule key required");
        require(tagKey != bytes32(0), "Executor: tag key required");
        require(externalNullifier != 0, "Executor: externalNullifier required");

        bytes32 voterId = _assertDelegatedCapability(
            jurisdictionId,
            registrarTokenId,
            Capabilities.PERMIT_LABOR_RULE_REGISTRATION
        );
        LaborRuleRegistrationPolicy memory policy = laborRuleRegistrationPolicy[jurisdictionId];
        require(policy.enabled, "Executor: labor registration disabled");

        bytes32 fingerprint = keccak256(
            abi.encode(metadataHash, tagKey, externalNullifier, policy.averageRuleBox, policy.ruleRegistry, policy.tagBallotBox)
        );
        bytes32 prior = laborRuleRegistrationFingerprint[jurisdictionId][ruleKey];
        if (prior != bytes32(0)) {
            require(prior == fingerprint, "Executor: conflicting labor registration");
            return false;
        }

        IDelegatedRuleRegistry registry = IDelegatedRuleRegistry(policy.ruleRegistry);
        require(registry.boxFor(jurisdictionId, ruleKey) == address(0), "Executor: rule already bound");

        IDelegatedAverageRuleBox averageBox = IDelegatedAverageRuleBox(policy.averageRuleBox);
        averageBox.registerRule(ruleKey, metadataHash, abi.encode(LABOR_RULE_MAX_VALUE));
        averageBox.setRuleExternalNullifier(ruleKey, externalNullifier);
        registry.bindRuleBox(jurisdictionId, ruleKey, policy.averageRuleBox);
        registry.bindRuleTag(jurisdictionId, ruleKey, tagKey, policy.tagBallotBox);

        laborRuleRegistrationFingerprint[jurisdictionId][ruleKey] = fingerprint;
        emit LaborRuleRegistered(
            jurisdictionId,
            ruleKey,
            voterId,
            registrarTokenId,
            metadataHash,
            tagKey,
            externalNullifier,
            fingerprint
        );
        return true;
    }

    /**
     * @notice Register one new topic Tag through a capability holder. This deliberately cannot
     *         activate a Tag, reserve a governance namespace, update an existing Tag, choose a
     *         different box, or alter voting thresholds.
     */
    function registerGovernanceTag(
        uint256 jurisdictionId,
        uint256 registrarTokenId,
        bytes32 tagKey,
        bytes32 metadataHash
    ) external returns (bool created) {
        require(tagKey != bytes32(0), "Executor: tag key required");
        require(metadataHash != bytes32(0), "Executor: tag metadata required");
        bytes32 voterId = _assertDelegatedCapability(
            jurisdictionId,
            registrarTokenId,
            Capabilities.PERMIT_GOVERNANCE_TAG_REGISTRATION
        );
        GovernanceTagRegistrationPolicy memory policy = governanceTagRegistrationPolicy[jurisdictionId];
        require(policy.enabled, "Executor: tag registration disabled");

        bytes32 fingerprint = keccak256(abi.encode(metadataHash, policy.tagBallotBox));
        bytes32 prior = governanceTagRegistrationFingerprint[jurisdictionId][tagKey];
        if (prior != bytes32(0)) {
            require(prior == fingerprint, "Executor: conflicting tag registration");
            return false;
        }

        IDelegatedTagBox tagBox = IDelegatedTagBox(policy.tagBallotBox);
        require(!tagBox.tagExists(tagKey), "Executor: tag already registered");
        tagBox.registerTag(tagKey, metadataHash, false, false);

        governanceTagRegistrationFingerprint[jurisdictionId][tagKey] = fingerprint;
        emit GovernanceTagRegistered(
            jurisdictionId,
            tagKey,
            voterId,
            registrarTokenId,
            metadataHash,
            fingerprint
        );
        return true;
    }

    function transferBootstrapSteward(address newSteward) external {
        require(msg.sender == bootstrapSteward, "Executor: only steward");
        emit BootstrapStewardUpdated(bootstrapSteward, newSteward);
        bootstrapSteward = newSteward;
    }

    /// Point of no return: after renouncing, configuration changes require a
    /// passed vote (action targeting this contract).
    function renounceBootstrapSteward() external {
        require(msg.sender == bootstrapSteward, "Executor: only steward");
        emit BootstrapStewardUpdated(bootstrapSteward, address(0));
        bootstrapSteward = address(0);
    }

    // ------------------------------------------------------------------
    // Democratic lifecycle: propose -> vote (on RuleBallotBox) -> execute
    // ------------------------------------------------------------------

    function ruleBallotBoxFor(uint256 jurisdictionId) public view returns (address) {
        address overrideBox = ruleBallotBoxOverride[jurisdictionId];
        if (overrideBox != address(0)) {
            return overrideBox;
        }
        (address ruleBallotBox,,,,, bool exists) = factory.jurisdictions(jurisdictionId);
        return exists ? ruleBallotBox : address(0);
    }

    /**
     * @notice Propose an executable action for a jurisdiction. Any holder of
     *         an active VoteToken in that jurisdiction may propose. The
     *         action is registered as a rule on the jurisdiction's
     *         RuleBallotBox; token holders then vote with `submitRuleVote`.
     * @param metadataHash optional content hash describing the action
     *        (IPFS/json digest); defaults to the rule key when zero.
     */
    function propose(
        uint256 jurisdictionId,
        uint256 proposerTokenId,
        address target,
        bytes calldata callData,
        bytes32 metadataHash
    ) external returns (uint256 actionId, bytes32 ruleKey) {
        require(target != address(0), "Executor: target required");
        _assertEligibleVoter(jurisdictionId, proposerTokenId);

        address box = ruleBallotBoxFor(jurisdictionId);
        require(box != address(0), "Executor: no ballot box for jurisdiction");

        actionId = ++actionCount;
        ruleKey = keccak256(abi.encode(address(this), actionId, jurisdictionId, target, keccak256(callData)));

        IDecisionBallotBox(box).registerRule(ruleKey, metadataHash == bytes32(0) ? ruleKey : metadataHash, "");

        actions[actionId] = Action({
            jurisdictionId: jurisdictionId,
            proposer: msg.sender,
            proposerTokenId: proposerTokenId,
            target: target,
            callData: callData,
            ruleKey: ruleKey,
            proposedAt: uint64(block.timestamp),
            executed: false,
            cancelled: false
        });

        (, uint64 delay) = turnoutPolicyFor(jurisdictionId);
        actionExecutableAt[actionId] = uint64(block.timestamp) + delay;

        emit ActionProposed(actionId, jurisdictionId, msg.sender, proposerTokenId, target, ruleKey, callData);
    }

    function cancel(uint256 actionId) external {
        Action storage action = _action(actionId);
        require(!action.executed, "Executor: already executed");
        require(!action.cancelled, "Executor: already cancelled");
        require(
            msg.sender == action.proposer || (bootstrapSteward != address(0) && msg.sender == bootstrapSteward),
            "Executor: proposer or steward only"
        );
        action.cancelled = true;
        emit ActionCancelled(actionId, msg.sender);
    }

    /**
     * @notice Execute a passed action. Permissionless: anyone may trigger it
     *         once the waiting time has passed, the action has not expired,
     *         turnout meets the jurisdiction's gate and support meets the
     *         ballot box quorum threshold.
     */
    function execute(uint256 actionId) external returns (bytes memory result) {
        Action storage action = _action(actionId);
        require(!action.executed, "Executor: already executed");
        require(!action.cancelled, "Executor: cancelled");

        uint256 executableAt = actionExecutableAt[actionId];
        require(block.timestamp >= executableAt, "Executor: waiting time not over");
        require(block.timestamp <= executableAt + ACTION_LIFETIME, "Executor: action expired");

        address box = ruleBallotBoxFor(action.jurisdictionId);
        require(box != address(0), "Executor: no ballot box for jurisdiction");

        // Gate on the box's ANONYMOUS result (the uniform B.2 read). `quorumMet` is computed by the
        // box (support ≥ its quorum bar) over votes that may be anonymous (castVoteAnonymous) or
        // transparent — JGE no longer knows or cares which. (GOVERNANCE_SPINE §8.3.)
        (int256 value, uint256 totalVotes, bool quorumMet) = IDecisionBallotBox(box).currentResult(action.ruleKey);
        // Turnout is measured against the LIVE electorate (active VoteTokens), not an absolute count.
        require(totalVotes >= requiredVotes(action.jurisdictionId), "Executor: participation below floor");
        require(quorumMet, "Executor: support below quorum");
        uint256 supportBps = value < 0 ? 0 : uint256(value);

        action.executed = true;
        // No publishRule — B.2 boxes carry no "publish"; the continuously-read result IS the decision.

        bool ok;
        (ok, result) = action.target.call(action.callData);
        if (!ok) {
            // Bubble the inner revert reason for diagnosability.
            if (result.length > 0) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
            revert("Executor: action call failed");
        }

        emit ActionExecuted(actionId, action.jurisdictionId, msg.sender, supportBps, totalVotes);
    }

    function getAction(uint256 actionId)
        external
        view
        returns (
            uint256 jurisdictionId,
            address proposer,
            uint256 proposerTokenId,
            address target,
            bytes memory callData,
            bytes32 ruleKey,
            uint64 proposedAt,
            bool executed,
            bool cancelled
        )
    {
        Action storage action = _action(actionId);
        return (
            action.jurisdictionId,
            action.proposer,
            action.proposerTokenId,
            action.target,
            action.callData,
            action.ruleKey,
            action.proposedAt,
            action.executed,
            action.cancelled
        );
    }

    function _requireJurisdictionInScope(uint256 jurisdictionId) private view {
        require(jurisdictionId > 0, "Executor: jurisdiction required");
        require(
            scopeJurisdictionId == 0 || jurisdictionId == scopeJurisdictionId,
            "Executor: jurisdiction out of scope"
        );
    }

    function _action(uint256 actionId) private view returns (Action storage action) {
        action = actions[actionId];
        require(action.proposer != address(0), "Executor: unknown action");
    }

    function _assertEligibleVoter(uint256 jurisdictionId, uint256 tokenId) private view {
        _assertEligibleVoterFor(jurisdictionId, tokenId, msg.sender);
    }

    /// Shared template for future delegated governance operations. Each new permit must call this
    /// identity gate and then enforce its own narrow targets + semantic constraints on-chain.
    function _assertDelegatedCapability(uint256 jurisdictionId, uint256 tokenId, bytes32 capability)
        private
        view
        returns (bytes32 voterId)
    {
        address actor = _delegatedSender();
        _assertEligibleVoterFor(jurisdictionId, tokenId, actor);
        require(address(capabilityRegistry) != address(0), "Executor: capability registry required");
        voterId = voteToken.voterIdOf(tokenId);
        require(voterId != bytes32(0), "Executor: voterId required");
        require(
            capabilityRegistry.hasCapability(jurisdictionId, voterId, capability),
            "Executor: delegated capability denied"
        );
    }

    function _assertEligibleVoterFor(uint256 jurisdictionId, uint256 tokenId, address actor) private view {
        _requireJurisdictionInScope(jurisdictionId);
        require(tokenId > 0, "Executor: vote token required");
        require(voteToken.isActive(tokenId), "Executor: vote token inactive");
        require(voteToken.jurisdictionIdOf(tokenId) == jurisdictionId, "Executor: jurisdiction mismatch");
        require(voteTokenNft.ownerOf(tokenId) == actor, "Executor: not token owner");
    }

    function _delegatedSender() private view returns (address sender) {
        if (msg.sender == delegatedTrustedForwarder && msg.data.length >= 20) {
            assembly {
                sender := shr(96, calldataload(sub(calldatasize(), 20)))
            }
        } else {
            sender = msg.sender;
        }
    }
}
