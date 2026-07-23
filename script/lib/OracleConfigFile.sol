// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ConfigToml} from "./ConfigToml.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

struct WstEthOracleConfig {
    address wstETH;
    address proxyAdmin;
}

struct UsdyOracleConfig {
    address usdyOracle;
    address feed;
    address loanToken;
    address collateralToken;
    address proxyAdmin;
}

library OracleConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error ArtifactAlreadyExists(string path);

    function readRaw(string memory name) internal view returns (string memory) {
        return vm.readFile(configPath(name));
    }

    function hasKey(string memory toml, string memory key) internal view returns (bool) {
        return vm.keyExistsToml(toml, key);
    }

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
        cfg.collateralToken = ConfigToml.requireAddress(toml, ".collateral_token");
        cfg.proxyAdmin = ConfigToml.requireAddress(toml, ".proxy_admin");
    }

    function configPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/oracles/", name, ".toml");
    }

    function writeDeployed(string memory name, address oracle, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        ArtifactMetadataFile.ensureArtifactsDir();
        path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
        string memory artifact = ArtifactMetadataFile.header(metadata, "oracle");
        artifact = string.concat(artifact, "\n[oracle]\n");
        artifact = string.concat(artifact, "config = \"", name, "\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(oracle), "\"\n");
        vm.writeFile(path, artifact);
    }

    function requireUndeployed(string memory name) internal view {
        string memory path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }

    function readDeployed(string memory name) internal view returns (address) {
        string memory path = deployedPath(name);
        if (!vm.exists(path)) return address(0);
        return vm.parseTomlAddress(vm.readFile(path), ".oracle.address");
    }

    function deployedPath(string memory name) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/oracle-", name, ".toml");
    }
}
