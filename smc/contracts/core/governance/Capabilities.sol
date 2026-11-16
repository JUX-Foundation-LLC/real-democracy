// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Capabilities
 * @notice Canonical capability keys for on-chain democratic permissioning, and the reserved
 *         base-role id. These name the USER ACTIONS a jurisdiction governs; the chain is the
 *         source of truth so self-custody users / third-party clients are gated identically to
 *         the first-party backend. (Permits replace the retired `permission_tree` rules.)
 *
 *         Model (see docs/ONCHAIN_CAPABILITIES.md):
 *          - A jurisdiction's `voter` base role (VOTER_ROLE_ID) holds the DEFAULT capability set,
 *            applied to every active VoteToken holder *implicitly* (no per-member grant). Seeded
 *            permissive (all permits) — restriction = voting a capability OFF the voter role.
 *          - Elevated roles (admin/proposer/…) may ADD capabilities a restricted base lacks.
 *          - A capability gates a USER ACTION (propose / vote / delegate / change-tag / invite /
 *            spawn-jurisdiction). The democratic OUTCOME (creating the Rule/Tag/Initiative) is the
 *            executor's job and carries no per-user permit.
 */
library Capabilities {
    /// Reserved RoleCatalog roleId whose per-jurisdiction capabilities are the implicit base set
    /// for every active VoteToken holder. Distinct from the rendered roles (1=admin, 2=proposer,
    /// 20=token_guardian); 0 is invalid in RoleCatalog.
    uint256 internal constant VOTER_ROLE_ID = 1000;

    // ── Authoring (a user STARTS a process; the executor enacts the outcome) ──────────────
    // Proposal creation is enforced PER TYPE — rule / tag / initiative are separate buckets in
    // voting terms, so each is separately permissioned (structure-agnostic within its type).
    /// Start a Rule Proposal (any voting structure).
    bytes32 internal constant PERMIT_RULE_PROPOSAL = keccak256("permit_rule_proposal");
    /// Start a Tag Proposal.
    bytes32 internal constant PERMIT_TAG_PROPOSAL = keccak256("permit_tag_proposal");
    /// Start an Initiative Proposal.
    bytes32 internal constant PERMIT_INITIATIVE_PROPOSAL = keccak256("permit_initiative_proposal");
    /// Author an Amendment to an existing Proposal.
    bytes32 internal constant PERMIT_AMENDMENTS = keccak256("permit_amendments");
    /// Spawn a child Jurisdiction (inherits the Foundational baseline).
    bytes32 internal constant PERMIT_JURISDICTION_CREATION = keccak256("permit_jurisdiction_creation");
    /// Invite new members into the Jurisdiction.
    bytes32 internal constant PERMIT_INVITATION_CREATION = keccak256("permit_invitation_creation");

    // ── Delegated governance operations ────────────────────────────────────────────────
    // These permits open narrow, contract-enforced operational lanes through the jurisdiction
    // executor. They NEVER authorize arbitrary executor calldata. Each capability must ship with
    // a consumer that fixes the permitted targets and validates every action parameter on-chain.
    /// Register a new Labor scoring Rule in the jurisdiction's pre-approved Average Rule box.
    bytes32 internal constant PERMIT_LABOR_RULE_REGISTRATION =
        keccak256("permit_labor_rule_registration");
    /// Register a new inactive, non-reserved topic Tag in the jurisdiction's governed Tag box.
    bytes32 internal constant PERMIT_GOVERNANCE_TAG_REGISTRATION =
        keccak256("permit_governance_tag_registration");

    // ── Voting (per governance TYPE; structure-agnostic — applies to all voting structures) ─
    /// Vote in the off-chain Proposal seconding/quorum stage.
    bytes32 internal constant PERMIT_PROPOSAL_VOTING = keccak256("permit_proposal_voting");
    /// Cast an on-chain Rule vote (any structure: boolean/median/plurality/…).
    bytes32 internal constant PERMIT_RULE_VOTING = keccak256("permit_rule_voting");
    /// Cast an on-chain Initiative vote.
    bytes32 internal constant PERMIT_INITIATIVE_VOTING = keccak256("permit_initiative_voting");
    /// Cast an on-chain Tag signal/vote.
    bytes32 internal constant PERMIT_TAG_VOTING = keccak256("permit_tag_voting");
    /// Vote on an Amendment.
    bytes32 internal constant PERMIT_AMENDMENT_VOTING = keccak256("permit_amendment_voting");
    /// Cast an on-chain Role vote — grant/revoke a role to a member (RoleBallotBox → JurisdictionRoleRegistry).
    /// Admin is just a role (roleId 1), so this covers admin voting — there is deliberately NO separate
    /// PERMIT_ADMIN_VOTING. Whether admin-role voting is unlocked at all is the orthogonal `vote_on_administrators`
    /// constitutional rule (the per-jurisdiction switch), not a capability.
    bytes32 internal constant PERMIT_ROLE_VOTING = keccak256("permit_role_voting");
    /// Cast an on-chain Capability vote — govern the RoleCatalog itself by vote: which capabilities a role
    /// confers, and defining bespoke per-jurisdiction roles. The forward seam for democratic RoleCatalog control
    /// (a future CapabilityBallotBox set as the catalog's `jurisdictionGovernor`, mirroring how RoleBallotBox
    /// governs role GRANTS) — additive, no re-architecture needed.
    bytes32 internal constant PERMIT_CAPABILITY_VOTING = keccak256("permit_capability_voting");

    // ── Tags + delegation ─────────────────────────────────────────────────────────────────
    /// Change which (single) Tag a Rule is affixed to (replaces the dead permit_tag_append).
    bytes32 internal constant PERMIT_TAG_CHANGE = keccak256("permit_tag_change");
    /// Act as a Delegate / accept delegations.
    bytes32 internal constant PERMIT_DELEGATE = keccak256("permit_delegate");
}

/// The on-chain capability gate read by action contracts (CapabilityRegistry implements it).
interface ICapabilityGate {
    function hasCapability(uint256 jurisdictionId, bytes32 voterId, bytes32 capability) external view returns (bool);
}
