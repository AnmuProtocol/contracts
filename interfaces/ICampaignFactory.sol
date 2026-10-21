// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CampaignConfig} from "../types/CauseLaunchTypes.sol";

/// @notice Creates campaigns from a creator-authorization proof and public configuration.
/// @dev `msg.sender` is the gas payer, not the creator. The implementation must not store
///      `msg.sender` as a creator address. `createCampaign` calls `CreatorVerifier`, then
///      binds the keccak digest, the current authorization root, and the nullifier.
interface ICampaignFactory {
    event CampaignCreated(
        uint256 indexed campaignId, bytes32 indexed nullifier, bytes32 configurationHash
    );

    error CreationPaused();
    error InvalidProof();
    error ProofVersionMismatch(uint256 expected, uint256 actual);
    error PublicInputLengthMismatch(uint256 expected, uint256 actual);
    error PublicInputOutOfField();
    error ConfigurationLimbMismatch();
    error InvalidAllocation(uint16 beneficiaryBps, uint16 liquidityBps, uint16 protocolBps);
    error ZeroCommitment();
    error CommitmentsNotDistinct();
    error ZeroTokenSupply();
    error EmptyTokenName();
    error EmptyTokenSymbol();
    error MetadataNotContentAddressed();
    error MetadataTooLong(uint256 length);
    error CampaignNotLaunchable(uint256 campaignId);
    error InvalidLaunchKind();
    error CreationFeeMismatch(uint256 value);
    error FeeVaultNotSet();

    /// @notice Verifies the creator-authorization proof, checks the configuration, and registers
    ///         a Pending campaign.
    /// @param proof EVM UltraHonk proof bytes for the generated creator-auth verifier.
    /// @param publicInputs Seven field elements in `CreatorAuthLayout` order, each strictly
    ///        less than the BN254 scalar modulus.
    /// @param config Public campaign configuration. Must not contain identity or address fields.
    function createCampaign(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        CampaignConfig calldata config
    ) external returns (uint256 campaignId);

    /// @notice Registers a standard token. `msg.value` must be exactly 0.005 BNB.
    /// @dev The fee is credited to the fee vault for the fee-receiver commitment. It is not a donation.
    function createStandardToken(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        CampaignConfig calldata config
    ) external payable returns (uint256 campaignId);

    /// @notice Deploys the fixed-supply token and the vault for a Verified campaign.
    /// @dev Permissionless. Parameters come from the registry, not from the caller.
    function launch(uint256 campaignId) external;
}
