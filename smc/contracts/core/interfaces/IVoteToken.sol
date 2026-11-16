// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVoteToken {
    enum DisableReason {
        None,
        Self,
        Custodian,
        Administrator
    }

    struct Secrets {
        bytes32 cryptoVote;
        bytes32 signKey;
        bytes32 userBiometric;
        uint256 biometricTypeMask;
    }

    struct TokenInfo {
        bytes32 voterId;
        uint256 jurisdictionId;
        bytes32 policyDigest;
        bytes32 cryptoVote;
        bytes32 signKey;
        bytes32 userBiometric;
        uint256 biometricTypeMask;
        bytes32 stealthCommitment;
        bool disabled;
        bool frozen;
        uint64 issuedAt;
        uint64 freezeEndsAt;
        uint64 disableTimestamp;
        uint32 revocationNonce;
        DisableReason disableReason;
        address disableSource;
    }

    function issueToken(
        address to,
        bytes32 voterId,
        uint256 jurisdictionId,
        Secrets calldata secrets,
        bytes32 policyDigest,
        bytes32 stealthCommitment
    ) external returns (uint256 tokenId);

    function handoverCustody(
        uint256 tokenId,
        address newOwner,
        Secrets calldata secrets,
        bytes32 stealthCommitment
    ) external returns (uint256 newTokenId);

    function selfDisable(uint256 tokenId) external;

    function adminDisable(uint256 tokenId) external;

    function custodianDisable(uint256 tokenId) external;

    function freezeToken(uint256 tokenId, uint64 freezeForSeconds, string calldata reason) external;

    function unfreezeToken(uint256 tokenId) external;

    function isActive(uint256 tokenId) external view returns (bool);

    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256);

    function voterIdOf(uint256 tokenId) external view returns (bytes32);

    function revocationNonceOf(uint256 tokenId) external view returns (uint32);

    function activeTokenOf(bytes32 voterId, uint256 jurisdictionId) external view returns (uint256 tokenId);

    function tokenInfo(uint256 tokenId) external view returns (TokenInfo memory info);

    function updateSecrets(
        uint256 tokenId,
        Secrets calldata secrets,
        bytes32 policyDigest
    ) external;
}
