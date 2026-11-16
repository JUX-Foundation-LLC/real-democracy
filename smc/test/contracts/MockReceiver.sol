// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVoteToken {
    function selfDisable(uint256 tokenId) external;
}

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract MockReceiver is IERC721Receiver {
    address public token;
    bool public reenter;

    constructor(address _token) {
        token = _token;
        reenter = false;
    }

    function setReenter(bool v) external {
        reenter = v;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes memory) public returns (bytes4) {
        if (reenter) {
            // attempt to call back into the token contract
            IVoteToken(token).selfDisable(tokenId);
        }
        return this.onERC721Received.selector;
    }
}
