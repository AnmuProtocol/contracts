// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {VaultAccounting} from "../types/CauseLaunchTypes.sol";

/// @notice Holds donated BNB and the campaign token inventory.
/// @dev No admin withdrawal. Beneficiary BNB moves only through the private-claim proof
///      specified in docs/zk-design.md. The recipient is visible in the payment.
interface ICampaignVault {
    event DonationReceived(uint256 indexed campaignId, uint256 amount);
    event Withdrawal(uint256 indexed campaignId, bytes32 indexed nullifier, uint256 amount);
    event ProtocolFeesForwarded(uint256 indexed campaignId, uint256 amount);

    error DonationsPaused();
    error ZeroAmount();
    error RecipientZero();
    error InvalidProof();
    error NullifierAlreadyUsed(bytes32 nullifier);
    error WithdrawalAmountExceedsBalance(uint256 requested, uint256 available);
    error CampaignNotAcceptingDonations();

    function campaignId() external view returns (uint256);

    /// @notice Credits BNB into the beneficiary, liquidity, and protocol buckets.
    function donate() external payable;

    /// @notice Sends beneficiary-bucket BNB to `recipient`.
    /// @dev The proof must bind `recipient`, `amount`, the campaign id, and the beneficiary
    ///      commitment. `recipient` is visible in this transaction.
    function withdraw(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        address recipient,
        uint256 amount
    ) external;

    /// @notice Moves the full accounted protocol balance to the immutable fee vault.
    /// @dev Permissionless. The destination is fixed at construction.
    function forwardProtocolFees() external;

    function balance() external view returns (uint256);

    function totalReceived() external view returns (uint256);

    function totalWithdrawn() external view returns (uint256);

    function accounting() external view returns (VaultAccounting memory);

    /// @notice The module copied at launch. The zero address means liquidity stays here.
    function liquidityModule() external view returns (address);

    function claimNullifierUsed(bytes32 nullifier) external view returns (bool);

    /// @notice Retired. The curve migrates on the filling buy. This does not move inventory.
    function releaseLiquidity() external;

    /// @notice Credits a buy or sell fee paid in BNB. Callable only by this campaign's trade router.
    function creditTradingFees(uint256 creatorAmount, uint256 counterpartyAmount) external payable;

    /// @notice Pays a trading-fee BNB balance to `recipient`.
    /// @dev Role 3 is the creator. Role 1 is not a trading-fee bucket. Role 2 pays a platform
    ///      balance that was kept here because no fee vault was set. A standard token's platform
    ///      share is forwarded to the fee vault instead.
    function claimTradingFees(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        address recipient,
        uint256 amount,
        uint256 role
    ) external;

    /// @notice Pays the creator's 5% PancakeSwap LP balance to `recipient`.
    /// @dev The proof is the creator role. The other 95% of the LP token is burned at seeding.
    function claimLp(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        address recipient,
        uint256 amount
    ) external;

    /// @notice Pays unsold standard-token inventory to `recipient`. Campaign inventory stays for the pool.
    function claimSupply(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        address recipient,
        uint256 amount
    ) external;
}
