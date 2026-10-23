// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.34 <0.9.0;

import {Vm} from "forge-std/Vm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";
import {ConfigToml} from "./ConfigToml.sol";
import {DeployConfigFile} from "./DeployConfigFile.sol";

/// @param weth The WETH the general adapter wraps and unwraps.
/// @param wsteth The wstETH the general adapter wraps stETH into; its `stETH()` is the adapter's stETH.
struct BundlerConfig {
    address weth;
    address wsteth;
}

/// @notice Config and run artifact for a run's own bundler stack: the stock Bundler3 dispatcher, the vendored
///         general adapter (bound to the core) and the Lido vault adapter (both bound to that Bundler3). One
///         dispatcher per run, one adapter each — so the artifact is run-level (`bundler.toml`), like
///         `exit-books.toml`, not a per-market resource.
library BundlerConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactAlreadyExists(string path);

    // ---
    // CONFIG
    // ---

    /// @notice The bundler config of deployment `config`: one stack per deployment, so the file carries no name.
    function read(string memory config) internal view returns (BundlerConfig memory cfg) {
        return parse(vm.readFile(configPath(config)));
    }

    function parse(string memory toml) internal pure returns (BundlerConfig memory cfg) {
        cfg.weth = ConfigToml.requireAddress(toml, ".weth");
        cfg.wsteth = ConfigToml.requireAddress(toml, ".wsteth");
    }

    function configPath(string memory config) internal pure returns (string memory) {
        return string.concat(DeployConfigFile.configDir(config), "/bundler.toml");
    }

    // ---
    // ARTIFACT
    // ---

    /// @param bundler3 The dispatcher this run deployed, which both adapters froze.
    /// @param core The general adapter's `MORPHO` immutable: the run's core.
    function write(
        string memory name,
        BundlerConfig memory cfg,
        address bundler3,
        address generalAdapter,
        address vaultAdapter,
        address core,
        uint256 deployedBlock,
        ArtifactMetadata memory metadata
    ) internal returns (string memory path) {
        ArtifactMetadataFile.ensureArtifactsDir();
        path = deployedPath();
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);

        string memory artifact = ArtifactMetadataFile.header(metadata, "bundler3-adapters");
        artifact = string.concat(artifact, "\n[bundler]\n");
        artifact = string.concat(artifact, "name = \"", name, "\"\n");
        artifact = string.concat(artifact, "bundler3 = \"", vm.toString(bundler3), "\"\n");
        artifact = string.concat(artifact, "general_adapter = \"", vm.toString(generalAdapter), "\"\n");
        artifact = string.concat(artifact, "vault_adapter = \"", vm.toString(vaultAdapter), "\"\n");
        artifact = string.concat(artifact, "morpho = \"", vm.toString(core), "\"\n");
        artifact = string.concat(artifact, "weth = \"", vm.toString(cfg.weth), "\"\n");
        artifact = string.concat(artifact, "wsteth = \"", vm.toString(cfg.wsteth), "\"\n");
        artifact = string.concat(artifact, "deployed_block = ", vm.toString(deployedBlock), "\n");
        vm.writeFile(path, artifact);
    }

    function requireUndeployed() internal view {
        string memory path = deployedPath();
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }

    function deployedPath() internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/bundler.toml");
    }
}
