// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ClaimVerifier} from "./privacy/ClaimVerifier.sol";
import {ICampaignRegistry} from "./interfaces/ICampaignRegistry.sol";
import {ICampaignVault} from "./interfaces/ICampaignVault.sol";
import {IPrivateFeeVault} from "./interfaces/IPrivateFeeVault.sol";
import {ClaimBinding} from "./libraries/ClaimBinding.sol";
import {Campaign, ClaimLayout, LaunchKind, Roles} from "./types/CauseLaunchTypes.sol";

/// @notice Holds protocol-fee BNB and pays it against a fee-receiver commitment.
/// @dev A deposit is accepted only from the campaign vault recorded in the registry.
///      `claim` pays `recipient` only after a private-claim proof. The recipient is
///      public in that transaction. There is no admin withdrawal and no claim pause.
contract PrivateFeeVault is ReentrancyGuard, IPrivateFeeVault {
    ICampaignRegistry public immutable registry;
    ClaimVerifier public immutable claims;

    mapping(uint256 => uint256) public campaignBalance;
    mapping(bytes32 => bool) public usedNullifiers;

    error ZeroAddress();
    error NotCampaignVault(address caller);
    error NotFactory(address caller);
    error NotStandardToken(uint256 campaignId);
    error ClaimTransferFailed();

    constructor(ICampaignRegistry registry_, ClaimVerifier claims_) {
        if (address(registry_) == address(0) || address(claims_) == address(0)) revert ZeroAddress();
        registry = registry_;
        claims = claims_;
    }

    /// @notice Credits protocol fees forwarded by the campaign's own vault.
    function deposit(uint256 campaignId, bytes32 feeReceiverCommitment) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault != msg.sender) revert NotCampaignVault(msg.sender);
        if (campaign.feeReceiverCommitment != feeReceiverCommitment) {
            revert UnknownCommitment(feeReceiverCommitment);
        }
        campaignBalance[campaignId] += msg.value;
        emit FeesDeposited(campaignId, msg.value);
    }

    /// @notice Credits the 0.005 BNB standard-token creation fee.
    /// @dev The vault does not exist yet, so this cannot use `deposit`.
    function depositCreationFee(uint256 campaignId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        if (!AccessControl(address(registry)).hasRole(Roles.FACTORY_ROLE, msg.sender)) revert NotFactory(msg.sender);
        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.launchKind != LaunchKind.Standard) revert NotStandardToken(campaignId);
        campaignBalance[campaignId] += msg.value;
        emit FeesDeposited(campaignId, msg.value);
    }

    /// @notice Pays `amount` to `recipient` from this campaign's protocol-fee balance.
    function claim(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        uint256 campaignId,
        address recipient,
        uint256 amount
    ) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert RecipientZero();

        Campaign memory campaign = registry.getCampaign(campaignId);
        if (campaign.vault == address(0)) revert WrongCampaign(campaignId);
        ClaimBinding.bind(
            publicInputs,
            ClaimLayout.FEE_RECEIVER_ROLE,
            campaign.feeReceiverCommitment,
            campaignId,
            recipient,
            amount
        );
        bytes32 nullifier = publicInputs[ClaimLayout.INDEX_NULLIFIER];
        if (usedNullifiers[nullifier]) revert NullifierAlreadyUsed(nullifier);
        if (campaign.vault != address(0) && ICampaignVault(campaign.vault).claimNullifierUsed(nullifier)) {
            revert NullifierAlreadyUsed(nullifier);
        }
        uint256 available = campaignBalance[campaignId];
        if (amount > available) revert WithdrawalAmountExceedsBalance(amount, available);
        if (!claims.verifyClaim(proof, publicInputs)) revert InvalidProof();

        usedNullifiers[nullifier] = true;
        campaignBalance[campaignId] = available - amount;
        emit PrivateClaim(campaignId, nullifier, amount);

        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert ClaimTransferFailed();
    }
}
