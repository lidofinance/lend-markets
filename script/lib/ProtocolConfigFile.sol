// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

/// @notice Governance inputs for the protocol backbone.
struct ProtocolConfig {
    address agent;
    address evmScriptExecutor;
}

/// @notice Deploy-known inputs to a market's activation motion; `pauserCommittee` / `enableSettlement` are
///         activation-time decisions left as placeholders (see `writeActivationPlan`).
struct ActivationPlan {
    string name;
    string deployment;
    string network;
    uint256 chainId;
    bytes32 configHash;
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
    address controller;
    AdaptiveCurveParams curveParams;
}

/// @notice The shared protocol addresses a deploy produces. `deployedBlock` is captured before the broadcast
///         as a lower bound for acceptance's event scan; `deployer` is the EOA that ran the deploy, recorded
///         so acceptance can assert it retained no role.
struct ProtocolDeployment {
    string deployment;
    string network;
    uint256 chainId;
    bytes32 configHash;
    address core;
    address ownerFacade;
    address irmRouter;
    address adaptiveCurveIrm;
    address factory;
    address builder;
    address riskStewardDashboard;
    address guardianSignalsImpl;
    uint256 deployedBlock;
    address deployer;
    address circuitBreaker; // one instance for all markets; each controller's PAUSER_ROLE holder
}

/// @notice One market's deployed components, written under `[markets.<name>]`. `deployedBlock` is per market:
///         one added via `AddMarket` deploys in a different block range than the backbone.
struct MarketDeployment {
    string name;
    bytes32 id;
    address controller;
    address vault;
    address oracle;
    address guardianSignals;
    address[] pausers;
    uint256 deployedBlock;
}

/// @notice The full result of one `DeployProtocol` run: backbone, optional exit books, every market.
struct Deployment {
    ProtocolDeployment protocol;
    bool hasExitBooks;
    address morphoExitBook;
    address erc4626ExitBook;
    MarketDeployment[] markets;
}

