// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DelegationRegistry
 * @custom:deprecated RETIRED at the prod re-genesis (#343 item 5, Coi-ratified). This V1 address-keyed
 *         delegation store predates OPEN delegate voting. The current model is "the delegate signals
 *         their vote to the chain IN THE OPEN" via `governance/PublicDelegateVoteRegistry` — there is no
 *         separate delegation registry. Removed from `scripts/deploy.js`; not deployed at the cut. Will
 *         move to `contracts/archive/` post-cut. Do NOT build on it. (Backend work-order: drop the
 *         `delegationRegistry` read in `config/contracts.js`.)
 * @dev Manages delegations of voting power by tag
 *
 * Key principles:
 * - Delegations are by tag (not per-proposal)
 * - Private mappings: only delegator can see their delegations
 * - Voter retains token ownership; delegate has permission only
 * - All-or-nothing: delegate must use ALL delegated tokens for a proposal at once
 * - Delegate CANNOT burn delegated tokens (only owner can)
 * - Delegations are revocable anytime before voting window closes
 */

contract DelegationRegistry {
    // Delegation data
    struct Delegation {
        address delegator;      // Who delegated
        address delegate;       // Who received delegation
        bytes32 tag;            // Which tag this delegation covers
        bool active;            // Is this delegation still active?
        uint256 createdAt;      // When was this delegation created?
    }

    // Store delegations: delegator → tag → delegate
    mapping(address => mapping(bytes32 => address)) public delegations;

    // Track all delegations for a delegator (for revocation)
    mapping(address => Delegation[]) public delegatorDelegations;

    // Track which delegators have delegated to a delegate for a tag
    // delegate → tag → array of delegators
    mapping(address => mapping(bytes32 => address[])) public delegatesByTag;

    // Events
    event DelegationCreated(
        address indexed delegator,
        address indexed delegate,
        bytes32 indexed tag,
        uint256 createdAt
    );

    event DelegationRevoked(
        address indexed delegator,
        address indexed delegate,
        bytes32 indexed tag,
        uint256 revokedAt
    );

    event DelegateVotedOnBehalf(
        address indexed delegator,
        address indexed delegate,
        bytes32 indexed tag,
        uint256 proposalId,
        uint256 tokenCount
    );

    // ============ DELEGATION CREATION ============

    /**
     * @dev Create a delegation for a specific tag
     * Voter delegates their voting power on [tag] to another address
     * Voter retains token ownership; delegate only has permission to vote
     */
    function delegate(address _delegate, bytes32 _tag) external {
        require(_delegate != address(0), "Invalid delegate");
        require(_delegate != msg.sender, "Cannot delegate to self");
        require(_tag != bytes32(0), "Invalid tag");

        // If already delegated to someone else, revoke first
        address currentDelegate = delegations[msg.sender][_tag];
        if (currentDelegate != address(0)) {
            _revokeDelegation(msg.sender, currentDelegate, _tag);
        }

        // Create new delegation
        delegations[msg.sender][_tag] = _delegate;

        // Track delegation for this delegator
        Delegation memory newDelegation = Delegation({
            delegator: msg.sender,
            delegate: _delegate,
            tag: _tag,
            active: true,
            createdAt: block.timestamp
        });
        delegatorDelegations[msg.sender].push(newDelegation);

        // Track delegate for this tag
        delegatesByTag[_delegate][_tag].push(msg.sender);

        emit DelegationCreated(msg.sender, _delegate, _tag, block.timestamp);
    }

    // ============ DELEGATION REVOCATION ============

    /**
     * @dev Revoke a delegation for a specific tag
     * Can be called anytime, but especially before voting window closes
     */
    function revokeDelegation(address _delegate, bytes32 _tag) external {
        require(delegations[msg.sender][_tag] == _delegate, "No delegation to revoke");

        _revokeDelegation(msg.sender, _delegate, _tag);
    }

    /**
     * @dev Internal function to revoke delegation
     */
    function _revokeDelegation(address _delegator, address _delegate, bytes32 _tag) internal {
        delegations[_delegator][_tag] = address(0);

        // Mark as inactive in delegatorDelegations array
        for (uint256 i = 0; i < delegatorDelegations[_delegator].length; i++) {
            if (delegatorDelegations[_delegator][i].delegate == _delegate &&
                delegatorDelegations[_delegator][i].tag == _tag) {
                delegatorDelegations[_delegator][i].active = false;
                break;
            }
        }

        // Remove from delegatesByTag array
        address[] storage delegators = delegatesByTag[_delegate][_tag];
        for (uint256 i = 0; i < delegators.length; i++) {
            if (delegators[i] == _delegator) {
                // Swap with last and pop
                delegators[i] = delegators[delegators.length - 1];
                delegators.pop();
                break;
            }
        }

        emit DelegationRevoked(_delegator, _delegate, _tag, block.timestamp);
    }

    // ============ QUERY FUNCTIONS ============

    /**
     * @dev Get current delegate for a tag
     * Private: only delegator should be able to see this
     */
    function getDelegateForTag(address _delegator, bytes32 _tag)
        external
        view
        returns (address)
    {
        return delegations[_delegator][_tag];
    }

    /**
     * @dev Check if delegation exists and is active
     */
    function hasDelegation(address _delegator, bytes32 _tag)
        external
        view
        returns (bool)
    {
        return delegations[_delegator][_tag] != address(0);
    }

    /**
     * @dev Get all delegations for a delegator
     * Private: only delegator should be able to see this
     */
    function getDelegatorDelegations(address _delegator)
        external
        view
        returns (Delegation[] memory)
    {
        return delegatorDelegations[_delegator];
    }

    /**
     * @dev Get all delegators who delegated to a delegate for a tag
     * Private: only delegate should be able to see this
     */
    function getDelegatorsByTag(address _delegate, bytes32 _tag)
        external
        view
        returns (address[] memory)
    {
        return delegatesByTag[_delegate][_tag];
    }

    /**
     * @dev Get count of delegations for a delegator
     */
    function getDelegationCount(address _delegator)
        external
        view
        returns (uint256)
    {
        uint256 count = 0;
        for (uint256 i = 0; i < delegatorDelegations[_delegator].length; i++) {
            if (delegatorDelegations[_delegator][i].active) {
                count++;
            }
        }
        return count;
    }

    /**
     * @dev Get count of delegators for a delegate for a tag
     */
    function getDelegatorCountByTag(address _delegate, bytes32 _tag)
        external
        view
        returns (uint256)
    {
        return delegatesByTag[_delegate][_tag].length;
    }

    // ============ VOTING COORDINATION (Optional: called by backend) ============

    /**
     * @dev Log when delegate votes on behalf of delegator
     * Called by backend after tokens are transferred to ballot box
     * This is an audit trail event (not required for functionality)
     */
    function recordDelegateVote(
        address _delegator,
        bytes32 _tag,
        uint256 _proposalId,
        uint256 _tokenCount
    ) external {
        require(delegations[_delegator][_tag] == msg.sender, "Not authorized delegate");

        emit DelegateVotedOnBehalf(_delegator, msg.sender, _tag, _proposalId, _tokenCount);
    }

    // ============ SECURITY: PREVENT ACCIDENTAL TRANSFERS ============

    /**
     * @dev Reject any accidental transfers to this contract
     */
    receive() external payable {
        revert("DelegationRegistry does not accept ETH");
    }

    fallback() external payable {
        revert("DelegationRegistry does not accept ETH");
    }
}
