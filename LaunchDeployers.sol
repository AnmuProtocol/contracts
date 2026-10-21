// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {CampaignVault} from "./CampaignVault.sol";
import {CauseToken} from "./CauseToken.sol";

/// @notice Deploys campaign vaults. The factory is the only caller.
/// @dev The vault creation code lives here so the factory stays within the deployment size limit.
contract VaultDeployer {
    address public factory;

    error FactoryAlreadySet();
    error NotFactory(address caller);

    function setFactory(address next) external {
        if (factory != address(0)) revert FactoryAlreadySet();
        if (next == address(0)) revert NotFactory(next);
        factory = next;
    }

    function predict(
        bytes32 salt,
        uint256 campaignId,
        address registry,
        address feeVault,
        address liquidityModule,
        address claimVerifier
    ) external view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(
            type(CampaignVault).creationCode,
            abi.encode(campaignId, registry, feeVault, liquidityModule, claimVerifier)
        ));
        return Create2.computeAddress(salt, hash, address(this));
    }

    function deploy(
        bytes32 salt,
        uint256 campaignId,
        address registry,
        address feeVault,
        address liquidityModule,
        address claimVerifier
    ) external returns (address) {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        return address(new CampaignVault{salt: salt}(
            campaignId, registry, feeVault, liquidityModule, claimVerifier
        ));
    }
}

/// @notice Deploys campaign tokens. The factory is the only caller.
contract TokenDeployer {
    address public factory;

    error FactoryAlreadySet();
    error NotFactory(address caller);

    function setFactory(address next) external {
        if (factory != address(0)) revert FactoryAlreadySet();
        if (next == address(0)) revert NotFactory(next);
        factory = next;
    }

    function deploy(
        bytes32 salt,
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        address vault,
        address liquidityModule,
        address tradeRouter
    ) external returns (address) {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        return address(new CauseToken{salt: salt}(
            name, symbol, totalSupply, vault, liquidityModule, tradeRouter
        ));
    }
}
