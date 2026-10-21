// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The pair hook the liquidity module uses after a pool exists.
interface ICauseToken {
    function liquidityModule() external view returns (address);

    function tradeRouter() external view returns (address);

    function pair() external view returns (address);

    function registerPair(address pair) external;
}
