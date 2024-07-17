// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import { RelayedNonceCancellation } from "../types/RelayedNonceCancellation.sol";
import { RelayedSignerUpdate } from "../types/RelayedSignerUpdate.sol";

// @notice Relays messages to downstream handlers, compensating keepers for the transaction
interface IRelayer {
    /// @notice Relays a message to Verifier extension to invalidate a nonce
    /// @param message Request with details needed for keeper compensation
    /// @param outerSignature Signature of the RelayedNonceCancellation message
    /// @param innerSignature Signature of the embedded Common message
    function relayNonceCancellation(
        RelayedNonceCancellation calldata message,
        bytes calldata outerSignature,
        bytes calldata innerSignature
    ) external;

    /// @notice Relays a message to MarketFactory to update status of a delegated signer
    /// @param message Request with details needed for keeper compensation
    /// @param outerSignature Signature of the RelayedSignerUpdate message
    /// @param innerSignature Signature of the embedded SignerUpdate message
    function relaySignerUpdate(
        RelayedSignerUpdate calldata message,
        bytes calldata outerSignature,
        bytes calldata innerSignature
    ) external;
}