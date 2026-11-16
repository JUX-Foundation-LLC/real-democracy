// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ProofReader
 * @notice Sequential byte reader for a Winterfell 0.13.1 `Proof` blob (the prover's
 *         `proof.to_bytes()`). The primitives here are COMPLETE + tested; the high-level
 *         `Proof` layout they assemble (Context → trace commitments → constraint commitment
 *         → OOD frame → query proofs → FRI proof → PoW nonce → num-unique-queries) is mapped
 *         in VERIFIER_IMPL_NOTES and finalized against emitted fixtures (the byte offsets are
 *         the one part that must be confirmed by running real proofs through the reader).
 *
 *         Winterfell serializes integers little-endian via `winter-utils::ByteWriter`. Field
 *         elements are 8-byte LE canonical Goldilocks; digests are 32 raw bytes.
 */
library ProofReader {
    struct Cursor {
        uint256 offset;
    }

    function readU8(bytes calldata data, Cursor memory c) internal pure returns (uint8 v) {
        require(c.offset + 1 <= data.length, "ProofReader: OOB u8");
        v = uint8(data[c.offset]);
        c.offset += 1;
    }

    function readU16LE(bytes calldata data, Cursor memory c) internal pure returns (uint16 v) {
        require(c.offset + 2 <= data.length, "ProofReader: OOB u16");
        v = uint16(uint8(data[c.offset])) | (uint16(uint8(data[c.offset + 1])) << 8);
        c.offset += 2;
    }

    function readU32LE(bytes calldata data, Cursor memory c) internal pure returns (uint32 v) {
        require(c.offset + 4 <= data.length, "ProofReader: OOB u32");
        for (uint256 i = 0; i < 4; i++) {
            v |= uint32(uint8(data[c.offset + i])) << (8 * uint32(i));
        }
        c.offset += 4;
    }

    /// 8-byte little-endian → canonical Goldilocks element (the caller range-checks `< p`).
    function readU64LE(bytes calldata data, Cursor memory c) internal pure returns (uint64 v) {
        require(c.offset + 8 <= data.length, "ProofReader: OOB u64");
        for (uint256 i = 0; i < 8; i++) {
            v |= uint64(uint8(data[c.offset + i])) << (8 * uint64(i));
        }
        c.offset += 8;
    }

    /// A 32-byte Blake3 digest (`ByteDigest<32>`), read raw (big-endian into bytes32).
    function readDigest(bytes calldata data, Cursor memory c) internal pure returns (bytes32 d) {
        require(c.offset + 32 <= data.length, "ProofReader: OOB digest");
        assembly {
            d := calldataload(add(data.offset, mload(c)))
        }
        c.offset += 32;
    }

    function readBytes(bytes calldata data, Cursor memory c, uint256 len)
        internal
        pure
        returns (bytes memory out)
    {
        require(c.offset + len <= data.length, "ProofReader: OOB bytes");
        out = data[c.offset:c.offset + len];
        c.offset += len;
    }

    function remaining(bytes calldata data, Cursor memory c) internal pure returns (uint256) {
        return data.length - c.offset;
    }

    /// winter-utils variable-length `usize` (`ByteReader::read_usize`): the length is
    /// `trailing_zeros(first_byte) + 1`; for length 9 a leading zero byte precedes a plain u64-LE,
    /// otherwise read `length` little-endian bytes and shift right by `length`.
    function readUsizeVar(bytes calldata data, Cursor memory c) internal pure returns (uint64 v) {
        require(c.offset + 1 <= data.length, "ProofReader: OOB usize");
        uint8 first = uint8(data[c.offset]);
        uint256 len = uint256(_ctz8(first)) + 1;
        if (len == 9) {
            c.offset += 1; // length byte is zero in the 9-byte case
            v = readU64LE(data, c);
        } else {
            require(c.offset + len <= data.length, "ProofReader: OOB usize body");
            uint64 acc = 0;
            for (uint256 i = 0; i < len; i++) {
                acc |= uint64(uint8(data[c.offset + i])) << (8 * uint64(i));
            }
            c.offset += len;
            v = acc >> uint64(len);
        }
    }

    /// trailing_zeros of a byte (Rust `u8::trailing_zeros`: returns 8 for 0).
    function _ctz8(uint8 x) private pure returns (uint8 c) {
        if (x == 0) return 8;
        while (x & 1 == 0) {
            c++;
            x >>= 1;
        }
    }
}
