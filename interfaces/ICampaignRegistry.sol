// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Campaign, CampaignStatus} from "../types/CauseLaunchTypes.sol";

/// @notice Stores public campaign records and enforces the lifecycle.
/// @dev The campaign struct has no creator, beneficiary, or fee-receiver wallet. Those identities
///      are commitments. A claim payment names its recipient when the BNB moves.
interface ICampaignRegistry {
    event CampaignRegistered(
        uint256 indexed campaignId,
        bytes32 indexed nullifier,
        bytes32 creatorCommitment,
        bytes32 configurationHash
    );
    event CampaignVerified(uint256 indexed campaignId);
    event CampaignRejected(uint256 indexed campaignId);
    event CampaignLaunched(uint256 indexed campaignId, address token, address vault);
    event CampaignActivated(uint256 indexed campaignId);
    event CampaignClosed(uint256 indexed campaignId);
    event DonationsPauseSet(bool paused);

    error CampaignNotFound(uint256 campaignId);
    error NullifierAlreadyUsed(bytes32 nullifier);
    error InvalidCampaignStatus(CampaignStatus current, CampaignStatus attempted);
    error TokenAlreadySet(uint256 campaignId);
    error ParameterImmutable(uint256 campaignId);

    /// @notice Registers a pending campaign. Callable only by the factory role.
    /// @dev Consumes `campaign.nullifier`. Rejects a reused nullifier.
    function register(Campaign calldata campaign) external returns (uint256 campaignId);

    /// @notice Pending -> Verified. Callable only by the verifier role.
    function markVerified(uint256 campaignId) external;

    /// @notice Pending -> Closed. Callable only by the verifier role.
    /// @dev Does not clear the consumed nullifier and does not deploy a token.
    function rejectPending(uint256 campaignId) external;

    /// @notice Verified -> Launched. Callable only by the factory role.
    /// @dev Token and vault are set once in this transition.
    function markLaunched(uint256 campaignId, address token, address vault) external;

    /// @notice Launched -> Active. Records that the liquidity step has been completed.
    /// @dev Callable by the factory role, or by the liquidity module stored on this campaign's vault.
    ///      Must not change allocations, commitments, token, or vault.
    function markActive(uint256 campaignId) external;

    /// @notice Active or Launched -> Closed. Stops new donations.
    /// @dev Must not move, seize, or redirect vault balances.
    function close(uint256 campaignId) external;

    function getCampaign(uint256 campaignId) external view returns (Campaign memory);

    function nullifierUsed(bytes32 nullifier) external view returns (bool);

    function campaignCount() external view returns (uint256);

    /// @notice Global donation pause. It does not pause claims or fee forwarding.
    function donationsPaused() external view returns (bool);

    /// @notice Pausable only by the pauser role. Closing a campaign is separate.
    function setDonationsPaused(bool paused) external;
}
