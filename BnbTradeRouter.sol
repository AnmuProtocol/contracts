// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CauseToken} from "./CauseToken.sol";
import {ICampaignRegistry} from "./interfaces/ICampaignRegistry.sol";
import {ICampaignVault} from "./interfaces/ICampaignVault.sol";
import {IPancakeRouter} from "./interfaces/IPancakeRouter.sol";
import {LaunchRules} from "./libraries/LaunchRules.sol";
import {Campaign, CampaignStatus} from "./types/CauseLaunchTypes.sol";

interface IBondingCurveVault {
    function buyOnCurve(address recipient, uint256 minTokens) external payable returns (uint256 tokensOut);
    function sellOnCurve(address recipient, uint256 tokenAmount, uint256 minBnb) external returns (uint256 bnbOut);
    function curveMigrated() external view returns (bool);
    function curveQuote() external view returns (uint256);
}

/// @notice Buys and sells a launched token and pays that launch's trade fee in BNB.
/// @dev While the campaign is `Launched`, the vault's virtual-reserve curve is the market.
///      After migration the campaign is `Active` and the remaining BNB is what PancakeSwap
///      swaps. Direct pair transfers are rejected by the token unless this router has opened
///      the trade. PancakeSwap's own pool fee is charged by the pair and is not part of these amounts.
contract BnbTradeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    ICampaignRegistry public immutable registry;
    IPancakeRouter public immutable router;

    error ZeroAddress();
    error ZeroAmount();
    error NotActive(uint256 campaignId);
    error Slippage(uint256 received, uint256 minimum);
    error SwapDidNotSettle();
    error PaymentFailed();

    constructor(address registry_, address router_) {
        if (registry_ == address(0) || router_ == address(0)) revert ZeroAddress();
        registry = ICampaignRegistry(registry_);
        router = IPancakeRouter(router_);
    }

    /// @notice Buys `campaignId`'s token. `minTokens` is the minimum the buyer receives.
    /// @dev On the curve the vault takes the fee. After migration the fee is skimmed here.
    function buy(uint256 campaignId, uint256 minTokens) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.status == CampaignStatus.Launched) {
            IBondingCurveVault(campaign.vault).buyOnCurve{value: msg.value}(msg.sender, minTokens);
            return;
        }
        if (campaign.status != CampaignStatus.Active) revert NotActive(campaignId);
        (uint256 creatorFee, uint256 counterpartyFee) = _fee(campaign, msg.value);
        uint256 swapIn = msg.value - creatorFee - counterpartyFee;
        if (swapIn == 0) revert ZeroAmount();

        uint256 start = address(this).balance - msg.value;
        CauseToken token = CauseToken(campaign.token);
        token.beginTrade();
        router.swapExactETHForTokens{value: swapIn}(
            minTokens, _path(router.WETH(), campaign.token), msg.sender, block.timestamp
        );
        token.endTrade();
        if (address(this).balance != start + creatorFee + counterpartyFee) revert SwapDidNotSettle();
        _credit(campaign, creatorFee, counterpartyFee);
    }

    /// @notice Sells `amount` of `campaignId`'s token. `minBnb` is the minimum the seller receives after the fee.
    function sell(uint256 campaignId, uint256 amount, uint256 minBnb) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.status == CampaignStatus.Launched || _closedCurveExit(campaign)) {
            IERC20(campaign.token).safeTransferFrom(msg.sender, campaign.vault, amount);
            IBondingCurveVault(campaign.vault).sellOnCurve(msg.sender, amount, minBnb);
            return;
        }
        if (campaign.status != CampaignStatus.Active) revert NotActive(campaignId);
        (uint16 creatorBps, uint16 counterpartyBps) = LaunchRules.tradeFees(campaign.launchKind, campaign.creatorTaxBps);

        IERC20 token = IERC20(campaign.token);
        uint256 dust = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        token.forceApprove(address(router), amount);

        uint256 start = address(this).balance;
        CauseToken(campaign.token).beginTrade();
        router.swapExactTokensForETH(
            amount,
            _grossMin(minBnb, uint256(creatorBps) + counterpartyBps),
            _path(campaign.token, router.WETH()),
            address(this),
            block.timestamp
        );
        CauseToken(campaign.token).endTrade();
        if (token.balanceOf(address(this)) != dust) revert SwapDidNotSettle();

        uint256 got = address(this).balance - start;
        (uint256 creatorFee, uint256 counterpartyFee) = _fee(campaign, got);
        uint256 payout = got - creatorFee - counterpartyFee;
        if (payout < minBnb) revert Slippage(payout, minBnb);
        _credit(campaign, creatorFee, counterpartyFee);
        (bool ok,) = msg.sender.call{value: payout}("");
        if (!ok) revert PaymentFailed();
        if (address(this).balance != start) revert SwapDidNotSettle();
    }

    receive() external payable {}

    function _fee(Campaign memory campaign, uint256 amount)
        private
        pure
        returns (uint256 creatorFee, uint256 counterpartyFee)
    {
        (uint16 creatorBps, uint16 counterpartyBps) = LaunchRules.tradeFees(campaign.launchKind, campaign.creatorTaxBps);
        creatorFee = (amount * creatorBps) / 10_000;
        counterpartyFee = (amount * counterpartyBps) / 10_000;
    }

    function _credit(Campaign memory campaign, uint256 creatorFee, uint256 counterpartyFee) private {
        uint256 fee = creatorFee + counterpartyFee;
        if (fee == 0) return;
        ICampaignVault(campaign.vault).creditTradingFees{value: fee}(creatorFee, counterpartyFee);
    }

    /// @dev Gross BNB that still leaves `netMin` after both fee legs are rounded down.
    function _grossMin(uint256 netMin, uint256 feeBps) private pure returns (uint256) {
        if (netMin == 0 || feeBps == 0) return netMin;
        uint256 denom = 10_000 - feeBps;
        return (netMin * 10_000 + denom - 1) / denom;
    }

    /// @dev A closed curve that still holds quote can be sold. Buys stay on `Launched` only.
    ///      A vault that does not expose the curve is not an exit, so `close` never has to call it.
    function _closedCurveExit(Campaign memory campaign) private view returns (bool) {
        if (campaign.status != CampaignStatus.Closed || campaign.vault == address(0)) return false;
        (bool migratedOk, bytes memory migratedData) =
            campaign.vault.staticcall(abi.encodeWithSelector(IBondingCurveVault.curveMigrated.selector));
        if (!migratedOk || migratedData.length != 32 || abi.decode(migratedData, (bool))) return false;
        (bool quoteOk, bytes memory quoteData) =
            campaign.vault.staticcall(abi.encodeWithSelector(IBondingCurveVault.curveQuote.selector));
        if (!quoteOk || quoteData.length != 32) return false;
        return abi.decode(quoteData, (uint256)) > 0;
    }

    function _path(address from, address to) private pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = from;
        path[1] = to;
    }
}
