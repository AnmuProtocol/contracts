// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ClaimVerifier} from "./privacy/ClaimVerifier.sol";
import {ICampaignRegistry} from "./interfaces/ICampaignRegistry.sol";
import {ICampaignVault} from "./interfaces/ICampaignVault.sol";
import {ICauseToken} from "./interfaces/ICauseToken.sol";
import {IPrivateFeeVault} from "./interfaces/IPrivateFeeVault.sol";
import {BondingCurve} from "./libraries/BondingCurve.sol";
import {ClaimBinding} from "./libraries/ClaimBinding.sol";
import {LaunchRules} from "./libraries/LaunchRules.sol";
import {Campaign, CampaignStatus, ClaimLayout, LaunchKind, VaultAccounting} from "./types/CauseLaunchTypes.sol";

interface ITradingLiquidity {
    function depositTradingLiquidity(uint256 campaignId) external payable;
}

interface ICurveMigration {
    function migrateCurve(uint256 campaignId, uint256 tokenAmount) external payable;
}

/// @notice Holds a campaign's token inventory and accounted donation buckets.
/// @dev `donate` credits native BNB. `withdraw` pays the beneficiary bucket only after a
///      private-claim proof that opens the stored beneficiary commitment and binds the
///      recipient, the amount, and this campaign. `forwardProtocolFees` sends only the
///      protocol bucket to the immutable fee vault. There is no sweep.
///      `feeVault`, `liquidityModule`, and `claims` are copied at launch and are immutable.
///      The zero fee vault means protocol fees stay here. Forced BNB is stuck.
contract CampaignVault is ReentrancyGuard, ICampaignVault {
    using SafeERC20 for IERC20;

    uint256 public immutable campaignId;
    ICampaignRegistry public immutable registry;
    address public immutable feeVault;
    address public immutable liquidityModule;
    ClaimVerifier public immutable claims;

    uint256 public beneficiaryBalance;
    uint256 public liquidityBalance;
    uint256 public protocolBalance;
    uint256 public totalReceived;
    uint256 public totalWithdrawn;
    uint256 public creatorTradingFees;
    uint256 public beneficiaryTradingFees;
    uint256 public platformTradingFees;
    uint256 public liquidityTradingFees;
    /// @notice Unused. A public seed is rejected. Curve BNB is `curveQuote` and `curveLiquidityBnb`.
    uint256 public poolSeed;
    /// @notice Supply locked into the curve on the first trade. Zero until the curve opens.
    uint256 public curveSupply;
    uint256 public curveTokenReserve;
    /// @notice Real BNB inside the constant product. Fees are not included.
    uint256 public curveQuote;
    /// @notice Campaign trade-fee BNB waiting to be added when the curve migrates. It is not inside `k`.
    uint256 public curveLiquidityBnb;
    bool public curveMigrated;
    mapping(bytes32 => bool) public claimNullifierUsed;

    error ZeroRegistry();
    error ZeroClaimVerifier();
    error FeeVaultNotSet();
    error FeeTransferFailed();
    error ClaimTransferFailed();
    error VaultNotRegistered();
    error NotLiquidityModule(address caller);
    error LiquidityModuleNotSet();
    error LiquidityNotReady();
    error LiquidityTransferFailed();
    error NotTradeRouter(address caller);
    error NotStandardToken();
    error PairNotRegistered();
    error FeeValueMismatch(uint256 value, uint256 accounted);
    error LiquidityNotOpen();
    error CurveAlreadyMigrated();
    error CurveComplete();
    error CurveInventoryProtected();
    error TradingRoleUnavailable();
    error Slippage(uint256 received, uint256 minimum);
    event LiquidityReleased(uint256 indexed campaignId, uint256 tokenAmount, uint256 bnbAmount);
    event TradingFeesCredited(uint256 indexed campaignId, uint256 creatorAmount, uint256 counterpartyAmount);
    event LiquidityFunded(uint256 indexed campaignId, uint256 amount);
    event TradingLiquidityDeposited(uint256 indexed campaignId, uint256 amount);
    event TradingFeesClaimed(uint256 indexed campaignId, bytes32 indexed nullifier, uint256 amount);
    event SupplyClaimed(uint256 indexed campaignId, bytes32 indexed nullifier, uint256 amount);
    event LpClaimed(uint256 indexed campaignId, bytes32 indexed nullifier, uint256 amount);
    event CurveTrade(
        uint256 indexed campaignId, address indexed trader, bool buy, uint256 bnbAmount, uint256 tokenAmount
    );
    event CurveMigrated(uint256 indexed campaignId, uint256 tokenAmount, uint256 bnbAmount);

    constructor(
        uint256 campaignId_,
        address registry_,
        address feeVault_,
        address liquidityModule_,
        address claimVerifier_
    ) {
        if (registry_ == address(0)) revert ZeroRegistry();
        if (claimVerifier_ == address(0)) revert ZeroClaimVerifier();
        campaignId = campaignId_;
        registry = ICampaignRegistry(registry_);
        feeVault = feeVault_;
        liquidityModule = liquidityModule_;
        claims = ClaimVerifier(claimVerifier_);
    }

    /// @notice Credits `msg.value` to the beneficiary. A campaign donation is not split.
    /// @dev The donor is the transaction sender and is not a field of the event. The frozen
    ///      basis points are 10000 / 0 / 0, so the whole payment stays in the beneficiary bucket.
    function donate() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (registry.donationsPaused()) revert DonationsPaused();

        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != address(this) || campaign.launchKind != LaunchKind.Campaign || !_accepting(campaign.status))
        {
            revert CampaignNotAcceptingDonations();
        }

        uint256 protocolAmount = (msg.value * campaign.protocolBps) / 10_000;
        uint256 liquidityAmount = (msg.value * campaign.liquidityBps) / 10_000;
        uint256 beneficiaryAmount = msg.value - protocolAmount - liquidityAmount;

        protocolBalance += protocolAmount;
        liquidityBalance += liquidityAmount;
        beneficiaryBalance += beneficiaryAmount;
        totalReceived += msg.value;

        emit DonationReceived(campaignId, msg.value);
    }

    /// @notice Retired. The curve migrates itself on the filling buy. A public seed can empty the inventory.
    function fundLiquidity() external payable {
        revert CurveInventoryProtected();
    }

    /// @notice Sends `amount` of beneficiary-bucket BNB to `recipient`.
    /// @dev Before a beneficiary accepts, the creator proof opens this bucket. After accept,
    ///      only the beneficiary proof does. The recipient is public in this transaction.
    function withdraw(bytes calldata proof, bytes32[] calldata publicInputs, address recipient, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert RecipientZero();

        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != address(this)) revert VaultNotRegistered();
        (uint256 role, bytes32 commitment) = _donationClaim(campaign);
        ClaimBinding.bind(publicInputs, role, commitment, campaignId, recipient, amount);
        bytes32 nullifier = publicInputs[ClaimLayout.INDEX_NULLIFIER];
        _unused(nullifier);
        if (amount > beneficiaryBalance) revert WithdrawalAmountExceedsBalance(amount, beneficiaryBalance);
        if (!claims.verifyClaim(proof, publicInputs)) revert InvalidProof();

        _spend(nullifier);
        beneficiaryBalance -= amount;
        totalWithdrawn += amount;
        emit Withdrawal(campaignId, nullifier, amount);

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert ClaimTransferFailed();
    }

    /// @notice Sends the full protocol bucket to `feeVault`.
    /// @dev Permissionless. The destination was fixed at construction and is not an argument.
    ///      A zero fee vault leaves the bucket in place. This is not a beneficiary withdrawal.
    function forwardProtocolFees() external nonReentrant {
        uint256 amount = protocolBalance;
        if (amount == 0) revert ZeroAmount();
        if (feeVault == address(0)) revert FeeVaultNotSet();

        bytes32 commitment = registry.getCampaign(campaignId).feeReceiverCommitment;
        protocolBalance = 0;
        emit ProtocolFeesForwarded(campaignId, amount);

        (bool ok,) = feeVault.call{value: amount}(
            abi.encodeWithSelector(IPrivateFeeVault.deposit.selector, campaignId, commitment)
        );
        if (!ok) revert FeeTransferFailed();
    }

    /// @notice Retired. Migration sends the unsold curve reserve from the filling buy, not the whole balance.
    /// @dev A permissionless pull of `balanceOf(this)` can move the curve inventory and leave `curveQuote` behind.
    function releaseLiquidity() external view {
        if (liquidityModule == address(0)) revert LiquidityModuleNotSet();
        if (msg.sender != liquidityModule) revert NotLiquidityModule(msg.sender);
        revert CurveInventoryProtected();
    }

    /// @notice Adds a buy or sell fee, paid in BNB, to the creator bucket and the counterparty bucket.
    /// @dev On a campaign the counterparty is sent to the liquidity module, which adds it to the
    ///      pool. It is not credited to the beneficiary. On a standard token the platform share is
    ///      forwarded to the fee vault when one was copied at launch. These balances are not
    ///      donation buckets and do not change `totalReceived`.
    function creditTradingFees(uint256 creatorAmount, uint256 counterpartyAmount) external payable nonReentrant {
        uint256 fee = creatorAmount + counterpartyAmount;
        if (msg.value == 0 || msg.value != fee) revert FeeValueMismatch(msg.value, fee);
        Campaign memory campaign = registry.getCampaign(campaignId);
        address router = ICauseToken(campaign.token).tradeRouter();
        if (router == address(0) || msg.sender != router) revert NotTradeRouter(msg.sender);

        creatorTradingFees += creatorAmount;
        bool deposited = false;
        if (campaign.launchKind == LaunchKind.Campaign) {
            address pair = ICauseToken(campaign.token).pair();
            if (liquidityModule != address(0) && pair != address(0) && counterpartyAmount != 0) {
                ITradingLiquidity(liquidityModule).depositTradingLiquidity{value: counterpartyAmount}(campaignId);
                deposited = true;
                emit TradingLiquidityDeposited(campaignId, counterpartyAmount);
            } else {
                liquidityTradingFees += counterpartyAmount;
            }
        } else if (feeVault == address(0) || counterpartyAmount == 0) {
            platformTradingFees += counterpartyAmount;
        }
        emit TradingFeesCredited(campaignId, creatorAmount, counterpartyAmount);
        if (deposited) return;

        if (campaign.launchKind == LaunchKind.Standard && feeVault != address(0) && counterpartyAmount != 0) {
            IPrivateFeeVault(feeVault).deposit{value: counterpartyAmount}(campaignId, campaign.feeReceiverCommitment);
        }
    }

    /// @notice Sends trading-fee BNB to `recipient` after a private-claim proof.
    function claimTradingFees(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        address recipient,
        uint256 amount,
        uint256 role
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert RecipientZero();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != address(this)) revert VaultNotRegistered();

        bytes32 commitment = _commitment(campaign, role);
        ClaimBinding.bind(publicInputs, role, commitment, campaignId, recipient, amount);
        bytes32 nullifier = publicInputs[ClaimLayout.INDEX_NULLIFIER];
        _unused(nullifier);
        uint256 available = _tradingBucket(role);
        if (amount > available) revert WithdrawalAmountExceedsBalance(amount, available);
        if (!claims.verifyClaim(proof, publicInputs)) revert InvalidProof();

        _spend(nullifier);
        _decreaseTradingBucket(role, amount);
        emit TradingFeesClaimed(campaignId, nullifier, amount);
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert ClaimTransferFailed();
    }

    /// @notice Moves campaign trade-fee BNB that arrived before the pair existed into that pair.
    /// @dev The curve parks its own fee in `curveLiquidityBnb` and adds it at migration. This clears
    ///      the fallback bucket once the pair is registered. It does not pay the beneficiary.
    function flushLiquidityTradingFees() external nonReentrant {
        uint256 amount = liquidityTradingFees;
        if (amount == 0) revert ZeroAmount();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != address(this) || campaign.status != CampaignStatus.Active) revert LiquidityNotReady();
        address pair = ICauseToken(campaign.token).pair();
        if (liquidityModule == address(0) || pair == address(0)) revert PairNotRegistered();
        liquidityTradingFees = 0;
        ITradingLiquidity(liquidityModule).depositTradingLiquidity{value: amount}(campaignId);
        emit TradingLiquidityDeposited(campaignId, amount);
    }

    /// @notice Sends the creator's PancakeSwap LP balance to `recipient`. The creator proof names the recipient.
    /// @dev This is the 5% kept at seeding. Redeeming it removes that share of the pool.
    function claimLp(bytes calldata proof, bytes32[] calldata publicInputs, address recipient, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert RecipientZero();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != address(this)) revert VaultNotRegistered();
        address pair = ICauseToken(campaign.token).pair();
        if (pair == address(0)) revert PairNotRegistered();

        ClaimBinding.bind(
            publicInputs, ClaimLayout.CREATOR_ROLE, campaign.creatorCommitment, campaignId, recipient, amount
        );
        bytes32 nullifier = publicInputs[ClaimLayout.INDEX_NULLIFIER];
        _unused(nullifier);
        uint256 available = IERC20(pair).balanceOf(address(this));
        if (amount > available) revert WithdrawalAmountExceedsBalance(amount, available);
        if (!claims.verifyClaim(proof, publicInputs)) revert InvalidProof();

        _spend(nullifier);
        emit LpClaimed(campaignId, nullifier, amount);
        IERC20(pair).safeTransfer(recipient, amount);
    }

    /// @notice Sends unsold standard-token inventory to `recipient`. The creator proof names the recipient.
    /// @dev Campaign inventory is reserved for the pool and cannot be claimed here.
    function claimSupply(bytes calldata proof, bytes32[] calldata publicInputs, address recipient, uint256 amount)
        external
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert RecipientZero();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != address(this)) revert VaultNotRegistered();
        if (campaign.launchKind != LaunchKind.Standard) revert NotStandardToken();
        if (campaign.status != CampaignStatus.Active) revert CurveComplete();

        ClaimBinding.bind(
            publicInputs, ClaimLayout.CREATOR_ROLE, campaign.creatorCommitment, campaignId, recipient, amount
        );
        bytes32 nullifier = publicInputs[ClaimLayout.INDEX_NULLIFIER];
        _unused(nullifier);
        uint256 available = IERC20(campaign.token).balanceOf(address(this));
        if (amount > available) revert WithdrawalAmountExceedsBalance(amount, available);
        if (!claims.verifyClaim(proof, publicInputs)) revert InvalidProof();

        _spend(nullifier);
        emit SupplyClaimed(campaignId, nullifier, amount);
        IERC20(campaign.token).safeTransfer(recipient, amount);
    }

    /// @dev Until a beneficiary accepts, the organizer's creator proof withdraws donations.
    function _donationClaim(Campaign memory campaign) private pure returns (uint256 role, bytes32 commitment) {
        if (campaign.beneficiaryCommitment == bytes32(0)) {
            return (ClaimLayout.CREATOR_ROLE, campaign.creatorCommitment);
        }
        return (ClaimLayout.BENEFICIARY_ROLE, campaign.beneficiaryCommitment);
    }

    function _commitment(Campaign memory campaign, uint256 role) private pure returns (bytes32) {
        if (role == ClaimLayout.CREATOR_ROLE) return campaign.creatorCommitment;
        if (role == ClaimLayout.BENEFICIARY_ROLE) return campaign.beneficiaryCommitment;
        if (role == ClaimLayout.FEE_RECEIVER_ROLE) return campaign.feeReceiverCommitment;
        revert InvalidProof();
    }

    function _tradingBucket(uint256 role) private view returns (uint256) {
        if (role == ClaimLayout.BENEFICIARY_ROLE) revert TradingRoleUnavailable();
        if (role == ClaimLayout.CREATOR_ROLE) return creatorTradingFees;
        if (role == ClaimLayout.FEE_RECEIVER_ROLE) return platformTradingFees;
        revert InvalidProof();
    }

    function _decreaseTradingBucket(uint256 role, uint256 amount) private {
        if (role == ClaimLayout.BENEFICIARY_ROLE) revert TradingRoleUnavailable();
        if (role == ClaimLayout.CREATOR_ROLE) creatorTradingFees -= amount;
        else if (role == ClaimLayout.FEE_RECEIVER_ROLE) platformTradingFees -= amount;
        else revert InvalidProof();
    }

    function _unused(bytes32 nullifier) private view {
        if (claimNullifierUsed[nullifier]) revert NullifierAlreadyUsed(nullifier);
        if (feeVault != address(0) && IPrivateFeeVault(feeVault).usedNullifiers(nullifier)) {
            revert NullifierAlreadyUsed(nullifier);
        }
    }

    function _spend(bytes32 nullifier) private {
        claimNullifierUsed[nullifier] = true;
    }

    /// @notice Spot market cap, in wei of BNB, at which this curve migrates. It does not depend on supply.
    function migrationMarketCap() external pure returns (uint256) {
        return BondingCurve.migrationMarketCap();
    }

    /// @notice Real reserve progress toward migration, in basis points.
    function curveProgress() external view returns (uint256) {
        return BondingCurve.progress(curveQuote);
    }

    /// @notice Buys from the virtual-reserve curve. Callable only by this launch's trade router.
    /// @dev The fee is taken outside `k`. A buy that fills the migration reserve refunds the unused
    ///      BNB and, when a liquidity module is set, moves the remaining tokens and the real reserve
    ///      into that module in this transaction.
    function buyOnCurve(address recipient, uint256 minTokens) external payable nonReentrant returns (uint256 tokensOut) {
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) revert RecipientZero();
        Campaign memory campaign = _curveCaller(false);
        _openCurve(campaign.token);
        if (curveQuote >= BondingCurve.MIGRATION_QUOTE) revert CurveComplete();

        (uint256 gross, uint256 net) = _chargeBuy(campaign, msg.value);
        (uint256 newReserve, uint256 out) = BondingCurve.tokensOut(curveSupply, curveTokenReserve, curveQuote, net);
        if (out < minTokens) revert Slippage(out, minTokens);

        curveTokenReserve = newReserve;
        curveQuote += net;
        IERC20(campaign.token).safeTransfer(recipient, out);
        _refund(recipient, msg.value - gross);
        emit CurveTrade(campaignId, recipient, true, net, out);
        tokensOut = out;
        if (curveQuote + 10_000 >= BondingCurve.MIGRATION_QUOTE) _migrate(campaign);
    }

    /// @notice Sells into the curve. The router has already transferred `tokenAmount` to this vault.
    function sellOnCurve(address recipient, uint256 tokenAmount, uint256 minBnb)
        external
        nonReentrant
        returns (uint256 bnbOut)
    {
        if (tokenAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert RecipientZero();
        Campaign memory campaign = _curveCaller(true);
        _openCurve(campaign.token);
        bnbOut = _sell(campaign, recipient, tokenAmount, minBnb);
    }

    /// @dev Buys require `Launched`. A sell is also allowed after `close` while the curve still
    ///      holds quote, so closing the market does not trap `curveQuote`.
    function _curveCaller(bool allowClosedExit) private view returns (Campaign memory campaign) {
        if (curveMigrated) revert CurveAlreadyMigrated();
        campaign = registry.getCampaign(campaignId);
        bool open = campaign.status == CampaignStatus.Launched
            || (allowClosedExit && campaign.status == CampaignStatus.Closed && curveQuote > 0);
        if (!open || campaign.vault != address(this)) revert LiquidityNotOpen();
        address router = ICauseToken(campaign.token).tradeRouter();
        if (router == address(0) || msg.sender != router) revert NotTradeRouter(msg.sender);
    }

    function _chargeBuy(Campaign memory campaign, uint256 value) private returns (uint256 gross, uint256 net) {
        (uint16 creatorBps, uint16 counterpartyBps) = LaunchRules.tradeFees(campaign.launchKind, campaign.creatorTaxBps);
        uint256 creatorFee;
        uint256 counterpartyFee;
        (gross, creatorFee, counterpartyFee, net) = BondingCurve.charge(value, curveQuote, creatorBps, counterpartyBps);
        if (net == 0) revert ZeroAmount();
        creatorTradingFees += creatorFee;
        _takeCounterparty(campaign, counterpartyFee);
    }

    function _sell(Campaign memory campaign, address recipient, uint256 tokenAmount, uint256 minBnb)
        private
        returns (uint256 payout)
    {
        (uint256 newReserve, uint256 gross) =
            BondingCurve.quoteOut(curveSupply, curveTokenReserve, curveQuote, tokenAmount);
        if (gross == 0) revert ZeroAmount();
        (uint16 creatorBps, uint16 counterpartyBps) = LaunchRules.tradeFees(campaign.launchKind, campaign.creatorTaxBps);
        uint256 creatorFee = gross * creatorBps / 10_000;
        uint256 counterpartyFee = gross * counterpartyBps / 10_000;
        payout = gross - creatorFee - counterpartyFee;
        if (payout < minBnb) revert Slippage(payout, minBnb);
        curveTokenReserve = newReserve;
        curveQuote -= gross;
        creatorTradingFees += creatorFee;
        _takeCounterparty(campaign, counterpartyFee);
        emit CurveTrade(campaignId, recipient, false, payout, tokenAmount);
        (bool ok,) = recipient.call{value: payout}("");
        if (!ok) revert ClaimTransferFailed();
    }

    function _refund(address recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert ClaimTransferFailed();
    }

    function _openCurve(address token) private {
        if (curveSupply != 0) return;
        uint256 supply = IERC20(token).balanceOf(address(this));
        if (supply == 0) revert ZeroAmount();
        curveSupply = supply;
        curveTokenReserve = supply;
    }

    /// @dev Campaign counterparty waits beside the curve and is added at migration. A standard
    ///      token forwards its platform share to the fee vault. Neither amount changes `k`.
    function _takeCounterparty(Campaign memory campaign, uint256 counterpartyFee) private {
        if (counterpartyFee == 0) return;
        if (campaign.launchKind == LaunchKind.Campaign) {
            curveLiquidityBnb += counterpartyFee;
            return;
        }
        if (feeVault == address(0)) {
            platformTradingFees += counterpartyFee;
            return;
        }
        IPrivateFeeVault(feeVault).deposit{value: counterpartyFee}(campaignId, campaign.feeReceiverCommitment);
    }

    function _migrate(Campaign memory campaign) private {
        if (curveMigrated || liquidityModule == address(0)) return;
        uint256 tokens = curveTokenReserve;
        uint256 parked = liquidityTradingFees;
        uint256 bnb = curveQuote + curveLiquidityBnb + parked;
        if (tokens == 0 || bnb == 0) return;
        curveTokenReserve = 0;
        curveQuote = 0;
        curveLiquidityBnb = 0;
        liquidityTradingFees = 0;
        curveMigrated = true;
        IERC20(campaign.token).safeTransfer(liquidityModule, tokens);
        emit CurveMigrated(campaignId, tokens, bnb);
        ICurveMigration(liquidityModule).migrateCurve{value: bnb}(campaignId, tokens);
    }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    function accounting() external view returns (VaultAccounting memory) {
        return VaultAccounting({
            beneficiaryBalance: beneficiaryBalance,
            liquidityBalance: liquidityBalance,
            protocolBalance: protocolBalance,
            totalReceived: totalReceived,
            totalWithdrawn: totalWithdrawn
        });
    }

    function _accepting(CampaignStatus status) private pure returns (bool) {
        return status == CampaignStatus.Launched || status == CampaignStatus.Active;
    }
}
