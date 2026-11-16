// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/zk/Transcript.sol";
import "../governance/zk/Goldilocks.sol";
import "../governance/zk/IHasher.sol";

/// Test harness: runs the {Transcript} through the exact scripted sequence the Rust reference
/// (`transcript_ref.rs`) runs against winterfell's real `DefaultRandomCoin<Blake3_256>`, so the two
/// can be asserted equal byte-for-byte.
contract TranscriptHarness {
    IHasher public immutable hasher;

    constructor(address h) {
        hasher = IHasher(h);
    }

    function runSequence(
        uint64[] calldata seedElems,
        bytes32 reseedData,
        uint64 nonce,
        uint256 numInts,
        uint256 domainSize
    )
        external
        view
        returns (
            uint64 b1,
            uint64 b2,
            uint64 q1a0,
            uint64 q1a1,
            uint64 q2a0,
            uint64 q2a1,
            uint32 lz,
            uint64[] memory ints
        )
    {
        Transcript.State memory s = Transcript.init(hasher, seedElems);
        b1 = Transcript.drawBaseElement(hasher, s);
        b2 = Transcript.drawBaseElement(hasher, s);
        Goldilocks.Fp2 memory q1 = Transcript.drawElement(hasher, s);
        (q1a0, q1a1) = (q1.a0, q1.a1);
        Transcript.reseed(hasher, s, reseedData);
        Goldilocks.Fp2 memory q2 = Transcript.drawElement(hasher, s);
        (q2a0, q2a1) = (q2.a0, q2.a1);
        lz = Transcript.checkLeadingZeros(hasher, s, nonce);
        ints = Transcript.drawIntegers(hasher, s, numInts, domainSize, nonce);
    }
}
