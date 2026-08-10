// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {LinearKinkConfig} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkConfig.sol";
import {LinearKinkIrm} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkIrm.sol";
import {LinearKinkParams} from "@lido-lend-irm/src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {IIrm} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IIrm.sol";
// The IRM ships its own nested copy of the core, so its `Id` is a distinct UDVT from `@lido-lend`'s. Same bytes32
// market hash; bridged by unwrap/wrap only where the IRM's typed API needs it.
import {Id as IrmId, MarketParams as IrmMarketParams} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

import {IOssifiableProxy} from "./IOssifiableProxy.sol";
import {MockPriceOracle} from "./Mocks.sol";
import {IrmKind, Market, Protocol} from "./Types.sol";
import {MarketActions} from "./MarketActions.sol";

/// @notice Base for Lido Lend tests. Deploys with `new` (no `vm.getCode`; the fork core and IRM are
///         0.8.36-compatible): one `LidoLend` core and one guardian registry (singletons), then any number
///         of markets on that core (`_addMarket`). Seeds a non-trivial oracle price from a logged seed.
///         Action helpers live in `MarketActions` (`using ... for Market` → `market.borrow(bob, x)`);
///         funding (`deal`) stays here because it is StdCheats, not a `vm` cheatcode.
abstract contract LidoLendSetup is Test, LidoLendDeployer {
    using MarketParamsLib for MarketParams;
    using MarketActions for Market;

    /// @dev The deployed protocol (singletons + markets), reachable from any helper or test.
    Protocol internal protocol;

    // ── Seeding (never parity, seed logged, math on non-round values) ──
    uint256 internal seed;
    uint256 internal oraclePrice; // Morpho 1e36 convention; seeded, never 1e36 parity
    bool private _seeded;

    // ── IRM selection (config-driven) ──
    IrmKind internal irmKind = IrmKind.Adaptive;
    uint256 internal fixedBorrowRate = uint256(3e16) / 365 days; // ~3%/yr, used iff irmKind == Fixed

    // ---
    // CONFIG BUILDERS
    // ---

    /// @notice Sensible default config for a market over the given tokens. `admin` and the sole guardian
    ///         are the test contract; swap fields per test before deploying.
    function _defaultConfig(address loan, address collateral, address oracleSource)
        internal
        view
        returns (DeployConfig memory cfg)
    {
        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        cfg = DeployConfig({
            admin: address(this),
            loanToken: loan,
            collateralToken: collateral,
            oracleSource: oracleSource,
            lltv: 0.8e18,
            enableSettlement: true,
            activation: CollateralActivationConfig({
                minActivationDelay: 10 minutes,
                maxActivationDelay: 2 hours,
                maxDelayInflow: 10_000 ether,
                activatingLockAmount: 0,
                activatingLockDuration: 0,
                minActivationAmount: 10 ether,
                maxGuardiansQuorumDelay: 0,
                delayPerStrike: 2 hours,
                delayPerSuspect: 0
            }),
            settlementConfig: SettlementConfig({
                sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
            }),
            guardians: guardians,
            quorum: 1,
            suspectWindow: 0,
            vaultName: "Lido Loan Vault",
            vaultSymbol: "lidoLOAN"
        });
    }

    // ---
    // SEEDING
    // ---

    /// @notice Picks the run seed (env `TEST_SEED`, else random), logs it, and derives the oracle price.
    ///         A failed run reproduces by exporting the logged `TEST_SEED`.
    function _initSeed() internal {
        if (_seeded) return;
        _seeded = true;
        seed = vm.envOr("TEST_SEED", uint256(vm.randomUint()));
        oraclePrice = _priceFromSeed(seed);
        console2.log("TEST_SEED       :", seed);
        console2.log("oraclePrice(1e36):", oraclePrice);
    }

    /// @dev Non-round collateral-per-loan price in `[3e35, 3e36)` (Morpho 1e36 scale) — never `1e36` parity.
    function _priceFromSeed(uint256 s) internal pure returns (uint256) {
        return 3e35 + (uint256(keccak256(abi.encode(s, "oracle-price"))) % 2.7e36);
    }

    // ---
    // DEPLOYMENT (via `new` — no getCode)
    // ---

    /// @notice Deploy the singletons if needed, then add a market from `cfg`. Returns the new market.
    function _deployProtocol(DeployConfig memory cfg) internal returns (Market storage) {
        if (address(protocol.core) == address(0)) {
            protocol.config = cfg;
            _deployCore(cfg.admin);
        }
        return _addMarket(cfg);
    }

    /// @notice Deploy the singleton core (base step) and mirror it to `protocol`. Each market gets its own
    ///         guardian registry in `_addMarket`.
    function _deployCore(address admin) internal override returns (address core) {
        core = super._deployCore(admin);
        protocol.core = ILidoLend(core);
        protocol.coreProxy = IOssifiableProxy(core);
    }

    /// @dev Deploy and seed this market's guardian registry (one GuardianSignals per market; base step).
    ///      `initialize` seeds the admin, guardian set, and quorum; `admin` holds DEFAULT_ADMIN_ROLE, so it
    ///      self-grants MANAGER_ROLE and sets the delay parameters. Also mirrors it to `protocol` so
    ///      single-market tests can read `protocol.guardianSignals`.
    function _deployMarketGuardian(DeployConfig memory cfg, address admin) private returns (address guardianSignals) {
        guardianSignals = _deployGuardianSignals(address(new GuardianSignals()), admin, cfg.guardians, cfg.quorum);
        GuardianSignals gs = GuardianSignals(guardianSignals);
        gs.grantRole(gs.MANAGER_ROLE(), admin);
        gs.setSuspectWindow(cfg.suspectWindow);
        protocol.guardianSignals = IGuardianSignals(guardianSignals);
        protocol.guardianSignalsProxy = IOssifiableProxy(guardianSignals);
    }

    /// @notice Deploy a market on the existing core: oracle (seeded mock by default), IRM (by `irmKind`),
    ///         controller, vault, then `createMarket` and the settlement config. Pushes it to `markets`.
    function _addMarket(DeployConfig memory cfg) internal returns (Market storage m) {
        _initSeed();
        address admin = cfg.admin;
        address core = address(protocol.core);

        address oracle = _deployOracle(cfg.oracleSource, admin);
        address irm = _deployIrm(core, admin);

        MarketParams memory params = MarketParams({
            loanToken: cfg.loanToken, collateralToken: cfg.collateralToken, oracle: oracle, irm: irm, lltv: cfg.lltv
        });
        Id id = params.id();

        // `irm` is the shared router. Deploy the chosen IRM and its immutable config, apply that config, and route
        // the market through the router (all owner-gated calls run as `admin`).
        _routeMarketIrm(irm, params, admin);

        // One GuardianSignals per market, deployed and seeded before the controller (which binds to it).
        address guardianSignals = _deployMarketGuardian(cfg, admin);

        (address controller, address controllerImpl) = _deployMarketController(cfg, core, id, guardianSignals);

        protocol.core.createMarket(params, controller, cfg.enableSettlement);

        address vault = _deployMarketVault(cfg, core, params, controller);

        // The settlement config is set in `initialize`. Grant `admin` MANAGER_ROLE for later policy changes
        // (tests act as `admin`); `admin` holds DEFAULT_ADMIN_ROLE, the MANAGER_ROLE admin.
        LidoLendMarketController c = LidoLendMarketController(controller);
        c.grantRole(c.MANAGER_ROLE(), admin);

        protocol.markets.push();
        m = protocol.markets[protocol.markets.length - 1];
        m.config = cfg;
        m.params = params;
        m.id = id;
        m.core = protocol.core;
        m.controller = ILidoLendMarketController(controller);
        m.controllerProxy = IOssifiableProxy(controller);
        m.controllerImpl = controllerImpl;
        m.guardianSignals = IGuardianSignals(guardianSignals);
        m.guardianSignalsProxy = IOssifiableProxy(guardianSignals);
        m.vault = ILidoLendERC4626(vault);
        m.vaultProxy = IOssifiableProxy(vault);
        m.oracle = IOracle(oracle);
        m.oracleProxy = IOssifiableProxy(oracle);
        m.irm = irm;
        m.loanToken = IERC20(cfg.loanToken);
        m.collateralToken = IERC20(cfg.collateralToken);
    }

    /// @dev Thin frame-splitters over the base `_deployController` / `_deployERC4626Wrapper` steps: they exist only to
    ///      keep `_addMarket`'s frame under the `via_ir = false` stack limit, not to add logic.
    function _deployMarketController(DeployConfig memory cfg, address core, Id id, address guardianSignals)
        private
        returns (address controller, address controllerImpl)
    {
        (controller, controllerImpl) =
            _deployController(core, id, guardianSignals, cfg.admin, cfg.activation, cfg.settlementConfig);
    }

    function _deployMarketVault(DeployConfig memory cfg, address core, MarketParams memory params, address controller)
        private
        returns (address)
    {
        return _deployERC4626Wrapper(core, params, controller, cfg.admin, cfg.vaultName, cfg.vaultSymbol);
    }

    /// @notice Oracle deployment: seeded mock behind a proxy. Override for a fork oracle (real feeds).
    function _deployOracle(
        address,
        /* oracleSource */
        address admin
    )
        internal
        virtual
        override
        returns (address)
    {
        address impl = address(new MockPriceOracle());
        return _behindProxy(impl, admin, abi.encodeCall(MockPriceOracle.initialize, (oraclePrice)));
    }

    /// @dev Route the market's selected IRM through the shared `router`: the adaptive kind is the deployer's
    ///      `_configureAdaptiveIrm` step; `Fixed` swaps in a flat LinearKink emulating a constant rate. All
    ///      configuration and routing calls are owner-gated, so they run pranked as `admin`.
    function _routeMarketIrm(address router, MarketParams memory params, address admin) private {
        if (irmKind == IrmKind.Fixed) {
            IrmMarketParams memory irmParams = IrmMarketParams({
                loanToken: params.loanToken,
                collateralToken: params.collateralToken,
                oracle: params.oracle,
                irm: params.irm, // == router
                lltv: params.lltv
            });
            LinearKinkIrm kink = new LinearKinkIrm(admin, admin);
            LinearKinkConfig config = new LinearKinkConfig(_kinkParams());
            vm.startPrank(admin);
            kink.applyIrmConfig(irmParams, address(config));
            IrmRouter(router).setMarketIrm(irmParams, IIrm(address(kink)));
            vm.stopPrank();
        } else {
            vm.startPrank(admin);
            _configureAdaptiveIrm(router, params, admin);
            vm.stopPrank();
        }
    }

    /// @dev Flat linear-kink curve emulating the old fixed rate: constant `fixedBorrowRate` at any utilization
    ///      (both slopes zero).
    function _kinkParams() internal view returns (LinearKinkParams memory) {
        return
            LinearKinkParams({
                optimalUtilization: uint64(0.9e18), baseRate: uint64(fixedBorrowRate), slope1: 0, slope2: 0
            });
    }

    // ---
    // ACTORS & FUNDING
    // ---

    /// @notice Deterministic labelled actor.
    function _actor(string memory name) internal returns (address a) {
        a = makeAddr(name);
    }

    /// @notice Fund `to` with `amount` of `token` (test-only mint via `deal`).
    function _fund(IERC20 token, address to, uint256 amount) internal {
        deal(address(token), to, amount);
    }
}
