// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Campaign lifecycle. Transitions are one-way and are specified in ICampaignRegistry.
enum CampaignStatus {
    None,
    Pending,
    Verified,
    Launched,
    Active,
    Closed
}

/// @notice Which product a launch is. The value is bound into the configuration digest.
enum LaunchKind {
    None,
    Campaign,
    Standard
}

/// @notice Public campaign record.
/// @dev There is no creator, beneficiary, or fee-receiver address field.
///      `vault` and `token` are protocol contracts. `campaignNonce` and `nullifier`
///      are public replay-protection values, not identities.
///      Name, symbol, supply, and metadata are stored so a permissionless launch can
///      rebuild the token. They are bound by `configurationHash` and are not identities.
struct Campaign {
    uint256 id;
    address token;
    address vault;
    bytes32 creatorCommitment;
    bytes32 beneficiaryCommitment;
    bytes32 feeReceiverCommitment;
    bytes32 configurationHash;
    bytes32 nullifier;
    uint256 campaignNonce;
    uint16 beneficiaryBps;
    uint16 liquidityBps;
    uint16 protocolBps;
    CampaignStatus status;
    uint256 createdAt;
    string name;
    string symbol;
    uint256 totalSupply;
    string metadataURI;
    LaunchKind launchKind;
    uint16 creatorTaxBps;
    /// @dev keccak256(abi.encode(inviteSecret)). It stays after acceptance so the
    ///      configuration digest does not change. Zero when the beneficiary was set at creation.
    bytes32 beneficiaryInviteHash;
}

/// @notice Public inputs to registration. The factory derives `configurationHash`.
/// @dev The caller does not supply a creator address or a precomputed configuration hash.
///      Beneficiary and fee-receiver commitments are Pedersen field elements from
///      zk/private_claim, as specified in docs/zk-design.md.
struct CampaignConfig {
    string name;
    string symbol;
    uint256 totalSupply;
    string metadataURI;
    bytes32 beneficiaryCommitment;
    bytes32 feeReceiverCommitment;
    uint16 beneficiaryBps;
    uint16 liquidityBps;
    uint16 protocolBps;
    LaunchKind launchKind;
    uint16 creatorTaxBps;
    /// @dev Hash of the invite secret. A campaign can leave `beneficiaryCommitment` at zero
    ///      and set this instead. The writer later submits only their commitment.
    bytes32 beneficiaryInviteHash;
}

/// @notice Accounted BNB buckets. Their sum equals credited donations.
struct VaultAccounting {
    uint256 beneficiaryBalance;
    uint256 liquidityBalance;
    uint256 protocolBalance;
    uint256 totalReceived;
    uint256 totalWithdrawn;
}

/// @dev OpenZeppelin AccessControl uses bytes32(0) for the default admin role.
library Roles {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);
    bytes32 internal constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
}

library Allocations {
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    uint16 internal constant CAMPAIGN_BENEFICIARY_BPS = 10_000;
    uint16 internal constant CAMPAIGN_LIQUIDITY_BPS = 0;
    uint16 internal constant CAMPAIGN_PROTOCOL_BPS = 0;
    uint16 internal constant CAMPAIGN_CREATOR_TRADE_BPS = 50;
    uint16 internal constant CAMPAIGN_LIQUIDITY_TRADE_BPS = 50;
    uint16 internal constant STANDARD_CREATOR_TRADE_BPS = 70;
    uint16 internal constant STANDARD_PLATFORM_TRADE_BPS = 30;
}

/// @notice Canonical public-input layout for zk/creator_auth proof version 1.
/// @dev Index order matches the `pub` parameters of `main` in zk/creator_auth/src/main.nr.
library CreatorAuthLayout {
    uint256 internal constant PROOF_VERSION = 1;
    uint256 internal constant PUBLIC_INPUT_COUNT = 7;
    uint256 internal constant MERKLE_DEPTH = 16;
    uint256 internal constant LIMB_BITS = 128;
    uint256 internal constant INDEX_CREATOR_COMMITMENT = 0;
    uint256 internal constant INDEX_CONFIGURATION_HASH_HI = 1;
    uint256 internal constant INDEX_CONFIGURATION_HASH_LO = 2;
    uint256 internal constant INDEX_CAMPAIGN_NONCE = 3;
    uint256 internal constant INDEX_PROOF_VERSION = 4;
    uint256 internal constant INDEX_NULLIFIER = 5;
    uint256 internal constant INDEX_AUTHORIZATION_ROOT = 6;

    /// @dev BN254 scalar field order.
    uint256 internal constant BN254_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;
}

/// @notice Public-input layout for zk/private_claim proof version 1.
/// @dev Index order matches the `pub` parameters of `main` in zk/private_claim/src/main.nr.
library ClaimLayout {
    uint256 internal constant PROOF_VERSION = 1;
    uint256 internal constant PUBLIC_INPUT_COUNT = 7;
    uint256 internal constant BENEFICIARY_ROLE = 1;
    uint256 internal constant FEE_RECEIVER_ROLE = 2;
    /// @dev Opens the creator commitment from separator 1. The generated verifier must
    ///      be rebuilt from zk/private_claim after this role is added to the circuit.
    uint256 internal constant CREATOR_ROLE = 3;
    uint256 internal constant ADDRESS_BITS = 160;
    uint256 internal constant INDEX_COMMITMENT = 0;
    uint256 internal constant INDEX_CAMPAIGN_ID = 1;
    uint256 internal constant INDEX_RECIPIENT = 2;
    uint256 internal constant INDEX_AMOUNT = 3;
    uint256 internal constant INDEX_NULLIFIER = 4;
    uint256 internal constant INDEX_PROOF_VERSION = 5;
    uint256 internal constant INDEX_ROLE = 6;

    /// @dev BN254 scalar field order. Same modulus as creator authorization.
    uint256 internal constant BN254_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;
}
