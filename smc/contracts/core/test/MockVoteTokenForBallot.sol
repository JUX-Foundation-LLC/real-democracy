// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IProposalBallotBoxHarness {
    function recordVote(uint256 tokenId, bytes32 voteChoice) external;
    function processRevocation(uint256 tokenId) external;
}

contract MockVoteTokenForBallot is ERC721 {
    mapping(uint256 => uint256) private _jurisdictionByTokenId;

    constructor() ERC721("MockVoteToken", "MVOTE") {}

    function mint(address to, uint256 tokenId, uint256 jurisdictionId) external {
        _jurisdictionByTokenId[tokenId] = jurisdictionId;
        _mint(to, tokenId);
    }

    function jurisdictionIdOf(uint256 tokenId) external view returns (uint256) {
        return _jurisdictionByTokenId[tokenId];
    }

    function castVoteToBallot(address ballot, uint256 tokenId, bytes32 voteChoice) external {
        safeTransferFrom(msg.sender, ballot, tokenId, abi.encode(voteChoice));
    }

    function recordVoteOnBallot(address ballot, uint256 tokenId, bytes32 voteChoice) external {
        IProposalBallotBoxHarness(ballot).recordVote(tokenId, voteChoice);
    }

    function revokeFromBallot(address ballot, uint256 tokenId) external {
        IProposalBallotBoxHarness(ballot).processRevocation(tokenId);
    }
}
