// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

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
    uint256 minPrice;
    uint256 maxPrice;
}

/// @notice One NAV oracle: the adapter kind, its constructor arguments, and the bounds, lifetime and speeds it is
///         initialized with. `poolId` and `shareClassId` apply to `nav-centrifuge` only.
struct NavOracleConfig {
    string kind;
    address source;
    uint64 poolId;
    bytes16 shareClassId;
    address loanToken;
    address collateralToken;
    uint256 maxPriceIncrease;
    uint256 maxPriceDecrease;
    uint40 anchorLifetime;
    uint256 maxAnchorRise;
    uint256 maxAnchorFall;
}

library OracleConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant KIND_NAV_USDY = "nav-usdy";
    string internal constant KIND_NAV_CENTRIFUGE = "nav-centrifuge";

    error ArtifactAlreadyExists(string path);
    error UnknownOracleKind(string kind);
    error ShareClassIdNot16Bytes(uint256 length);
    error ValueOutOfRange(string key, uint256 value);

    function readRaw(string memory name) internal view returns (string memory) {
        return vm.readFile(configPath(name));
    }

    function hasKey(string memory toml, string memory key) internal view returns (bool) {
        return vm.keyExistsToml(toml, key);
    }

    /// @notice The config's `kind`, which selects the deployment script and the preflight.
    function kind(string memory name) internal view returns (string memory) {
        return ConfigToml.requireString(readRaw(name), ".kind");
    }

    function isNavKind(string memory value) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(value));
        return h == keccak256(bytes(KIND_NAV_USDY)) || h == keccak256(bytes(KIND_NAV_CENTRIFUGE));
    }

    function isKind(string memory value, string memory expected) internal pure returns (bool) {
        return keccak256(bytes(value)) == keccak256(bytes(expected));
    }

    function readWstEth(string memory name) internal view returns (WstEthOracleConfig memory cfg) {
        string memory toml = vm.readFile(configPath(name));
        cfg.wstETH = ConfigToml.requireAddress(toml, ".wsteth");
    }

    function readUsdy(string memory name) internal view returns (UsdyOracleConfig memory cfg) {
        return parseUsdy(vm.readFile(configPath(name)));
    }

    function parseUsdy(string memory toml) internal view returns (UsdyOracleConfig memory cfg) {
        cfg.usdyOracle = ConfigToml.requireAddress(toml, ".usdy_oracle");
        cfg.feed = ConfigToml.requireAddress(toml, ".feed");
        cfg.loanToken = ConfigToml.requireAddress(toml, ".loan_token");
        cfg.collateralToken = ConfigToml.requireAddress(toml, ".collateral_token");
        // Both bounds are in the oracle's returned 1e36-convention domain, so they are strings: TOML
        // integers are limited to int64.
        cfg.minPrice = ConfigToml.requireUint(toml, ".min_price");
        cfg.maxPrice = ConfigToml.requireUint(toml, ".max_price");
    }

    function readNav(string memory name) internal view returns (NavOracleConfig memory) {
        return parseNav(vm.readFile(configPath(name)), "");
    }

    /// @notice Parses a NAV oracle config, or the `[oracle]` table of its artifact with `prefix = ".oracle"`. Amounts
    ///         are strings because TOML integers are limited to int64.
    function parseNav(string memory toml, string memory prefix) internal view returns (NavOracleConfig memory cfg) {
        cfg.kind = ConfigToml.requireString(toml, string.concat(prefix, ".kind"));
        if (!isNavKind(cfg.kind)) revert UnknownOracleKind(cfg.kind);
        cfg.source = ConfigToml.requireAddress(toml, string.concat(prefix, ".source"));
        cfg.loanToken = ConfigToml.requireAddress(toml, string.concat(prefix, ".loan_token"));
        cfg.collateralToken = ConfigToml.requireAddress(toml, string.concat(prefix, ".collateral_token"));
        if (isKind(cfg.kind, KIND_NAV_CENTRIFUGE)) {
            uint256 poolId = ConfigToml.requireUint(toml, string.concat(prefix, ".pool_id"));
            if (poolId > type(uint64).max) revert ValueOutOfRange("pool_id", poolId);
            cfg.poolId = uint64(poolId);
            bytes memory scId = vm.parseBytes(ConfigToml.requireString(toml, string.concat(prefix, ".share_class_id")));
            if (scId.length != 16) revert ShareClassIdNot16Bytes(scId.length);
            cfg.shareClassId = bytes16(scId);
        }
        // All five are required non-zero: the oracle's validator needs both bounds and the lifetime, and a zero speed
        // would leave the anchor unable to follow the source in that direction.
        cfg.maxPriceIncrease = ConfigToml.requireUint(toml, string.concat(prefix, ".max_price_increase"));
        cfg.maxPriceDecrease = ConfigToml.requireUint(toml, string.concat(prefix, ".max_price_decrease"));
        cfg.anchorLifetime = _requireUint40(toml, string.concat(prefix, ".anchor_lifetime"));
        cfg.maxAnchorRise = ConfigToml.requireUint(toml, string.concat(prefix, ".max_anchor_rise"));
        cfg.maxAnchorFall = ConfigToml.requireUint(toml, string.concat(prefix, ".max_anchor_fall"));
    }

    function _requireUint40(string memory toml, string memory key) private view returns (uint40) {
        uint256 value = ConfigToml.requireUint(toml, key);
        if (value > type(uint40).max) revert ValueOutOfRange(key, value);
        return uint40(value);
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
        } else if (isNavKind(kind(name))) {
            artifact = string.concat(artifact, navArtifact(readNav(name)));
        } else {
            UsdyOracleConfig memory cfg = readUsdy(name);
            artifact = string.concat(artifact, "kind = \"usdy-stable\"\n");
            artifact = string.concat(artifact, "usdy_oracle = \"", vm.toString(cfg.usdyOracle), "\"\n");
            artifact = string.concat(artifact, "feed = \"", vm.toString(cfg.feed), "\"\n");
            artifact = string.concat(artifact, "loan_token = \"", vm.toString(cfg.loanToken), "\"\n");
            artifact = string.concat(artifact, "collateral_token = \"", vm.toString(cfg.collateralToken), "\"\n");
            artifact = string.concat(artifact, "min_price = \"", vm.toString(cfg.minPrice), "\"\n");
            artifact = string.concat(artifact, "max_price = \"", vm.toString(cfg.maxPrice), "\"\n");
        }
        vm.writeFile(path, artifact);
    }

    /// @notice The NAV oracle's constructor arguments and initial bounds, lifetime and speeds as the body of its
    ///         artifact's `[oracle]` table, in the keys the config uses, so `parseNav(artifact, ".oracle")` reads them
    ///         back.
    function navArtifact(NavOracleConfig memory cfg) internal pure returns (string memory s) {
        s = string.concat("kind = \"", cfg.kind, "\"\n");
        s = string.concat(s, "source = \"", vm.toString(cfg.source), "\"\n");
        if (isKind(cfg.kind, KIND_NAV_CENTRIFUGE)) {
            s = string.concat(s, "pool_id = \"", vm.toString(uint256(cfg.poolId)), "\"\n");
            s = string.concat(s, "share_class_id = \"", vm.toString(abi.encodePacked(cfg.shareClassId)), "\"\n");
        }
        s = string.concat(s, "loan_token = \"", vm.toString(cfg.loanToken), "\"\n");
        s = string.concat(s, "collateral_token = \"", vm.toString(cfg.collateralToken), "\"\n");
        s = string.concat(s, "max_price_increase = \"", vm.toString(cfg.maxPriceIncrease), "\"\n");
        s = string.concat(s, "max_price_decrease = \"", vm.toString(cfg.maxPriceDecrease), "\"\n");
        s = string.concat(s, "anchor_lifetime = ", vm.toString(uint256(cfg.anchorLifetime)), "\n");
        s = string.concat(s, "max_anchor_rise = \"", vm.toString(cfg.maxAnchorRise), "\"\n");
        s = string.concat(s, "max_anchor_fall = \"", vm.toString(cfg.maxAnchorFall), "\"\n");
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
