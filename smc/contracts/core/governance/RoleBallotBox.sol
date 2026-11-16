// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./BaseRuleBallotBox.sol";

interface IRoleRegistryWrite {
    function grantRoles(uint256 jurisdictionId, bytes32 voterId, uint256[] calldata roleIds) external;
    function revokeRoles(uint256 jurisdictionId, bytes32 voterId, uint256[] calldata roleIds) external;
}

interface IRoleCatalogView {
    function isActiveRole(uint256 jurisdictionId, uint256 roleId) external view returns (bool);
}

/**
 * @title RoleBallotBox
 * @notice ANONYMOUS, STANDING democratic granting of durable (governance-tier) roles. Rides the
 *         shared `BaseRuleBallotBox` anonymous spine — zk membership proof + rotating nullifier — so
 *         WHO votes support/oppose is anonymous; only the SUBJECT (which `voterId` is up for which
 *         `roleId`, grant or revoke) is public. (Replaces the retired tokenId-public `submitRoleVote`
 *         design: per Coi, ALL ballotboxes are anonymous; the only revealed fact is the subject.)
 *
 *         A subject is a boolean support/oppose tally that **never closes** (standing), exactly like a
 *         long-term Rule: cross the quorum up ⇒ the governor publishes a **grant** (graduation); as
 *         support shifts, an inverse (grant=false) ballot publishes a **revoke** (demotion) — an Admin
 *         who loses support loses the role. Admin is just a role (id 1); no special-casing here —
 *         gated by `PERMIT_ROLE_VOTING` (the `vote_on_administrators` rule is the orthogonal
 *         constitutional switch that grants that capability to the base voter role).
 *
 *         The box is the JurisdictionRoleRegistry's per-jurisdiction governor, so a published outcome
 *         flows straight into `grantRoles`/`revokeRoles`. Durable jurisdiction roles only (admin,
 *         proposer, token_guardian, …); ephemeral show/staff roles are out-of-band.
 */
