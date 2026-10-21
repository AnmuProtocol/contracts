// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LaunchKind} from "../types/CauseLaunchTypes.sol";

/// @notice Canonical campaign configuration digest shared by the factory and the registry.
/// @dev Domain 2 includes the launch kind and the creator tax. A proof bound to domain 1
///      cannot register either product.
library ConfigHash {
    uint256 internal constant NAME_MAX_BYTES = 64;
    uint256 internal constant SYMBOL_MAX_BYTES = 32;
    uint256 internal constant METADATA_MAX_BYTES = 128;
    uint256 internal constant DOMAIN = 2;

    function digest(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        string memory metadataURI,
        bytes32 beneficiaryCommitment,
        bytes32 feeReceiverCommitment,
        uint16 beneficiaryBps,
        uint16 liquidityBps,
        uint16 protocolBps,
        LaunchKind launchKind,
        uint16 creatorTaxBps
    ) internal pure returns (bytes32) {
        return digest(
            name,
            symbol,
            totalSupply,
            metadataURI,
            beneficiaryCommitment,
            feeReceiverCommitment,
            beneficiaryBps,
            liquidityBps,
            protocolBps,
            launchKind,
            creatorTaxBps,
            bytes32(0)
        );
    }

    /// @dev `beneficiaryInviteHash` is bound here so a relayer cannot swap the invite.
    ///      A zero hash means the beneficiary commitment was already set.
    function digest(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        string memory metadataURI,
        bytes32 beneficiaryCommitment,
        bytes32 feeReceiverCommitment,
        uint16 beneficiaryBps,
        uint16 liquidityBps,
        uint16 protocolBps,
        LaunchKind launchKind,
        uint16 creatorTaxBps,
        bytes32 beneficiaryInviteHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN,
                name,
                symbol,
                totalSupply,
                metadataURI,
                beneficiaryCommitment,
                feeReceiverCommitment,
                beneficiaryBps,
                liquidityBps,
                protocolBps,
                launchKind,
                creatorTaxBps,
                beneficiaryInviteHash
            )
        );
    }

    /// @notice High and low 128-bit limbs. A keccak256 digest fits without reduction.
    function split(bytes32 configurationHash) internal pure returns (bytes32 hi, bytes32 lo) {
        uint256 value = uint256(configurationHash);
        hi = bytes32(value >> 128);
        lo = bytes32(value & ((1 << 128) - 1));
    }
}
