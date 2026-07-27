// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfig, DeployConfigFile} from "./lib/DeployConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";
import {VaultV2Config, VaultV2AdapterConfig, VaultV2ConfigFile} from "./lib/VaultV2ConfigFile.sol";

/// @notice Deploys an external vault-v2 vault together with its Morpho adapter over this run's protocol, and
///         records them as `vaults/<vaultName>.toml` + `adapters/<adapterName>.toml`.
/// @dev One operation, two artifacts: the adapter's parent vault is a constructor immutable, so the pair must
///      be created together. Both are left UNCONFIGURED — no curator, no registered adapter, no caps: those
///      are the vault owner's calls, not deployment inputs.
///
///      Both contracts pin solc 0.8.28 while this repo is on 0.8.35, so they are deployed from their `out/`
///      artifacts via `vm.deployCode` rather than `new`. `test/utils/_VaultV2CompileTriggers.sol` is what makes
///      forge emit those artifacts.
contract DeployVaultV2 is Script {
    error DeployFailed(string what);

    /// @param config The deploy config name (`script/config/<config>.toml`).
    /// @param vaultName The `vaults/<vaultName>.toml` config and artifact name.
    /// @param adapterName The `adapters/<adapterName>.toml` config and artifact name.
    function run(string memory config, string memory vaultName, string memory adapterName)
        external
        returns (address vault, address adapter)
    {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);

        VaultV2Config memory vaultCfg = VaultV2ConfigFile.readVault(vaultName);
        VaultV2AdapterConfig memory adapterCfg = VaultV2ConfigFile.readAdapter(adapterName);
        VaultV2ConfigFile.requireVaultArtifact(adapterCfg, vaultName);
        VaultV2ConfigFile.requireUndeployed(vaultName, adapterName);

        // The adapter's `morpho` / `adaptiveCurveIrm` immutables are this run's backbone, never config inputs.
        string memory protocol = vm.readFile(ProtocolConfigFile.protocolPath());
        address core = vm.parseTomlAddress(protocol, ".protocol.core");
        address irmRouter = vm.parseTomlAddress(protocol, ".protocol.irm_router");

        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: ArtifactMetadataFile.deployment(),
            chainId: deployConfig.chainId,
            configHash: deployConfig.configHash
        });

        vm.startBroadcast();
        vault = vm.deployCode("VaultV2.sol:VaultV2", abi.encode(vaultCfg.owner, vaultCfg.asset));
        adapter =
            vm.deployCode("MorphoMarketV1AdapterV2.sol:MorphoMarketV1AdapterV2", abi.encode(vault, core, irmRouter));
        vm.stopBroadcast();

        if (vault.code.length == 0) revert DeployFailed("VaultV2");
        if (adapter.code.length == 0) revert DeployFailed("MorphoMarketV1AdapterV2");

        console2.log("vaultV2 :", vaultName);
        console2.log("  address   :", vault);
        console2.log("  owner     :", vaultCfg.owner);
        console2.log("  asset     :", vaultCfg.asset);
        console2.log("  recorded  :", VaultV2ConfigFile.writeVault(vaultName, vault, vaultCfg, metadata));
        console2.log("adapter :", adapterName);
        console2.log("  address   :", adapter);
        console2.log("  morpho    :", core);
        console2.log("  irmRouter :", irmRouter);
        console2.log(
            "  recorded  :",
            VaultV2ConfigFile.writeAdapter(adapterName, adapter, vaultName, vault, core, irmRouter, metadata)
        );
    }
}