contract RoleBallotBox is BaseRuleBallotBox {
    struct Tally {
        uint256 support;
        uint256 oppose;
    }
    mapping(bytes32 => Tally) public tallies;

    struct RoleSubject {
        bytes32 voterId;
        uint256 roleId;
        bool grant; // true = grant, false = revoke
        bool exists;
    }
    mapping(bytes32 => RoleSubject) public roleSubject;

    IRoleRegistryWrite public immutable registry;
    IRoleCatalogView public immutable catalog;

    event RoleBallotRegistered(
        bytes32 indexed ballotKey,
        bytes32 indexed voterId,
        uint256 indexed roleId,
        bool grant,
        bytes32 metadataHash
    );
    event RoleBallotPublished(
        bytes32 indexed ballotKey,
        bytes32 indexed voterId,
        uint256 indexed roleId,
        bool grant,
        uint256 supportBps,
        uint256 totalVotes,
        uint256 tick
    );

    constructor(
        address voteTokenAddress,
        uint256 _jurisdictionId,
        address _governor,
        address _chainClock,
        uint16 _quorumThresholdBps,
        address trustedForwarder,
        address _registry,
        address _catalog
    )
        BaseRuleBallotBox(voteTokenAddress, _jurisdictionId, _governor, _chainClock, _quorumThresholdBps, trustedForwarder)
    {
        require(_registry != address(0), "RoleBox: registry required");
        require(_catalog != address(0), "RoleBox: catalog required");
        registry = IRoleRegistryWrite(_registry);
        catalog = IRoleCatalogView(_catalog);
    }

    function structureId() external pure override returns (bytes32) {
        return keccak256("role_support");
    }

    /// Role voting requires PERMIT_ROLE_VOTING — NOT PERMIT_RULE_VOTING (the shared base default).
    function _votingCapability() internal pure override returns (bytes32) {
        return Capabilities.PERMIT_ROLE_VOTING;
    }

    /// INFO-2 (#310): accurate capability-denied message for this box.
    function _votingDeniedMessage() internal pure override returns (string memory) {
        return "RoleBox: role voting not permitted";
    }

    /// #310 HIGH-1: role/admin votes are anonymous-only — close the transparent tokenId path by
    /// construction (no bootstrap window per ANONYMOUS_ROLE_BALLOTBOX.md). Self-enforcing default,
    /// not a deploy-script flip that could be silently skipped (the C2 lesson).
    function _transparentVotingDisabledByDefault() internal pure override returns (bool) {
        return true;
    }

    /// The public subject key — a (voterId, roleId, grant) triple. The candidate under consideration.
    function ballotKey(bytes32 voterId, uint256 roleId, bool grant) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(voterId, roleId, grant));
    }

    /// Open a STANDING role ballot (the subject). Governor-only. For a grant, the role must be active.
    /// Anonymous votes flow once the governor binds the subject's scope via `setRuleExternalNullifier`.
    function registerRoleBallot(bytes32 voterId, uint256 roleId, bool grant, bytes32 metadataHash)
        external
        onlyGovernor
        returns (bytes32 key)
    {
        require(voterId != bytes32(0), "RoleBox: voter required");
        if (grant) {
            require(catalog.isActiveRole(jurisdictionId, roleId), "RoleBox: inactive role");
        }
        key = ballotKey(voterId, roleId, grant);
        roleSubject[key] = RoleSubject(voterId, roleId, grant, true);

        // Register the subject as a votable key in the base (no structure config) so the shared
        // anonymous-vote machinery (castVoteAnonymous) applies to it.
        RuleMeta storage m = ruleMeta[key];
        m.metadataHash = metadataHash;
        if (!m.exists) {
            m.exists = true;
            emit RuleRegistered(key, metadataHash);
        } else {
            emit RuleConfigUpdated(key, metadataHash);
        }
        emit RoleBallotRegistered(key, voterId, roleId, grant, metadataHash);
    }

    /// Publish the STANDING result: on quorum, grant/revoke the role via the registry. Re-callable as
    /// support shifts — this is what makes the box a standing tally (support up ⇒ grant; the inverse
    /// grant=false ballot publishes the revoke when an admin loses support). Governor-only.
    function publishRoleBallot(bytes32 key) external onlyGovernor {
        RoleSubject storage s = roleSubject[key];
        require(s.exists, "RoleBox: unknown ballot");
        (int256 supportBps, uint256 total, bool quorumMet) = currentResult(key);
        require(total > 0, "RoleBox: no votes");
        require(quorumMet, "RoleBox: quorum not met");

        uint256[] memory ids = new uint256[](1);
        ids[0] = s.roleId;
        if (s.grant) {
            registry.grantRoles(jurisdictionId, s.voterId, ids);
        } else {
            registry.revokeRoles(jurisdictionId, s.voterId, ids);
        }
        emit RoleBallotPublished(key, s.voterId, s.roleId, s.grant, uint256(supportBps), total, _currentTick());
    }

    // ── boolean support/oppose tally (mirrors BooleanRuleBallotBox) ─────────────────────────────
    function _configureRule(bytes32, bytes calldata) internal pure override {
        // role ballots carry no structure-specific config (support/oppose)
    }

    function _validateBallot(bytes32, uint16[] calldata ballot) internal pure override {
        require(ballot.length == 1 && ballot[0] <= 1, "RoleBox: ballot must be [0] or [1]");
    }

    function _applyVote(bytes32 key, uint16[] memory prev, uint16[] calldata next) internal override {
        Tally storage t = tallies[key];
        if (prev.length == 1) {
            if (prev[0] == 1) t.support -= 1;
            else t.oppose -= 1;
        }
        if (next[0] == 1) t.support += 1;
        else t.oppose += 1;
    }

    function _resultValue(bytes32 key, uint256 totalVotes)
        internal
        view
        override
        returns (int256 value, bool quorumMet)
    {
        uint256 supportBps = (tallies[key].support * uint256(MAX_BPS)) / totalVotes;
        value = int256(supportBps);
        quorumMet = supportBps >= quorumThresholdBps;
    }
}
