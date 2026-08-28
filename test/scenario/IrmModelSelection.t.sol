// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

// IRM model-selection harness.
// The adaptive candidate is the real `AdaptiveCurveIrm` from the `lido-lend-irm` submodule; the pegged and kinked
// candidates, the mock tokens, the scenario harness (mock + mainnet-fork token sources), and the adaptive
// parameter-upgrade tests live in this file. Not production code.

import {Test, console2} from "forge-std/Test.sol";
import {IIrm} from "@lido-lend/src/interfaces/IIrm.sol";
import {Id, MarketParams, Market} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

// The adaptive and kinked candidates are the real `AdaptiveCurveIrm` / `LinearKinkIrm` from the `lido-lend-irm`
// submodule, reached through the `IrmRouter` a market's immutable `irm` points at. They carry their own
// `IIrm` / `MarketParams` / `Id` types (its own nested copy of the core) that do not unify with the core's, so
// those are imported under `Irm*` aliases and the ABI-identical structs are converted at the call boundary.
import {AdaptiveCurveConfig} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {LinearKinkConfig} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkConfig.sol";
import {LinearKinkIrm} from "@lido-lend-irm/src/linear-kink-irm/LinearKinkIrm.sol";
import {LinearKinkParams} from "@lido-lend-irm/src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {IIrm as IrmIIrm} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IIrm.sol";
import {MarketParams as IrmMarketParams} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

// Adaptive-curve math, reused by the local CapD prototype. These libraries are pragma ^0.8.0 (not strict
// 0.8.19 like AdaptiveCurveIrm), so they share this 0.8.36 compilation unit.
import {MathLib as MorphoMathLib} from "@lido-lend/src/libraries/MathLib.sol";
import {MathLib as IrmMathLib, WAD_INT} from "@lido-lend-irm/src/adaptive-curve-irm/libraries/MathLib.sol";
import {ExpLib} from "@lido-lend-irm/src/adaptive-curve-irm/libraries/ExpLib.sol";
import {UtilsLib} from "@lido-lend-irm/src/adaptive-curve-irm/libraries/UtilsLib.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

/// @dev Minimal view onto the adaptive IRM's `rateAtTarget`, declared locally so it can be read with the core's
///      `Id` type (the submodule's `AdaptiveCurveIrm` carries its own `Id` that does not unify with the core's).
interface IRateAtTargetLike {
    function rateAtTarget(Id id) external view returns (int256);
}

// ==========================================================================================================
// Candidate IRMs. The adaptive and kinked candidates are the real `AdaptiveCurveIrm` / `LinearKinkIrm` (see
// above). The pegged and capD candidates are local variants declared here rather than in the submodule.
// ==========================================================================================================

/// @dev Source of the collateral's accumulating exchange rate (wstETH's `stEthPerToken`).
interface IRateSource {
    function stEthPerToken() external view returns (uint256);
}

/// @notice Hard staking-peg IRM: measures realized staking APR from the growth of the collateral's
///         `stEthPerToken`, then sets `borrow = stakingAPR - MARGIN` at target utilization and
///         `MAX_MULTIPLE * stakingAPR` at 100% (a hard cap that tracks staking). `WINDOW > 0` measures over a
///         lookback (a ring-buffer TWAP) so per-report noise is absorbed.
contract StakingPeggedIrm is IIrm {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant CARD = 8;

    error NotRouter();
    error ZeroAddress();

    // Router-routed: the `IrmRouter` probes and delegates `borrowRate`, so the gate is the router, not the core.
    address public immutable ROUTER;
    IRateSource public immutable RATE_SOURCE;
    uint256 public immutable TARGET_UTIL;
    uint256 public immutable MARGIN;
    uint256 public immutable MAX_MULTIPLE;
    uint256 public immutable WINDOW;
    uint256 public immutable SAMPLE_GAP;

    uint256 public stakingApr;

    uint256 internal _lastRate;
    uint64 internal _lastTs;

    struct Sample {
        uint64 ts;
        uint192 rate;
    }

    Sample[CARD] internal _ring;
    uint256 internal _head;

    constructor(
        address router,
        address rateSource,
        uint256 targetUtil,
        uint256 margin,
        uint256 maxMultiple,
        uint256 window
    ) {
        if (router == address(0) || rateSource == address(0)) revert ZeroAddress();
        ROUTER = router;
        RATE_SOURCE = IRateSource(rateSource);
        TARGET_UTIL = targetUtil;
        MARGIN = margin;
        MAX_MULTIPLE = maxMultiple;
        WINDOW = window;
        SAMPLE_GAP = window / CARD;

        uint256 r = IRateSource(rateSource).stEthPerToken();
        _lastRate = r;
        _lastTs = uint64(block.timestamp);
        _ring[0] = Sample({ts: uint64(block.timestamp), rate: uint192(r)});
    }

    function borrowRateView(MarketParams memory, Market memory market) external view returns (uint256) {
        return _rate(_peekApr(), market);
    }

    function borrowRate(MarketParams memory, Market memory market) external returns (uint256) {
        if (msg.sender != ROUTER) revert NotRouter();
        return _rate(_updateApr(), market);
    }

    function _updateApr() internal returns (uint256) {
        return WINDOW == 0 ? _updateSinglePeriod() : _updateWindowed();
    }

    function _peekApr() internal view returns (uint256) {
        return WINDOW == 0 ? _peekSinglePeriod() : _windowApr(RATE_SOURCE.stEthPerToken(), block.timestamp);
    }

    function _updateSinglePeriod() internal returns (uint256) {
        uint256 current = RATE_SOURCE.stEthPerToken();
        uint256 elapsed = block.timestamp - _lastTs;
        if (elapsed != 0 && _lastRate != 0 && current > _lastRate) {
            stakingApr = (current - _lastRate) * WAD / _lastRate / elapsed;
            _lastRate = current;
            _lastTs = uint64(block.timestamp);
        }
        return stakingApr;
    }

    function _peekSinglePeriod() internal view returns (uint256) {
        uint256 current = RATE_SOURCE.stEthPerToken();
        uint256 elapsed = block.timestamp - _lastTs;
        if (elapsed != 0 && _lastRate != 0 && current > _lastRate) {
            return (current - _lastRate) * WAD / _lastRate / elapsed;
        }
        return stakingApr;
    }

    function _updateWindowed() internal returns (uint256) {
        uint256 current = RATE_SOURCE.stEthPerToken();
        uint256 nowTs = block.timestamp;
        Sample memory newest = _ring[_head];
        if (current > newest.rate && nowTs - newest.ts >= SAMPLE_GAP) {
            _head = (_head + 1) % CARD;
            _ring[_head] = Sample({ts: uint64(nowTs), rate: uint192(current)});
        }
        stakingApr = _windowApr(current, nowTs);
        return stakingApr;
    }

    function _windowApr(uint256 current, uint256 nowTs) internal view returns (uint256) {
        uint256 cutoff = nowTs > WINDOW ? nowTs - WINDOW : 0;
        Sample memory anchor;
        for (uint256 i; i < CARD; ++i) {
            Sample memory s = _ring[(_head + 1 + i) % CARD];
            if (s.ts != 0 && s.ts >= cutoff) {
                anchor = s;
                break;
            }
        }
        if (anchor.ts == 0 || nowTs <= anchor.ts || current <= anchor.rate) return stakingApr;
        return (current - anchor.rate) * WAD / anchor.rate / (nowTs - anchor.ts);
    }

    function _rate(uint256 apr, Market memory market) internal view returns (uint256) {
        uint256 u =
            market.totalSupplyAssets == 0 ? 0 : uint256(market.totalBorrowAssets) * WAD / market.totalSupplyAssets;
        uint256 atTarget = apr > MARGIN ? apr - MARGIN : 0;
        if (u >= TARGET_UTIL) {
            uint256 atMax = apr * MAX_MULTIPLE / WAD;
            return atTarget + (atMax - atTarget) * (u - TARGET_UTIL) / (WAD - TARGET_UTIL);
        }
        return atTarget * u / TARGET_UTIL;
    }
}

