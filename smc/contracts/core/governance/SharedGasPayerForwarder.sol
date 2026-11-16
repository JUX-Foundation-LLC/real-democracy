// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/metatx/MinimalForwarder.sol";

/**
 * @title SharedGasPayerForwarder
 * @notice The single EIP-2771 trusted forwarder every rule ballotbox points at. A JUX-funded
 *         shared gas-payer calls {execute} with a voter-signed ForwardRequest and pays the
 *         gas; the box recovers the real voter via `_msgSender()`, so voting is gasless for
 *         BOTH custodial voters (backend signs as their custody wallet) and self-custody
 *         voters (they sign off-chain). See vote/docs/B2_BALLOTBOX_FAMILY.md §8.
 *
 *         Built on OpenZeppelin's audited MinimalForwarder (replay-protected per-sender
 *         nonces + EIP-712 verification). Quotas / rate-limits / mixing for privacy are the
 *         off-chain gas-payer's job (see contracts/experimental/CustodialRelayer) and do not
 *         change this contract or the boxes — keeping the trusted on-chain surface minimal.
 *
 *         The EIP-712 domain stays MinimalForwarder("MinimalForwarder","0.0.1") so existing
 *         signing tooling needs no special-casing.
 */
contract SharedGasPayerForwarder is MinimalForwarder {}
