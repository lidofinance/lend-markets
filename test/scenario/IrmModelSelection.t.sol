// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

// Self-contained IRM model-selection harness.
// Everything the comparison needs lives in this one file so it can be deleted or updated as a unit: the three candidate
// IRMs, the mock tokens, the scenario harness (mock + mainnet-fork token sources), and the adaptive
// parameter-upgrade tests. Not production code.

import {Test, console2} from "forge-std/Test.sol";
import {IIrm} from "@morpho-blue/src/interfaces/IIrm.sol";
import {Id, MarketParams, Market} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";
import {MathLib as MorphoMathLib} from "@morpho-blue/src/libraries/MathLib.sol";
import {SharesMathLib} from "@morpho-blue/src/libraries/SharesMathLib.sol";
import {UtilsLib} from "@morpho-blue-irm/src/adaptive-curve-irm/libraries/UtilsLib.sol";
import {ExpLib} from "@morpho-blue-irm/src/adaptive-curve-irm/libraries/ExpLib.sol";
import {MathLib, WAD_INT} from "@morpho-blue-irm/src/adaptive-curve-irm/libraries/MathLib.sol";

import {LidoBlue} from "../../src/LidoBlue.sol";
import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {IWethWstEthController} from "../utils/IWethWstEthController.sol";
import {LidoBlueDeployer} from "../../script/lib/LidoBlueDeployer.sol";

// ==========================================================================================================
// Candidate IRMs (local variants, declared here rather than in src/ so the whole comparison is one file)
// ==========================================================================================================

