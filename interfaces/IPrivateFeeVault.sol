// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Holds protocol-fee BNB claimed against a fee-receiver commitment.
/// @dev A withdrawal to `recipient` is publicly visible. This vault does not provide
///      transaction anonymity. The claim statement is proof version 1 in `docs/zk-design.md`.
interface IPrivateFeeVault {
    event FeesDeposited(uint256 indexed campaignId, uint256 amount);
    event PrivateClaim(uint256 indexed campaignId, bytes32 indexed nullifier, uint256 amount);

    error InvalidProof();
    error NullifierAlreadyUsed(bytes32 nullifier);
    error UnknownCommitment(bytes32 commitment);
    error WrongCampaign(uint256 campaignId);
    error WithdrawalAmountExceedsBalance(uint256 requested, uint256 available);
    error ZeroAmount();
    error RecipientZero();

    function usedNullifiers(bytes32 nullifier) external view returns (bool);

    /// @notice Credits forwarded protocol fees to a campaign's fee-receiver commitment.
    /// @dev Callable only by that campaign's vault.
    function deposit(uint256 campaignId, bytes32 feeReceiverCommitment) external payable;

    /// @notice Credits a standard token's 0.005 BNB creation fee. Callable only by the factory role.
    function depositCreationFee(uint256 campaignId) external payable;

    /// @notice Pays `amount` to `recipient` after a private-claim proof.
    /// @dev The proof must bind the fee-receiver commitment, campaign id, nullifier,
    ///      recipient, and amount. The implementation marks `nullifier` used before transfer.
    function claim(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        uint256 campaignId,
        address recipient,
        uint256 amount
    ) external;
}
