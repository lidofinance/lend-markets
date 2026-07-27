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

// --- Minimal write surfaces, mirroring test/acceptance/AcceptanceBase.t.sol. The IRM submodule's setters take
//     its own nested `MarketParams`, but that type is ABI-identical to the core's, so the core `MarketParams`
//     matches; `setMarketIrm` takes the IRM as a plain `address` for the same reason. The CircuitBreaker pins
//     solc 0.8.34 and cannot be imported here, so it too is reached through a local interface. ---

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

/// @notice Replays the `LidoLendActivateMarket` EasyTrack motion for every market the deploy config lists,
///         binding the inert markets recorded under `deployed/<RUN>/` and broadcasting as the
///         `EVMScriptExecutor`. Idempotent: an already-activated market (core `market(id).lastUpdate != 0`) is
///         skipped with a log line, so a run can be resumed.
/// @dev Draft, not production-ready — a real activation is the governance motion, not this script. Model of
///      that motion, in the mandatory order (an unset IRM reverts on its first `borrowRate` ping, so params
///      must be set before `createMarket`):
///        1. set the routed model's per-market params — `setMarketCurveParams` or `setMarketKinkParams`
///        2. `IrmRouter.setMarketIrm(params, routedIrm)`
///        3. `LidoLendOwner.createMarket(params, controller, true)`
///        4. `CircuitBreaker.registerPauser(controller, committee)`
///        5. exit-book allowances (`setMarketAllowed` / `setVaultAllowed`) — ONLY when the run has exit books
///      Every input comes from the market's immutable artifact, never from the config: the artifact is the
///      reviewed record, and it is what `test/acceptance/` asserts the live stack against. `params` is
///      rebuilt from it and cross-checked against the recorded id, so a config/artifact disagreement fails
///      loudly.
///
/// Usage (as the executor, via anvil auto-impersonation):
///   ARTIFACTS_DIR=<run> forge script script/ActivateMarkets.s.sol --sig 'run(string)' <config> \
///     --rpc-url "$RPC_URL" --unlocked --sender "$EXECUTOR" --broadcast
contract ActivateMarkets is Script {
    using MarketParamsLib for MarketParams;

    error WrongSender(address expected, address actual);
    error MarketIdMismatch(string name, bytes32 fromParams, bytes32 fromArtifact);
    error UnknownIrmArtifact(string name, string artifactRef);

    /// @dev Shared backbone addresses and activation-time inputs, resolved once in `run`.
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
        // The registered pauser is a runtime motion choice (a real motion routes an emergency committee); the
        // Agent stands in for it here. The fork suites never read it.
        bb.pauserCommittee = vm.parseTomlAddress(protocol, ".protocol.agent");

        string memory exitBooksPath = ProtocolConfigFile.exitBooksPath();
        if (vm.exists(exitBooksPath)) {
            string memory exitBooks = vm.readFile(exitBooksPath);
            bb.hasExitBooks = true;
            bb.morphoBook = vm.parseTomlAddress(exitBooks, ".exit_books.morpho");
            bb.erc4626Book = vm.parseTomlAddress(exitBooks, ".exit_books.erc4626");
        }

        // The motion runs as the executor; the wrapper points `--sender` at it. Fail loudly when the
        // broadcaster is not the router's manager, i.e. not the real executor.
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

        // Idempotency: a bound market has a non-zero interest clock. Skip cleanly so a run can be resumed.
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

    /// @dev The model this market names: the backbone adaptive-curve singleton from `protocol.toml`, or the
    ///      instance recorded under `irms/<name>.toml`.
    function _routedIrm(string memory name, string memory artifact) internal view returns (address irm) {
        string memory artifactRef = vm.parseTomlString(artifact, ".market.irm_artifact");
        if (IrmConfigFile.isAdaptiveCurve(artifactRef)) return bb.adaptiveCurveIrm;
        irm = IrmConfigFile.readDeployed(artifactRef);
        if (irm == address(0)) revert UnknownIrmArtifact(name, artifactRef);
    }

    /// @dev Set the per-market params of whichever model is routed, from the section the artifact recorded for
    ///      it. A market artifact carries `[curve]` or `[kink]`, never both.
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
