// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply token. The constructor mints once, to the vault.
/// @dev There is no owner, no second mint, no pause, no blacklist, and no proxy.
///      Wallet-to-wallet transfers are free. Seeding the pool is free.
///      Once the PancakeSwap pair is registered, a transfer to or from that pair
///      is allowed only while the launch's trade router has opened the trade.
///      The BNB fee is collected by that router, not by withholding tokens.
contract CauseToken is ERC20 {
    address public immutable vault;
    address public immutable liquidityModule;
    address public immutable tradeRouter;
    address public pair;
    bool public tradeOpen;

    error ZeroSupply();
    error ZeroVault();
    error NotLiquidityModule(address caller);
    error NotTradeRouter(address caller);
    error PairAlreadySet();
    error InvalidPair();
    error DirectTradeDisabled();
    error TradeAlreadyOpen();
    error TradeNotOpen();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address vault_,
        address liquidityModule_,
        address tradeRouter_
    ) ERC20(name_, symbol_) {
        if (totalSupply_ == 0) revert ZeroSupply();
        if (vault_ == address(0)) revert ZeroVault();
        vault = vault_;
        liquidityModule = liquidityModule_;
        tradeRouter = tradeRouter_;
        _mint(vault_, totalSupply_);
    }

    /// @notice Records the PancakeSwap pair. Only the launch's liquidity module can call this, once.
    function registerPair(address pair_) external {
        if (msg.sender != liquidityModule) revert NotLiquidityModule(msg.sender);
        if (pair != address(0)) revert PairAlreadySet();
        if (pair_ == address(0) || pair_ == vault || pair_ == liquidityModule || pair_ == tradeRouter) {
            revert InvalidPair();
        }
        pair = pair_;
    }

    /// @notice Lets the pair move tokens for the duration of one router trade.
    function beginTrade() external {
        if (msg.sender != tradeRouter) revert NotTradeRouter(msg.sender);
        if (tradeOpen) revert TradeAlreadyOpen();
        tradeOpen = true;
    }

    /// @notice Closes the trade flag opened by `beginTrade`.
    function endTrade() external {
        if (msg.sender != tradeRouter) revert NotTradeRouter(msg.sender);
        if (!tradeOpen) revert TradeNotOpen();
        tradeOpen = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (pair != address(0) && (from == pair || to == pair) && !_exempt(from, to) && !tradeOpen) {
            revert DirectTradeDisabled();
        }
        super._update(from, to, value);
    }

    function _exempt(address from, address to) private view returns (bool) {
        return from == address(0) || to == address(0) || from == vault || to == vault || from == liquidityModule
            || to == liquidityModule;
    }
}
