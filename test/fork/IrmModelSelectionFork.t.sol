// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

// Mainnet-fork mirror of the IRM model-selection scenario, run against ALREADY-DEPLOYED, ALREADY-ACTIVATED
// markets rather than a freshly deployed stack. One market per candidate: the activation motion routed
// `fork-weth-wsteth` to the protocol's `AdaptiveCurveIrm` and `fork-weth-wsteth-kinked` to the deployed
// `LinearKinkIrm`, so this suite never routes anything — it binds the market whose IRM it wants to exercise and
// reads the routed instance back off the router. The mock-token flavour, the shared `IrmScenarioBase` harness,
// and the adaptive parameter-upgrade tests stay in `test/scenario/IrmModelSelection.t.sol`; only the fork
// flavour lives here so every fork suite is under `test/fork/`.
// Not production code.

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {IrmScenarioBase} from "../scenario/IrmModelSelection.t.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

// The router and the routed candidates are the already-deployed instances, reached through the same submodule
// types the scenario builds by hand. `Id` is the IRM submodule's nested copy of the core interface
// (field-identical but a distinct type), aliased so the router's ABI unifies.
import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";
import {Id as IrmId} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {LinearKinkIrm} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkIrm.sol";
import {IOwnerManager} from "@lido-lend-irm/src/common/IOwnerManager.sol";

