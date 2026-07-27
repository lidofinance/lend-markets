// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {LinearKinkParams} from "@lido-lend-irm/src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";

import {DeployConfig, DeployConfigFile} from "./lib/DeployConfigFile.sol";
import {IrmConfigFile} from "./lib/IrmConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";

// --- Minimal write surfaces. The IRM submodule's nested `MarketParams` is ABI-identical to the core's, so the
//     core type matches; the CircuitBreaker pins solc 0.8.34 and cannot be imported here. ---

interface IActivationCurve {
    function setMarketCurveParams(MarketParams calldata marketParams, AdaptiveCurveParams calldata curveParams) external;
}

interface IActivationKink {
    function setMarketKinkParams(MarketParams calldata marketParams, LinearKinkParams calldata params) external;
}

interface IActivationRouter {
    function manager() external view returns (address);
    function setMarketIrm(MarketParams calldata marketParams, address irm) external;
}

interface IActivationFacade {
    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement) external;
}

interface IActivationMorphoBook {
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed) external;
}

interface IActivationErc4626Book {
    function setVaultAllowed(address vault, bool allowed) external;
}

interface IActivationCircuitBreaker {
    function registerPauser(address pausable, address newPauser) external;
}

interface IActivationCore {
    function market(bytes32 id)
        external
        view
        returns (
            uint128 tSupplyA,
            uint128 tSupplyS,
            uint128 tBorrowA,
            uint128 tBorrowS,
            uint128 lastUpdate,
            uint128 fee
        );
}

