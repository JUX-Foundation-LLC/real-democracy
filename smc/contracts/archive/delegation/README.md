# Retired delegation contracts

`DelegationRegistry` and `DelegationManager` are retained solely for historical ABI/source
inspection. Neither is part of the canonical deployment pipeline, and Hardhat's configured
`contracts/core` source root deliberately does not compile them.

The active model has two distinct sources:

- private delegator → delegate/tag assignments live in the backend delegation projection; and
- the delegate's attributable, revealed ballot signal lives on chain in
  `core/governance/PublicDelegateVoteRegistry.sol`.

Do not restore either archived contract to `core`. New delegation work must use the private
assignment plus public-signal model and the unified ballot external nullifier.
