// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ConfigToml} from "./ConfigToml.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

/// @notice Deploy inputs for a `WstEthRateOracle` (config in immutables, no initialize).
struct WstEthOracleConfig {
    address wstETH; // underlying wstETH the rate is read from
    address proxyAdmin; // `OssifiableProxy` admin
}

/// @notice Deploy inputs for a `UsdyStableOracle` (proxy + `initialize(feed, loanToken)`).
struct UsdyOracleConfig {
    address usdyOracle; // USDY price source (constructor)
    address feed; // Chainlink aggregator (initialize)
    address loanToken; // market's loan token, its decimals bake into the price (initialize)
    address proxyAdmin; // `OssifiableProxy` admin
}

/// @notice Reads an oracle deploy config from `script/config/oracles/<name>.toml` (one reader per oracle
///         type), and records / resolves a deployed oracle's address.
library OracleConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactAlreadyExists(string path);
    error ArtifactConfigMismatch(string expected, string actual);

    function readWstEth(string memory name) internal view returns (WstEthOracleConfig memory cfg) {
        string memory toml = vm.readFile(configPath(name));
        cfg.wstETH = ConfigToml.requireAddress(toml, ".wsteth");
        cfg.proxyAdmin = ConfigToml.requireAddress(toml, ".proxy_admin");
    }

    function readUsdy(string memory name) internal view returns (UsdyOracleConfig memory cfg) {
        string memory toml = vm.readFile(configPath(name));
        cfg.usdyOracle = ConfigToml.requireAddress(toml, ".usdy_oracle");
        cfg.feed = ConfigToml.requireAddress(toml, ".feed");
        cfg.loanToken = ConfigToml.requireAddress(toml, ".loan_token");
        cfg.proxyAdmin = ConfigToml.requireAddress(toml, ".proxy_admin");
    }

    function configPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/oracles/", name, ".toml");
    }

    /// @notice Record a deployed oracle's address so a market with `[market].oracle` zero resolves it.
    function writeDeployed(string memory name, address oracle, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        ArtifactMetadataFile.ensureArtifactsDir();
        path = deployedPath(name, metadata);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
        string memory artifact = ArtifactMetadataFile.header(metadata, "oracle");
        artifact = string.concat(artifact, "\n[oracle]\n");
        artifact = string.concat(artifact, "config = \"", name, "\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(oracle), "\"\n");
        vm.writeFile(path, artifact);
    }

    /// @notice Revert before broadcasting when this output directory already carries the oracle record.
    function requireUndeployed(string memory name, ArtifactMetadata memory metadata) internal view {
        string memory path = deployedPath(name, metadata);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }

    /// @notice The recorded oracle address for `name`, or zero if no artifact was written yet.
    function readDeployed(string memory name, ArtifactMetadata memory expected) internal view returns (address) {
        string memory path = deployedPath(name, expected);
        if (!vm.exists(path)) return address(0);
        string memory artifact = vm.readFile(path);
        ArtifactMetadataFile.requireMatch(artifact, expected, "oracle");
        string memory actualConfig = vm.parseTomlString(artifact, ".oracle.config");
        if (keccak256(bytes(actualConfig)) != keccak256(bytes(name))) {
            revert ArtifactConfigMismatch(name, actualConfig);
        }
        return vm.parseTomlAddress(artifact, ".oracle.address");
    }

    function deployedPath(string memory name, ArtifactMetadata memory) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/oracle-", name, ".toml");
    }
}