interface IWETHFork {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

interface IStETHFork {
    function submit(address) external payable returns (uint256);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IWstETHFork {
    function wrap(uint256) external returns (uint256);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function stEthPerToken() external view returns (uint256);
}

/// @notice Fork mirror of the simulation against real WETH/wstETH, bound to a deployed market via {ForkStack}
///         (never re-deployed). Loan funding wraps ETH to WETH; collateral funding submits ETH to Lido and wraps
///         stETH to wstETH; staking moves are simulated by mocking the real wstETH `stEthPerToken` (the scenario
///         reads it as the staking index; the market oracle reads `getStETHByWstETH`, so it deliberately does NOT
///         follow that mock). `setUp` creates the fork and reads the token addresses from the run's network
///         config.
///
///         State-robustness contract: the deployed market may carry pre-existing supply (merely dilutes
///         utilization, tolerated), but the override loud-fails on any pre-existing DEBT, which would corrupt the
///         cohort utilization/rate metrics the scenario measures. Rather than deploy its own IRM, `_deployStack`
///         binds the market, reads the routed candidate off the router, and sets the initial params on it in place
///         as its live owner — the work the local one-shot deploy path did at construction time.
contract IrmModelSelectionForkTest is IrmScenarioBase, ForkStack {
    // Populated in setUp from the run's network config.
    address internal WETH;
    address internal STETH;
    address internal WSTETH;

    function setUp() public {
        _fork();
        WETH = _ext("weth");
        STETH = _ext("stEth");
        WSTETH = _ext("wstEth");
    }

    /// @dev Bind the deployed market for the selected candidate and stand up the initial params the local deploy
    ///      set at construction time. Re-runs cleanly per test: forge re-runs `setUp` (a fresh fork) before each
    ///      `test_scenario_*`, so each test binds its own market.
    function _deployStack() internal override {
        _setupTokens();

        BoundMarket memory m = _bindMarket(_marketName());

        // Pre-existing SUPPLY only dilutes utilization and is tolerated; pre-existing DEBT breaks the cohort
        // carry/utilization math the scenario metrics are read from. Fail loudly on a dirty market.
        require(
            m.core.market(m.id).totalBorrowAssets == 0,
            string.concat(
                "IrmModelSelectionFork: market '",
                _marketName(),
                "' carries pre-existing debt; the scenario metrics need a quiet market"
            )
        );

        // Populate the harness fields the base's deploy-time `_deployStack` used to set, from the bound market.
        market = m.core;
        vault = address(m.vault);
        oracle = address(m.oracle);
        params = m.params;
        id = m.id;
        _router = m.irmRouter;

        // The cohort LTVs (7..13x leverage, position LTV = (L-1)/L) and collateral sizing are derived against the
        // scenario's `LLTV` constant. A market with a different lltv would run a mis-sized cohort, so fail loudly.
        require(params.lltv == LLTV, "IrmModelSelectionFork: market lltv != scenario LLTV; cohort sizing invalid");

        // The activation motion already routed this market; read the routed instance back rather than routing
        // again, so the suite exercises exactly the IRM the deployment bound.
        _candidate = address(IIrmRouter(_router).marketIrm(IrmId.wrap(Id.unwrap(id))));
        require(_candidate != address(0), "IrmModelSelectionFork: market has no routed IRM");
        _setInitialParams();
    }

    /// @dev The candidate's live owner (both `AdaptiveCurveIrm` and `LinearKinkIrm` are `OwnerManagerBase`, and
    ///      their param setters accept the owner). Used by `_setInitialParams` here and by the base's `_retune`.
    function _candidateAdmin() internal view override returns (address) {
        return IOwnerManager(_candidate).owner();
    }

    function _setupTokens() internal override {
        loanToken = WETH;
        collateralToken = WSTETH;
    }

    function _fundLoan(address to, uint256 amount) internal override {
        vm.deal(to, amount);
        vm.prank(to);
        IWETHFork(WETH).deposit{value: amount}();
        vm.prank(to);
        IWETHFork(WETH).approve(address(market), type(uint256).max);
    }

    function _fundCollateral(address to, uint256 amount) internal override {
        uint256 eth = amount * 13 / 10 + 1 ether;
        vm.deal(to, eth);
        vm.prank(to);
        IStETHFork(STETH).submit{value: eth}(address(0));
        uint256 st = IStETHFork(STETH).balanceOf(to);
        vm.prank(to);
        IStETHFork(STETH).approve(WSTETH, st);
        vm.prank(to);
        IWstETHFork(WSTETH).wrap(st);
        vm.prank(to);
        IWstETHFork(WSTETH).approve(address(market), type(uint256).max);
        require(IWstETHFork(WSTETH).balanceOf(to) >= amount, "fork: insufficient wstETH wrapped");
    }

    function _setStakingIndex(uint256 index) internal override {
        vm.mockCall(WSTETH, abi.encodeWithSelector(IWstETHFork.stEthPerToken.selector), abi.encode(index));
    }

    function _currentStakingIndex() internal view override returns (uint256) {
        return IWstETHFork(WSTETH).stEthPerToken();
    }

    /// @dev The market the selected candidate is routed on. One market per candidate: the activation motion
    ///      routes each market's configured `irm_artifact`, so the market name is what selects the model here.
    function _marketName() private view returns (string memory) {
        return _irmKind == IrmKind.Adaptive ? "fork-weth-wsteth" : "fork-weth-wsteth-kinked";
    }

    /// @dev Overwrite the routed candidate's params with the scenario's initial set, mirroring
    ///      `IrmScenarioBase._configureAdaptiveIrm`. The deployment sets its params; the scenario measures
    ///      against its own initial set, and year-0 normalization needs `_adaptiveCapApr` to match the
    ///      curve's `maxBorrowRate`.
    function _setInitialParams() private {
        vm.startPrank(_candidateAdmin());
        if (_irmKind == IrmKind.Adaptive) {
            _adaptiveCapApr = INITIAL_CAP_APR;
            AdaptiveCurveIrm(_candidate).setMarketCurveParams(_toIrmParams(params), _initialAdaptiveParams());
        } else {
            LinearKinkIrm(_candidate)
                .setMarketKinkParams(
                    _toIrmParams(params),
                    _kinkParams(uint256(0.005 ether) / YEAR, uint256(0.02 ether) / YEAR, uint256(0.014 ether) / YEAR)
                );
        }
        vm.stopPrank();
    }

    /// @dev The adaptive initial set (mirrors `IrmScenarioBase._configureAdaptiveIrm`, Adaptive branch).
    function _initialAdaptiveParams() private view returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: ADAPT_SPEED,
            targetUtilization: int256(TARGET_UTIL),
            initialRateAtTarget: int256(0.02 ether) / int256(YEAR),
            minRateAtTarget: int256(0.005 ether) / int256(YEAR),
            maxRateAtTarget: int256(0.0275 ether) / int256(YEAR),
            maxBorrowRate: _adaptiveCapApr / YEAR
        });
    }

    /// @dev Runs the multi-year IRM comparison scenario on the market routed to the adaptive-curve IRM.
    function test_scenario_adaptive() public {
        _run(IrmKind.Adaptive);
    }

    /// @dev Runs the multi-year IRM comparison scenario on the market routed to the linear-kink IRM.
    function test_scenario_kinked() public {
        _run(IrmKind.Kinked);
    }
}
