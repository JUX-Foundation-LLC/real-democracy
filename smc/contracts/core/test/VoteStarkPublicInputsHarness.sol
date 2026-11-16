// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../governance/zk/VoteStarkPublicInputs.sol";

/// Test-only harness for {VoteStarkPublicInputs}: round-trips the 17-element codec and exposes
/// the audit bounds-checks (F2/F3/F8 + F5) so they can be exercised against real fixtures and
/// adversarial inputs.
contract VoteStarkPublicInputsHarness {
    using VoteStarkPublicInputs for VoteStarkPublicInputs.PublicInputs;

    /// fromElements -> toElements; must be the identity for the wire form to be consensus-safe.
    function roundTrip(uint64[17] calldata e) external pure returns (uint64[17] memory) {
        return VoteStarkPublicInputs.toElements(VoteStarkPublicInputs.fromElements(e));
    }

    /// Run the audit bounds gate; reverts with the library's reason string on violation.
    function validate(uint64[17] calldata e) external pure {
        VoteStarkPublicInputs.validate(VoteStarkPublicInputs.fromElements(e));
    }

    /// F5 scalar clamp.
    function requireScalarMax(uint64[17] calldata e, uint64 maxValue) external pure {
        VoteStarkPublicInputs.requireScalarMax(VoteStarkPublicInputs.fromElements(e), maxValue);
    }

    /// Expose the parsed view for assertions on field placement.
    function parse(uint64[17] calldata e)
        external
        pure
        returns (
            uint64[4] memory merkleRoot,
            uint64 externalNullifier,
            uint64 revision,
            uint64 voteMode,
            uint64 choiceCount,
            uint64 voteChoice,
            uint64[4] memory nullifierHash,
            uint64[4] memory prevNullifierHash
        )
    {
        VoteStarkPublicInputs.PublicInputs memory pi = VoteStarkPublicInputs.fromElements(e);
        return (
            pi.merkleRoot,
            pi.externalNullifier,
            pi.revision,
            pi.voteMode,
            pi.choiceCount,
            pi.voteChoice,
            pi.nullifierHash,
            pi.prevNullifierHash
        );
    }
}
