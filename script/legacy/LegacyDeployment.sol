// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {DeploymentSnapshot, RecordedMarket} from "../deployment/DeploymentSnapshot.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "./lib/DeployConfigFile.sol";
import {MarketConfigFile} from "./lib/MarketConfigFile.sol";

library LegacyDeployment {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function metadata(string memory runName) internal view returns (ArtifactMetadata memory m) {
        string memory file = string.concat(ArtifactMetadataFile.artifactsDir(runName), "/protocol.toml");
        string memory p = vm.readFile(file);
        DeployConfigFile.requireProtocolArtifactCompatibility(p);
        require(
            keccak256(bytes(vm.parseTomlString(p, ".protocol.deployment"))) == keccak256(bytes(runName)),
            "Historical protocol run mismatch"
        );
        m = ArtifactMetadata({
            deployment: runName,
            chainId: vm.parseTomlUint(p, ".protocol.chain_id"),
            configHash: vm.parseTomlBytes32(p, ".protocol.config_hash"),
            compatibilityHash: vm.parseTomlBytes32(p, ".artifact.compatibility_hash")
        });
        ArtifactMetadataFile.requireExact(file, m);
        require(m.chainId == block.chainid, "Historical protocol chain mismatch");
    }

    function loadProtocol(string memory runName) internal view returns (DeploymentSnapshot memory d) {
        ArtifactMetadata memory m = metadata(runName);
        string memory dir = ArtifactMetadataFile.artifactsDir(runName);
        string memory p = vm.readFile(string.concat(dir, "/protocol.toml"));
        string memory config = vm.envOr("ARTIFACTS_CONFIG", string(""));
        string memory configPath = DeployConfigFile.configPath(bytes(config).length == 0 ? runName : config);
        if (bytes(config).length == 0 && !vm.exists(configPath)) {
            configPath = DeployConfigFile.configPath(vm.parseTomlString(p, ".protocol.network"));
        }
        string memory externalConfig = vm.readFile(configPath);
        d.weth = vm.parseTomlAddress(externalConfig, ".external.weth");
        d.wstEth = vm.parseTomlAddress(externalConfig, ".external.wstEth");
        d.stEth = vm.parseTomlAddress(externalConfig, ".external.stEth");
        d.usdt = _optionalExternal(externalConfig, "usdt");
        d.usdy = _optionalExternal(externalConfig, "usdy");
        d.ondoOracle = _optionalExternal(externalConfig, "ondoOracle");
        d.usdyBlocklist = _optionalExternal(externalConfig, "usdyBlocklist");
        d.protocol.chainId = m.chainId;
        d.protocol.core = vm.parseTomlAddress(p, ".protocol.core");
        d.protocol.factory = vm.parseTomlAddress(p, ".protocol.factory");
        d.protocol.ownerFacade = vm.parseTomlAddress(p, ".protocol.owner_facade");
        d.protocol.irmRouter = vm.parseTomlAddress(p, ".protocol.irm_router");
        d.protocol.adaptiveCurveIrm = vm.parseTomlAddress(p, ".protocol.adaptive_curve_irm");
        d.protocol.irmConfigFactory = vm.parseTomlAddress(p, ".protocol.irm_config_factory");
        d.protocol.dashboard = vm.parseTomlAddress(p, ".protocol.risk_steward_dashboard");
        d.protocol.circuitBreaker = vm.parseTomlAddress(p, ".protocol.circuit_breaker");
        d.protocol.resealManager = vm.parseTomlAddress(p, ".protocol.reseal_manager");
        d.protocol.agent = vm.parseTomlAddress(p, ".protocol.agent");
        d.protocol.executor = vm.parseTomlAddress(p, ".protocol.evm_script_executor");
        string memory cb = ArtifactMetadataFile.requireCompatible(
            string.concat(
                dir, "/circuit-breakers/", vm.parseTomlString(p, ".protocol.circuit_breaker_artifact"), ".toml"
            ),
            m
        );
        require(
            vm.parseTomlAddress(cb, ".circuit_breaker.address") == d.protocol.circuitBreaker,
            "Historical circuit breaker mismatch"
        );
        d.circuitBreakerPlan.minPauseDuration = vm.parseTomlUint(cb, ".circuit_breaker.min_pause_duration");
        d.circuitBreakerPlan.maxPauseDuration = vm.parseTomlUint(cb, ".circuit_breaker.max_pause_duration");
        d.circuitBreakerPlan.minHeartbeatInterval = vm.parseTomlUint(cb, ".circuit_breaker.min_heartbeat_interval");
        d.circuitBreakerPlan.maxHeartbeatInterval = vm.parseTomlUint(cb, ".circuit_breaker.max_heartbeat_interval");
        d.circuitBreakerPlan.initialPauseDuration = vm.parseTomlUint(cb, ".circuit_breaker.initial_pause_duration");
        d.circuitBreakerPlan.initialHeartbeatInterval =
            vm.parseTomlUint(cb, ".circuit_breaker.initial_heartbeat_interval");
    }

    function loadMarket(string memory runName, string memory name, address core)
        internal
        view
        returns (RecordedMarket memory entry)
    {
        ArtifactMetadata memory m = metadata(runName);
        string memory dir = ArtifactMetadataFile.artifactsDir(runName);
        string memory a = ArtifactMetadataFile.requireCompatible(string.concat(dir, "/markets/", name, ".toml"), m);
        string memory p = vm.readFile(string.concat(dir, "/protocol.toml"));
        require(vm.parseTomlAddress(p, ".protocol.core") == core, "Historical market core mismatch");
        require(
            vm.parseTomlAddress(a, ".market.factory") == vm.parseTomlAddress(p, ".protocol.factory"),
            "Historical market factory mismatch"
        );
        require(
            vm.parseTomlAddress(a, ".market.irm") == vm.parseTomlAddress(p, ".protocol.irm_router"),
            "Historical market router mismatch"
        );
        entry.deployedBlock = vm.parseTomlUint(a, ".market.deployed_block");
        entry.role = vm.parseTomlString(a, ".market.role");
        entry.plan.name = vm.parseTomlString(a, ".market.name");
        (entry.plan.market, entry.plan.wrapper, entry.plan.curve) = MarketConfigFile.parse(a);
        string memory group = vm.parseTomlString(a, ".market.guardian_group");
        string memory g = ArtifactMetadataFile.requireCompatible(string.concat(dir, "/guardians/", group, ".toml"), m);
        require(
            vm.parseTomlAddress(g, ".guardian_signals.address") == entry.plan.market.guardianSignals,
            "Historical guardian mismatch"
        );
        string memory feed = ArtifactMetadataFile.requireCompatible(
            string.concat(dir, "/oracles/", vm.parseTomlString(a, ".market.oracle_artifact"), ".toml"), m
        );
        require(
            vm.parseTomlAddress(feed, ".oracle.address") == entry.plan.market.oracle, "Historical price feed mismatch"
        );
        if (vm.keyExistsToml(feed, ".oracle.wsteth")) {
            entry.priceFeed.wstEth = vm.parseTomlAddress(feed, ".oracle.wsteth");
        }
        if (vm.keyExistsToml(feed, ".oracle.usdy_oracle")) {
            entry.priceFeed.usdySource = vm.parseTomlAddress(feed, ".oracle.usdy_oracle");
            entry.priceFeed.feed = vm.parseTomlAddress(feed, ".oracle.feed");
            entry.priceFeed.loanToken = vm.parseTomlAddress(feed, ".oracle.loan_token");
            entry.priceFeed.collateralToken = vm.parseTomlAddress(feed, ".oracle.collateral_token");
            entry.priceFeed.minPrice = vm.parseTomlUint(feed, ".oracle.min_price");
            entry.priceFeed.maxPrice = vm.parseTomlUint(feed, ".oracle.max_price");
        }
        entry.priceFeedKind = vm.parseTomlString(feed, ".oracle.kind");
        require(
            bytes(entry.role).length != 0 && keccak256(bytes(entry.plan.name)) == keccak256(bytes(name)),
            "Historical market identity mismatch"
        );
        entry.plan.guardianGroup = keccak256(bytes(group));
        entry.plan.committee.guardians = vm.parseTomlAddressArray(g, ".guardian_signals.guardians");
        entry.plan.committee.quorum = vm.parseTomlUint(g, ".guardian_signals.quorum");
        entry.plan.committee.suspectWindow = vm.parseTomlUint(g, ".guardian_signals.suspect_window");
        entry.contracts.id = Id.wrap(vm.parseTomlBytes32(a, ".market.id"));
        entry.contracts.params = MarketParams({
            loanToken: entry.plan.market.loanToken,
            collateralToken: entry.plan.market.collateralToken,
            oracle: entry.plan.market.oracle,
            irm: vm.parseTomlAddress(a, ".market.irm"),
            lltv: entry.plan.market.lltv
        });
        entry.contracts.controller = vm.parseTomlAddress(a, ".market.controller");
        entry.contracts.vault = vm.parseTomlAddress(a, ".market.vault");
        entry.contracts.guardianSignals = entry.plan.market.guardianSignals;
        entry.contracts.irmConfig = vm.parseTomlAddress(a, ".market.irm_config");
        string memory v = string.concat(dir, "/vaults/", name, ".toml");
        string memory adapter = string.concat(dir, "/adapters/", name, ".toml");
        if (vm.exists(v) && !vm.keyExistsToml(vm.readFile(v), ".header.version")) {
            _loadVault(entry, v, adapter, m, core);
        } else {
            require(!vm.exists(adapter), "Historical adapter without vault");
        }
    }

    function _loadVault(
        RecordedMarket memory entry,
        string memory vaultPath,
        string memory adapterPath,
        ArtifactMetadata memory m,
        address core
    ) private view {
        string memory v = ArtifactMetadataFile.requireCompatible(vaultPath, m);
        string memory a = ArtifactMetadataFile.requireCompatible(adapterPath, m);
        bytes32 name = keccak256(bytes(entry.plan.name));
        require(
            keccak256(bytes(vm.parseTomlString(v, ".vault.name"))) == name
                && keccak256(bytes(vm.parseTomlString(a, ".adapter.name"))) == name
                && keccak256(bytes(vm.parseTomlString(a, ".adapter.vault_artifact"))) == name,
            "Historical vault identity mismatch"
        );
        entry.vaultV2 = vm.parseTomlAddress(v, ".vault.address");
        entry.adapter = vm.parseTomlAddress(a, ".adapter.address");
        require(vm.parseTomlAddress(a, ".adapter.vault") == entry.vaultV2, "Historical adapter vault mismatch");
        require(vm.parseTomlAddress(a, ".adapter.morpho") == core, "Historical adapter core mismatch");
        require(
            vm.parseTomlAddress(a, ".adapter.adaptive_curve_irm") == entry.contracts.params.irm,
            "Historical adapter router mismatch"
        );
    }

    function _optionalExternal(string memory config, string memory name) private view returns (address) {
        string memory key = string.concat(".external.", name);
        return vm.keyExistsToml(config, key) ? vm.parseTomlAddress(config, key) : address(0);
    }
}