/// @notice Binds every market the deploy config lists, broadcasting as the `EVMScriptExecutor`. Stands in for
///         the `LidoLendActivateMarket` motion on fork and devnet runs, where governance is not available.
/// @dev Call order is fixed: the routed model's per-market params precede `createMarket`, whose first
///      `borrowRate` ping reverts on an unset model. Inputs come from each market's recorded artifact rather
///      than its config. A market whose `market(id).lastUpdate` is non-zero is already bound and is skipped,
///      so a partial run can be repeated.
contract ActivateMarkets is Script {
    using MarketParamsLib for MarketParams;

    error WrongSender(address expected, address actual);
    error MarketIdMismatch(string name, bytes32 fromParams, bytes32 fromArtifact);
    error UnknownIrmArtifact(string name, string artifactRef);

    /// @dev Backbone addresses and activation inputs, resolved once in `run`.
    struct Backbone {
        address router;
        address adaptiveCurveIrm;
        address facade;
        address core;
        address pauserCommittee;
        bool hasExitBooks;
        address morphoBook;
        address erc4626Book;
    }

    Backbone internal bb;

    function run(string memory config) external {
        DeployConfig memory cfg = DeployConfigFile.read(config);

        string memory protocol = vm.readFile(ProtocolConfigFile.protocolPath());
        bb.router = vm.parseTomlAddress(protocol, ".protocol.irm_router");
        bb.adaptiveCurveIrm = vm.parseTomlAddress(protocol, ".protocol.adaptive_curve_irm");
        bb.facade = vm.parseTomlAddress(protocol, ".protocol.owner_facade");
        bb.core = vm.parseTomlAddress(protocol, ".protocol.core");
        // Motion input: governance routes an emergency committee. The Agent stands in for it.
        bb.pauserCommittee = vm.parseTomlAddress(protocol, ".protocol.agent");

        string memory exitBooksPath = ProtocolConfigFile.exitBooksPath();
        if (vm.exists(exitBooksPath)) {
            string memory exitBooks = vm.readFile(exitBooksPath);
            bb.hasExitBooks = true;
            bb.morphoBook = vm.parseTomlAddress(exitBooks, ".exit_books.morpho");
            bb.erc4626Book = vm.parseTomlAddress(exitBooks, ".exit_books.erc4626");
        }

        // The broadcaster must be the router's manager, i.e. the executor the deployment wired.
        address executor = IActivationRouter(bb.router).manager();
        if (msg.sender != executor) revert WrongSender(executor, msg.sender);

        for (uint256 i; i < cfg.markets.length; ++i) {
            _activateOne(cfg.markets[i]);
        }
    }

    function _activateOne(string memory name) internal {
        string memory artifact = vm.readFile(ProtocolConfigFile.marketPath(name));
        address controller = vm.parseTomlAddress(artifact, ".market.controller");
        address vault = vm.parseTomlAddress(artifact, ".market.vault");
        address circuitBreaker = vm.parseTomlAddress(artifact, ".market.circuit_breaker");
        bytes32 artifactId = vm.parseTomlBytes32(artifact, ".market.id");

        MarketParams memory p = MarketParams({
            loanToken: vm.parseTomlAddress(artifact, ".market.loan_token"),
            collateralToken: vm.parseTomlAddress(artifact, ".market.collateral_token"),
            oracle: vm.parseTomlAddress(artifact, ".market.oracle"),
            irm: bb.router,
            lltv: vm.parseTomlUint(artifact, ".market.lltv")
        });

        bytes32 id = Id.unwrap(p.id());
        if (id != artifactId) revert MarketIdMismatch(name, id, artifactId);

        // A bound market has a non-zero interest clock.
        (,,,, uint128 lastUpdate,) = IActivationCore(bb.core).market(id);
        if (lastUpdate != 0) {
            console2.log("skip (already activated):", name);
            return;
        }

        address routedIrm = _routedIrm(name, artifact);

        vm.startBroadcast();
        _setIrmParams(routedIrm, p, artifact);
        IActivationRouter(bb.router).setMarketIrm(p, routedIrm);
        IActivationFacade(bb.facade).createMarket(p, controller, true);
        if (circuitBreaker != address(0)) {
            IActivationCircuitBreaker(circuitBreaker).registerPauser(controller, bb.pauserCommittee);
        }
        if (bb.hasExitBooks) {
            IActivationMorphoBook(bb.morphoBook).setMarketAllowed(p, true);
            IActivationErc4626Book(bb.erc4626Book).setVaultAllowed(vault, true);
        }
        vm.stopBroadcast();

        console2.log("activated:", name);
        console2.log("  routed irm:", routedIrm);
    }

    /// @dev Resolves `market.irm_artifact` to the backbone adaptive curve recorded in `protocol.toml`, or to
    ///      the instance recorded under `irms/<name>.toml`.
    function _routedIrm(string memory name, string memory artifact) internal view returns (address irm) {
        string memory artifactRef = vm.parseTomlString(artifact, ".market.irm_artifact");
        if (IrmConfigFile.isAdaptiveCurve(artifactRef)) return bb.adaptiveCurveIrm;
        irm = IrmConfigFile.readDeployed(artifactRef);
        if (irm == address(0)) revert UnknownIrmArtifact(name, artifactRef);
    }

    /// @dev A market artifact carries `[curve]` or `[kink]`, never both, so the section selects the setter.
    function _setIrmParams(address routedIrm, MarketParams memory p, string memory artifact) internal {
        if (vm.keyExistsToml(artifact, ".kink")) {
            IActivationKink(routedIrm)
                .setMarketKinkParams(
                    p,
                    LinearKinkParams({
                    optimalUtilization: uint64(vm.parseTomlUint(artifact, ".kink.optimal_utilization")),
                    baseRate: uint64(vm.parseTomlUint(artifact, ".kink.base_rate")),
                    slope1: uint64(vm.parseTomlUint(artifact, ".kink.slope1")),
                    slope2: uint64(vm.parseTomlUint(artifact, ".kink.slope2"))
                })
                );
            return;
        }
        IActivationCurve(routedIrm)
            .setMarketCurveParams(
                p,
                AdaptiveCurveParams({
                curveSteepness: vm.parseTomlInt(artifact, ".curve.curve_steepness"),
                adjustmentSpeed: vm.parseTomlInt(artifact, ".curve.adjustment_speed"),
                targetUtilization: vm.parseTomlInt(artifact, ".curve.target_utilization"),
                initialRateAtTarget: vm.parseTomlInt(artifact, ".curve.initial_rate_at_target"),
                minRateAtTarget: vm.parseTomlInt(artifact, ".curve.min_rate_at_target"),
                maxRateAtTarget: vm.parseTomlInt(artifact, ".curve.max_rate_at_target"),
                maxBorrowRate: vm.parseTomlUint(artifact, ".curve.max_borrow_rate")
            })
            );
    }
}
