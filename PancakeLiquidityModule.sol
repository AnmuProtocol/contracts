// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ICampaignRegistry} from "./interfaces/ICampaignRegistry.sol";
import {ICauseToken} from "./interfaces/ICauseToken.sol";
import {IPancakeFactory, IPancakePair, IPancakeRouter, IWETH} from "./interfaces/IPancakeRouter.sol";
import {Campaign, CampaignStatus} from "./types/CauseLaunchTypes.sol";

/// @notice Seeds a PancakeSwap V2 pool with one campaign's token inventory and liquidity bucket.
/// @dev The router address is immutable. 95% of the LP token is burned. The other 5% is sent
///      to the campaign vault for the creator to claim. This is not an AMM.
contract PancakeLiquidityModule is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Receives 95% of the PancakeSwap LP token. No key can redeem that share.
    address public constant LP_BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant LP_BURN_BPS = 9_500;

    ICampaignRegistry public immutable registry;
    IPancakeRouter public immutable router;

    error ZeroAddress();
    error ZeroAmount();
    error NotCampaignModule(uint256 campaignId);
    error CampaignNotLaunchable(uint256 campaignId);
    error LiquidityIncomplete(uint256 tokenAmount, uint256 bnbAmount);
    error PairMissing(address token);
    error LpShareEmpty();
    error NotCampaignVault(address caller);
    error CurveInventoryProtected(uint256 campaignId);

    event LiquidityCreated(
        uint256 indexed campaignId,
        address indexed pair,
        uint256 tokenAmount,
        uint256 bnbAmount,
        uint256 liquidity
    );
    event LpSplit(uint256 indexed campaignId, uint256 burned, uint256 creatorLp);
    event TradingLiquidityAdded(uint256 indexed campaignId, address indexed pair, uint256 bnbAmount);

    constructor(address registry_, address router_) {
        if (registry_ == address(0) || router_ == address(0)) revert ZeroAddress();
        registry = ICampaignRegistry(registry_);
        router = IPancakeRouter(router_);
    }

    receive() external payable {}

    /// @notice Retired. A public seed can pull the vault's whole token balance, including an open curve.
    /// @dev The filling curve buy calls `migrateCurve` instead.
    function createPosition(uint256 campaignId) external pure {
        revert CurveInventoryProtected(campaignId);
    }

    /// @notice Receives the curve's remaining tokens and real BNB and opens the PancakeSwap pair.
    /// @dev Only the campaign vault can call this, at the buy that fills the migration reserve.
    ///      95% of the LP token is burned. The other 5% is sent to the vault. The campaign becomes Active.
    function migrateCurve(uint256 campaignId, uint256 tokenAmount) external payable nonReentrant {
        if (msg.value == 0 || tokenAmount == 0) revert ZeroAmount();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != msg.sender) revert NotCampaignVault(msg.sender);
        if (campaign.status != CampaignStatus.Launched || campaign.token == address(0)) {
            revert CampaignNotLaunchable(campaignId);
        }

        IERC20 token = IERC20(campaign.token);
        if (token.balanceOf(address(this)) < tokenAmount) revert LiquidityIncomplete(tokenAmount, msg.value);
        uint256 tokenBefore = token.balanceOf(address(this)) - tokenAmount;
        uint256 bnbBefore = address(this).balance - msg.value;
        uint256[3] memory lpBefore = _lpBalances(campaign.token, campaign.vault);

        token.forceApprove(address(router), tokenAmount);
        (uint256 usedToken, uint256 usedBnb, uint256 liquidity) = router.addLiquidityETH{value: msg.value}(
            campaign.token, tokenAmount, tokenAmount, msg.value, address(this), block.timestamp
        );
        token.forceApprove(address(router), 0);
        if (usedToken != tokenAmount || usedBnb != msg.value || liquidity == 0) {
            revert LiquidityIncomplete(usedToken, usedBnb);
        }
        if (token.balanceOf(address(this)) != tokenBefore || address(this).balance != bnbBefore) {
            revert LiquidityIncomplete(tokenAmount, msg.value);
        }

        address pair = IPancakeFactory(router.factory()).getPair(campaign.token, router.WETH());
        if (pair == address(0) || IERC20(pair).balanceOf(address(this)) != lpBefore[1] + liquidity) {
            revert PairMissing(campaign.token);
        }
        _splitLp(campaignId, pair, campaign.vault, liquidity, lpBefore);
        if (ICauseToken(campaign.token).liquidityModule() == address(this)) {
            ICauseToken(campaign.token).registerPair(pair);
        }
        registry.markActive(campaignId);
        emit LiquidityCreated(campaignId, pair, usedToken, usedBnb, liquidity);
    }

    /// @notice Adds campaign trade-fee BNB to the existing pair's WBNB reserve.
    /// @dev Only that campaign's vault can call this, and only after the pair exists.
    ///      No new LP token is minted. The BNB deepens the pool.
    function depositTradingLiquidity(uint256 campaignId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != msg.sender) revert NotCampaignVault(msg.sender);
        if (campaign.status != CampaignStatus.Active) revert CampaignNotLaunchable(campaignId);
        address pair = ICauseToken(campaign.token).pair();
        if (pair == address(0)) revert PairMissing(campaign.token);

        IWETH weth = IWETH(router.WETH());
        weth.deposit{value: msg.value}();
        if (!weth.transfer(pair, msg.value)) revert LiquidityIncomplete(0, msg.value);
        IPancakePair(pair).sync();
        emit TradingLiquidityAdded(campaignId, pair, msg.value);
    }

    /// @dev Returns the LP balances of the burn address, this module, and the vault before the mint.
    function _lpBalances(address token, address vault) private view returns (uint256[3] memory balances) {
        address existingPair = IPancakeFactory(router.factory()).getPair(token, router.WETH());
        if (existingPair == address(0)) return balances;
        balances[0] = IERC20(existingPair).balanceOf(LP_BURN);
        balances[1] = IERC20(existingPair).balanceOf(address(this));
        balances[2] = IERC20(existingPair).balanceOf(vault);
    }

    function _splitLp(
        uint256 campaignId,
        address pair,
        address vault,
        uint256 liquidity,
        uint256[3] memory lpBefore
    ) private {
        uint256 burned = (liquidity * LP_BURN_BPS) / 10_000;
        uint256 creatorLp = liquidity - burned;
        if (burned == 0 || creatorLp == 0) revert LpShareEmpty();
        IERC20 lp = IERC20(pair);
        lp.safeTransfer(LP_BURN, burned);
        lp.safeTransfer(vault, creatorLp);
        if (lp.balanceOf(LP_BURN) != lpBefore[0] + burned || lp.balanceOf(vault) != lpBefore[2] + creatorLp) {
            revert PairMissing(pair);
        }
        if (lp.balanceOf(address(this)) != lpBefore[1]) revert PairMissing(pair);
        emit LpSplit(campaignId, burned, creatorLp);
    }
}
