// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Minimal IVoteTokenOwnership stub for VoteCommitmentRegistry tests: configurable
/// ownerOf / isActive, and a jurisdictionIdOf the registry doesn't rely on for auth.
contract MockOwnedVoteToken {
    mapping(uint256 => address) private _owner;
    mapping(uint256 => bool) private _active;
    mapping(uint256 => uint256) private _jur;

    function setOwner(uint256 tokenId, address o) external { _owner[tokenId] = o; }
    function setActive(uint256 tokenId, bool a) external { _active[tokenId] = a; }
    function setJurisdiction(uint256 tokenId, uint256 j) external { _jur[tokenId] = j; }

    function ownerOf(uint256 tokenId) external view returns (address) { return _owner[tokenId]; }
    function isActive(uint256 tokenId) external view returns (bool) { return _active[tokenId]; }
    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256) { return _jur[tokenId]; }
}