/// @notice capD: adaptive-curve IRM with a dynamic, staking-pegged ceiling.
///         The curve and `rateAtTarget` adaptation are Morpho's adaptive curve (steepness `C`); on
///         top, both the charged rate and the adapting `rateAtTarget` are capped at `k * stakingAPR`. Staking
///         APR is measured from the collateral's `stEthPerToken` growth over a lookback window (ring-buffer
///         TWAP), as in `StakingPeggedIrm`. Unlike a static `MAX_BORROW_RATE`, the ceiling tracks the yield
///         down, so `rateAtTarget` cannot stay wound up ("hangover") when staking falls.
contract CapDIrm is IIrm {
    using IrmMathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MarketParamsLib for MarketParams;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant CARD = 8;

    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    error NotRouter();
    error ZeroAddress();
    error InvalidParams();

    struct Config {
        int256 curveSteepness; // WAD, >= 1e18
        int256 adjustmentSpeed; // WAD per second, >= 0
        int256 targetUtilization; // WAD, in (0, 1e18)
        int256 initialRateAtTarget; // WAD per second
        int256 minRateAtTarget; // WAD per second, > 0
        int256 maxRateAtTarget; // WAD per second, >= min (static upper bound; the dynamic k*sd cap sits under it)
        int256 capMultiple; // WAD, k >= 1e18: ceiling = k * stakingAPR
        uint256 window; // staking-APR lookback (seconds), > 0
    }

    // Router-routed: the `IrmRouter` probes and delegates `borrowRate`, so the gate is the router, not the core.
    address public immutable ROUTER;
    IRateSource public immutable RATE_SOURCE;
    int256 public immutable CURVE_STEEPNESS;
    int256 public immutable ADJUSTMENT_SPEED;
    int256 public immutable TARGET_UTILIZATION;
    int256 public immutable INITIAL_RATE_AT_TARGET;
    int256 public immutable MIN_RATE_AT_TARGET;
    int256 public immutable MAX_RATE_AT_TARGET;
    int256 public immutable CAP_MULTIPLE;
    uint256 public immutable WINDOW;
    uint256 public immutable SAMPLE_GAP;

    mapping(Id => int256) public rateAtTarget;

    // Staking-APR measurement (ring-buffer TWAP of stEthPerToken growth), mirroring StakingPeggedIrm.
    uint256 public stakingApr; // per-second WAD

    struct Sample {
        uint64 ts;
        uint192 rate;
    }

    Sample[CARD] internal _ring;
    uint256 internal _head;

    constructor(address router, address rateSource, Config memory cfg) {
        if (router == address(0) || rateSource == address(0)) revert ZeroAddress();
        if (
            cfg.curveSteepness < WAD_INT || cfg.adjustmentSpeed < 0 || cfg.targetUtilization <= 0
                || cfg.targetUtilization >= WAD_INT || cfg.minRateAtTarget <= 0
                || cfg.maxRateAtTarget < cfg.minRateAtTarget || cfg.capMultiple < WAD_INT || cfg.window == 0
        ) revert InvalidParams();

        ROUTER = router;
        RATE_SOURCE = IRateSource(rateSource);
        CURVE_STEEPNESS = cfg.curveSteepness;
        ADJUSTMENT_SPEED = cfg.adjustmentSpeed;
        TARGET_UTILIZATION = cfg.targetUtilization;
        INITIAL_RATE_AT_TARGET = cfg.initialRateAtTarget;
        MIN_RATE_AT_TARGET = cfg.minRateAtTarget;
        MAX_RATE_AT_TARGET = cfg.maxRateAtTarget;
        CAP_MULTIPLE = cfg.capMultiple;
        WINDOW = cfg.window;
        SAMPLE_GAP = cfg.window / CARD;

        _ring[0] = Sample({ts: uint64(block.timestamp), rate: uint192(IRateSource(rateSource).stEthPerToken())});
    }

    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market, _peekStakingApr());
        return avgRate;
    }

    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
        if (msg.sender != ROUTER) revert NotRouter();
        Id id = marketParams.id();
        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market, _updateStakingApr());
        rateAtTarget[id] = endRateAtTarget;
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));
        return avgRate;
    }

    /// @dev Adaptive curve with the dynamic `k * stakingAPR` ceiling on both `rateAtTarget` and the charged rate.
    function _borrowRate(Id id, Market memory market, uint256 sd) private view returns (uint256, int256) {
        int256 capRate = CAP_MULTIPLE.wMulToZero(int256(sd)); // k * stakingAPR (per-second WAD)
        int256 dynMax = capRate < MAX_RATE_AT_TARGET ? capRate : MAX_RATE_AT_TARGET;

        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);
        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD_INT - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = (utilization - TARGET_UTILIZATION).wDivToZero(errNormFactor);

        int256 startRateAtTarget = rateAtTarget[id];
        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            // First interaction: seed at the initial rate, clamped under the dynamic ceiling.
            avgRateAtTarget = INITIAL_RATE_AT_TARGET.bound(MIN_RATE_AT_TARGET, dynMax);
            endRateAtTarget = avgRateAtTarget;
        } else {
            int256 speed = ADJUSTMENT_SPEED.wMulToZero(err);
            int256 elapsed = int256(block.timestamp - market.lastUpdate);
            int256 linearAdaptation = speed * elapsed;
            // _newRateAtTarget re-clamps to dynMax every step, so the ceiling rides the yield down even when
            // linearAdaptation is small (no hangover).
            endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation, dynMax);
            int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2, dynMax);
            avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
        }

        uint256 rate = uint256(_curve(avgRateAtTarget, err));
        if (rate > uint256(capRate)) rate = uint256(capRate); // charged rate clipped at k * stakingAPR
        return (rate, endRateAtTarget);
    }

    function _curve(int256 _rateAtTarget, int256 err) private view returns (int256) {
        int256 coeff = err < 0 ? WAD_INT - WAD_INT.wDivToZero(CURVE_STEEPNESS) : CURVE_STEEPNESS - WAD_INT;
        return (coeff.wMulToZero(err) + WAD_INT).wMulToZero(_rateAtTarget);
    }

    function _newRateAtTarget(int256 start, int256 linearAdaptation, int256 dynMax) private view returns (int256) {
        return start.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(MIN_RATE_AT_TARGET, dynMax);
    }

    function _updateStakingApr() internal returns (uint256) {
        uint256 current = RATE_SOURCE.stEthPerToken();
        uint256 nowTs = block.timestamp;
        Sample memory newest = _ring[_head];
        if (current > newest.rate && nowTs - newest.ts >= SAMPLE_GAP) {
            _head = (_head + 1) % CARD;
            _ring[_head] = Sample({ts: uint64(nowTs), rate: uint192(current)});
        }
        stakingApr = _windowApr(current, nowTs);
        return stakingApr;
    }

    function _peekStakingApr() internal view returns (uint256) {
        return _windowApr(RATE_SOURCE.stEthPerToken(), block.timestamp);
    }

    function _windowApr(uint256 current, uint256 nowTs) internal view returns (uint256) {
        uint256 cutoff = nowTs > WINDOW ? nowTs - WINDOW : 0;
        Sample memory anchor;
        for (uint256 i; i < CARD; ++i) {
            Sample memory s = _ring[(_head + 1 + i) % CARD];
            if (s.ts != 0 && s.ts >= cutoff) {
                anchor = s;
                break;
            }
        }
        if (anchor.ts == 0 || nowTs <= anchor.ts || current <= anchor.rate) return stakingApr;
        return (current - anchor.rate) * WAD / anchor.rate / (nowTs - anchor.ts);
    }
}