/// @notice Adaptive curve IRM, a fork of Morpho's `AdaptiveCurveIrm` with the upstream `ConstantsLib`
///         constants lifted to constructor immutables. The per-second rate is `curve(rateAtTarget, err)`,
///         `err` measuring distance from `TARGET_UTILIZATION`; `rateAtTarget` itself adapts over time toward
///         the settled utilization, bounded to `[MIN, MAX]`. No external rate input. An optional
///         `MAX_BORROW_RATE` is an absolute ceiling on the charged rate (0 disables it) that never touches the
///         adapting `rateAtTarget`. It clips wherever the curve would exceed it, independent of the curve params.
contract LidoAdaptiveCurveIrm is IIrm {
    using MathLib for int256;
    using UtilsLib for int256;
    using MorphoMathLib for uint128;
    using MarketParamsLib for MarketParams;

    event BorrowRateUpdate(Id indexed id, uint256 avgBorrowRate, uint256 rateAtTarget);

    error ZeroAddress();
    error NotMorpho();
    error InvalidParams();

    struct Config {
        int256 curveSteepness; // WAD, >= 1e18
        int256 adjustmentSpeed; // WAD per second, >= 0
        int256 targetUtilization; // WAD, in (0, 1e18)
        int256 initialRateAtTarget; // WAD per second, in [min, max]
        int256 minRateAtTarget; // WAD per second, > 0
        int256 maxRateAtTarget; // WAD per second, >= min
        int256 maxBorrowRate; // WAD per second, 0 = uncapped; else an absolute hard ceiling on the charged rate
    }

    address public immutable MORPHO;
    int256 public immutable CURVE_STEEPNESS;
    int256 public immutable ADJUSTMENT_SPEED;
    int256 public immutable TARGET_UTILIZATION;
    int256 public immutable INITIAL_RATE_AT_TARGET;
    int256 public immutable MIN_RATE_AT_TARGET;
    int256 public immutable MAX_RATE_AT_TARGET;
    int256 public immutable MAX_BORROW_RATE; // hard cap on the charged rate; 0 disables it

    mapping(Id => int256) public rateAtTarget;

    constructor(address morpho, Config memory cfg) {
        if (morpho == address(0)) revert ZeroAddress();
        if (
            cfg.curveSteepness < WAD_INT || cfg.adjustmentSpeed < 0 || cfg.targetUtilization <= 0
                || cfg.targetUtilization >= WAD_INT || cfg.minRateAtTarget <= 0
                || cfg.maxRateAtTarget < cfg.minRateAtTarget || cfg.initialRateAtTarget < cfg.minRateAtTarget
                || cfg.initialRateAtTarget > cfg.maxRateAtTarget || cfg.maxBorrowRate < 0
        ) {
            revert InvalidParams();
        }

        MORPHO = morpho;
        CURVE_STEEPNESS = cfg.curveSteepness;
        ADJUSTMENT_SPEED = cfg.adjustmentSpeed;
        TARGET_UTILIZATION = cfg.targetUtilization;
        INITIAL_RATE_AT_TARGET = cfg.initialRateAtTarget;
        MIN_RATE_AT_TARGET = cfg.minRateAtTarget;
        MAX_RATE_AT_TARGET = cfg.maxRateAtTarget;
        MAX_BORROW_RATE = cfg.maxBorrowRate;
    }

    function borrowRateView(MarketParams memory marketParams, Market memory market) external view returns (uint256) {
        (uint256 avgRate,) = _borrowRate(marketParams.id(), market);
        return avgRate;
    }

    function borrowRate(MarketParams memory marketParams, Market memory market) external returns (uint256) {
        if (msg.sender != MORPHO) revert NotMorpho();
        Id id = marketParams.id();
        (uint256 avgRate, int256 endRateAtTarget) = _borrowRate(id, market);
        rateAtTarget[id] = endRateAtTarget;
        emit BorrowRateUpdate(id, avgRate, uint256(endRateAtTarget));
        return avgRate;
    }

    function _borrowRate(Id id, Market memory market) private view returns (uint256, int256) {
        int256 utilization =
            int256(market.totalSupplyAssets > 0 ? market.totalBorrowAssets.wDivDown(market.totalSupplyAssets) : 0);

        int256 errNormFactor = utilization > TARGET_UTILIZATION ? WAD_INT - TARGET_UTILIZATION : TARGET_UTILIZATION;
        int256 err = (utilization - TARGET_UTILIZATION).wDivToZero(errNormFactor);

        int256 startRateAtTarget = rateAtTarget[id];

        int256 avgRateAtTarget;
        int256 endRateAtTarget;

        if (startRateAtTarget == 0) {
            avgRateAtTarget = INITIAL_RATE_AT_TARGET;
            endRateAtTarget = INITIAL_RATE_AT_TARGET;
        } else {
            int256 speed = ADJUSTMENT_SPEED.wMulToZero(err);
            int256 elapsed = int256(block.timestamp - market.lastUpdate);
            int256 linearAdaptation = speed * elapsed;

            if (linearAdaptation == 0) {
                avgRateAtTarget = startRateAtTarget;
                endRateAtTarget = startRateAtTarget;
            } else {
                endRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation);
                int256 midRateAtTarget = _newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
                avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
            }
        }

        // Hard cap: clamp the charged rate to MAX_BORROW_RATE, leaving endRateAtTarget untouched. Adaptation is
        // err-driven, not rate-driven, so the state machine is unchanged and only the reported rate is bounded.
        uint256 rate = uint256(_curve(avgRateAtTarget, err));
        if (MAX_BORROW_RATE != 0 && rate > uint256(MAX_BORROW_RATE)) rate = uint256(MAX_BORROW_RATE);
        return (rate, endRateAtTarget);
    }

    function _curve(int256 _rateAtTarget, int256 err) private view returns (int256) {
        int256 coeff = err < 0 ? WAD_INT - WAD_INT.wDivToZero(CURVE_STEEPNESS) : CURVE_STEEPNESS - WAD_INT;
        return (coeff.wMulToZero(err) + WAD_INT).wMulToZero(_rateAtTarget);
    }

    function _newRateAtTarget(int256 startRateAtTarget, int256 linearAdaptation) private view returns (int256) {
        return startRateAtTarget.wMulToZero(ExpLib.wExp(linearAdaptation)).bound(MIN_RATE_AT_TARGET, MAX_RATE_AT_TARGET);
    }
}

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

    error NotMorpho();
    error ZeroAddress();

    address public immutable MORPHO;
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
        address morpho,
        address rateSource,
        uint256 targetUtil,
        uint256 margin,
        uint256 maxMultiple,
        uint256 window
    ) {
        if (morpho == address(0) || rateSource == address(0)) revert ZeroAddress();
        MORPHO = morpho;
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
        if (msg.sender != MORPHO) revert NotMorpho();
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

/// @notice Static Aave/Compound-style kinked IRM. Fixed piecewise-linear rate in utilization, no adaptation
///         and no external input. Does not track staking: when the yield moves, governance must redeploy.
contract KinkedIrm is IIrm {
    uint256 internal constant WAD = 1e18;

    error InvalidParams();

    uint256 public immutable BASE_RATE;
    uint256 public immutable SLOPE1;
    uint256 public immutable SLOPE2;
    uint256 public immutable KINK;

    constructor(uint256 baseRate, uint256 slope1, uint256 slope2, uint256 kink) {
        if (kink == 0 || kink >= WAD) revert InvalidParams();
        BASE_RATE = baseRate;
        SLOPE1 = slope1;
        SLOPE2 = slope2;
        KINK = kink;
    }

    function borrowRateView(MarketParams memory, Market memory market) external view returns (uint256) {
        return _rate(market);
    }

    function borrowRate(MarketParams memory, Market memory market) external view returns (uint256) {
        return _rate(market);
    }

    function _rate(Market memory market) internal view returns (uint256) {
        if (market.totalSupplyAssets == 0) return BASE_RATE;
        uint256 u = uint256(market.totalBorrowAssets) * WAD / market.totalSupplyAssets;
        if (u <= KINK) {
            return BASE_RATE + SLOPE1 * u / KINK;
        }
        return BASE_RATE + SLOPE1 + SLOPE2 * (u - KINK) / (WAD - KINK);
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
}

// ==========================================================================================================
// Scenario harness: one scenario, three IRMs, on a real LidoBlue + controller + vault instance.
// ==========================================================================================================

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

/// @notice A lender supplies, a heterogeneous set of loopers run real leveraged positions (supplyCollateral +
///         borrow/repay) with different LTVs, sizes, carry thresholds and reaction delays, so utilization and
///         the borrow rate come from the live market. Staking is driven through the collateral's
///         `stEthPerToken` index over a multi-year decline. The path includes two lender-driven utilization
///         spikes and one sudden staking step-down (the issuance-change stress). Once a year the scenario retunes
///         the IRM params from the trailing-year average APR (adaptive and kinked by proxy upgrade, the peg
///         needs none). Concrete subclasses wire the token/staking source (mock or mainnet fork); the IRM is
///         selected per test through `_irmKind`.
abstract contract IrmScenarioBase is Test, LidoBlueDeployer {
    using SharesMathLib for uint256;

    enum IrmKind {
        Adaptive,
        Pegged,
        Kinked
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
    LidoBlue internal market;
    IWethWstEthController internal controller;
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

    address internal _irmProxy; // adaptive/kinked live behind a proxy so the yearly retune can upgrade them
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
    function _skip() internal view virtual returns (bool);

    // --- run one IRM through the scenario ---
    function _run(IrmKind kind) internal {
        vm.skip(_skip(), "scenario setup unavailable (mainnet fork required?)");
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
        return "KINKED";
    }

    /// @dev Deploy the IRM under test. The peg reads staking directly and needs no retune, so it is deployed
    ///      directly (its constructor also seeds storage, which a proxy would not run). Adaptive and kinked are
    ///      retuned yearly by upgrade, so they live behind an `OssifiableProxy`. Initial params are
    ///      scenario inputs; yearly `_retune` derives params from the trailing-year average APR.
    function _deployIrm(address core) internal override returns (address) {
        if (_irmKind == IrmKind.Pegged) {
            return address(
                new StakingPeggedIrm(
                    core, collateralToken, TARGET_UTIL, uint256(0.001 ether) / YEAR, 1.5 ether, 14 days
                )
            );
        }

        address impl;
        if (_irmKind == IrmKind.Adaptive) {
            // initial set for ~2.6% staking
            _adaptiveCapApr = INITIAL_CAP_APR;
            impl = address(
                new LidoAdaptiveCurveIrm(
                    core,
                    LidoAdaptiveCurveIrm.Config({
                        curveSteepness: int256(1.5 ether),
                        adjustmentSpeed: ADAPT_SPEED,
                        targetUtilization: int256(TARGET_UTIL),
                        initialRateAtTarget: int256(0.02 ether) / int256(YEAR),
                        minRateAtTarget: int256(0.005 ether) / int256(YEAR),
                        maxRateAtTarget: int256(0.0275 ether) / int256(YEAR),
                        maxBorrowRate: int256(_adaptiveCapApr) / int256(YEAR)
                    })
                )
            );
        } else {
            impl = address(
                new KinkedIrm(
                    uint256(0.005 ether) / YEAR, uint256(0.02 ether) / YEAR, uint256(0.014 ether) / YEAR, TARGET_UTIL
                )
            );
        }
        _irmProxy =
            deployCode("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, address(this), new bytes(0)));
        return _irmProxy;
    }

    /// @dev Yearly retune: rebuild the IRM params from the trailing-year average APR and upgrade the impl
    ///      behind the proxy. The peg auto-tracks and is not behind a proxy, so this is a no-op for it.
    function _retune(uint256 avgApr) internal {
        if (_irmProxy == address(0)) return;
        address newImpl;
        if (_irmKind == IrmKind.Adaptive) {
            // light touch: the bounds move with the APR (initial is re-derived too, but it is inert once the
            // market's rateAtTarget is set); the rate self-adapts via utilization between retunes
            _adaptiveCapApr = avgApr * CAP_MULT_BPS / 10_000;
            newImpl = address(new LidoAdaptiveCurveIrm(address(market), _adaptiveCfgFor(avgApr)));
        } else {
            // re-center the whole curve: at target ~0.9*avgApr, at 100% ~1.5*avgApr
            newImpl =
                address(new KinkedIrm(avgApr / 5 / YEAR, avgApr * 7 / 10 / YEAR, avgApr * 6 / 10 / YEAR, TARGET_UTIL));
        }
        IOssifiableProxy(_irmProxy).proxy__upgradeTo(newImpl);
    }

    function _adaptiveCfgFor(uint256 avgApr) internal view returns (LidoAdaptiveCurveIrm.Config memory) {
        // floor keeps headroom below avgApr; rateAtTarget persists. Each retune re-derives the borrow ceiling on the
        // same trailing-avg basis as the bounds: 1.25x the average APR.
        return LidoAdaptiveCurveIrm.Config({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: ADAPT_SPEED,
            targetUtilization: int256(TARGET_UTIL),
            initialRateAtTarget: int256(avgApr * 8 / 10) / int256(YEAR),
            minRateAtTarget: int256(avgApr / 4) / int256(YEAR),
            maxRateAtTarget: int256(avgApr) / int256(YEAR),
            maxBorrowRate: int256(avgApr * CAP_MULT_BPS / 10_000) / int256(YEAR)
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

    function _deployStack() internal {
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
                deleverageEnabled: true,
                activation: ActivationConfig({
                    minActivationDelay: 10 minutes,
                    maxActivationDelay: 2 hours,
                    maxSuspicionDelay: 2 hours,
                    maxDecayDuration: 4 hours,
                    maxDelayLoad: 10_000 ether,
                    minActivationAmount: 10 ether,
                    minDecayAmount: 1_000 ether
                }),
                guardians: guardians,
                quorum: 1,
                vaultName: "Lido scenario vault",
                vaultSymbol: "lido-scn"
            })
        );

        market = LidoBlue(d.core);
        controller = IWethWstEthController(d.controllerProxy);
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
            (, uint128 bs,) = market.position(id, who);
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
        (, uint128 borrowShares,) = market.position(id, who);
        return uint256(borrowShares).toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    function _collateralValue(address who) internal view returns (uint256) {
        (,, uint128 col) = market.position(id, who);
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
        (uint256 supplyShares,,) = market.position(id, who);
        return supplyShares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
    }

    function _marketStruct() internal view returns (Market memory m) {
        (uint128 tsa, uint128 tss, uint128 tba, uint128 tbs, uint128 lastUpdate, uint128 fee) = market.market(id);
        m = Market(tsa, tss, tba, tbs, lastUpdate, fee);
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
        if (r.peakBorrowVsStakingBps == 0) {
            console2.log("  peak borrow/staking: <=1.00x (never above staking)");
        } else {
            console2.log(string.concat("  peak borrow/staking: ", _mult(r.peakBorrowVsStakingBps)));
        }
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

    function _skip() internal view override returns (bool) {
        return false;
    }

    function test_scenario_adaptive() public {
        _run(IrmKind.Adaptive);
    }

    function test_scenario_pegged() public {
        _run(IrmKind.Pegged);
    }

    function test_scenario_kinked() public {
        _run(IrmKind.Kinked);
    }
}

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

/// @notice Fork mirror of the simulation against real WETH/wstETH. Loan funding wraps ETH to WETH;
///         collateral funding submits ETH to Lido and wraps stETH to wstETH; staking moves are simulated by
///         mocking the real wstETH `stEthPerToken`. Skips unless run with `--fork-url $MAINNET_RPC_URL`.
contract IrmModelSelectionForkTest is IrmScenarioBase {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

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

    function _skip() internal view override returns (bool) {
        return !(block.chainid == 1 && WETH.code.length != 0 && WSTETH.code.length != 0);
    }

    function test_scenario_adaptive() public {
        _run(IrmKind.Adaptive);
    }

    function test_scenario_pegged() public {
        _run(IrmKind.Pegged);
    }

    function test_scenario_kinked() public {
        _run(IrmKind.Kinked);
    }
}

// ==========================================================================================================
// Adaptive parameter-upgrade tests: parameters are immutable per implementation, so retuning is an upgrade
// behind a proxy. Verifies the adapted `rateAtTarget` survives the upgrade, the spike/no-spike behavior, and
// that bad parameters are rejected at construction.
// ==========================================================================================================

interface IOssifiableProxy {
    function proxy__upgradeTo(address newImplementation) external;
    function proxy__getImplementation() external view returns (address);
}

contract AdaptiveIrmUpgradeTest is Test {
    using MarketParamsLib for MarketParams;

    int256 internal constant Y = 365 days;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TARGET = 0.9 ether;

    MarketParams internal params;
    Id internal id;

    function test_upgrade_statePersists_noSpike_whenBoundsContainRate() public {
        address proxy = _proxy(_impl(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y)));
        _wire(proxy);
        _adaptDown(proxy);

        int256 ratBefore = _rat(proxy);
        uint256 borrowBefore = _borrowAtTarget(proxy);

        IOssifiableProxy(proxy).proxy__upgradeTo(_impl(_cfg(ratBefore, ratBefore / 2, ratBefore * 2)));

        assertEq(_rat(proxy), ratBefore, "rateAtTarget persisted through the upgrade (proxy storage intact)");
        assertEq(_borrowAtTarget(proxy), borrowBefore, "no spike: borrow continues from the persisted rate");
    }

    function test_upgrade_rateJumps_whenNewBoundsExcludeStoredRate() public {
        address proxy = _proxy(_impl(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y)));
        _wire(proxy);
        _adaptDown(proxy);

        int256 ratBefore = _rat(proxy);
        int256 newMin = ratBefore * 3 / 2;
        IOssifiableProxy(proxy).proxy__upgradeTo(_impl(_cfg(newMin, newMin, newMin * 4)));

        assertEq(_rat(proxy), ratBefore, "stored rate unchanged until the next adapting call");

        _poke(proxy, 0.95 ether);
        int256 ratAfter = _rat(proxy);
        assertGe(ratAfter, newMin, "rate clamped up to the new MIN");
        assertGt(ratAfter, ratBefore, "rate jumped up after the upgrade (the spike)");
    }

    function test_upgrade_rateDrops_whenNewMaxBelowStoredRate() public {
        address proxy = _proxy(_impl(_cfg(int256(0.025 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y)));
        _wire(proxy);
        _adaptDown(proxy);

        int256 ratBefore = _rat(proxy);
        int256 newMax = ratBefore * 2 / 3;
        IOssifiableProxy(proxy).proxy__upgradeTo(_impl(_cfg(newMax, ratBefore / 4, newMax)));

        assertEq(_rat(proxy), ratBefore, "stored rate unchanged until the next adapting call");

        _poke(proxy, 0.95 ether);
        int256 ratAfter = _rat(proxy);
        assertLe(ratAfter, newMax, "rate clamped down to the new MAX");
        assertLt(ratAfter, ratBefore, "rate jumped down after the upgrade");
    }

    function testRevert_badParams_rejectedAtConstruction() public {
        vm.expectRevert(LidoAdaptiveCurveIrm.InvalidParams.selector);
        new LidoAdaptiveCurveIrm(
            address(this), _cfg(int256(0.02 ether) / Y, int256(0.05 ether) / Y, int256(0.02 ether) / Y)
        );

        vm.expectRevert(LidoAdaptiveCurveIrm.InvalidParams.selector);
        new LidoAdaptiveCurveIrm(
            address(this),
            LidoAdaptiveCurveIrm.Config({
                curveSteepness: int256(0.5 ether),
                adjustmentSpeed: int256(20 ether) / Y,
                targetUtilization: int256(TARGET),
                initialRateAtTarget: int256(0.02 ether) / Y,
                minRateAtTarget: int256(0.005 ether) / Y,
                maxRateAtTarget: int256(0.08 ether) / Y,
                maxBorrowRate: 0
            })
        );

        vm.expectRevert(LidoAdaptiveCurveIrm.InvalidParams.selector);
        new LidoAdaptiveCurveIrm(
            address(this), _cfg(int256(0.2 ether) / Y, int256(0.005 ether) / Y, int256(0.08 ether) / Y)
        );
    }

    function _cfg(int256 initial, int256 min, int256 max) internal pure returns (LidoAdaptiveCurveIrm.Config memory) {
        return LidoAdaptiveCurveIrm.Config({
            curveSteepness: int256(1.5 ether),
            adjustmentSpeed: int256(20 ether) / Y,
            targetUtilization: int256(TARGET),
            initialRateAtTarget: initial,
            minRateAtTarget: min,
            maxRateAtTarget: max,
            maxBorrowRate: 0
        });
    }

    function _impl(LidoAdaptiveCurveIrm.Config memory cfg) internal returns (address) {
        return address(new LidoAdaptiveCurveIrm(address(this), cfg));
    }

    function _proxy(address impl) internal returns (address) {
        return
            deployCode("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, address(this), new bytes(0)));
    }

    function _wire(address proxy) internal {
        params = MarketParams({
            loanToken: address(0xA11CE),
            collateralToken: address(0xB0B),
            oracle: address(0x0AC1E),
            irm: proxy,
            lltv: 0.8 ether
        });
        id = params.id();
    }

    function _adaptDown(address proxy) internal {
        _poke(proxy, TARGET);
        for (uint256 i; i < 6; ++i) {
            _poke(proxy, 0.3 ether);
        }
    }

    function _poke(address proxy, uint256 utilWad) internal {
        Market memory m = _market(utilWad);
        vm.warp(block.timestamp + 5 days);
        LidoAdaptiveCurveIrm(proxy).borrowRate(params, m);
    }

    function _borrowAtTarget(address proxy) internal view returns (uint256) {
        return LidoAdaptiveCurveIrm(proxy).borrowRateView(params, _market(TARGET)) * uint256(Y);
    }

    function _rat(address proxy) internal view returns (int256) {
        return LidoAdaptiveCurveIrm(proxy).rateAtTarget(id);
    }

    function _market(uint256 utilWad) internal view returns (Market memory m) {
        m.totalSupplyAssets = uint128(SUPPLY);
        m.totalBorrowAssets = uint128(SUPPLY * utilWad / 1e18);
        m.lastUpdate = uint128(block.timestamp);
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
    int256 internal constant CAP = int256(0.035 ether) / Y; // 3.5%/yr: above MAX (2.75%), below the 4.125% tip

    LidoAdaptiveCurveIrm internal uncapped;
    LidoAdaptiveCurveIrm internal capped;
    MarketParams internal pu;
    MarketParams internal pc;
    Id internal idu;
    Id internal idc;

    function setUp() public {
        uncapped = new LidoAdaptiveCurveIrm(address(this), _cfg(0));
        capped = new LidoAdaptiveCurveIrm(address(this), _cfg(CAP));
        pu = _params(address(uncapped));
        idu = pu.id();
        pc = _params(address(capped));
        idc = pc.id();
    }

    function test_hardCap_clampsTip() public {
        // First call uses INITIAL_RATE_AT_TARGET (= MAX here), so the 100%-util tip is the natural peak MAX*steepness.
        uint256 tipUncapped = uncapped.borrowRateView(pu, _market(1 ether)) * uint256(Y);
        uint256 tipCapped = capped.borrowRateView(pc, _market(1 ether)) * uint256(Y);

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
            uncapped.rateAtTarget(idu), int256(0.0275 ether) / Y, "rateAtTarget left the MAX boundary (state moved)"
        );
        assertGt(uncapped.rateAtTarget(idu), int256(0.005 ether) / Y, "rateAtTarget stayed above MIN");
    }

    function test_hardCap_belowMax_clipsAtTarget() public {
        // An absolute ceiling below MAX clips even the at-target rate (here rateAtTarget = MAX = 2.75%).
        LidoAdaptiveCurveIrm low = new LidoAdaptiveCurveIrm(address(this), _cfg(int256(0.025 ether) / Y));
        MarketParams memory p = _params(address(low));
        uint256 atTarget = low.borrowRateView(p, _market(0.9 ether)) * uint256(Y);
        assertApproxEqAbs(atTarget, 0.025 ether, 0.001 ether, "at-target rate clipped to the absolute 2.5% ceiling");
    }

    function testRevert_negativeCap_rejectedAtConstruction() public {
        vm.expectRevert(LidoAdaptiveCurveIrm.InvalidParams.selector);
        new LidoAdaptiveCurveIrm(address(this), _cfg(-1));
    }

    function _stepBothAndAssertStateMatches(uint256 utilWad) internal {
        Market memory m = _market(utilWad);
        vm.warp(block.timestamp + 5 days);
        uncapped.borrowRate(pu, m);
        capped.borrowRate(pc, m);
        assertEq(
            capped.rateAtTarget(idc),
            uncapped.rateAtTarget(idu),
            "rateAtTarget adapts identically: the hard cap bounds the charged rate, never the state"
        );
    }

    function _cfg(int256 cap) internal pure returns (LidoAdaptiveCurveIrm.Config memory) {
        return LidoAdaptiveCurveIrm.Config({
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

    function _market(uint256 utilWad) internal view returns (Market memory m) {
        m.totalSupplyAssets = uint128(SUPPLY);
        m.totalBorrowAssets = uint128(SUPPLY * utilWad / 1e18);
        m.lastUpdate = uint128(block.timestamp);
    }
}
