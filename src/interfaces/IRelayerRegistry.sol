// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Minimal view of the Tornado Cash RelayerRegistry used by the aggregator.
interface IRelayerRegistry {
    function getRelayerBalance(address relayer) external view returns (uint256);

    function isRelayerRegistered(address relayer, address toResolve) external view returns (bool);
}
