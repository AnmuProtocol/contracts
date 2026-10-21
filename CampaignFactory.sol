// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CauseToken} from "./CauseToken.sol";
import {CampaignRegistry} from "./CampaignRegistry.sol";
import {TokenDeployer, VaultDeployer} from "./LaunchDeployers.sol";
import {ICampaignFactory} from "./interfaces/ICampaignFactory.sol";
import {ICampaignRegistry} from "./interfaces/ICampaignRegistry.sol";
import {IPrivateFeeVault} from "./interfaces/IPrivateFeeVault.sol";
import {CreatorVerifier} from "./privacy/CreatorVerifier.sol";
import {ConfigHash} from "./libraries/ConfigHash.sol";
import {LaunchRules} from "./libraries/LaunchRules.sol";
import {Campaign, CampaignConfig, CampaignStatus, CreatorAuthLayout, LaunchKind} from "./types/CauseLaunchTypes.sol";

/// @notice Registers a campaign from a creator-auth proof, then launches its token and vault.
/// @dev `msg.sender` pays gas and is not stored. The proof is checked by `CreatorVerifier`.
///      This contract binds the proof to the configuration digest, the current authorization
///      root, and an unused nullifier. It does not decide that a cause is real.
contract CampaignFactory is ICampaignFactory, ReentrancyGuard {
    CampaignRegistry public immutable registry;
    CreatorVerifier public immutable verifier;
    address public immutable claimVerifier;
    VaultDeployer public immutable vaults;
    TokenDeployer public immutable tokens;

    error AuthorizationRootNotSet();
    error AuthorizationRootMismatch(bytes32 expected, bytes32 actual);
    error TokenNameTooLong(uint256 length);
    error TokenSymbolTooLong(uint256 length);
    error VaultAddressMismatch(address predicted, address deployed);
    error TokenSupplyMismatch();

    constructor(CampaignRegistry registry_, CreatorVerifier verifier_, address claimVerifier_) {
        if (address(registry_) == address(0) || address(verifier_) == address(0) || claimVerifier_ == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        verifier = verifier_;
        claimVerifier = claimVerifier_;
        VaultDeployer vaults_ = new VaultDeployer();
        TokenDeployer tokens_ = new TokenDeployer();
        vaults_.setFactory(address(this));
        tokens_.setFactory(address(this));
        vaults = vaults_;
        tokens = tokens_;
    }

    error ZeroAddress();

    function createCampaign(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        CampaignConfig calldata config
    ) external nonReentrant returns (uint256 campaignId) {
        if (config.launchKind != LaunchKind.Campaign) revert InvalidLaunchKind();
        campaignId = _create(proof, publicInputs, config);
    }

    /// @notice Registers a standard token and credits the 0.005 BNB creation fee to the fee vault.
    function createStandardToken(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        CampaignConfig calldata config
    ) external payable nonReentrant returns (uint256 campaignId) {
        if (config.launchKind != LaunchKind.Standard) revert InvalidLaunchKind();
        if (msg.value != LaunchRules.STANDARD_CREATION_FEE) revert CreationFeeMismatch(msg.value);
        if (registry.feeVault() == address(0)) revert FeeVaultNotSet();
        campaignId = _create(proof, publicInputs, config);
        IPrivateFeeVault(registry.feeVault()).depositCreationFee{value: msg.value}(campaignId);
    }

    function _create(
        bytes calldata proof,
        bytes32[] calldata publicInputs,
        CampaignConfig calldata config
    ) private returns (uint256 campaignId) {
        if (registry.creationPaused()) revert CreationPaused();
        if (publicInputs.length != CreatorAuthLayout.PUBLIC_INPUT_COUNT) {
            revert PublicInputLengthMismatch(CreatorAuthLayout.PUBLIC_INPUT_COUNT, publicInputs.length);
        }

        _checkField(publicInputs);
        _checkConfig(config, publicInputs[CreatorAuthLayout.INDEX_CREATOR_COMMITMENT]);
        bytes32 configurationHash = _checkDigestAndRoot(config, publicInputs);

        bytes32 nullifier = publicInputs[CreatorAuthLayout.INDEX_NULLIFIER];
        if (registry.nullifierUsed(nullifier)) revert ICampaignRegistry.NullifierAlreadyUsed(nullifier);

        if (!verifier.verifyCreatorAuthorization(proof, publicInputs)) revert InvalidProof();

        campaignId = registry.register(_record(config, publicInputs, configurationHash));
        emit CampaignCreated(campaignId, nullifier, configurationHash);
        _launch(campaignId);
    }

    /// @notice Deploys the token and the vault for a campaign that was verified and not yet launched.
    /// @dev A successful `createCampaign` or `createStandardToken` already does this in the same
    ///      transaction. This entry remains for a record that was verified without that deploy.
    ///      The vault salt is `bytes32(campaignId)`. The token salt is
    ///      `keccak256(abi.encode(campaignId, uint256(1)))`. The vault and token
    ///      deployers, not this contract, are the CREATE2 deployers. The caller cannot
    ///      choose the recipient, the supply, the name, or the commitments.
    function launch(uint256 campaignId) external nonReentrant {
        if (registry.getCampaign(campaignId).status != CampaignStatus.Verified) {
            revert CampaignNotLaunchable(campaignId);
        }
        _launch(campaignId);
    }

    function _launch(uint256 campaignId) private {
        Campaign memory campaign = registry.getCampaign(campaignId);
        address feeVault_ = registry.feeVault();
        address liquidityModule_ = registry.liquidityModule();
        address tradeRouter_ = registry.tradeRouter();
        bytes32 vaultSalt = bytes32(campaignId);
        address predictedVault = vaults.predict(
            vaultSalt, campaignId, address(registry), feeVault_, liquidityModule_, claimVerifier
        );

        address token = tokens.deploy(
            keccak256(abi.encode(campaignId, uint256(1))),
            campaign.name,
            campaign.symbol,
            campaign.totalSupply,
            predictedVault,
            liquidityModule_,
            tradeRouter_
        );
        address vault = vaults.deploy(
            vaultSalt, campaignId, address(registry), feeVault_, liquidityModule_, claimVerifier
        );
        if (vault != predictedVault) revert VaultAddressMismatch(predictedVault, vault);
        if (CauseToken(token).balanceOf(vault) != campaign.totalSupply) revert TokenSupplyMismatch();

        registry.markLaunched(campaignId, token, vault);
    }

    function _record(
        CampaignConfig calldata config,
        bytes32[] calldata publicInputs,
        bytes32 configurationHash
    ) private pure returns (Campaign memory) {
        return Campaign({
            id: 0,
            token: address(0),
            vault: address(0),
            creatorCommitment: publicInputs[CreatorAuthLayout.INDEX_CREATOR_COMMITMENT],
            beneficiaryCommitment: config.beneficiaryCommitment,
            feeReceiverCommitment: config.feeReceiverCommitment,
            configurationHash: configurationHash,
            nullifier: publicInputs[CreatorAuthLayout.INDEX_NULLIFIER],
            campaignNonce: uint256(publicInputs[CreatorAuthLayout.INDEX_CAMPAIGN_NONCE]),
            beneficiaryBps: config.beneficiaryBps,
            liquidityBps: config.liquidityBps,
            protocolBps: config.protocolBps,
            status: CampaignStatus.None,
            createdAt: 0,
            name: config.name,
            symbol: config.symbol,
            totalSupply: config.totalSupply,
            metadataURI: config.metadataURI,
            launchKind: config.launchKind,
            creatorTaxBps: config.creatorTaxBps,
            beneficiaryInviteHash: config.beneficiaryInviteHash
        });
    }

    function _checkField(bytes32[] calldata publicInputs) private pure {
        uint256 field = CreatorAuthLayout.BN254_SCALAR_FIELD;
        for (uint256 i = 0; i < publicInputs.length; ++i) {
            if (uint256(publicInputs[i]) >= field) revert PublicInputOutOfField();
        }
        if (uint256(publicInputs[CreatorAuthLayout.INDEX_PROOF_VERSION]) != CreatorAuthLayout.PROOF_VERSION) {
            revert ProofVersionMismatch(
                CreatorAuthLayout.PROOF_VERSION,
                uint256(publicInputs[CreatorAuthLayout.INDEX_PROOF_VERSION])
            );
        }
    }

    function _checkConfig(CampaignConfig calldata config, bytes32 creatorCommitment) private pure {
        uint256 nameLength = bytes(config.name).length;
        uint256 symbolLength = bytes(config.symbol).length;
        if (nameLength == 0) revert EmptyTokenName();
        if (nameLength > ConfigHash.NAME_MAX_BYTES) revert TokenNameTooLong(nameLength);
        if (symbolLength == 0) revert EmptyTokenSymbol();
        if (symbolLength > ConfigHash.SYMBOL_MAX_BYTES) revert TokenSymbolTooLong(symbolLength);
        if (config.totalSupply == 0) revert ZeroTokenSupply();
        uint256 metadataLength = bytes(config.metadataURI).length;
        if (metadataLength > ConfigHash.METADATA_MAX_BYTES) revert MetadataTooLong(metadataLength);
        if (!_contentAddressed(config.metadataURI)) revert MetadataNotContentAddressed();
        if (creatorCommitment == bytes32(0) || config.feeReceiverCommitment == bytes32(0)) revert ZeroCommitment();
        if (creatorCommitment == config.feeReceiverCommitment) revert CommitmentsNotDistinct();
        if (config.launchKind == LaunchKind.Campaign && config.beneficiaryCommitment == bytes32(0)) {
            if (config.beneficiaryInviteHash == bytes32(0)) revert ZeroCommitment();
        } else {
            if (config.beneficiaryCommitment == bytes32(0) || config.beneficiaryInviteHash != bytes32(0)) {
                revert ZeroCommitment();
            }
            if (
                creatorCommitment == config.beneficiaryCommitment
                    || config.beneficiaryCommitment == config.feeReceiverCommitment
            ) revert CommitmentsNotDistinct();
        }
        if (
            !LaunchRules.valid(
                config.launchKind, config.beneficiaryBps, config.liquidityBps, config.protocolBps, config.creatorTaxBps
            )
        ) {
            revert InvalidAllocation(config.beneficiaryBps, config.liquidityBps, config.protocolBps);
        }
    }

    function _checkDigestAndRoot(CampaignConfig calldata config, bytes32[] calldata publicInputs)
        private
        view
        returns (bytes32 configurationHash)
    {
        configurationHash = ConfigHash.digest(
            config.name,
            config.symbol,
            config.totalSupply,
            config.metadataURI,
            config.beneficiaryCommitment,
            config.feeReceiverCommitment,
            config.beneficiaryBps,
            config.liquidityBps,
            config.protocolBps,
            config.launchKind,
            config.creatorTaxBps,
            config.beneficiaryInviteHash
        );
        (bytes32 hi, bytes32 lo) = ConfigHash.split(configurationHash);
        if (
            publicInputs[CreatorAuthLayout.INDEX_CONFIGURATION_HASH_HI] != hi
                || publicInputs[CreatorAuthLayout.INDEX_CONFIGURATION_HASH_LO] != lo
        ) revert ConfigurationLimbMismatch();

        bytes32 root = registry.authorizationRoot();
        if (root == bytes32(0)) revert AuthorizationRootNotSet();
        if (publicInputs[CreatorAuthLayout.INDEX_AUTHORIZATION_ROOT] != root) {
            revert AuthorizationRootMismatch(root, publicInputs[CreatorAuthLayout.INDEX_AUTHORIZATION_ROOT]);
        }
    }

    function _contentAddressed(string memory metadataURI) private pure returns (bool) {
        bytes memory value = bytes(metadataURI);
        if (value.length < 8) return false;
        bytes memory prefix = bytes("ipfs://");
        for (uint256 i = 0; i < prefix.length; ++i) {
            if (value[i] != prefix[i]) return false;
        }
        return true;
    }
}