// ==========================================================================================================
// Mock tokens (no-fork runs). Self-contained (no OpenZeppelin, which pins ^0.8.20) so they compile at 0.8.19.
// ==========================================================================================================

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockWstETH is MockERC20 {
    uint256 public stEthPerToken = 1e18;

    constructor() MockERC20("Mock wstETH", "mwstETH") {}

    function setStEthPerToken(uint256 value) external {
        stEthPerToken = value;
    }

    /// @dev Mirrors real wstETH: stETH backing `wstETHAmount` wstETH. `WstEthRateOracle.price()` queries this.
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256) {
        return wstETHAmount * stEthPerToken / 1e18;
    }
}

// ==========================================================================================================
// Scenario harness: one scenario, three IRMs, on a real ILidoLend + controller + vault instance.
// ==========================================================================================================

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

/// @notice A lender supplies, a heterogeneous set of loopers run real leveraged positions (supplyCollateral +
///         borrow/repay) with different LTVs, sizes, carry thresholds and reaction delays, so utilization and
///         the borrow rate come from the live market. Staking is driven through the collateral's
///         `stEthPerToken` index over a multi-year decline. The path includes two lender-driven utilization
///         spikes and one sudden staking step-down (the issuance-change stress). Once a year the scenario retunes
///         the IRM params from the trailing-year average APR (adaptive and kinked by applying a new config; the peg
///         needs none). Concrete subclasses wire the token/staking source (mock or mainnet fork); the IRM is selected
///         per test through `_irmKind`.
abstract contract IrmScenarioBase is Test, LidoLendDeployer {
    using SharesMathLib for uint256;

    enum IrmKind {
        Adaptive,
        Pegged,
        Kinked,
        CapD
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant LLTV = 0.945 ether; // realistic wstETH/WETH liquidation LTV (low-risk pair, high LLTV)
    uint256 internal constant TARGET_UTIL = 0.9 ether;
    uint256 internal constant SUPPLY_AMT = 1_000 ether;
    // Borrow ceiling for the adaptive IRM: 2.75% at start (matching the initial max rateAtTarget), then each
    // yearly retune re-derives it as 1.25x the trailing-year average APR.
    uint256 internal constant CAP_MULT_BPS = 12_500; // 1.25x in basis points
    uint256 internal constant INITIAL_CAP_APR = 0.0275 ether;
    // Adaptive adjustment speed (per year). Higher = the curve chases utilization faster (shorter above-staking tail,
    // but more overshoot/ringing). Morpho's upstream default is 50/yr.
    int256 internal constant ADAPT_SPEED = int256(20 ether) / int256(YEAR);

    uint256 internal constant N_BORROWERS = 12;
    uint256 internal constant LEV_STEP = 0.02 ether;
    uint256 internal constant ACT_CADENCE = 2; // a borrower re-evaluates only every Nth step, offset by its phase

    uint256 internal constant DECLINE_DAYS = 730; // staking declines 2.6% -> 1.25% over this, then holds flat
    uint256 internal constant ISSUANCE_STEP_DAY = 900; // sudden issuance cut: staking steps down here
    uint256 internal constant SCEN_DAYS = 1200;
    uint256 internal constant STEP_DAYS = 2;
    uint256 internal constant LOG_EVERY = 15;

    uint256 internal constant N_LENDERS = 10; // distributed lender base (vs one whale); slices sum to SUPPLY_AMT

    IrmKind internal _irmKind;

    address internal loanToken;
    address internal collateralToken;
    ILidoLend internal market;
    address internal vault;
    address internal oracle;
    MarketParams internal params;
    Id internal id;

    address[] internal _borrowers;
    uint256[] internal _maxLev; // target position LTV (debt/collateral), clustered near LLTV
    uint256[] internal _curLev; // current LTV, ramps toward _maxLev
    uint256[] internal _margin;
    uint256[] internal _delay;
    uint256[] internal _wait;
    uint256[] internal _lev; // target leverage multiple (WAD), 7..13x; position LTV = (L-1)/L
    uint256[] internal _phase; // step-phase offset so borrowers do not all act on the same step
    int256[] internal _pnl; // accumulated net carry P&L (value terms): shows leverage-scaled gains/losses
    int256[] internal _loss; // sum of the negative-carry periods only (the crunch bleed), leverage-scaled
    uint256[] internal _equity0; // committed capital (equity at full target leverage), a stable P&L denominator

    address[] internal _lenders;
    uint256[] internal _lenderPulled; // assets each lender withdrew in the current spike, returned gradually

    uint256 internal _spikeWithdrawn;
    uint256 internal _spikeResupplyChunk;

    address internal _router; // the market's `irm`: routes to the model below, which the yearly retune re-tunes
    address internal _candidate; // the routed IRM under test (adaptive/kinked/pegged/capD), re-tuned in place
    uint256 internal _lastRetuneYear; // last whole year the retune fired
    uint256 internal _adaptiveCapApr; // the live ceiling (annual WAD): 1.5x initial estimate, re-derived each retune

    struct Metrics {
        uint256 daysUnprofitable;
        uint256 peakBorrowVsStakingBps;
        uint256 minBorrow;
        uint256 maxBorrow;
        uint256 minUtil;
        uint256 finalUtil;
    }

    // --- token/staking source: implemented by the mock and fork subclasses ---
    function _setupTokens() internal virtual;
    function _fundLoan(address to, uint256 amount) internal virtual;
    function _fundCollateral(address to, uint256 amount) internal virtual;
    function _setStakingIndex(uint256 index) internal virtual;
    function _currentStakingIndex() internal view virtual returns (uint256);

    // --- run one IRM through the scenario ---
    function _run(IrmKind kind) internal {
        _irmKind = kind;
        _deployStack();
        Metrics memory r = _runScenario();
        _logMetrics(r);
        _logBorrowerPnl();
        assertGt(r.maxBorrow, 0, "observed a live borrow rate");
    }

    function _label() internal view returns (string memory) {
        if (_irmKind == IrmKind.Adaptive) return "ADAPTIVE";
        if (_irmKind == IrmKind.Pegged) return "PEGGED";
        if (_irmKind == IrmKind.CapD) return "CAPD";
        return "KINKED";
    }

    /// @dev Account authorized to apply a replacement config to the routed IRM.
    function _candidateAdmin() internal view virtual returns (address) {
        return address(this);
    }

    /// @dev Attach the IRM under test behind the market's `router` (`_deployIrm` deployed the router; the market's
    ///      immutable `irm` points at it). The peg and capD read staking directly (their dynamic ceiling tracks the
    ///      yield) and need no retune; adaptive and kinked are re-tuned yearly with newly deployed immutable configs.
    ///      Initial params are scenario inputs; yearly `_retune` derives params from the trailing-year average
    ///      APR. Runs before `createMarket`, so `setMarketIrm` probes the model on a fresh (zero) market.
    function _configureAdaptiveIrm(address router, MarketParams memory params, address owner)
        internal
        override
        returns (address)
    {
        _router = router;
        IrmMarketParams memory irmParams = _toIrmParams(params);
        IrmIIrm candidate;

        if (_irmKind == IrmKind.Pegged) {
            candidate = IrmIIrm(
                address(
                    new StakingPeggedIrm(
                        router, collateralToken, TARGET_UTIL, uint256(0.001 ether) / YEAR, 1.5 ether, 14 days
                    )
                )
            );
        } else if (_irmKind == IrmKind.CapD) {
            // Adaptive-curve initial set + k = 1.25x (matching CAP_MULT_BPS); the ceiling is the dynamic k*staking.
            candidate = IrmIIrm(
                address(
                    new CapDIrm(
                        router,
                        collateralToken,
                        CapDIrm.Config({
                            curveSteepness: int256(1.5 ether),
                            adjustmentSpeed: ADAPT_SPEED,
                            targetUtilization: int256(TARGET_UTIL),
                            initialRateAtTarget: int256(0.02 ether) / int256(YEAR),
                            minRateAtTarget: int256(0.005 ether) / int256(YEAR),
                            maxRateAtTarget: int256(0.0275 ether) / int256(YEAR),
                            capMultiple: int256(1.25 ether),
                            window: 14 days
                        })
                    )
                )
            );
        } else if (_irmKind == IrmKind.Adaptive) {
            // initial set for ~2.6% staking
            _adaptiveCapApr = INITIAL_CAP_APR;
            AdaptiveCurveIrm adaptive = new AdaptiveCurveIrm(router, owner, owner);
            AdaptiveCurveConfig config = new AdaptiveCurveConfig(
                AdaptiveCurveParams({
                    curveSteepness: int256(1.5 ether),
                    adjustmentSpeed: ADAPT_SPEED,
                    targetUtilization: int256(TARGET_UTIL),
                    initialRateAtTarget: int256(0.02 ether) / int256(YEAR),
                    minRateAtTarget: int256(0.005 ether) / int256(YEAR),
                    maxRateAtTarget: int256(0.0275 ether) / int256(YEAR),
                    maxBorrowRate: _adaptiveCapApr / YEAR
                })
            );
            adaptive.applyIrmConfig(irmParams, address(config));
            candidate = IrmIIrm(address(adaptive));
        } else {
            LinearKinkIrm kink = new LinearKinkIrm(owner, owner);
            LinearKinkConfig config = new LinearKinkConfig(
                _kinkParams(uint256(0.005 ether) / YEAR, uint256(0.02 ether) / YEAR, uint256(0.014 ether) / YEAR)
            );
            kink.applyIrmConfig(irmParams, address(config));
            candidate = IrmIIrm(address(kink));
        }

        _candidate = address(candidate);
        IrmRouter(router).setMarketIrm(irmParams, candidate);
        return _candidate;
    }

    /// @dev Yearly retune: rebuild the params from the trailing-year average APR, deploy a config, and apply it
    ///      to the routed IRM (adaptive/kinked). The routed instance keeps its `rateAtTarget`, so the rate resumes
    ///      from the frozen state rather than the initial rate. Pegged and capD auto-track, so this is a no-op.
    function _retune(uint256 avgApr) internal {
        IrmMarketParams memory irmParams = _toIrmParams(params);
        if (_irmKind == IrmKind.Adaptive) {
            // light touch: the bounds move with the APR (initial is re-derived too, but it is inert once the
            // market's rateAtTarget is set); the rate self-adapts via utilization between retunes
            _adaptiveCapApr = avgApr * CAP_MULT_BPS / 10_000;
            AdaptiveCurveConfig config = new AdaptiveCurveConfig(_adaptiveCfgFor(avgApr));
            vm.prank(_candidateAdmin());
            AdaptiveCurveIrm(_candidate).applyIrmConfig(irmParams, address(config));
        } else if (_irmKind == IrmKind.Kinked) {
            // re-center the whole curve: at target ~0.9*avgApr, at 100% ~1.5*avgApr
            LinearKinkConfig config =
                new LinearKinkConfig(_kinkParams(avgApr / 5 / YEAR, avgApr * 7 / 10 / YEAR, avgApr * 6 / 10 / YEAR));
            vm.prank(_candidateAdmin());
            LinearKinkIrm(_candidate).applyIrmConfig(irmParams, address(config));
        }
    }

    function _adaptiveCfgFor(uint256 avgApr) internal view returns (AdaptiveCurveParams memory) {
        // floor keeps headroom below avgApr; rateAtTarget persists. Each retune re-derives the borrow ceiling on the
        // same trailing-avg basis as the bounds: 1.25x the average APR.
        return AdaptiveCurveParams({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: ADAPT_SPEED,
            targetUtilization: int256(TARGET_UTIL),
            initialRateAtTarget: int256(avgApr * 8 / 10) / int256(YEAR),
            minRateAtTarget: int256(avgApr / 4) / int256(YEAR),
            maxRateAtTarget: int256(avgApr) / int256(YEAR),
            maxBorrowRate: avgApr * CAP_MULT_BPS / 10_000 / YEAR
        });
    }

    /// @dev Kinked initial/retune params: flat intercept `base`, `slope1` up to the target-utilization kink, `slope2`
    ///      above it. Rates are per-second WAD, narrowed to the config struct's `uint64`.
    function _kinkParams(uint256 base, uint256 slope1, uint256 slope2) internal pure returns (LinearKinkParams memory) {
        return LinearKinkParams({
            optimalUtilization: uint64(TARGET_UTIL),
            baseRate: uint64(base),
            slope1: uint64(slope1),
            slope2: uint64(slope2)
        });
    }

    function _toIrmParams(MarketParams memory p) internal pure returns (IrmMarketParams memory) {
        return IrmMarketParams({
            loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv
        });
    }

    /// @dev Average of the staking schedule over the trailing year, the figure each retune uses.
    function _trailingAvgApr(uint256 dayIndex) internal pure returns (uint256) {
        uint256 start = dayIndex >= 365 ? dayIndex - 365 : 0;
        uint256 sum;
        uint256 n;
        for (uint256 d = start; d < dayIndex; d += STEP_DAYS) {
            sum += _stakingApr(d);
            ++n;
        }
        return n == 0 ? _stakingApr(dayIndex) : sum / n;
    }

    function _deployStack() internal virtual {
        _setupTokens();
        address[] memory guardians = new address[](1);
        guardians[0] = address(this);

        Deployed memory d = _deployForkStack(
            DeployConfig({
                admin: address(this),
                loanToken: loanToken,
                collateralToken: collateralToken,
                oracleSource: collateralToken,
                lltv: LLTV,
                supplyCap: 0,
                enableSettlement: true,
                activation: CollateralActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    maxDelayInflow: 10_000 ether,
                    activatingLockDuration: 0,
                    minActivationAmount: 10 ether,
                    minDepositAmount: 0,
                    maxGuardiansQuorumDelay: 0,
                    delayPerStrike: 2 hours,
                    delayPerSuspect: 0
                }),
                settlementConfig: SettlementConfig({
                    sliceFloorBps: 100, sliceFloorAssets: 0, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
                }),
                guardians: guardians,
                quorum: 1,
                suspectWindow: 1 hours,
                vaultName: "Lido scenario vault",
                vaultSymbol: "lido-scn"
            })
        );

        market = ILidoLend(d.core);
        vault = d.vault;
        oracle = d.oracle;
        params = d.params;
        id = d.marketId;
    }

    function _runScenario() internal returns (Metrics memory r) {
        uint256 index = _currentStakingIndex();
        _spikeWithdrawn = 0;
        _spikeResupplyChunk = 0;

        console2.log(_label());

        _setupLenders();

        _setupBorrowers(index);

        r.minBorrow = type(uint256).max;
        r.minUtil = type(uint256).max;

        for (uint256 i; i < SCEN_DAYS / STEP_DAYS; ++i) {
            uint256 apr = _stakingApr(i * STEP_DAYS);
            index += index * apr * STEP_DAYS / WAD / 365;
            _setStakingIndex(index);

            vm.warp(block.timestamp + STEP_DAYS * 1 days);
            market.accrueInterest(params);

            // Once a year the scenario retunes the IRM params from the trailing-year average APR (no-op for the peg).
            if ((i * STEP_DAYS) / 365 > _lastRetuneYear) {
                _lastRetuneYear = (i * STEP_DAYS) / 365;
                uint256 avg = _trailingAvgApr(i * STEP_DAYS);
                _retune(avg);
                console2.log(
                    string.concat("  >> retune, day ", vm.toString(i * STEP_DAYS), ", trailing avg APR ", _pct(avg))
                );
            }

            _spikeStep(i);

            (uint256 util, uint256 borrowRate) = _readState();

            // The live ceiling holds at every step: 2.75% at start, then 1.25x trailing-avg per retune.
            if (_irmKind == IrmKind.Adaptive) {
                assertLe(borrowRate, _adaptiveCapApr, "borrow APR never exceeds the retuned ceiling");
            }

            if (i > 0 && i * STEP_DAYS >= ISSUANCE_STEP_DAY && (i - 1) * STEP_DAYS < ISSUANCE_STEP_DAY) {
                console2.log("  >> issuance step: sudden staking cut, day", i * STEP_DAYS);
            }

            bool spikeOnset = _inSpike(i * STEP_DAYS) && !(i > 0 && _inSpike((i - 1) * STEP_DAYS));
            if (i % LOG_EVERY == 0 || spikeOnset) {
                console2.log(
                    string.concat(
                        "  d",
                        vm.toString(i * STEP_DAYS),
                        ": staking ",
                        _pct(apr),
                        "  borrow ",
                        _pct(borrowRate),
                        "  util ",
                        _pct(util),
                        "  idx ",
                        _idx(_currentStakingIndex()),
                        _inSpike(i * STEP_DAYS) ? "  [SPIKE]" : ""
                    )
                );
            }

            for (uint256 b; b < N_BORROWERS; ++b) {
                _stepBorrower(b, i, util, apr, borrowRate);
            }

            if (borrowRate > apr) {
                r.daysUnprofitable += STEP_DAYS;
                if (apr != 0 && borrowRate * 10_000 / apr > r.peakBorrowVsStakingBps) {
                    r.peakBorrowVsStakingBps = borrowRate * 10_000 / apr;
                }
            }
            if (borrowRate < r.minBorrow) r.minBorrow = borrowRate;
            if (borrowRate > r.maxBorrow) r.maxBorrow = borrowRate;
            if (util < r.minUtil) r.minUtil = util;
            r.finalUtil = util;
        }
    }

    /// @dev A heterogeneous looper cohort for a high-LLTV wstETH/WETH market. Each looper targets a leverage in the
    ///      realistic 7..13x band (the typical wstETH/ETH loop is 8-12x, reached in one shot via flash-loop), so
    ///      position LTV sits just under LLTV. Leverage is decorrelated from position size and scales how hard a
    ///      looper reacts. Entry ramps from a varied partial level, not a synchronous day-0 pile-in, and each looper
    ///      acts on its own phase.
    function _setupBorrowers(uint256 index) internal {
        for (uint256 k; k < N_BORROWERS; ++k) {
            uint256 lev = 7 + (k % 7); // target leverage 7..13x; the typical wstETH/ETH loop is 8-12x
            uint256 tgtLtv = (lev - 1) * WAD / lev; // position LTV = (L-1)/L, all under LLTV 0.945
            uint256 size = 40 ether + k * 7 ether; // debt at full leverage; sum ~0.94*supply (controls util)
            uint256 collat = (size * WAD / tgtLtv) * WAD / index; // collateral value = debt / LTV

            address who = address(uint160(uint256(keccak256(abi.encodePacked("scnBorrower", k)))));
            _borrowers.push(who);
            _maxLev.push(tgtLtv);
            _lev.push(lev * WAD); // leverage multiple (WAD) for display and reaction scaling
            _curLev.push(tgtLtv * (78 + (k * 37) % 18) / 100); // ramp entry: open at a varied 78..95% of target
            _phase.push(k);
            _pnl.push(0);
            _loss.push(0);
            _margin.push(0.0003 ether + (k % 5) * 0.0003 ether); // 3 .. 15 bps, decorrelated from leverage
            _delay.push(1 + (13 - lev) / 3); // 1..3 steps; higher leverage -> shorter delay (equity bleeds L x faster)
            _wait.push(0);

            _fundCollateral(who, collat);
            _fundLoan(who, 0);
            vm.prank(who);
            market.supplyCollateral(params, collat, who, "");
            // committed capital = equity at full target leverage = collateralValue * (1 - LTV). Fixed baseline for
            // P&L %, so the readout does not depend on whether a looper ended levered up or delevered.
            _equity0.push(_collateralValue(who) * (WAD - tgtLtv) / WAD);
        }

        vm.warp(block.timestamp + 3 hours);

        // Open each position at its (partial) entry leverage. The remaining ramp to target happens dynamically.
        for (uint256 k; k < N_BORROWERS; ++k) {
            address who = _borrowers[k];
            uint256 target = _collateralValue(who) * _curLev[k] / WAD;
            uint256 borrowAmt = _min(target, _availableLiquidity());
            if (borrowAmt > 0) {
                vm.prank(who);
                market.borrow(params, borrowAmt, 0, who, who);
            }
        }
    }

    function _stepBorrower(uint256 b, uint256 i, uint256 util, uint256 staking, uint256 borrowRate) internal {
        address who = _borrowers[b];
        uint256 debt = _debtOf(who);
        uint256 collatValue = _collateralValue(who);

        // Net carry on the position at its current leverage (value terms): staking accrues on the collateral the
        // looper economically holds (equity + debt) and borrow is paid on the debt. Delevering sells collateral, so
        // the idle entry stack does not keep earning. Accrues every period regardless of rebalancing.
        int256 net =
            (int256(staking * (_equity0[b] + debt) / WAD) - int256(borrowRate * debt / WAD)) * int256(STEP_DAYS) / 365;
        _pnl[b] += net;
        if (net < 0) _loss[b] += net; // isolate the bleed during negative-carry stretches (b > s)

        // Desync: each looper re-evaluates only every ACT_CADENCE steps, offset by its phase, so the cohort does not
        // lever up or delever in lockstep on a shared rate snapshot.
        if ((i + _phase[b]) % ACT_CADENCE != 0) return;

        int256 carry = int256(staking) - int256(borrowRate);
        if (carry > int256(_margin[b])) {
            _curLev[b] = _min(_curLev[b] + LEV_STEP, _maxLev[b]);
            _wait[b] = 0;
        } else if (carry < 0) {
            _wait[b] += 1;
            if (_wait[b] > _delay[b]) {
                // Dump scales with leverage: a 13x looper sheds ~1.9x the LTV per step of a 7x one, because its thin
                // buffer and L-times-faster equity bleed force a harder unwind. This sharpens the post-spike crash.
                uint256 dump = LEV_STEP * _lev[b] / (7 * WAD);
                // Delever capacity tracks the pool's remaining free liquidity (1 - util), which the lender run drains:
                // the deeper the drain, the slower a looper can source a repay, the longer it stays stuck at leverage
                // and bleeds at whatever rate the IRM sets. Below a 5% free floor it throttles proportionally. This is
                // where the borrow ceiling earns its keep: it bounds the stuck-looper bleed.
                uint256 free = util < WAD ? WAD - util : 0;
                if (free < 0.05 ether) dump = dump * free / 0.05 ether;
                _curLev[b] = _curLev[b] > dump ? _curLev[b] - dump : 0;
            }
        } else {
            _wait[b] = 0;
        }

        _rebalance(who, debt, collatValue * _curLev[b] / WAD);
    }

    /// @dev Move a looper's debt toward `target` (borrow up, or repay down), bounded by liquidity and LTV headroom.
    ///      Split out of _stepBorrower to keep that frame small (the repo builds with via_ir = false).
    function _rebalance(address who, uint256 debt, uint256 target) internal {
        if (target > debt) {
            uint256 add = _min(target - debt, _min(_availableLiquidity(), _ltvHeadroom(who, debt)));
            if (add > 0) {
                vm.prank(who);
                market.borrow(params, add, 0, who, who);
            }
        } else if (target < debt) {
            Market memory m = _marketStruct();
            uint128 bs = market.position(id, who).borrowShares;
            uint256 targetShares = target.toSharesUp(m.totalBorrowAssets, m.totalBorrowShares);
            uint256 repayShares = uint256(bs) > targetShares ? uint256(bs) - targetShares : 0;
            if (repayShares > 0) {
                uint256 owed = repayShares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
                uint256 bal = IERC20Like(loanToken).balanceOf(who);
                if (bal < owed) _fundLoan(who, owed - bal);
                vm.prank(who);
                market.repay(params, 0, repayShares, who, "");
            }
        }
    }

    function _readState() internal view returns (uint256 util, uint256 borrowRate) {
        Market memory m = _marketStruct();
        util = m.totalSupplyAssets == 0 ? 0 : uint256(m.totalBorrowAssets) * WAD / m.totalSupplyAssets;
        borrowRate = IIrm(params.irm).borrowRateView(params, m) * YEAR;
    }

    function _debtOf(address who) internal view returns (uint256) {
        Market memory m = _marketStruct();
        uint128 borrowShares = market.position(id, who).borrowShares;
        return uint256(borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    function _collateralValue(address who) internal view returns (uint256) {
        uint128 col = market.position(id, who).collateral;
        return uint256(col) * WstEthRateOracle(oracle).price() / 1e36;
    }

    function _ltvHeadroom(address who, uint256 debt) internal view returns (uint256) {
        uint256 maxDebt = _collateralValue(who) * LLTV / WAD;
        return maxDebt > debt ? maxDebt - debt : 0;
    }

    function _availableLiquidity() internal view returns (uint256) {
        Market memory m = _marketStruct();
        return m.totalSupplyAssets > m.totalBorrowAssets ? m.totalSupplyAssets - m.totalBorrowAssets : 0;
    }

    function _lenderSupplyAssets(address who) internal view returns (uint256) {
        Market memory m = _marketStruct();
        uint256 supplyShares = market.position(id, who).supplyShares;
        return supplyShares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
    }

    function _marketStruct() internal view returns (Market memory m) {
        m = market.market(id);
    }

    /// @dev A distributed lender base: N_LENDERS lenders with heterogeneous slices summing to SUPPLY_AMT,
    ///      instead of one whale holding all supply.
    function _setupLenders() internal {
        for (uint256 k; k < N_LENDERS; ++k) {
            uint256 amount = 55 ether + k * 10 ether; // 55..145, sum == 1000 == SUPPLY_AMT
            address who = address(uint160(uint256(keccak256(abi.encodePacked("scnLender", k)))));
            _lenders.push(who);
            _lenderPulled.push(0);
            _fundLoan(who, amount);
            vm.prank(who);
            market.supply(params, amount, 0, who, "");
        }
    }

    /// @dev Spike = a run on the shared liquidity. Lenders pull most of the available assets first-come, so
    ///      latecomers are stuck, draining the communal pool and pinning utilization high; afterwards they
    ///      return what they pulled gradually. Util pins high regardless of how many pull, because available
    ///      liquidity (not any single lender's balance) is the binding constraint.
    function _spikeStep(uint256 i) internal {
        bool spike = _inSpike(i * STEP_DAYS);
        bool prev = i > 0 && _inSpike((i - 1) * STEP_DAYS);
        if (spike && !prev) {
            uint256 toPull = _availableLiquidity() * 95 / 100;
            for (uint256 k; k < _lenders.length && toPull > 0; ++k) {
                uint256 amt = _min(toPull, _lenderSupplyAssets(_lenders[k]) * 90 / 100); // leave a dust to avoid
                // full-close rounding
                amt = _min(amt, _availableLiquidity());
                if (amt == 0) continue;
                vm.prank(_lenders[k]);
                market.withdraw(params, amt, 0, _lenders[k], _lenders[k]);
                _lenderPulled[k] += amt;
                _spikeWithdrawn += amt;
                toPull -= amt;
            }
            _spikeResupplyChunk = _spikeWithdrawn / 6;
        } else if (!spike && _spikeWithdrawn > 0) {
            uint256 chunk = _min(_spikeResupplyChunk, _spikeWithdrawn);
            for (uint256 k; k < _lenders.length && chunk > 0; ++k) {
                uint256 amt = _min(chunk, _lenderPulled[k]);
                if (amt == 0) continue;
                vm.prank(_lenders[k]);
                market.supply(params, amt, 0, _lenders[k], "");
                _lenderPulled[k] -= amt;
                _spikeWithdrawn -= amt;
                chunk -= amt;
            }
        }
    }

    /// @dev Two lender-driven demand spikes (day index): one long (~30d), one short (~6d).
    function _inSpike(uint256 dayIndex) internal pure returns (bool) {
        if (dayIndex >= 300 && dayIndex < 330) return true;
        if (dayIndex >= 520 && dayIndex < 526) return true;
        return false;
    }

    /// @dev Staking APR (annual WAD): linear decline 2.6% -> 1.25% over DECLINE_DAYS, flat 1.25% to the
    ///      issuance step, then a sudden step down to 1.0% at ISSUANCE_STEP_DAY (the issuance-change stress).
    function _stakingApr(uint256 dayIndex) internal pure returns (uint256) {
        if (dayIndex >= ISSUANCE_STEP_DAY) return 0.01 ether; // sudden step down to 1.0%
        if (dayIndex >= DECLINE_DAYS) return 0.0125 ether; // flat 1.25% after the gradual decline
        return 0.026 ether - (0.0135 ether * dayIndex) / DECLINE_DAYS; // 2.6% -> 1.25% over DECLINE_DAYS
    }

    function _logMetrics(Metrics memory r) internal view {
        console2.log("  -- summary --");
        console2.log("  days borrow APR > staking APR:", r.daysUnprofitable);
        if (r.peakBorrowVsStakingBps == 0) console2.log("  peak borrow/staking: <=1.00x (never above staking)");
        else console2.log(string.concat("  peak borrow/staking: ", _mult(r.peakBorrowVsStakingBps)));
        console2.log(string.concat("  borrow ", _pct(r.minBorrow), " .. ", _pct(r.maxBorrow)));
        console2.log(string.concat("  util min ", _pct(r.minUtil), " / final ", _pct(r.finalUtil)));
    }

    /// @dev Net carry P&L per looper as a % of current equity, to show leverage spreading outcomes: the same rate
    ///      path leaves high-leverage loopers with larger swings than low-leverage ones.
    function _logBorrowerPnl() internal view {
        console2.log("  -- looper P&L (% of committed capital), by leverage: net over the run, and crunch bleed --");
        int256 sumNet;
        int256 sumBled;
        for (uint256 k; k < N_BORROWERS; ++k) {
            int256 eq0 = int256(_equity0[k]);
            int256 netBps = _pnl[k] * 10_000 / eq0;
            int256 bledBps = _loss[k] * 10_000 / eq0;
            sumNet += netBps;
            sumBled += bledBps;
            console2.log(
                string.concat(
                    "  ", _mult(_lev[k] * 10_000 / WAD), " lev: net ", _signed(netBps), "  bled ", _signed(bledBps)
                )
            );
        }
        console2.log(
            string.concat(
                "  avg net ",
                _signed(sumNet / int256(N_BORROWERS)),
                "  avg bled ",
                _signed(sumBled / int256(N_BORROWERS))
            )
        );
    }

    function _signed(int256 bps) internal pure returns (string memory) {
        uint256 abs = uint256(bps < 0 ? -bps : bps);
        uint256 frac = abs % 100;
        return
            string.concat(
                bps < 0 ? "-" : "+", vm.toString(abs / 100), ".", frac < 10 ? "0" : "", vm.toString(frac), "%"
            );
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _pct(uint256 wad) internal view returns (string memory) {
        uint256 bps = wad * 10_000 / WAD;
        uint256 frac = bps % 100;
        return string.concat(vm.toString(bps / 100), ".", frac < 10 ? "0" : "", vm.toString(frac), "%");
    }

    function _mult(uint256 bps) internal view returns (string memory) {
        uint256 frac = (bps % 10_000) / 100;
        return string.concat(vm.toString(bps / 10_000), ".", frac < 10 ? "0" : "", vm.toString(frac), "x");
    }

    function _idx(uint256 raw) internal view returns (string memory) {
        uint256 frac = (raw % WAD) / 1e14;
        bytes memory fb = bytes(vm.toString(frac));
        string memory pad = fb.length == 1 ? "000" : fb.length == 2 ? "00" : fb.length == 3 ? "0" : "";
        return string.concat(vm.toString(raw / WAD), ".", pad, string(fb));
    }
}

// ==========================================================================================================
// Token sources
// ==========================================================================================================

/// @notice Mock-token run: no fork needed, reproduces the comparison numbers anywhere.
contract IrmModelSelectionMockTest is IrmScenarioBase {
    MockWstETH internal mockWst;

    function _setupTokens() internal override {
        loanToken = address(new MockERC20("Mock WETH", "mWETH"));
        mockWst = new MockWstETH();
        collateralToken = address(mockWst);
    }

    function _fundLoan(address to, uint256 amount) internal override {
        MockERC20(loanToken).mint(to, amount);
        vm.prank(to);
        MockERC20(loanToken).approve(address(market), type(uint256).max);
    }

    function _fundCollateral(address to, uint256 amount) internal override {
        MockWstETH(collateralToken).mint(to, amount);
        vm.prank(to);
        MockWstETH(collateralToken).approve(address(market), type(uint256).max);
    }

    function _setStakingIndex(uint256 index) internal override {
        mockWst.setStEthPerToken(index);
    }

    function _currentStakingIndex() internal view override returns (uint256) {
        return mockWst.stEthPerToken();
    }

    /// @dev Runs the multi-year IRM comparison scenario driven by the adaptive-curve IRM (mock tokens, no fork).
    function test_scenario_adaptive() public {
        _run(IrmKind.Adaptive);
    }

    /// @dev Runs the multi-year IRM comparison scenario driven by the staking-pegged IRM (mock tokens, no fork).
    function test_scenario_pegged() public {
        _run(IrmKind.Pegged);
    }

    /// @dev Runs the multi-year IRM comparison scenario driven by the linear-kink IRM (mock tokens, no fork).
    function test_scenario_kinked() public {
        _run(IrmKind.Kinked);
    }

    /// @dev Runs the multi-year IRM comparison scenario driven by the capD dynamic-ceiling IRM (mock tokens, no fork).
    function test_scenario_capD() public {
        _run(IrmKind.CapD);
    }
}

// ==========================================================================================================
// Adaptive parameter-retune tests: parameters live in external immutable configs. Verifies the adapted
// `rateAtTarget` survives applying a new config and the spike/no-spike behavior.
// ==========================================================================================================

/// @notice The adaptive IRM's yearly retune applies a new immutable config to the routed instance. The instance
///         keeps its `rateAtTarget`, so a retune whose new bounds contain the stored rate causes no spike, and one
///         whose bounds exclude it clamps the stored rate into the new band when the config is applied.
contract AdaptiveIrmRetuneTest is Test {
    using MarketParamsLib for MarketParams;

    int256 internal constant Y = 365 days;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TARGET = 0.9 ether;

    AdaptiveCurveIrm internal irm;
    MarketParams internal params;
    Id internal id;

    function setUp() public {
        // ROUTER == owner == manager == this: the test drives `borrowRate` directly and re-tunes as owner.
        irm = new AdaptiveCurveIrm(address(this), address(this), address(this));
        params = MarketParams({
            loanToken: address(0xA11CE),
            collateralToken: address(0xB0B),
            oracle: address(0x0AC1E),
            irm: address(irm),
            lltv: 0.8 ether
        });
        id = params.id();
    }

    /// @dev A retune whose new bounds still contain the adapted `rateAtTarget` keeps the stored rate and the borrow
    ///      rate continues unchanged — no spike.
    function test_retune_statePersists_noSpike_whenBoundsContainRate() public {
        _setBounds(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y);
        _adaptDown();

        int256 ratBefore = _rat();
        uint256 borrowBefore = _borrowAtTarget();

        _setBounds(ratBefore, ratBefore / 2, ratBefore * 2);

        assertEq(_rat(), ratBefore, "rateAtTarget persisted through the retune (instance storage intact)");
        assertEq(_borrowAtTarget(), borrowBefore, "no spike: borrow continues from the persisted rate");
    }

    /// @dev A retune whose new minimum exceeds the stored `rateAtTarget` clamps it up when the config is applied,
    ///      producing an upward rate jump (spike).
    function test_retune_rateJumps_whenNewBoundsExcludeStoredRate() public {
        _setBounds(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y);
        _adaptDown();

        int256 ratBefore = _rat();
        int256 newMin = ratBefore * 3 / 2;
        _setBounds(newMin, newMin, newMin * 4);

        assertEq(_rat(), newMin, "stored rate clamped up when the config is applied");

        _poke(0.95 ether);
        int256 ratAfter = _rat();
        assertGe(ratAfter, newMin, "subsequent adaptation stays within the new band");
        assertGt(ratAfter, ratBefore, "rate jumped up after the retune (the spike)");
    }

    /// @dev A retune whose new maximum sits below the stored `rateAtTarget` clamps it down when the config is applied,
    ///      dropping the rate.
    function test_retune_rateDrops_whenNewMaxBelowStoredRate() public {
        _setBounds(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y);
        _adaptDown();

        int256 ratBefore = _rat();
        int256 newMax = ratBefore * 2 / 3;
        _setBounds(newMax, ratBefore / 4, newMax);

        assertEq(_rat(), newMax, "stored rate clamped down when the config is applied");

        _poke(0.95 ether);
        int256 ratAfter = _rat();
        assertLe(ratAfter, newMax, "subsequent adaptation stays within the new band");
        assertLt(ratAfter, ratBefore, "rate dropped after the retune");
    }

    /// @dev Re-tune the routed instance in place with a new immutable config.
    function _setBounds(int256 initial, int256 min, int256 max) internal {
        AdaptiveCurveConfig config = new AdaptiveCurveConfig(_cfg(initial, min, max));
        irm.applyIrmConfig(_toIrmParams(params), address(config));
    }

    function _cfg(int256 initial, int256 min, int256 max) internal pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: int256(20 ether) / Y,
            targetUtilization: int256(TARGET),
            initialRateAtTarget: initial,
            minRateAtTarget: min,
            maxRateAtTarget: max,
            maxBorrowRate: 0
        });
    }

    function _adaptDown() internal {
        _poke(TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(0.3 ether);
        }
    }

    function _poke(uint256 utilWad) internal {
        Market memory m = _market(utilWad);
        vm.warp(block.timestamp + 5 days);
        IIrm(address(irm)).borrowRate(params, m);
    }

    function _borrowAtTarget() internal view returns (uint256) {
        return IIrm(address(irm)).borrowRateView(params, _market(TARGET)) * uint256(Y);
    }

    function _rat() internal view returns (int256) {
        return IRateAtTargetLike(address(irm)).rateAtTarget(id);
    }

    function _market(uint256 utilWad) internal view returns (Market memory m) {
        m.totalSupplyAssets = uint128(SUPPLY);
        m.totalBorrowAssets = uint128(SUPPLY * utilWad / 1e18);
        m.lastUpdate = uint128(block.timestamp);
    }

    function _toIrmParams(MarketParams memory p) internal pure returns (IrmMarketParams memory) {
        return IrmMarketParams({
            loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv
        });
    }
}

