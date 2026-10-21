// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ClaimLayout} from "../types/CauseLaunchTypes.sol";

/// @notice Binds a private-claim proof's public inputs to the payment the contract will make.
/// @dev This does not verify the proof. Call it before verification so a substituted
///      recipient, amount, campaign, role, or commitment never reaches the prover check
///      and never consumes a nullifier.
library ClaimBinding {
    error PublicInputLengthMismatch(uint256 expected, uint256 actual);
    error PublicInputOutOfField();
    error ProofVersionMismatch(uint256 expected, uint256 actual);
    error RoleMismatch(uint256 expected, uint256 actual);
    error CommitmentMismatch(bytes32 expected, bytes32 actual);
    error CampaignMismatch(uint256 expected, uint256 actual);
    error AmountMismatch(uint256 expected, uint256 actual);
    error RecipientMismatch(address expected, uint256 claimed);

    function bind(
        bytes32[] calldata publicInputs,
        uint256 role,
        bytes32 commitment,
        uint256 campaignId,
        address recipient,
        uint256 amount
    ) internal pure {
        if (publicInputs.length != ClaimLayout.PUBLIC_INPUT_COUNT) {
            revert PublicInputLengthMismatch(ClaimLayout.PUBLIC_INPUT_COUNT, publicInputs.length);
        }
        uint256 field = ClaimLayout.BN254_SCALAR_FIELD;
        for (uint256 i = 0; i < publicInputs.length; ++i) {
            if (uint256(publicInputs[i]) >= field) revert PublicInputOutOfField();
        }
        if (uint256(publicInputs[ClaimLayout.INDEX_PROOF_VERSION]) != ClaimLayout.PROOF_VERSION) {
            revert ProofVersionMismatch(
                ClaimLayout.PROOF_VERSION, uint256(publicInputs[ClaimLayout.INDEX_PROOF_VERSION])
            );
        }
        if (uint256(publicInputs[ClaimLayout.INDEX_ROLE]) != role) {
            revert RoleMismatch(role, uint256(publicInputs[ClaimLayout.INDEX_ROLE]));
        }
        if (publicInputs[ClaimLayout.INDEX_COMMITMENT] != commitment) {
            revert CommitmentMismatch(commitment, publicInputs[ClaimLayout.INDEX_COMMITMENT]);
        }
        if (uint256(publicInputs[ClaimLayout.INDEX_CAMPAIGN_ID]) != campaignId) {
            revert CampaignMismatch(campaignId, uint256(publicInputs[ClaimLayout.INDEX_CAMPAIGN_ID]));
        }
        if (uint256(publicInputs[ClaimLayout.INDEX_AMOUNT]) != amount) {
            revert AmountMismatch(amount, uint256(publicInputs[ClaimLayout.INDEX_AMOUNT]));
        }
        uint256 claimedRecipient = uint256(publicInputs[ClaimLayout.INDEX_RECIPIENT]);
        if (claimedRecipient >= (1 << ClaimLayout.ADDRESS_BITS) || claimedRecipient != uint256(uint160(recipient))) {
            revert RecipientMismatch(recipient, claimedRecipient);
        }
    }
}
