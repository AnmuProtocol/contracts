// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Allocations, LaunchKind} from "../types/CauseLaunchTypes.sol";

/// @notice The two launch products and the immutable fee rates that follow from them.
library LaunchRules {
    uint256 internal constant STANDARD_CREATION_FEE = 0.005 ether;

    error InvalidLaunchKind();

    function valid(
        LaunchKind kind,
        uint16 beneficiaryBps,
        uint16 liquidityBps,
        uint16 protocolBps,
        uint16 creatorTaxBps
    ) internal pure returns (bool) {
        if (kind == LaunchKind.Campaign) {
            return creatorTaxBps == 0 && beneficiaryBps == Allocations.CAMPAIGN_BENEFICIARY_BPS
                && liquidityBps == Allocations.CAMPAIGN_LIQUIDITY_BPS && protocolBps == Allocations.CAMPAIGN_PROTOCOL_BPS;
        }
        if (kind == LaunchKind.Standard) {
            if (beneficiaryBps != 0 || liquidityBps != 0 || protocolBps != 0) return false;
            return creatorTaxBps == 0 || creatorTaxBps == 100 || creatorTaxBps == 200 || creatorTaxBps == 300;
        }
        return false;
    }

    /// @notice Buy/sell rates in basis points of the BNB spent or the BNB received.
    /// @dev The creator rate on a standard token includes the extra tax.
    ///      On a campaign the counterparty rate is added to the pool, not paid to the beneficiary.
    ///      PancakeSwap's own 0.25% pool fee is not part of these numbers.
    function tradeFees(LaunchKind kind, uint16 creatorTaxBps)
        internal
        pure
        returns (uint16 creatorBps, uint16 counterpartyBps)
    {
        if (kind == LaunchKind.Campaign) {
            return (Allocations.CAMPAIGN_CREATOR_TRADE_BPS, Allocations.CAMPAIGN_LIQUIDITY_TRADE_BPS);
        }
        if (kind == LaunchKind.Standard) return (uint16(70 + creatorTaxBps), 30);
        revert InvalidLaunchKind();
    }
}
