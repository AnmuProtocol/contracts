// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Virtual-reserve constant product used before a launch migrates to PancakeSwap.
/// @dev Real tokens sit in the vault. `VIRTUAL_QUOTE` is phantom BNB, so the opening price
///      is not zero and no deposit is required to start trading. The invariant is
///      `tokenReserve * (realQuote + VIRTUAL_QUOTE) = totalSupply * VIRTUAL_QUOTE`.
///      Fees are taken outside that product. Migration happens when `realQuote` reaches
///      `MIGRATION_QUOTE`. At that point 20% of the supply remains for the pool and the
///      spot market cap is `(VIRTUAL_QUOTE + MIGRATION_QUOTE)^2 / VIRTUAL_QUOTE` = 100 BNB.
///      The same BNB amounts apply to every supply.
library BondingCurve {
    uint256 internal constant VIRTUAL_QUOTE = 4 ether;
    uint256 internal constant MIGRATION_QUOTE = 16 ether;
    uint256 internal constant BPS = 10_000;

    error FeeTooHigh(uint256 feeBps);

    /// @notice Spot market cap, in wei of BNB, when the real reserve reaches `MIGRATION_QUOTE`.
    function migrationMarketCap() internal pure returns (uint256) {
        uint256 sum = VIRTUAL_QUOTE + MIGRATION_QUOTE;
        return sum * sum / VIRTUAL_QUOTE;
    }

    /// @notice `realQuote` as a fraction of `MIGRATION_QUOTE`, in basis points. 10000 means full.
    function progress(uint256 realQuote) internal pure returns (uint256) {
        if (realQuote >= MIGRATION_QUOTE) return BPS;
        return realQuote * BPS / MIGRATION_QUOTE;
    }

    /// @notice Tokens sold for `quoteIn` of real BNB. Fees are not part of `quoteIn`.
    function tokensOut(uint256 supply, uint256 tokenReserve, uint256 realQuote, uint256 quoteIn)
        internal
        pure
        returns (uint256 newReserve, uint256 amountOut)
    {
        uint256 k = supply * VIRTUAL_QUOTE;
        uint256 newQuote = realQuote + quoteIn;
        newReserve = k / (newQuote + VIRTUAL_QUOTE);
        if (newReserve >= tokenReserve) return (tokenReserve, 0);
        amountOut = tokenReserve - newReserve;
    }

    /// @notice Real BNB returned for `tokensIn`. The seller cannot sell more than the circulating supply.
    function quoteOut(uint256 supply, uint256 tokenReserve, uint256 realQuote, uint256 tokensIn)
        internal
        pure
        returns (uint256 newReserve, uint256 bnbOut)
    {
        if (tokensIn == 0 || tokensIn > supply - tokenReserve) return (tokenReserve, 0);
        uint256 k = supply * VIRTUAL_QUOTE;
        newReserve = tokenReserve + tokensIn;
        uint256 quotePlusVirtual = k / newReserve;
        if (quotePlusVirtual <= VIRTUAL_QUOTE) return (supply, realQuote);
        uint256 newQuote = quotePlusVirtual - VIRTUAL_QUOTE;
        if (newQuote >= realQuote) return (tokenReserve, 0);
        bnbOut = realQuote - newQuote;
    }

    /// @notice Caps a buy so the real reserve does not pass `MIGRATION_QUOTE`.
    /// @dev Fees are basis points of the filled gross. The unused part of `value` is a refund.
    function charge(uint256 value, uint256 realQuote, uint16 creatorBps, uint16 counterpartyBps)
        internal
        pure
        returns (uint256 gross, uint256 creatorFee, uint256 counterpartyFee, uint256 net)
    {
        uint256 feeBps = uint256(creatorBps) + counterpartyBps;
        if (feeBps >= BPS) revert FeeTooHigh(feeBps);
        uint256 remaining = MIGRATION_QUOTE - realQuote;
        uint256 denom = BPS - feeBps;
        gross = value;
        uint256 cap = remaining * BPS / denom;
        if (cap < gross) gross = cap;
        for (uint256 i = 0; i < 8; ++i) {
            creatorFee = gross * creatorBps / BPS;
            counterpartyFee = gross * counterpartyBps / BPS;
            net = gross - creatorFee - counterpartyFee;
            if (net <= remaining) return (gross, creatorFee, counterpartyFee, net);
            if (gross == 0) break;
            gross -= 1;
        }
        creatorFee = gross * creatorBps / BPS;
        counterpartyFee = gross * counterpartyBps / BPS;
        net = gross - creatorFee - counterpartyFee;
        if (net > remaining) net = remaining;
    }
}
