// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ClaimLayout} from "../types/CauseLaunchTypes.sol";
import {IVerifier} from "./honk/ClaimHonkVerifier.sol";

/// @notice Checks the private-claim public-input shape, then calls the generated UltraHonk verifier.
/// @dev A failed proof reverts inside the generated verifier. This contract does not return true
///      without that call. It does not store nullifiers or compare a commitment with campaign
///      storage. The vault and the fee vault do that before calling here.
contract ClaimVerifier {
    uint256 internal constant BN254_SCALAR_FIELD = ClaimLayout.BN254_SCALAR_FIELD;

    IVerifier public immutable honk;

    error ZeroAddress();
    error PublicInputLengthMismatch(uint256 expected, uint256 actual);
    error PublicInputOutOfField();
    error ProofVersionMismatch(uint256 expected, uint256 actual);
    error ClaimRoleInvalid(uint256 role);
    error RecipientOutOfRange();
    error ZeroAmount();
    error ZeroCampaign();

    constructor(IVerifier honkVerifier) {
        if (address(honkVerifier) == address(0)) revert ZeroAddress();
        honk = honkVerifier;
    }

    /// @notice Returns true when `proof` is a valid private-claim UltraHonk proof for `publicInputs`.
    /// @param publicInputs Seven field elements in `ClaimLayout` order.
    function verifyClaim(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool) {
        if (publicInputs.length != ClaimLayout.PUBLIC_INPUT_COUNT) {
            revert PublicInputLengthMismatch(ClaimLayout.PUBLIC_INPUT_COUNT, publicInputs.length);
        }
        for (uint256 i = 0; i < publicInputs.length; ++i) {
            if (uint256(publicInputs[i]) >= BN254_SCALAR_FIELD) revert PublicInputOutOfField();
        }
        if (uint256(publicInputs[ClaimLayout.INDEX_PROOF_VERSION]) != ClaimLayout.PROOF_VERSION) {
            revert ProofVersionMismatch(
                ClaimLayout.PROOF_VERSION, uint256(publicInputs[ClaimLayout.INDEX_PROOF_VERSION])
            );
        }
        uint256 role = uint256(publicInputs[ClaimLayout.INDEX_ROLE]);
        if (
            role != ClaimLayout.BENEFICIARY_ROLE && role != ClaimLayout.FEE_RECEIVER_ROLE
                && role != ClaimLayout.CREATOR_ROLE
        ) {
            revert ClaimRoleInvalid(role);
        }
        if (uint256(publicInputs[ClaimLayout.INDEX_RECIPIENT]) >= (1 << ClaimLayout.ADDRESS_BITS)) {
            revert RecipientOutOfRange();
        }
        if (uint256(publicInputs[ClaimLayout.INDEX_AMOUNT]) == 0) revert ZeroAmount();
        if (uint256(publicInputs[ClaimLayout.INDEX_CAMPAIGN_ID]) == 0) revert ZeroCampaign();
        return honk.verify(proof, publicInputs);
    }
}
