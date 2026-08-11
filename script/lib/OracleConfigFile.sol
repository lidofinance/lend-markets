// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {ConfigToml} from "./ConfigToml.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

struct WstEthOracleConfig {
    address wstETH;
}

struct UsdyOracleConfig {
    address usdyOracle;
    address feed;
    address loanToken;
    address collateralToken;
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
    }

    function readUsdy(string memory name) internal view returns (UsdyOracleConfig memory cfg) {
        string memory toml = vm.readFile(configPath(name));
        cfg.usdyOracle = ConfigToml.requireAddress(toml, ".usdy_oracle");
        cfg.feed = ConfigToml.requireAddress(toml, ".feed");
        cfg.loanToken = ConfigToml.requireAddress(toml, ".loan_token");
        cfg.collateralToken = ConfigToml.requireAddress(toml, ".collateral_token");
    }

    function configPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/oracles/", name, ".toml");
    }

    function writeDeployed(string memory name, address oracle, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        return _write(name, oracle, false, metadata);
    }

    function writeReference(string memory name, address oracle, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        return _write(name, oracle, true, metadata);
    }

    function _write(string memory name, address oracle, bool reused, ArtifactMetadata memory metadata)
        private
        returns (string memory path)
    {
        ArtifactMetadataFile.ensureArtifactsDir();
        string memory dir = string.concat(ArtifactMetadataFile.artifactsDir(), "/oracles");
        if (!vm.exists(dir)) vm.createDir(dir, false);
        path = deployedPath(name);
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
        string memory artifact = ArtifactMetadataFile.header(metadata, "oracle");
        artifact = string.concat(artifact, "\n[oracle]\n");
        artifact = string.concat(artifact, "name = \"", name, "\"\n");
        artifact = string.concat(artifact, "address = \"", vm.toString(oracle), "\"\n");
        artifact = string.concat(artifact, reused ? "reused = true\n" : "reused = false\n");
        address admin = OssifiableProxy(payable(oracle)).proxy__getAdmin();
        artifact = string.concat(artifact, "proxy_admin = \"", vm.toString(admin), "\"\n");
        string memory raw = readRaw(name);
        if (hasKey(raw, ".wsteth")) {
            WstEthOracleConfig memory cfg = readWstEth(name);
            artifact = string.concat(artifact, "kind = \"wsteth-rate\"\n");
            artifact = string.concat(artifact, "wsteth = \"", vm.toString(cfg.wstETH), "\"\n");
        } else {
            UsdyOracleConfig memory cfg = readUsdy(name);
            artifact = string.concat(artifact, "kind = \"usdy-stable\"\n");
            artifact = string.concat(artifact, "usdy_oracle = \"", vm.toString(cfg.usdyOracle), "\"\n");
            artifact = string.concat(artifact, "feed = \"", vm.toString(cfg.feed), "\"\n");
            artifact = string.concat(artifact, "loan_token = \"", vm.toString(cfg.loanToken), "\"\n");
            artifact = string.concat(artifact, "collateral_token = \"", vm.toString(cfg.collateralToken), "\"\n");
        }
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

    function readDeployed(string memory name, ArtifactMetadata memory expected) internal view returns (address) {
        string memory path = deployedPath(name);
        if (!vm.exists(path)) return address(0);
        string memory artifact = ArtifactMetadataFile.requireCompatible(path, expected);
        return vm.parseTomlAddress(artifact, ".oracle.address");
    }

    function deployedPath(string memory name) internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/oracles/", name, ".toml");
    }
}
