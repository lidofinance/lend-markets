// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

struct ProtocolConfig {
    address agent;
    address evmScriptExecutor;
    address circuitBreaker;
}

struct ProtocolDeployment {
    string deployment;
    string network;
    uint256 chainId;
    bytes32 configHash;
    string circuitBreakerArtifact;
    address core;
    address ownerFacade;
    address irmRouter;
    address adaptiveCurveIrm;
    address irmConfigFactory;
    address factory;
    address riskStewardDashboard;
    address circuitBreaker;
    address guardianSignalsImpl;
    uint256 deployedBlock;
    address deployer;
    address agent;
    address evmScriptExecutor;
}

struct MarketDeployment {
    string name;
    /// @dev The part this market plays, shared across networks. Consumers bind by it rather than by `name`.
    string role;
    string oracleArtifact;
    string guardianGroup;
    bytes32 id;
    address factory;
    address controller;
    address vault;
    /// @dev The market's immutable `params.irm`: the protocol IRM router, never the model itself.
    address irm;
    LidoLendMarketFactory.MarketSpec market;
    LidoLendMarketFactory.ERC4626WrapperSpec erc4626WrapperSpec;
    AdaptiveCurveParams curveParams;
    /// @dev Immutable parameter holder applied to the routed IRM during activation.
    address irmConfig;
    uint256 deployedBlock;
}

struct ExitBooksDeployment {
    address morpho;
    address erc4626;
    uint256 deployedBlock;
    address pauser;
    uint256 maxRequestLifetime;
}

library ProtocolConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error MarketAlreadyRecorded(string name);
    error MarketIdAlreadyRecorded(bytes32 id);
    error MarketRoleAlreadyRecorded(string role);
    error MarketRoleMissing(string path);
    error ExitBooksAlreadyRecorded();
    error ArtifactAlreadyExists(string path);

    function writeProtocol(ProtocolDeployment memory d, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        ArtifactMetadataFile.ensureArtifactsDir();
        path = protocolPath();
        _requireArtifactAbsent(path);

        string memory s = ArtifactMetadataFile.header(metadata, "protocol-deployment");
        s = string.concat(s, "\n[protocol]\n");
        s = string.concat(s, _kv("deployment", d.deployment));
        s = string.concat(s, _kv("network", d.network));
        s = string.concat(s, _kv("chain_id", d.chainId));
        s = string.concat(s, _kv("config_hash", d.configHash));
        s = string.concat(s, _kv("circuit_breaker_artifact", d.circuitBreakerArtifact));
        s = string.concat(s, _kv("core", d.core));
        s = string.concat(s, _kv("owner_facade", d.ownerFacade));
        s = string.concat(s, _kv("irm_router", d.irmRouter));
        s = string.concat(s, _kv("adaptive_curve_irm", d.adaptiveCurveIrm));
        s = string.concat(s, _kv("irm_config_factory", d.irmConfigFactory));
        s = string.concat(s, _kv("factory", d.factory));
        s = string.concat(s, _kv("risk_steward_dashboard", d.riskStewardDashboard));
        s = string.concat(s, _kv("circuit_breaker", d.circuitBreaker));
        s = string.concat(s, _kv("guardian_signals_impl", d.guardianSignalsImpl));
        s = string.concat(s, _kv("deployed_block", d.deployedBlock));
        s = string.concat(s, _kv("agent", d.agent));
        s = string.concat(s, _kv("evm_script_executor", d.evmScriptExecutor));
        vm.writeFile(path, s);
    }

    function writeMarket(MarketDeployment memory d, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        return _writeMarket(d, metadata, ArtifactMetadataFile.artifactsDir());
    }

    function writeMarket(MarketDeployment memory d, ArtifactMetadata memory metadata, string memory deployment)
        internal
        returns (string memory path)
    {
        return _writeMarket(d, metadata, ArtifactMetadataFile.artifactsDir(deployment));
    }

    function _writeMarket(MarketDeployment memory d, ArtifactMetadata memory metadata, string memory artifactsDir)
        private
        returns (string memory path)
    {
        _ensureMarketsDir(artifactsDir);
        path = _marketPath(artifactsDir, d.name);
        _requireArtifactAbsent(path);

        string memory s = ArtifactMetadataFile.header(metadata, "market-deployment");
        s = string.concat(s, _marketSection(d));
        s = string.concat(s, _activationSection(d.market));
        s = string.concat(s, _settlementSection(d.market));
        s = string.concat(s, _curveSection(d.curveParams));
        vm.writeFile(path, s);
    }

    function writeExitBooks(ExitBooksDeployment memory d, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        ArtifactMetadataFile.ensureArtifactsDir();
        path = exitBooksPath();
        if (vm.exists(path)) revert ExitBooksAlreadyRecorded();

        string memory s = ArtifactMetadataFile.header(metadata, "exit-books-deployment");
        s = string.concat(s, "\n[exit_books]\n");
        s = string.concat(s, _kv("morpho", d.morpho));
        s = string.concat(s, _kv("erc4626", d.erc4626));
        s = string.concat(s, _kv("deployed_block", d.deployedBlock));
        s = string.concat(s, _kv("max_request_lifetime", d.maxRequestLifetime));
        s = string.concat(s, _kv("pauser", d.pauser));
        vm.writeFile(path, s);
    }

    function requireProtocolUndeployed() internal view {
        _requireArtifactAbsent(protocolPath());
    }

    function requireMarketUndeployed(string memory name) internal view {
        if (vm.exists(marketPath(name))) revert MarketAlreadyRecorded(name);
    }

    function requireMarketIdUndeployed(bytes32 id) internal view {
        _requireMarketIdUndeployed(id, marketsDir());
    }

    function requireMarketIdUndeployed(bytes32 id, string memory deployment) internal view {
        _requireMarketIdUndeployed(id, _marketsDir(ArtifactMetadataFile.artifactsDir(deployment)));
    }

    function requireMarketRoleUndeployed(string memory role) internal view {
        _requireMarketRoleUndeployed(role, marketsDir());
    }

    function requireMarketRoleUndeployed(string memory role, string memory deployment) internal view {
        _requireMarketRoleUndeployed(role, _marketsDir(ArtifactMetadataFile.artifactsDir(deployment)));
    }

    function requireMarketsCompatible(ArtifactMetadata memory expected) internal view {
        _requireDirectoryCompatible(_marketsDir(ArtifactMetadataFile.artifactsDir(expected.deployment)), expected);
    }

    function _requireDirectoryCompatible(string memory dir, ArtifactMetadata memory expected) private view {
        if (!vm.exists(dir)) return;

        Vm.DirEntry[] memory entries = vm.readDir(dir);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || entries[i].isSymlink) continue;
            ArtifactMetadataFile.requireCompatible(entries[i].path, expected);
        }
    }

    function _requireMarketIdUndeployed(bytes32 id, string memory dir) private view {
        if (!vm.exists(dir)) return;

        Vm.DirEntry[] memory entries = vm.readDir(dir);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || entries[i].isSymlink) continue;
            if (containsMarketId(vm.readFile(entries[i].path), id)) revert MarketIdAlreadyRecorded(id);
        }
    }

    function _requireMarketRoleUndeployed(string memory role, string memory dir) private view {
        if (!vm.exists(dir)) return;

        bytes32 expected = keccak256(bytes(role));
        Vm.DirEntry[] memory entries = vm.readDir(dir);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || entries[i].isSymlink) continue;
            string memory artifact = vm.readFile(entries[i].path);
            if (!vm.keyExistsToml(artifact, ".market.role")) revert MarketRoleMissing(entries[i].path);
            string memory recorded = vm.parseTomlString(artifact, ".market.role");
            if (bytes(recorded).length == 0) revert MarketRoleMissing(entries[i].path);
            if (keccak256(bytes(recorded)) == expected) revert MarketRoleAlreadyRecorded(role);
        }
    }

    function requireExitBooksUndeployed() internal view {
        if (vm.exists(exitBooksPath())) revert ExitBooksAlreadyRecorded();
    }

    /// @dev Matches the exact market-id line to avoid other bytes32 fields.
    function containsMarketId(string memory artifact, bytes32 id) internal pure returns (bool) {
        bytes memory haystack = bytes(artifact);
        bytes memory needle = bytes(string.concat("id = \"", vm.toString(id), "\""));
        if (needle.length > haystack.length) return false;

        for (uint256 i; i <= haystack.length - needle.length; ++i) {
            bool matches = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    function protocolPath() internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/protocol.toml");
    }

    function marketPath(string memory name) internal view returns (string memory) {
        return _marketPath(ArtifactMetadataFile.artifactsDir(), name);
    }

    function marketsDir() internal view returns (string memory) {
        return _marketsDir(ArtifactMetadataFile.artifactsDir());
    }

    function exitBooksPath() internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/exit-books.toml");
    }

    function _marketSection(MarketDeployment memory d) private pure returns (string memory s) {
        s = "\n[market]\n";
        s = string.concat(s, _kv("name", d.name));
        s = string.concat(s, _kv("role", d.role));
        s = string.concat(s, _kv("id", d.id));
        s = string.concat(s, _kv("loan_token", d.market.loanToken));
        s = string.concat(s, _kv("collateral_token", d.market.collateralToken));
        s = string.concat(s, _kv("oracle", d.market.oracle));
        s = string.concat(s, _kv("oracle_artifact", d.oracleArtifact));
        s = string.concat(s, _kv("irm", d.irm));
        s = string.concat(s, _kv("irm_config", d.irmConfig));
        s = string.concat(s, _kvQuoted("lltv", d.market.lltv));
        s = string.concat(s, _kvQuoted("supply_cap", d.market.supplyCap));
        s = string.concat(s, _kv("guardian_signals", d.market.guardianSignals));
        s = string.concat(s, _kv("guardian_group", d.guardianGroup));
        s = string.concat(s, _kv("factory", d.factory));
        s = string.concat(s, _kv("controller", d.controller));
        s = string.concat(s, _kv("vault", d.vault));
        s = string.concat(s, _kv("vault_name", d.erc4626WrapperSpec.name));
        s = string.concat(s, _kv("vault_symbol", d.erc4626WrapperSpec.symbol));
        s = string.concat(s, _kv("deployed_block", d.deployedBlock));
    }

    function _activationSection(LidoLendMarketFactory.MarketSpec memory m) private pure returns (string memory s) {
        s = "\n[activation]\n";
        s = string.concat(s, _kvQuoted("min_activation_delay", m.activationConfig.minActivationDelay));
        s = string.concat(s, _kvQuoted("max_activation_delay", m.activationConfig.maxActivationDelay));
        s = string.concat(s, _kvQuoted("max_delay_inflow", m.activationConfig.maxDelayInflow));
        s = string.concat(s, _kvQuoted("activating_lock_duration", m.activationConfig.activatingLockDuration));
        s = string.concat(s, _kvQuoted("min_activation_amount", m.activationConfig.minActivationAmount));
        s = string.concat(s, _kvQuoted("min_deposit_amount", m.activationConfig.minDepositAmount));
        s = string.concat(s, _kvQuoted("max_guardians_quorum_delay", m.activationConfig.maxGuardiansQuorumDelay));
        s = string.concat(s, _kvQuoted("delay_per_strike", m.activationConfig.delayPerStrike));
        s = string.concat(s, _kvQuoted("delay_per_suspect", m.activationConfig.delayPerSuspect));
    }

    function _settlementSection(LidoLendMarketFactory.MarketSpec memory m) private pure returns (string memory s) {
        s = "\n[settlement]\n";
        s = string.concat(s, _kvQuoted("slice_floor_bps", m.settlementConfig.sliceFloorBps));
        s = string.concat(s, _kvQuoted("slice_floor_assets", m.settlementConfig.sliceFloorAssets));
        s = string.concat(s, _kvQuoted("full_cut_below_collateral", m.settlementConfig.fullCutBelowCollateral));
        s = string.concat(s, _kvQuoted("ltv_step_bps", m.settlementConfig.ltvStepBps));
    }

    function _curveSection(AdaptiveCurveParams memory p) private pure returns (string memory s) {
        s = "\n[curve]\n";
        s = string.concat(s, _kvQuoted("curve_steepness", p.curveSteepness));
        s = string.concat(s, _kvQuoted("adjustment_speed", p.adjustmentSpeed));
        s = string.concat(s, _kvQuoted("target_utilization", p.targetUtilization));
        s = string.concat(s, _kvQuoted("initial_rate_at_target", p.initialRateAtTarget));
        s = string.concat(s, _kvQuoted("min_rate_at_target", p.minRateAtTarget));
        s = string.concat(s, _kvQuoted("max_rate_at_target", p.maxRateAtTarget));
        s = string.concat(s, _kvQuoted("max_borrow_rate", p.maxBorrowRate));
    }

    function _ensureMarketsDir(string memory artifactsDir) private {
        if (!vm.exists(artifactsDir)) vm.createDir(artifactsDir, false);
        string memory dir = _marketsDir(artifactsDir);
        if (!vm.exists(dir)) vm.createDir(dir, false);
    }

    function _marketPath(string memory artifactsDir, string memory name) private pure returns (string memory) {
        return string.concat(_marketsDir(artifactsDir), "/", name, ".toml");
    }

    function _marketsDir(string memory artifactsDir) private pure returns (string memory) {
        return string.concat(artifactsDir, "/markets");
    }

    function _kv(string memory key, string memory value) private pure returns (string memory) {
        return string.concat(key, " = \"", value, "\"\n");
    }

    function _kv(string memory key, address value) private pure returns (string memory) {
        return string.concat(key, " = \"", vm.toString(value), "\"\n");
    }

    function _kv(string memory key, bytes32 value) private pure returns (string memory) {
        return string.concat(key, " = \"", vm.toString(value), "\"\n");
    }

    function _kv(string memory key, uint256 value) private pure returns (string memory) {
        return string.concat(key, " = ", vm.toString(value), "\n");
    }

    function _kvQuoted(string memory key, uint256 value) private pure returns (string memory) {
        return string.concat(key, " = \"", vm.toString(value), "\"\n");
    }

    function _kvQuoted(string memory key, int256 value) private pure returns (string memory) {
        return string.concat(key, " = \"", vm.toString(value), "\"\n");
    }

    function _requireArtifactAbsent(string memory path) private view {
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }
}
