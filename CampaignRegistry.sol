// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ICampaignRegistry} from "./interfaces/ICampaignRegistry.sol";
import {ICampaignVault} from "./interfaces/ICampaignVault.sol";
import {ConfigHash} from "./libraries/ConfigHash.sol";
import {LaunchRules} from "./libraries/LaunchRules.sol";
import {Campaign, CampaignStatus, CreatorAuthLayout, LaunchKind, Roles} from "./types/CauseLaunchTypes.sol";

/// @notice Public campaign records, the spent-nullifier map, and the current authorization root.
/// @dev Storage has no creator, beneficiary, or fee-receiver wallet. Nullifiers are never cleared.
contract CampaignRegistry is AccessControl, ICampaignRegistry {
    uint256 private _campaignCount;
    mapping(uint256 => Campaign) private _campaigns;
    mapping(bytes32 => bool) public nullifierUsed;
    /// @dev One lock per campaign. The secret can be published only by that locker, and only after the lock block.
    mapping(uint256 => BeneficiaryLock) private _beneficiaryLock;

    uint256 public constant BENEFICIARY_LOCK_TIMEOUT = 1 hours;

    struct BeneficiaryLock {
        address locker;
        bytes32 hash;
        uint64 blockNumber;
        uint64 timestamp;
    }

    bytes32 public authorizationRoot;
    bool public creationPaused;
    bool public donationsPaused;
    address public feeVault;
    address public liquidityModule;
    address public tradeRouter;

    error ZeroAddress();
    error ZeroNullifier();
    error AuthorizationRootZero();
    error ConfigurationHashMismatch(bytes32 supplied, bytes32 computed);
    error EmptyTokenName();
    error EmptyTokenSymbol();
    error TokenNameTooLong(uint256 length);
    error TokenSymbolTooLong(uint256 length);
    error MetadataNotContentAddressed();
    error MetadataTooLong(uint256 length);
    error ZeroTokenSupply();
    error ZeroCommitment();
    error CommitmentsNotDistinct();
    error InvalidAllocation(uint16 beneficiaryBps, uint16 liquidityBps, uint16 protocolBps);
    error InvalidLaunchKind();
    error CreationPaused();
    error BeneficiaryAlreadySet();
    error InviteMismatch();
    error AcceptanceMismatch();
    error AcceptanceTooSoon();
    error BeneficiaryLockActive();
    error CommitmentOutOfField();

    event AuthorizationRootUpdated(bytes32 root);
    event CreationPauseSet(bool paused);
    event FeeVaultUpdated(address feeVault);
    event LiquidityModuleUpdated(address liquidityModule);
    event TradeRouterUpdated(address tradeRouter);
    event BeneficiaryLocked(uint256 indexed campaignId, bytes32 acceptanceHash);
    event BeneficiaryAccepted(uint256 indexed campaignId, bytes32 beneficiaryCommitment);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function campaignCount() external view returns (uint256) {
        return _campaignCount;
    }

    function getCampaign(uint256 campaignId) external view returns (Campaign memory) {
        return _existing(campaignId);
    }

    function setAuthorizationRoot(bytes32 newRoot) external onlyRole(Roles.VERIFIER_ROLE) {
        if (newRoot == bytes32(0)) revert AuthorizationRootZero();
        authorizationRoot = newRoot;
        emit AuthorizationRootUpdated(newRoot);
    }

    function setCreationPaused(bool paused) external onlyRole(Roles.PAUSER_ROLE) {
        creationPaused = paused;
        emit CreationPauseSet(paused);
    }

    /// @notice Stops `donate` on every vault. It does not stop claims or `forwardProtocolFees`.
    function setDonationsPaused(bool paused) external onlyRole(Roles.PAUSER_ROLE) {
        donationsPaused = paused;
        emit DonationsPauseSet(paused);
    }

    /// @notice Address copied into vaults launched after this call. It does not move funds.
    function setFeeVault(address next) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeVault = next;
        emit FeeVaultUpdated(next);
    }

    /// @notice Address copied into vaults launched after this call. It does not move funds.
    function setLiquidityModule(address next) external onlyRole(DEFAULT_ADMIN_ROLE) {
        liquidityModule = next;
        emit LiquidityModuleUpdated(next);
    }

    /// @notice Address copied into tokens launched after this call. It does not move funds.
    function setTradeRouter(address next) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tradeRouter = next;
        emit TradeRouterUpdated(next);
    }

    function register(Campaign calldata campaign)
        external
        onlyRole(Roles.FACTORY_ROLE)
        returns (uint256 campaignId)
    {
        if (creationPaused) revert CreationPaused();
        _checkRecord(campaign);
        if (campaign.nullifier == bytes32(0)) revert ZeroNullifier();
        if (nullifierUsed[campaign.nullifier]) revert NullifierAlreadyUsed(campaign.nullifier);

        bytes32 computed = ConfigHash.digest(
            campaign.name,
            campaign.symbol,
            campaign.totalSupply,
            campaign.metadataURI,
            campaign.beneficiaryCommitment,
            campaign.feeReceiverCommitment,
            campaign.beneficiaryBps,
            campaign.liquidityBps,
            campaign.protocolBps,
            campaign.launchKind,
            campaign.creatorTaxBps,
            campaign.beneficiaryInviteHash
        );
        if (computed != campaign.configurationHash) {
            revert ConfigurationHashMismatch(campaign.configurationHash, computed);
        }

        nullifierUsed[campaign.nullifier] = true;
        campaignId = ++_campaignCount;

        Campaign storage stored = _campaigns[campaignId];
        stored.id = campaignId;
        stored.creatorCommitment = campaign.creatorCommitment;
        stored.beneficiaryCommitment = campaign.beneficiaryCommitment;
        stored.feeReceiverCommitment = campaign.feeReceiverCommitment;
        stored.configurationHash = campaign.configurationHash;
        stored.nullifier = campaign.nullifier;
        stored.campaignNonce = campaign.campaignNonce;
        stored.beneficiaryBps = campaign.beneficiaryBps;
        stored.liquidityBps = campaign.liquidityBps;
        stored.protocolBps = campaign.protocolBps;
        stored.status = CampaignStatus.Pending;
        stored.createdAt = block.timestamp;
        stored.name = campaign.name;
        stored.symbol = campaign.symbol;
        stored.totalSupply = campaign.totalSupply;
        stored.metadataURI = campaign.metadataURI;
        stored.launchKind = campaign.launchKind;
        stored.creatorTaxBps = campaign.creatorTaxBps;
        stored.beneficiaryInviteHash = campaign.beneficiaryInviteHash;

        emit CampaignRegistered(
            campaignId, campaign.nullifier, campaign.creatorCommitment, campaign.configurationHash
        );
    }

    function markVerified(uint256 campaignId) external onlyRole(Roles.VERIFIER_ROLE) {
        Campaign storage campaign = _existing(campaignId);
        if (campaign.status != CampaignStatus.Pending) {
            revert InvalidCampaignStatus(campaign.status, CampaignStatus.Verified);
        }
        campaign.status = CampaignStatus.Verified;
        emit CampaignVerified(campaignId);
    }

    function rejectPending(uint256 campaignId) external onlyRole(Roles.VERIFIER_ROLE) {
        Campaign storage campaign = _existing(campaignId);
        if (campaign.status != CampaignStatus.Pending) {
            revert InvalidCampaignStatus(campaign.status, CampaignStatus.Closed);
        }
        campaign.status = CampaignStatus.Closed;
        emit CampaignRejected(campaignId);
    }

    function markLaunched(uint256 campaignId, address token, address vault)
        external
        onlyRole(Roles.FACTORY_ROLE)
    {
        if (token == address(0) || vault == address(0)) revert ZeroAddress();
        Campaign storage campaign = _existing(campaignId);
        if (campaign.status != CampaignStatus.Verified && campaign.status != CampaignStatus.Pending) {
            revert InvalidCampaignStatus(campaign.status, CampaignStatus.Launched);
        }
        if (campaign.token != address(0) || campaign.vault != address(0)) revert TokenAlreadySet(campaignId);
        campaign.token = token;
        campaign.vault = vault;
        campaign.status = CampaignStatus.Launched;
        emit CampaignLaunched(campaignId, token, vault);
    }

    /// @dev The factory role can record the step. The vault's own liquidity module can too,
    ///      and only for the campaign whose vault points at that module.
    function markActive(uint256 campaignId) external {
        Campaign storage campaign = _existing(campaignId);
        if (campaign.status != CampaignStatus.Launched) {
            revert InvalidCampaignStatus(campaign.status, CampaignStatus.Active);
        }
        if (!hasRole(Roles.FACTORY_ROLE, msg.sender)) {
            address module = ICampaignVault(campaign.vault).liquidityModule();
            if (msg.sender != module) revert AccessControlUnauthorizedAccount(msg.sender, Roles.FACTORY_ROLE);
        }
        campaign.status = CampaignStatus.Active;
        emit CampaignActivated(campaignId);
    }

    /// @notice Stores the writer's hidden acceptance hash. One lock is active per campaign.
    /// @dev The hash is keccak256(abi.encode(inviteSecret, commitment)). A second wallet cannot replace
    ///      it until `BENEFICIARY_LOCK_TIMEOUT`. The invite secret is not an argument.
    function lockBeneficiary(uint256 campaignId, bytes32 acceptanceHash) external {
        Campaign storage campaign = _existing(campaignId);
        if (campaign.launchKind != LaunchKind.Campaign) revert InvalidLaunchKind();
        if (campaign.beneficiaryCommitment != bytes32(0) || campaign.beneficiaryInviteHash == bytes32(0)) {
            revert BeneficiaryAlreadySet();
        }
        if (acceptanceHash == bytes32(0)) revert ZeroCommitment();
        BeneficiaryLock storage lock = _beneficiaryLock[campaignId];
        if (lock.locker != address(0) && block.timestamp < uint256(lock.timestamp) + BENEFICIARY_LOCK_TIMEOUT) {
            revert BeneficiaryLockActive();
        }
        lock.locker = msg.sender;
        lock.hash = acceptanceHash;
        lock.blockNumber = uint64(block.number);
        lock.timestamp = uint64(block.timestamp);
        emit BeneficiaryLocked(campaignId, acceptanceHash);
    }

    /// @notice Sets the beneficiary commitment and ends the organizer's donation withdrawal.
    /// @dev `inviteSecret` is revealed here. Only the wallet that locked it can publish it, and only
    ///      in a later block, so a searcher cannot lock and accept inside the reveal transaction.
    function acceptBeneficiary(uint256 campaignId, bytes32 inviteSecret, bytes32 commitment) external {
        Campaign storage campaign = _existing(campaignId);
        if (campaign.beneficiaryCommitment != bytes32(0) || campaign.beneficiaryInviteHash == bytes32(0)) {
            revert BeneficiaryAlreadySet();
        }
        if (keccak256(abi.encode(inviteSecret)) != campaign.beneficiaryInviteHash) revert InviteMismatch();
        BeneficiaryLock storage lock = _beneficiaryLock[campaignId];
        if (lock.locker != msg.sender) revert AcceptanceMismatch();
        if (lock.blockNumber == 0 || lock.blockNumber >= block.number) revert AcceptanceTooSoon();
        if (lock.hash != keccak256(abi.encode(inviteSecret, commitment))) revert AcceptanceMismatch();
        if (commitment == bytes32(0)) revert ZeroCommitment();
        if (uint256(commitment) >= CreatorAuthLayout.BN254_SCALAR_FIELD) revert CommitmentOutOfField();
        if (commitment == campaign.creatorCommitment || commitment == campaign.feeReceiverCommitment) {
            revert CommitmentsNotDistinct();
        }
        campaign.beneficiaryCommitment = commitment;
        delete _beneficiaryLock[campaignId];
        emit BeneficiaryAccepted(campaignId, commitment);
    }

    function close(uint256 campaignId) external onlyRole(Roles.VERIFIER_ROLE) {
        Campaign storage campaign = _existing(campaignId);
        if (campaign.status != CampaignStatus.Launched && campaign.status != CampaignStatus.Active) {
            revert InvalidCampaignStatus(campaign.status, CampaignStatus.Closed);
        }
        campaign.status = CampaignStatus.Closed;
        emit CampaignClosed(campaignId);
    }

    function _existing(uint256 campaignId) private view returns (Campaign storage campaign) {
        if (campaignId == 0 || campaignId > _campaignCount) revert CampaignNotFound(campaignId);
        return _campaigns[campaignId];
    }

    function _checkRecord(Campaign calldata campaign) private pure {
        uint256 nameLength = bytes(campaign.name).length;
        uint256 symbolLength = bytes(campaign.symbol).length;
        if (nameLength == 0) revert EmptyTokenName();
        if (nameLength > ConfigHash.NAME_MAX_BYTES) revert TokenNameTooLong(nameLength);
        if (symbolLength == 0) revert EmptyTokenSymbol();
        if (symbolLength > ConfigHash.SYMBOL_MAX_BYTES) revert TokenSymbolTooLong(symbolLength);
        if (campaign.totalSupply == 0) revert ZeroTokenSupply();
        uint256 metadataLength = bytes(campaign.metadataURI).length;
        if (metadataLength > ConfigHash.METADATA_MAX_BYTES) revert MetadataTooLong(metadataLength);
        if (!_contentAddressed(campaign.metadataURI)) revert MetadataNotContentAddressed();
        if (campaign.creatorCommitment == bytes32(0) || campaign.feeReceiverCommitment == bytes32(0)) {
            revert ZeroCommitment();
        }
        if (campaign.creatorCommitment == campaign.feeReceiverCommitment) revert CommitmentsNotDistinct();
        if (campaign.launchKind == LaunchKind.Campaign && campaign.beneficiaryCommitment == bytes32(0)) {
            if (campaign.beneficiaryInviteHash == bytes32(0)) revert ZeroCommitment();
        } else {
            if (campaign.beneficiaryCommitment == bytes32(0) || campaign.beneficiaryInviteHash != bytes32(0)) {
                revert ZeroCommitment();
            }
            if (
                campaign.creatorCommitment == campaign.beneficiaryCommitment
                    || campaign.beneficiaryCommitment == campaign.feeReceiverCommitment
            ) revert CommitmentsNotDistinct();
        }
        if (campaign.launchKind != LaunchKind.Campaign && campaign.launchKind != LaunchKind.Standard) {
            revert InvalidLaunchKind();
        }
        if (
            !LaunchRules.valid(
                campaign.launchKind, campaign.beneficiaryBps, campaign.liquidityBps, campaign.protocolBps, campaign.creatorTaxBps
            )
        ) {
            revert InvalidAllocation(campaign.beneficiaryBps, campaign.liquidityBps, campaign.protocolBps);
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
