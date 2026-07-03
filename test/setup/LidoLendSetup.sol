// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IMorpho, Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";

import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {IMarketConfig} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IMarketConfig.sol";
import {MarketConfig} from "@lido-lend-irm/src/adaptive-curve-irm/MarketConfig.sol";
import {FixedRateIrm} from "@lido-lend-irm/src/fixed-rate-irm/FixedRateIrm.sol";
// The IRM ships its own morpho-blue, so its `Id` is a distinct UDVT from `@lido-lend`'s. Same bytes32
// market hash; bridged by unwrap/wrap only where the IRM's typed API needs it.
import {Id as IrmId} from "@lido-lend-irm/lib/morpho-blue/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {DelayParams} from "../../src/types/GuardianSignalsTypes.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

import {IOssifiableProxy} from "./IOssifiableProxy.sol";
import {MockPriceOracle} from "./Mocks.sol";
import {IrmKind, Market, Protocol} from "./Types.sol";
import {MarketActions} from "./MarketActions.sol";

/// @notice Base for Lido Lend tests. Deploys with `new` (no `vm.getCode`; the fork core and IRM are
///         0.8.35-compatible): one `LidoLend` core and one guardian registry (singletons), then any number
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
            activation: CollateralActivationConfigParams({
                minActivationDelay: 10 minutes,
                maxActivationDelay: 2 hours,
                maxDelayInflow: 10_000 ether,
                activatingLockAmount: 0,
                activatingLockDuration: 0,
                minActivationAmount: 10 ether,
                maxGuardiansQuorumDelay: 0
            }),
            settlementConfig: SettlementConfigParams({
                sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
            }),
            guardians: guardians,
            quorum: 1,
            guardianConfig: GuardianConfigParams({
                delayPerStrike: 2 hours, delayPerSuspect: 0, maxDelay: 0, suspectWindow: 0
            }),
            vaultName: "Lido Loan Vault",
            vaultSymbol: "lidoLOAN"
        });
    }

    /// @dev Standard adaptive curve parameters (Morpho mainnet-like; pass `_validateConfig`).
    function _curveConfig() internal pure returns (IMarketConfig.Config memory) {
        return IMarketConfig.Config({
            curveSteepness: 4e18,
            adjustmentSpeed: int256(50e18) / int256(365 days),
            targetUtilization: 9e17,
            initialRateAtTarget: int256(4e16) / int256(365 days),
            minRateAtTarget: int256(1e15) / int256(365 days),
            maxRateAtTarget: int256(2e18) / int256(365 days),
            maxBorrowRate: 0
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

    /// @notice Deploy the singleton core (behind `OssifiableProxy`). Each market gets its own guardian registry
    ///         in `_addMarket`.
    function _deployCore(address admin) internal override returns (address core) {
        core = address(
            new OssifiableProxy(address(new LidoLend()), admin, abi.encodeWithSignature("initialize(address)", admin))
        );
        protocol.core = ILidoLend(core);
        protocol.coreProxy = IOssifiableProxy(core);
    }

    /// @dev Deploy and seed this market's guardian registry (one GuardianSignals per market). `initialize` seeds
    ///      the admin, guardian set, and quorum; `admin` holds DEFAULT_ADMIN_ROLE, so it self-grants
    ///      MANAGER_ROLE and sets the delay parameters. Split out of `_addMarket` to keep its frame under
    ///      the stack limit. Also mirrors it to `protocol` so single-market tests can read
    ///      `protocol.guardianSignals`.
    function _deployMarketGuardian(DeployConfig memory cfg, address admin) private returns (address guardian) {
        guardian = address(
            new OssifiableProxy(
                address(new GuardianSignals()),
                admin,
                abi.encodeWithSignature("initialize(address,address[],uint256)", admin, cfg.guardians, cfg.quorum)
            )
        );
        GuardianSignals gs = GuardianSignals(guardian);
        gs.grantRole(gs.MANAGER_ROLE(), admin);
        gs.setDelayParams(
            DelayParams({
                delayPerStrike: cfg.guardianConfig.delayPerStrike,
                delayPerSuspect: cfg.guardianConfig.delayPerSuspect,
                maxDelay: cfg.guardianConfig.maxDelay,
                suspectWindow: cfg.guardianConfig.suspectWindow
            })
        );
        protocol.guardianSignals = IGuardianSignals(guardian);
        protocol.guardianSignalsProxy = IOssifiableProxy(guardian);
    }

    /// @notice Deploy a market on the existing core: oracle (seeded mock by default), IRM (by `irmKind`),
    ///         controller, vault, then `createMarket` and the settlement config. Pushes it to `markets`.
    function _addMarket(DeployConfig memory cfg) internal returns (Market storage m) {
        _initSeed();
        address admin = cfg.admin;
        address core = address(protocol.core);

        address oracle = _deployOracle(cfg.oracleSource, admin);
        address irm = _deployMarketIrm(core, admin);

        MarketParams memory params = MarketParams({
            loanToken: cfg.loanToken, collateralToken: cfg.collateralToken, oracle: oracle, irm: irm, lltv: cfg.lltv
        });
        Id id = params.id();

        // The IRM needs its per-market config set before the market is used. Fixed: a constant rate. Adaptive:
        // an immutable `MarketConfig` holding the curve params, pointed at by the owner via `setConfig`.
        if (irmKind == IrmKind.Fixed) {
            FixedRateIrm(irm).setBorrowRate(IrmId.wrap(Id.unwrap(id)), fixedBorrowRate);
        } else {
            MarketConfig marketConfig = new MarketConfig(_curveConfig());
            AdaptiveCurveIrm(irm).setConfig(IrmId.wrap(Id.unwrap(id)), marketConfig);
        }

        // One GuardianSignals per market, deployed and seeded before the controller (which binds to it).
        address guardian = _deployMarketGuardian(cfg, admin);

        (address controllerImpl, address controller) = _deployController(cfg, core, admin, id, guardian);

        protocol.core.createMarket(params, controller, cfg.enableSettlement);

        address vault = _deployVault(cfg, core, admin, params, controller);

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
        m.guardianSignals = IGuardianSignals(guardian);
        m.guardianSignalsProxy = IOssifiableProxy(guardian);
        m.vault = ILidoLendERC4626(vault);
        m.vaultProxy = IOssifiableProxy(vault);
        m.oracle = IOracle(oracle);
        m.oracleProxy = IOssifiableProxy(oracle);
        m.irm = irm;
        m.loanToken = IERC20(cfg.loanToken);
        m.collateralToken = IERC20(cfg.collateralToken);
    }

    /// @dev Deploy the controller impl + `OssifiableProxy`, running `initialize`. Split out of `_addMarket` to
    ///      keep its frame under the stack limit.
    function _deployController(DeployConfig memory cfg, address core, address admin, Id id, address guardian)
        private
        returns (address controllerImpl, address controller)
    {
        controllerImpl = address(new LidoLendMarketController(IMorpho(core)));
        controller = address(
            new OssifiableProxy(
                controllerImpl,
                admin,
                abi.encodeWithSignature(
                    "initialize(bytes32,address,address,(uint40,uint40,uint128,uint128,uint40,uint128,uint40),(uint16,uint96,uint96,uint16))",
                    Id.unwrap(id),
                    admin,
                    guardian,
                    cfg.activation,
                    cfg.settlementConfig
                )
            )
        );
    }

    /// @dev Deploy the vault impl + `OssifiableProxy`, running `initialize`. Split out of `_addMarket` to keep
    ///      its frame under the stack limit.
    function _deployVault(
        DeployConfig memory cfg,
        address core,
        address admin,
        MarketParams memory params,
        address controller
    ) private returns (address vault) {
        vault = address(
            new OssifiableProxy(
                address(new LidoLendERC4626(core)),
                admin,
                abi.encodeWithSignature(
                    "initialize((address,address,address,address,uint256),address,string,string)",
                    params,
                    controller,
                    cfg.vaultName,
                    cfg.vaultSymbol
                )
            )
        );
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
        return address(new OssifiableProxy(impl, admin, abi.encodeWithSignature("initialize(uint256)", oraclePrice)));
    }

    /// @dev IRM picked by `irmKind`. Both flavours have their per-market config set after the id is known
    ///      (Adaptive's curve via `setConfig`, Fixed's rate via `setBorrowRate`).
    function _deployMarketIrm(address core, address owner) internal returns (address) {
        if (irmKind == IrmKind.Fixed) return address(new FixedRateIrm());
        return address(new AdaptiveCurveIrm(core, owner));
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
