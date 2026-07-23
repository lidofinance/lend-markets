// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ConfigToml} from "./ConfigToml.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

/// @notice Governance inputs for one market's `GuardianSignals` registry, read from
///         `script/config/guardians/<name>.toml`.
struct GuardianSignalsConfig {
    address admin; // Agent — final DEFAULT_ADMIN_ROLE
    address proxyAdmin; // OssifiableProxy admin (upgrade authority)
    address evmScriptExecutor; // EasyTrack executor — MANAGER_ROLE + ACCESS_RESTORER_ROLE
    uint256 quorum;
    uint256 suspectWindow;
    address[] guardians;
    address accessLimiter; // risk-steward committee — ACCESS_LIMITER_ROLE (`ban`); zero = leave for the DAO
}

/// @notice Reads a `GuardianSignals` config, and records / resolves a deployed instance's address.
library GuardianSignalsConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactAlreadyExists(string path);
    error ArtifactConfigMismatch(string expected, string actual);

    function read(string memory name) internal view returns (GuardianSignalsConfig memory) {
        return parse(vm.readFile(configPath(name)));
    }

    function parse(string memory toml) internal view returns (GuardianSignalsConfig memory cfg) {
        cfg.admin = ConfigToml.requireAddress(toml, ".admin");
        cfg.proxyAdmin = ConfigToml.requireAddress(toml, ".proxy_admin");
        cfg.evmScriptExecutor = ConfigToml.requireAddress(toml, ".evm_script_executor");
        cfg.quorum = vm.parseTomlUint(toml, ".quorum");
        cfg.suspectWindow = vm.parseTomlUint(toml, ".suspect_window");
        cfg.guardians = vm.parseTomlAddressArray(toml, ".guardians");
        // Optional key: absent or zero → the `ban` role is left for the DAO to grant post-deploy.
        cfg.accessLimiter =
            vm.keyExistsToml(toml, ".access_limiter") ? vm.parseTomlAddress(toml, ".access_limiter") : address(0);
    }

    function configPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/guardians/", name, ".toml");
    }

    /// @notice Record a deployed shared instance's address so `MarketConfigFile.read` resolves it for a market
    ///         whose `guardian_signals` is left zero.
    function writeDeployed(string memory name, address guardianSignals, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        ArtifactMetadataFile.ensureArtifactsDir();
        path = deployedPath(name, metadata);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
        string memory artifact = ArtifactMetadataFile.header(metadata, "guardian-signals");
        artifact = string.concat(artifact, "\n[guardian_signals]\n");
        artifact = string.concat(artifact, "config = \"", name, "\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(guardianSignals), "\"\n");
        vm.writeFile(path, artifact);
    }

    /// @notice Revert before broadcasting when this output directory already carries the guardian record.
    function requireUndeployed(string memory name, ArtifactMetadata memory metadata) internal view {
        string memory path = deployedPath(name, metadata);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }

    /// @notice The recorded address for `name`, or zero if none was written (caller deploys a fresh instance).
    function readDeployed(string memory name, ArtifactMetadata memory expected) internal view returns (address) {
        string memory path = deployedPath(name, expected);
        if (!vm.exists(path)) return address(0);
        string memory artifact = vm.readFile(path);
        ArtifactMetadataFile.requireMatch(artifact, expected, "guardian-signals");
        string memory actualConfig = vm.parseTomlString(artifact, ".guardian_signals.config");
        if (keccak256(bytes(actualConfig)) != keccak256(bytes(name))) {
            revert ArtifactConfigMismatch(name, actualConfig);
        }
        return vm.parseTomlAddress(artifact, ".guardian_signals.address");
    }

    function deployedPath(string memory name, ArtifactMetadata memory) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/guardian-", name, ".toml");
    }
}
