// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "../interfaces/IVoteToken.sol";
import "./IRuleBallotBox.sol";
import "./Capabilities.sol";

interface IChainClockReader {
    function currentTick() external view returns (uint256);
}

interface IAnonymousVoteVerifier {
    function castAnonymousVote(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256 merkleRoot,
        uint256 externalNullifier,
        uint256 voteChoice,
        uint256 nullifierHash,
        uint256 prevNullifierHash
    ) external;
}

/**
 * @title BaseRuleBallotBox
 * @notice Shared, audited plumbing for the per-structure rule ballotboxes (B.2):
 *         VoteToken gating, ChainClock, governor + quorum, rule registration, the
 *         changeable-vote lifecycle, and distinct-voter counting. Concrete structures
 *         (boolean / average / median / plurality) implement ONLY the tally hooks:
 *         `_configureRule`, `_validateBallot`, `_applyVote`, `_resultValue`, `structureId`.
 *
 *         Exactness: the base keeps each token's last ballot per rule, and on a re-vote
 *         hands the structure (prev, next) so it can decrement the prior contribution
 *         before adding the new one — the running on-chain tally is always exact.
 */
abstract contract BaseRuleBallotBox is IRuleBallotBox, ERC165, ERC2771Context {
    uint16 internal constant MAX_BPS = 10_000;

    struct RuleMeta {
        bytes32 metadataHash;
        bool exists;
    }

    IVoteToken public immutable voteToken;
    IERC721 internal immutable voteTokenNft;
    uint256 public immutable override jurisdictionId;

    address public governor;
    address public chainClock;
    /// optional on-chain capability gate (CapabilityRegistry). address(0) = no on-chain check
    /// (bootstrap / backend-enforced). When set, castVote requires PERMIT_RULE_VOTING — so
    /// self-custody + third-party callers are gated identically to the first-party backend.
    address public capabilityRegistry;
    uint16 public quorumThresholdBps;
    /// optional anonymous-vote verifier (AnonymousVoteVerifier). address(0) = transparent-only.
    address public anonymousVerifier;

    mapping(bytes32 => RuleMeta) public ruleMeta;
    /// distinct tokens currently counted, per rule
    mapping(bytes32 => uint256) public voterCount;
    /// a token's (or nullifier's) last ballot per rule (empty = never voted) — drives exact re-vote
    /// decrement. Transparent path keys by tokenId; anonymous path keys by nullifierHash (same type).
    mapping(bytes32 => mapping(uint256 => uint16[])) internal _lastBallot;
    /// per-rule anonymous-vote scope (= backend zkBallotService externalNullifierField), bound at
    /// registerRule so a proof for rule A can't be replayed on rule B. 0 = not anonymized.
    mapping(bytes32 => uint256) public ruleExternalNullifier;
    /// G3 (audit S9): reverse index so an externalNullifier can't be bound to two rules — sharing one
    /// would share the (ext-keyed) nullifier set, corrupting tallies/voterCount across rules. 0 = free.
    mapping(uint256 => bytes32) public ruleKeyByExternalNullifier;

    event GovernorUpdated(address indexed previousGovernor, address indexed newGovernor);
    event ChainClockUpdated(address indexed previousClock, address indexed newClock);
    event QuorumThresholdUpdated(uint16 previousBps, uint16 newBps);

    modifier onlyGovernor() {
        require(msg.sender == governor, "RuleBox: only governor");
        _;
    }

    /**
     * @param trustedForwarder the shared gas-payer's EIP-2771 forwarder (address(0) to
     *        disable meta-tx; then every call is direct and `_msgSender() == msg.sender`).
     *        When set, the forwarder may submit `castVote` on behalf of a voter who signed
     *        off-chain — the box still sees the real voter via `_msgSender()`, so the
     *        ownerOf eligibility check holds while the forwarder pays the gas. This is what
     *        makes BOTH custodial submit (backend signs as the custody wallet) and
     *        self-custody (the user signs) gasless to the end voter.
     */
    constructor(
        address voteTokenAddress,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        uint16 _quorumThresholdBps,
        address trustedForwarder
    ) ERC2771Context(trustedForwarder) {
        require(voteTokenAddress != address(0), "RuleBox: vote token required");
        require(_jurisdictionId > 0, "RuleBox: jurisdiction required");
        require(_governor != address(0), "RuleBox: governor required");
        require(_quorumThresholdBps <= MAX_BPS, "RuleBox: threshold too high");
        voteToken = IVoteToken(voteTokenAddress);
        voteTokenNft = IERC721(voteTokenAddress);
        jurisdictionId = _jurisdictionId;
        governor = _governor;
        chainClock = _chainClock;
        quorumThresholdBps = _quorumThresholdBps == 0 ? 6000 : _quorumThresholdBps;
        // #310 HIGH-1: governance boxes (Role/Tag/Initiative) override this true so the transparent
        // tokenId-public path is closed by construction — anonymity is enforced on-chain, not by a
        // deploy-script flag that could be silently skipped (the C2 lesson).
        bool tvd = _transparentVotingDisabledByDefault();
        transparentVotingDisabled = tvd;
        emit GovernorUpdated(address(0), _governor);
        emit ChainClockUpdated(address(0), _chainClock);
        emit QuorumThresholdUpdated(0, quorumThresholdBps);
        if (tvd) emit TransparentVotingDisabledUpdated(true);
    }

    // ------------------------------------------------------------------ governance config
    function updateGovernor(address newGovernor) external onlyGovernor {
        require(newGovernor != address(0), "RuleBox: zero governor");
        emit GovernorUpdated(governor, newGovernor);
        governor = newGovernor;
    }

    function setChainClock(address newClock) external onlyGovernor {
        emit ChainClockUpdated(chainClock, newClock);
        chainClock = newClock;
    }

    /// Set (or clear with address(0)) the on-chain capability gate. Enabling it makes rule
    /// voting permission-checked on-chain for ALL callers (self-custody + third-party).
    event CapabilityRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);
    function setCapabilityRegistry(address registry) external onlyGovernor {
        emit CapabilityRegistryUpdated(capabilityRegistry, registry);
        capabilityRegistry = registry;
    }

    event AnonymousVerifierUpdated(address indexed previousVerifier, address indexed newVerifier);
    function setAnonymousVerifier(address verifier) external onlyGovernor {
        emit AnonymousVerifierUpdated(anonymousVerifier, verifier);
        anonymousVerifier = verifier;
    }

    /// Bind a rule's anonymous-vote scope (the backend's externalNullifierField). Required before
    /// castVoteAnonymous works for that rule; must equal the scope the eligibility root was
    /// registered under on the AnonymousVoteVerifier.
    function setRuleExternalNullifier(bytes32 ruleKey, uint256 externalNullifier) external onlyGovernor {
        require(ruleMeta[ruleKey].exists, "RuleBox: unknown rule");
        require(externalNullifier != 0, "RuleBox: externalNullifier required");
        // G3 (S9): an externalNullifier may belong to at most ONE rule (re-binding the same rule is ok).
        bytes32 owner = ruleKeyByExternalNullifier[externalNullifier];
        require(owner == bytes32(0) || owner == ruleKey, "RuleBox: externalNullifier already used");
        uint256 prev = ruleExternalNullifier[ruleKey];
        if (prev != 0 && prev != externalNullifier) ruleKeyByExternalNullifier[prev] = bytes32(0); // release old scope
        ruleExternalNullifier[ruleKey] = externalNullifier;
        ruleKeyByExternalNullifier[externalNullifier] = ruleKey;
    }

    /// Retire the transparent (tokenId) vote path on this box — governance flips this true at the
    /// cut once anonymous voting is fully wired, so every vote must be anonymous (castVoteAnonymous).
    /// Kept as a toggle for bootstrap/testing; in production it is set once and left true.
    bool public transparentVotingDisabled;
    event TransparentVotingDisabledUpdated(bool disabled);
    function setTransparentVotingDisabled(bool disabled) external onlyGovernor {
        transparentVotingDisabled = disabled;
        emit TransparentVotingDisabledUpdated(disabled);
    }

    function setQuorumThreshold(uint16 newBps) external onlyGovernor {
        require(newBps > 0 && newBps <= MAX_BPS, "RuleBox: bad threshold");
        emit QuorumThresholdUpdated(quorumThresholdBps, newBps);
        quorumThresholdBps = newBps;
    }

    // ------------------------------------------------------------------ IRuleBallotBox
    function registerRule(bytes32 ruleKey, bytes32 metadataHash, bytes calldata config)
        external
        override
        onlyGovernor
    {
        require(ruleKey != bytes32(0), "RuleBox: rule key required");
        _configureRule(ruleKey, config); // structure decodes / validates / stores its config
        RuleMeta storage m = ruleMeta[ruleKey];
        m.metadataHash = metadataHash;
        if (!m.exists) {
            m.exists = true;
            emit RuleRegistered(ruleKey, metadataHash);
        } else {
            emit RuleConfigUpdated(ruleKey, metadataHash);
        }
    }

    function castVote(bytes32 ruleKey, uint256 tokenId, uint16[] calldata ballot) external override {
        require(!transparentVotingDisabled, "RuleBox: transparent voting retired");
        require(ruleMeta[ruleKey].exists, "RuleBox: unknown rule");
        _assertEligible(tokenId);
        _assertCapability(tokenId); // on-chain democratic permission (PERMIT_RULE_VOTING) when gated
        _validateBallot(ruleKey, ballot);

        uint16[] memory prev = _lastBallot[ruleKey][tokenId];
        if (prev.length == 0) {
            voterCount[ruleKey] += 1;
        }
        _applyVote(ruleKey, prev, ballot);
        _lastBallot[ruleKey][tokenId] = ballot;

        (int256 value, uint256 total, ) = currentResult(ruleKey);
        emit RuleVoteCast(ruleKey, tokenId, ballot, value, total);
    }

    /**
     * @notice Anonymous vote — the SPINE DECIDE path. The voter proves eligibility (membership in
     *         the registered Merkle root) + a one-time nullifier via the AnonymousVoteVerifier; the
     *         box then applies the SAME structure tally, re-keyed by nullifierHash. No tokenId, no
     *         ownerOf — the proof IS the eligibility, and the rotating nullifier gives exact,
     *         changeable votes anonymously. Proof-system-agnostic (Groth16 now, STARK at the cut).
     */
    function castVoteAnonymous(
        bytes32 ruleKey,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256 merkleRoot,
        uint16[] calldata ballot,
        uint256 nullifierHash,
        uint256 prevNullifierHash
    ) external {
        require(ruleMeta[ruleKey].exists, "RuleBox: unknown rule");
        require(anonymousVerifier != address(0), "RuleBox: anonymous not configured");
        uint256 ext = ruleExternalNullifier[ruleKey];
        require(ext != 0, "RuleBox: rule scope not bound");
        _assertAnonymousCapability(); // G3/S8: jurisdiction-wide PERMIT_RULE_VOTING gate
        _validateBallot(ruleKey, ballot);
        uint256 voteChoice = _ballotToChoice(ballot);

        // Verify proof + spend nullifier + enforce rotating-nullifier vote-change. Reverts on
        // invalid/spent/wrong-prev-head, so a bad vote never reaches the tally below.
        IAnonymousVoteVerifier(anonymousVerifier).castAnonymousVote(
            a, b, c, merkleRoot, ext, voteChoice, nullifierHash, prevNullifierHash
        );

        uint16[] memory prev;
        if (prevNullifierHash == 0) {
            voterCount[ruleKey] += 1;
        } else {
            prev = _lastBallot[ruleKey][prevNullifierHash];
            if (prev.length == 0) {
                // Unknown prev head: the verifier just proved prevNullifierHash WAS the live
                // head of a real identity chain, but THIS box never applied that revision —
                // the chain's earlier casts happened outside this box (a verifier-direct gen-2
                // cast, or the rule was rebound to this box mid-chain per §5.3 type-change
                // reuse). The voter is real and not yet counted here, so count them as fresh;
                // there is no prior in-box contribution to decrement. Without this, the
                // revision's value entered the structure accumulator while voterCount stayed
                // 0 — an invisible phantom entry that corrupts the tally the moment any
                // fresh voter arrives (the 2026-07-02 prod flip halt).
                // KNOWN LIMIT (operational invariant, enforced by the backend routing flag
                // guard): if a chain's casts are ever SPLIT across this box and another path
                // again, a returning voter whose older revision IS in this box can be counted
                // twice and their stale ballot is never decremented. A box cannot distinguish
                // "prev spent elsewhere" from "prev spent here then superseded elsewhere" —
                // all of a rule's casts must route through its bound box within an epoch.
                voterCount[ruleKey] += 1;
            } else {
                delete _lastBallot[ruleKey][prevNullifierHash]; // retire the prior chain head
            }
        }
        _applyVote(ruleKey, prev, ballot);
        _lastBallot[ruleKey][nullifierHash] = ballot;

        (int256 value, uint256 total, ) = currentResult(ruleKey);
        // tokenId 0 = anonymous (no identity); nullifierHash is the public, unlinkable handle.
        emit RuleVoteCast(ruleKey, 0, ballot, value, total);
    }

    /// Map a structure ballot to the single uint256 voteChoice the circuit binds. Lean structures
    /// (boolean/average/median/plurality) use ballot[0]; multi-value structures override.
    function _ballotToChoice(uint16[] calldata ballot) internal pure virtual returns (uint256) {
        return ballot.length > 0 ? uint256(ballot[0]) : 0;
    }

    function currentResult(bytes32 ruleKey)
        public
        view
        override
        returns (int256 value, uint256 totalVotes, bool quorumMet)
    {
        totalVotes = voterCount[ruleKey];
        if (totalVotes == 0) {
            return (0, 0, false);
        }
        (value, quorumMet) = _resultValue(ruleKey, totalVotes);
    }

    function getLastBallot(bytes32 ruleKey, uint256 tokenId) external view returns (uint16[] memory) {
        return _lastBallot[ruleKey][tokenId];
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IRuleBallotBox).interfaceId || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ structure hooks
    /// Decode + validate + store the structure-specific config for a rule.
    function _configureRule(bytes32 ruleKey, bytes calldata config) internal virtual;

    /// Revert if `ballot` is invalid for the rule's structure/config.
    function _validateBallot(bytes32 ruleKey, uint16[] calldata ballot) internal view virtual;

    /// Decrement `prev`'s contribution (if non-empty) and add `next`. Keeps the tally exact.
    function _applyVote(bytes32 ruleKey, uint16[] memory prev, uint16[] calldata next) internal virtual;

    /// The structure's on-chain result + whether quorum is met. Called only when totalVotes > 0.
    function _resultValue(bytes32 ruleKey, uint256 totalVotes)
        internal
        view
        virtual
        returns (int256 value, bool quorumMet);

    function structureId() external view virtual override returns (bytes32);

    /// The capability a voter must hold to cast on this box. Rule boxes use PERMIT_RULE_VOTING;
    /// the Role/Tag/Initiative governance boxes override this (PERMIT_ROLE_VOTING /
    /// PERMIT_TAG_VOTING / PERMIT_INITIATIVE_VOTING) so the shared anonymous spine gates each
    /// ballotbox by its own permit. (Unified base change consolidating #305/#306/#311.)
    function _votingCapability() internal pure virtual returns (bytes32) {
        return Capabilities.PERMIT_RULE_VOTING;
    }

    /// The revert string when the capability gate denies a voter. Per-box override (INFO-2, #310)
    /// so monitoring/logs read "role/tag/initiative voting not permitted" instead of the generic
    /// "rule voting" — the governance boxes return their own label.
    function _votingDeniedMessage() internal pure virtual returns (string memory) {
        return "RuleBox: rule voting not permitted";
    }

    /// Whether the transparent (tokenId-public) vote path is RETIRED at construction time.
    /// B.2 structure boxes (Boolean/Median/Average/Plurality) return false — transparent rule
    /// voting is intentional during the bootstrap trial (the C5 cut-time flip). The Role/Tag/
    /// Initiative GOVERNANCE boxes override this to TRUE so anonymity is enforced BY CONSTRUCTION
    /// (#310 HIGH-1): the public tokenId path is closed at deploy with no deploy-script setter that
    /// could be silently skipped (the C2 failure mode). Governance can still re-open it via
    /// setTransparentVotingDisabled if a jurisdiction ever needs to (e.g. test), but the secure
    /// default is baked in.
    function _transparentVotingDisabledByDefault() internal pure virtual returns (bool) {
        return false;
    }

    // ------------------------------------------------------------------ internals
    function _assertEligible(uint256 tokenId) internal view {
        // _msgSender() (not msg.sender): when the call arrives via the trusted forwarder,
        // this resolves to the real voter who signed off-chain, NOT the gas-paying relayer —
        // so a relayed (gasless) vote is owned-checked against the actual voter.
        require(voteToken.isActive(tokenId), "RuleBox: inactive token");
        require(voteToken.jurisdictionIdOf(tokenId) == jurisdictionId, "RuleBox: wrong jurisdiction");
        require(voteTokenNft.ownerOf(tokenId) == _msgSender(), "RuleBox: not token owner");
    }

    /// On-chain democratic permission check. No-op until a CapabilityRegistry is bound; once set,
    /// the token's voter must hold PERMIT_RULE_VOTING (via the permissive voter base role or an
    /// elevated role) — enforced for self-custody + third-party callers, not just the backend.
    function _assertCapability(uint256 tokenId) internal view {
        address gate = capabilityRegistry;
        if (gate == address(0)) return;
        require(
            ICapabilityGate(gate).hasCapability(
                jurisdictionId,
                voteToken.voterIdOf(tokenId),
                _votingCapability()
            ),
            _votingDeniedMessage()
        );
    }

    /// G5 (audit S8): an anonymous vote has NO tokenId, so per-voter capability can't be checked at vote
    /// time — per-voter revocation is enforced by ELIGIBILITY-ROOT ROTATION (drop a voter's commitment
    /// from the merkle set → they can no longer prove membership). The JURISDICTION-WIDE gate still binds:
    /// resolving with the zero voterId hits only the permissive `voter` BASE ROLE, so if a jurisdiction
    /// votes PERMIT_RULE_VOTING off that base role, no one — anonymous included — may vote.
    function _assertAnonymousCapability() internal view {
        address gate = capabilityRegistry;
        if (gate == address(0)) return;
        require(
            ICapabilityGate(gate).hasCapability(jurisdictionId, bytes32(0), _votingCapability()),
            _votingDeniedMessage()
        );
    }

    function _currentTick() internal view returns (uint256) {
        if (chainClock == address(0)) {
            return block.timestamp;
        }
        return IChainClockReader(chainClock).currentTick();
    }
}