/// @notice The adaptive-IRM hard cap (`MAX_BORROW_RATE`): clamps the charged rate at the high-utilization tip
///         without touching the adapting `rateAtTarget`. Two properties — the cap bites the tip, and a capped
///         and an uncapped IRM driven identically end every step with the same stored `rateAtTarget`, proving the
///         clamp never feeds back into the state machine (adaptation is err-driven, not rate-driven).
contract AdaptiveHardCapTest is Test {
    using MarketParamsLib for MarketParams;

    int256 internal constant Y = 365 days;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant CAP = uint256(0.035 ether) / uint256(Y); // 3.5%/yr: above MAX (2.75%), below 4.125% tip

    address internal uncapped;
    address internal capped;
    MarketParams internal pu;
    MarketParams internal pc;
    Id internal idu;
    Id internal idc;

    function setUp() public {
        // ROUTER == owner == manager == this: the test drives `borrowRate` directly and sets the curve as owner.
        AdaptiveCurveIrm u = new AdaptiveCurveIrm(address(this), address(this), address(this));
        AdaptiveCurveIrm c = new AdaptiveCurveIrm(address(this), address(this), address(this));
        uncapped = address(u);
        capped = address(c);
        pu = _params(uncapped);
        idu = pu.id();
        pc = _params(capped);
        idc = pc.id();
        AdaptiveCurveConfig uncappedConfig = new AdaptiveCurveConfig(_cfg(0));
        AdaptiveCurveConfig cappedConfig = new AdaptiveCurveConfig(_cfg(CAP));
        u.applyIrmConfig(_toIrmParams(pu), address(uncappedConfig));
        c.applyIrmConfig(_toIrmParams(pc), address(cappedConfig));
    }

    /// @dev The hard cap clamps the high-utilization tip to `MAX_BORROW_RATE`, below the uncapped MAX*steepness peak.
    function test_hardCap_clampsTip() public {
        // First call uses INITIAL_RATE_AT_TARGET (= MAX here), so the 100%-util tip is the natural peak MAX*steepness.
        uint256 tipUncapped = IIrm(uncapped).borrowRateView(pu, _market(1 ether)) * uint256(Y);
        uint256 tipCapped = IIrm(capped).borrowRateView(pc, _market(1 ether)) * uint256(Y);

        assertApproxEqAbs(tipUncapped, 0.04125 ether, 0.001 ether, "uncapped tip = MAX*steepness = 4.125%");
        assertApproxEqAbs(tipCapped, 0.035 ether, 0.001 ether, "capped tip clamped to MAX_BORROW_RATE = 3.5%");
        assertLt(tipCapped, tipUncapped, "cap bites the high-utilization tip");
    }

    function test_hardCap_doesNotTouchState() public {
        // Phase 1: high util, the cap bites the reported rate every step. Phase 2: low util, rateAtTarget descends
        // through the interior. After each step the stored rateAtTarget must match between the two IRMs.
        for (uint256 i; i < 4; ++i) {
            _stepBothAndAssertStateMatches(0.98 ether);
        }
        for (uint256 i; i < 6; ++i) {
            _stepBothAndAssertStateMatches(0.5 ether);
        }
        assertLt(
            IRateAtTargetLike(uncapped).rateAtTarget(idu),
            int256(0.0275 ether) / Y,
            "rateAtTarget left the MAX boundary (state moved)"
        );
        assertGt(
            IRateAtTargetLike(uncapped).rateAtTarget(idu), int256(0.005 ether) / Y, "rateAtTarget stayed above MIN"
        );
    }

    function test_hardCap_belowMax_clipsAtTarget() public {
        // An absolute ceiling below MAX clips even the at-target rate (here rateAtTarget = MAX = 2.75%).
        address low = address(new AdaptiveCurveIrm(address(this), address(this), address(this)));
        MarketParams memory p = _params(low);
        AdaptiveCurveConfig config = new AdaptiveCurveConfig(_cfg(uint256(0.025 ether) / uint256(Y)));
        AdaptiveCurveIrm(low).applyIrmConfig(_toIrmParams(p), address(config));
        uint256 atTarget = IIrm(low).borrowRateView(p, _market(0.9 ether)) * uint256(Y);
        assertApproxEqAbs(atTarget, 0.025 ether, 0.001 ether, "at-target rate clipped to the absolute 2.5% ceiling");
    }

    function _stepBothAndAssertStateMatches(uint256 utilWad) internal {
        Market memory m = _market(utilWad);
        vm.warp(block.timestamp + 5 days);
        IIrm(uncapped).borrowRate(pu, m);
        IIrm(capped).borrowRate(pc, m);
        assertEq(
            IRateAtTargetLike(capped).rateAtTarget(idc),
            IRateAtTargetLike(uncapped).rateAtTarget(idu),
            "rateAtTarget adapts identically: the hard cap bounds the charged rate, never the state"
        );
    }

    function _cfg(uint256 cap) internal pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: int256(20 ether) / Y,
            targetUtilization: int256(0.9 ether),
            initialRateAtTarget: int256(0.0275 ether) / Y, // start at MAX so the first tip is the natural peak
            minRateAtTarget: int256(0.005 ether) / Y,
            maxRateAtTarget: int256(0.0275 ether) / Y,
            maxBorrowRate: cap
        });
    }

    function _params(address irm) internal pure returns (MarketParams memory p) {
        p = MarketParams({
            loanToken: address(0xA11CE),
            collateralToken: address(0xB0B),
            oracle: address(0x0AC1E),
            irm: irm,
            lltv: 0.8 ether
        });
    }

    function _toIrmParams(MarketParams memory p) internal pure returns (IrmMarketParams memory) {
        return IrmMarketParams({
            loanToken: p.loanToken, collateralToken: p.collateralToken, oracle: p.oracle, irm: p.irm, lltv: p.lltv
        });
    }

    function _market(uint256 utilWad) internal view returns (Market memory m) {
        m.totalSupplyAssets = uint128(SUPPLY);
        m.totalBorrowAssets = uint128(SUPPLY * utilWad / 1e18);
        m.lastUpdate = uint128(block.timestamp);
    }
}
