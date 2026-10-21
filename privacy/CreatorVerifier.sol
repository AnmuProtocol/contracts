// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CreatorAuthLayout} from "../types/CauseLaunchTypes.sol";
import {IVerifier} from "./honk/CreatorAuthHonkVerifier.sol";

/// @notice Checks the creator-auth public-input shape, then calls the generated UltraHonk verifier.
/// @dev A failed proof reverts inside the generated verifier. This contract does not return true
///      without that call. It does not store nullifiers, check the issuer root, or hash campaign
///      configuration. Those checks belong to the factory and the registry.
contract CreatorVerifier {
    /// @dev BN254 scalar field order. Same modulus as `MODULUS` in the generated verifier.
    uint256 internal constant BN254_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    IVerifier public immutable honk;

    error ZeroAddress();
    error PublicInputLengthMismatch(uint256 expected, uint256 actual);
    error PublicInputOutOfField();
    error ConfigurationLimbOutOfRange();
    error ProofVersionMismatch(uint256 expected, uint256 actual);

    constructor(IVerifier honkVerifier) {
        if (address(honkVerifier) == address(0)) revert ZeroAddress();
        honk = honkVerifier;
    }

    /// @notice Returns true when `proof` is a valid creator-auth UltraHonk proof for `publicInputs`.
    /// @param publicInputs Seven field elements in `CreatorAuthLayout` order.
    function verifyCreatorAuthorization(bytes calldata proof, bytes32[] calldata publicInputs)
        external
        view
        returns (bool)
    {
        if (publicInputs.length != CreatorAuthLayout.PUBLIC_INPUT_COUNT) {
            revert PublicInputLengthMismatch(CreatorAuthLayout.PUBLIC_INPUT_COUNT, publicInputs.length);
        }

        for (uint256 i = 0; i < publicInputs.length; ++i) {
            if (uint256(publicInputs[i]) >= BN254_SCALAR_FIELD) revert PublicInputOutOfField();
        }

        uint256 limbBound = 1 << CreatorAuthLayout.LIMB_BITS;
        if (uint256(publicInputs[CreatorAuthLayout.INDEX_CONFIGURATION_HASH_HI]) >= limbBound) {
            revert ConfigurationLimbOutOfRange();
        }
        if (uint256(publicInputs[CreatorAuthLayout.INDEX_CONFIGURATION_HASH_LO]) >= limbBound) {
            revert ConfigurationLimbOutOfRange();
        }
        if (uint256(publicInputs[CreatorAuthLayout.INDEX_PROOF_VERSION]) != CreatorAuthLayout.PROOF_VERSION) {
            revert ProofVersionMismatch(
                CreatorAuthLayout.PROOF_VERSION, uint256(publicInputs[CreatorAuthLayout.INDEX_PROOF_VERSION])
            );
        }

        return honk.verify(proof, publicInputs);
    }
}
