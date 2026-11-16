// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./interfaces/IVoteToken.sol";
import "./ProposalManager.sol";

/**
 * @title VoteTokenMinter (V3)
 * @notice Access-controlled helper that batches soulbound vote token issuance
 *         and custody actions. Designed for backend orchestration that already
 *         computed encrypted vote secrets and jurisdiction fingerprints.
 */
contract VoteTokenMinter is AccessControl {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    IVoteToken public immutable voteToken;
    ProposalManager public proposalManagerContract;
    uint256 private _batchSequence;

    mapping(uint256 => uint256[]) private _proposalTokenIds;

    event ProposalBatchIssued(
        uint256 indexed proposalId,
        uint256 indexed batchId,
        uint256 count,
        address indexed operator
    );

    event ProposalTokenIssued(
        uint256 indexed proposalId,
        uint256 indexed tokenId,
        address indexed wallet,
        bytes32 voterId,
        uint256 jurisdictionId,
        bytes32 policyDigest,
        bytes32 stealthCommitment
    );

    event BatchIssued(uint256 indexed batchId, uint256 count, address indexed operator);

    event CustodyHandedOver(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        address indexed operator,
        address newOwner
    );

    event SecretsUpdated(uint256 indexed tokenId, address indexed operator, bytes32 policyDigest);

    struct IssueRequest {
        address wallet;
        bytes32 voterId;
        uint256 jurisdictionId;
        IVoteToken.Secrets secrets;
        bytes32 policyDigest;
        bytes32 stealthCommitment;
    }

    constructor(address voteTokenAddress, address proposalManagerAddress, address admin) {
        require(voteTokenAddress != address(0), "voteToken required");
        voteToken = IVoteToken(voteTokenAddress);

        if (proposalManagerAddress != address(0)) {
            proposalManagerContract = ProposalManager(proposalManagerAddress);
        }

        address initialAdmin = admin == address(0) ? _msgSender() : admin;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(ISSUER_ROLE, initialAdmin);
    }

    function configureProposalManager(address proposalManagerAddress)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        proposalManagerContract = ProposalManager(proposalManagerAddress);
    }

    function issueBatch(IssueRequest[] calldata requests)
        external
        onlyRole(ISSUER_ROLE)
        returns (uint256[] memory tokenIds)
    {
        tokenIds = _issueRequests(requests);
        _batchSequence += 1;
        emit BatchIssued(_batchSequence, requests.length, _msgSender());
    }

    function issueProposalBatch(uint256 proposalId, IssueRequest[] calldata requests)
        external
        onlyRole(ISSUER_ROLE)
        returns (uint256[] memory tokenIds)
    {
        require(requests.length > 0, "empty batch");
        if (address(proposalManagerContract) != address(0)) {
            require(
                proposalManagerContract.proposalExists(proposalId),
                "invalid proposal"
            );
        }

        tokenIds = _issueRequests(requests);
        uint256[] storage minted = _proposalTokenIds[proposalId];
        for (uint256 i = 0; i < tokenIds.length; i++) {
            minted.push(tokenIds[i]);
            IssueRequest calldata req = requests[i];
            emit ProposalTokenIssued(
                proposalId,
                tokenIds[i],
                req.wallet,
                req.voterId,
                req.jurisdictionId,
                req.policyDigest,
                req.stealthCommitment
            );
        }

        _batchSequence += 1;
        emit ProposalBatchIssued(proposalId, _batchSequence, requests.length, _msgSender());
    }

    function handoverCustody(
        uint256 tokenId,
        address newOwner,
        IVoteToken.Secrets calldata secrets,
        bytes32 stealthCommitment
    ) external onlyRole(ISSUER_ROLE) returns (uint256 newTokenId) {
        newTokenId = voteToken.handoverCustody(tokenId, newOwner, secrets, stealthCommitment);
        emit CustodyHandedOver(tokenId, newTokenId, _msgSender(), newOwner);
    }

    function updateSecrets(
        uint256 tokenId,
        IVoteToken.Secrets calldata secrets,
        bytes32 policyDigest
    ) external onlyRole(ISSUER_ROLE) {
        voteToken.updateSecrets(tokenId, secrets, policyDigest);
        emit SecretsUpdated(tokenId, _msgSender(), policyDigest);
    }

    function tokensForProposal(uint256 proposalId)
        external
        view
        returns (uint256[] memory)
    {
        return _proposalTokenIds[proposalId];
    }

    function totalTokensForProposal(uint256 proposalId) external view returns (uint256) {
        return _proposalTokenIds[proposalId].length;
    }

    function _issueRequests(IssueRequest[] calldata requests)
        private
        returns (uint256[] memory tokenIds)
    {
        uint256 count = requests.length;
        require(count > 0, "empty batch");

        tokenIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            IssueRequest calldata req = requests[i];
            _validateRequest(req);
            tokenIds[i] = voteToken.issueToken(
                req.wallet,
                req.voterId,
                req.jurisdictionId,
                req.secrets,
                req.policyDigest,
                req.stealthCommitment
            );
        }
    }

    function _validateRequest(IssueRequest calldata req) private pure {
        require(req.wallet != address(0), "wallet required");
        require(req.voterId != bytes32(0), "voterId required");
        require(req.jurisdictionId != 0, "jurisdiction required");
    }

    receive() external payable {
        revert("VoteTokenMinter does not accept ETH");
    }

    fallback() external payable {
        revert("VoteTokenMinter does not accept ETH");
    }
}