/// @notice Composes and writes a deploy's TOML artifacts: the deployed-address registry and per-market
///         activation plans.
library ProtocolConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error MarketAlreadyRecorded(string name);
    error ArtifactAlreadyExists(string path);

    /// @notice Compose and write the full deployment registry to a dated per-run file; returns the path.
    function writeDeployment(Deployment memory d) internal returns (string memory path) {
        ArtifactMetadataFile.ensureArtifactsDir();
        string memory s = ArtifactMetadataFile.header(
            ArtifactMetadata({
                deployment: d.protocol.deployment,
                chainId: d.protocol.chainId,
                configHash: d.protocol.configHash
            }),
            "protocol-registry"
        );
        s = string.concat(s, "\n[protocol]\n");
        s = string.concat(s, _kv("deployment", d.protocol.deployment));
        s = string.concat(s, _kv("chain_id", d.protocol.chainId));
        s = string.concat(s, _kv("config_hash", d.protocol.configHash));
        s = string.concat(s, _kv("core", d.protocol.core));
        s = string.concat(s, _kv("owner_facade", d.protocol.ownerFacade));
        s = string.concat(s, _kv("irm_router", d.protocol.irmRouter));
        s = string.concat(s, _kv("adaptive_curve_irm", d.protocol.adaptiveCurveIrm));
        s = string.concat(s, _kv("factory", d.protocol.factory));
        s = string.concat(s, _kv("builder", d.protocol.builder));
        s = string.concat(s, _kv("risk_steward_dashboard", d.protocol.riskStewardDashboard));
        s = string.concat(s, _kv("guardian_signals_impl", d.protocol.guardianSignalsImpl));
        s = string.concat(s, _kv("deployed_block", d.protocol.deployedBlock));
        s = string.concat(s, _kv("deployer", d.protocol.deployer));
        s = string.concat(s, _kv("circuit_breaker", d.protocol.circuitBreaker));

        if (d.hasExitBooks) {
            s = string.concat(s, "\n[exit_books]\n");
            s = string.concat(s, _kv("morpho", d.morphoExitBook));
            s = string.concat(s, _kv("erc4626", d.erc4626ExitBook));
        }

        for (uint256 i; i < d.markets.length; ++i) {
            s = string.concat(s, _marketSection(d.markets[i]));
        }

        path = deployedPath();
        _requireArtifactAbsent(path);
        vm.writeFile(path, s);
    }

    /// @notice Fail before broadcast when this run already has a protocol registry.
    function requireDeploymentUndeployed() internal view {
        _requireArtifactAbsent(deployedPath());
    }

    /// @notice Append one market's section to an existing registry; reverts on a duplicate name.
    function appendMarket(string memory path, MarketDeployment memory m) internal {
        requireMarketAbsent(path, m.name);
        vm.writeFile(path, string.concat(vm.readFile(path), _marketSection(m)));
    }

    /// @notice Revert when the registry at `path` already carries `[markets.<name>]`. Callable before the
    ///         broadcast so a doomed append fails before any contract is deployed.
    function requireMarketAbsent(string memory path, string memory name) internal view {
        if (vm.keyExistsToml(vm.readFile(path), string.concat(".markets.", name))) {
            revert MarketAlreadyRecorded(name);
        }
    }

    /// @notice Write one market's section as a standalone artifact; the `AddMarket` fallback when no `REGISTRY`.
    function writeMarketOnly(MarketDeployment memory m, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        ArtifactMetadataFile.ensureArtifactsDir();
        path = string.concat(ArtifactMetadataFile.artifactsDir(), "/market-", m.name, ".toml");
        _requireArtifactAbsent(path);
        vm.writeFile(path, string.concat(ArtifactMetadataFile.header(metadata, "market-deployment"), _marketSection(m)));
    }

    function _marketSection(MarketDeployment memory m) private pure returns (string memory s) {
        s = string.concat("\n[markets.", m.name, "]\n");
        s = string.concat(s, _kv("id", m.id));
        s = string.concat(s, _kv("controller", m.controller));
        s = string.concat(s, _kv("vault", m.vault));
        s = string.concat(s, _kv("oracle", m.oracle));
        s = string.concat(s, _kv("guardian_signals", m.guardianSignals));
        s = string.concat(s, _kvArray("pausers", m.pausers));
        s = string.concat(s, _kv("deployed_block", m.deployedBlock));
    }

    /// @dev Address/bytes32 values are quoted (so `vm.parseToml*` reads them back); integers are not.
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

    function _kv(string memory key, int256 value) private pure returns (string memory) {
        return string.concat(key, " = ", vm.toString(value), "\n");
    }

    function _kvArray(string memory key, address[] memory values) private pure returns (string memory s) {
        s = string.concat(key, " = [");
        for (uint256 i; i < values.length; ++i) {
            s = string.concat(s, i == 0 ? "\"" : ", \"", vm.toString(values[i]), "\"");
        }
        s = string.concat(s, "]\n");
    }

    function deployedPath() internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/registry.toml");
    }

    /// @notice Write a market's activation plan to `deployed/activation-<network>-<name>-<run-id>.toml`; returns
    ///         the path. `pauser_committee` / `enable_settlement` are emitted as `# TODO` placeholders for the
    ///         operator to fill.
    function writeActivationPlan(ActivationPlan memory p) internal returns (string memory path) {
        ArtifactMetadataFile.ensureArtifactsDir();
        string memory s = ArtifactMetadataFile.header(
            ArtifactMetadata({
                deployment: p.deployment, chainId: p.chainId, configHash: p.configHash
            }),
            "activation-plan"
        );
        s = string.concat(s, "\n# Activation plan for market '", p.name, "'.\n");
        s = string.concat(s, "# Inputs to the LidoLendActivateMarket EasyTrack motion. FILL the two # TODO fields.\n");

        s = string.concat(s, "\n[activation]\n");
        s = string.concat(s, _kv("controller", p.controller));
        s = string.concat(s, "# TODO: the pauser committee registered on the CircuitBreaker at activation.\n");
        s = string.concat(s, _kv("pauser_committee", address(0)));
        s = string.concat(s, "# TODO: bind-time decision - whether the market is created with settlement enabled.\n");
        s = string.concat(s, "enable_settlement = false\n");

        s = string.concat(s, "\n[market_params]\n");
        s = string.concat(s, _kv("loan_token", p.loanToken));
        s = string.concat(s, _kv("collateral_token", p.collateralToken));
        s = string.concat(s, _kv("oracle", p.oracle));
        s = string.concat(s, _kv("irm", p.irm));
        s = string.concat(s, _kv("lltv", p.lltv));

        s = string.concat(s, "\n[curve_params]\n");
        s = string.concat(s, _kv("curve_steepness", p.curveParams.curveSteepness));
        s = string.concat(s, _kv("adjustment_speed", p.curveParams.adjustmentSpeed));
        s = string.concat(s, _kv("target_utilization", p.curveParams.targetUtilization));
        s = string.concat(s, _kv("initial_rate_at_target", p.curveParams.initialRateAtTarget));
        s = string.concat(s, _kv("min_rate_at_target", p.curveParams.minRateAtTarget));
        s = string.concat(s, _kv("max_rate_at_target", p.curveParams.maxRateAtTarget));
        s = string.concat(s, _kv("max_borrow_rate", p.curveParams.maxBorrowRate));

        path = string.concat(ArtifactMetadataFile.artifactsDir(), "/activation-", p.name, ".toml");
        _requireArtifactAbsent(path);
        vm.writeFile(path, s);
    }

    /// @notice Fail before broadcast when the market's activation plan path is already occupied.
    function requireActivationPlanUndeployed(string memory name) internal view {
        _requireArtifactAbsent(string.concat(ArtifactMetadataFile.artifactsDir(), "/activation-", name, ".toml"));
    }

    function _requireArtifactAbsent(string memory path) private view {
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }
}
