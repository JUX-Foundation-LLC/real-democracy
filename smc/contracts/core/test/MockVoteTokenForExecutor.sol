// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockVoteTokenForExecutor is ERC721 {
    mapping(uint256 => uint256) private _jurisdictionByTokenId;
    mapping(uint256 => bool) private _inactive;
    mapping(uint256 => uint256) private _activeCount;

    constructor() ERC721("MockVoteToken", "MVOTE") {}

    function mint(address to, uint256 tokenId, uint256 jurisdictionId) external {
        _jurisdictionByTokenId[tokenId] = jurisdictionId;
        _mint(to, tokenId);
        _activeCount[jurisdictionId] += 1;
    }

    function setInactive(uint256 tokenId, bool inactive) external {
        if (_inactive[tokenId] != inactive) {
            uint256 jurisdictionId = _jurisdictionByTokenId[tokenId];
            if (inactive) _activeCount[jurisdictionId] -= 1;
            else _activeCount[jurisdictionId] += 1;
        }
        _inactive[tokenId] = inactive;
    }

    /// Mirrors VoteToken.activeTokenCount: the electorate size for the executor's turnout gate.
    function activeTokenCount(uint256 jurisdictionId) external view returns (uint256) {
        return _activeCount[jurisdictionId];
    }

    function isActive(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0) && !_inactive[tokenId];
    }

    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256) {
        return _jurisdictionByTokenId[tokenId];
    }

    /// Deterministic voterId per token (capability resolution). Tests grant roles to this id.
    function voterIdOf(uint256 tokenId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked("voter", tokenId));
    }
}
