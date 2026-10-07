// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {stdError} from "forge-std/StdError.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {IIrm} from "@lido-lend/src/interfaces/IIrm.sol";
import {Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ErrorsLib} from "@lido-lend/src/libraries/ErrorsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {MathLib, WAD} from "@lido-lend/src/libraries/MathLib.sol";

import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IPausableUntil} from "../../src/interfaces/IPausableUntil.sol";
import {ExitBookLib} from "../../src/libs/ExitBookLib.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {GuardiansOpinion} from "../../src/types/GuardianSignalsTypes.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {ExitStatus, PriorityRamp, Request} from "../../src/types/ExitBookTypes.sol";
import {SettlementConfig, SettlementSlice} from "../../src/types/SettlementTypes.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";

import {ActivationModel} from "../setup/ActivationModel.sol";
import {Approvals} from "../setup/Approvals.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {TransientProbe} from "../setup/TransientProbe.sol";
import {IrmKind, Market} from "../setup/Types.sol";
import {Random} from "./Random.sol";

/// @notice The actors and moves of the solvency simulation. Each `Action` is a family of moves. A move draws an
///         account, sizes a random call, predicts from the test's own model whether it goes through or which exact
///         revert it hits, runs it through the asserting `MarketActions` helper or under that expected revert, and
///         books what moved in the ledgers. Most families draw from the whole population; the few that filter first say
///         so. Everyday families fire by per-iteration odds, rare ones once per run from the schedule. The guardians
///         are not a family: they follow the same fixed routine in every run. A leveraged borrower borrows to the top
///         of its room and never repays, withdraws or opts into personal settlement, so the scheduled crash has a
///         borrower to sink.
abstract contract SolvencyActions is LidoLendSetup {
    using MarketActions for Market;
    using Random for Random.Context;
    using SharesMathLib for uint256;
    using MathLib for uint256;

    /// @dev Time that passes after every move.
    uint256 internal constant SLOT = 1 hours;
    /// @dev How often `_guardianRoutine` takes one borrower through an incident, counted from the run's start.
    uint256 internal constant INCIDENT_PERIOD = 10 days;
    /// @dev Buffer at each end of the schedule window. Entries due together fire one slot apart, so an entry can be
    ///      late by its burst: at most 18 slots with the 19 entries a run schedules (18 without the crash), which a
    ///      day covers. It does not cover the wait of the five entries `_readyToFire` gates.
    uint256 internal constant SCHEDULE_MARGIN = 1 days;
    /// @dev Protocol fee on interest, minted to `feeRecipient` as supply shares.
    uint256 internal constant FEE = 0.1e18;
    /// @dev Exit book: longest request lifetime and the service cut taken from every priority fee.
    uint256 internal constant BOOK_LIFETIME = 30 days;
    uint256 internal constant BOOK_SERVICE_FEE = 0.2e18;
    uint256 internal constant ORACLE_SCALE = 1e36;
    /// @dev Scale of `g.supplyIndex`, finer than WAD so that rounding the index at every accrual of a year costs no
    ///      supplier a loan-asset unit.
    uint256 internal constant INDEX_SCALE = 1e36;
    /// @dev `_nextDue`'s answer when no schedule entry is due; no index can collide with it.
    uint256 internal constant NOTHING_DUE = type(uint256).max;
    /// @dev How far under water the scheduled crash must put a leveraged borrower before it fires: debt over collateral
    ///      value at the crashed price, in WAD. `_crashReady` argues the size.
    uint256 internal constant CRASH_MARGIN = 1.2e18;
    /// @dev Collateral under which `_borrow` tops a leveraged borrower up, and the top-up. A write-off can wipe such a
    ///      borrower out; the top-up lets it lever again.
    uint256 internal constant LEVERAGE_FLOOR = 100 ether;
    uint256 internal constant LEVERAGE_TOP_UP = 200 ether;

    enum Action {
        Deposit,
        Mint,
        Withdraw,
        Redeem,
        SupplyCollateral,
        Borrow,
        RepayPartial,
        RepayFull,
        WithdrawCollateral,
        SetSettlementLtv,
        Settle,
        FallbackExit,
        Liquidate,
        LiquidateBadDebt,
        PriceStep,
        Pause,
        Resume,
        Freeze,
        Unfreeze,
        SetSupplyCap,
        CoreSupply,
        CoreWithdraw,
        CoreSettle,
        DonateLoanToVault,
        DonateLoanToCore,
        DonateCollateralToCore,
        ThirdPartySupply,
        PlaceExitRequest,
        FillExitRequest,
        CancelExitRequest,
        CoreSettleNonRoot,
        TransferShares,
        SetSettlementConfig,
        SetActivationConfig,
        PauseBook,
        ResumeBook,
        Crash,
        FallbackExitScenario,
        FillExitRequestScenario,
        RemoveSupplyCap,
        SettleScenario,
        CoreSettleScenario
    }

    struct Counts {
        uint256 lenders;
        uint256 directLenders;
        uint256 borrowers;
        uint256 keepers;
    }

    /// @dev One rare-family occurrence, fired once at or after `at`, so every run exercises it whatever the odds draw.
    struct Scheduled {
        Action action;
        uint256 at;
        bool fired;
    }

    /// @dev What a supplier put in and took out.
    struct LenderLedger {
        uint256 loanIn;
        uint256 loanOut; // everything that left on the supplier's behalf, exit-book fees included
        uint256 collateralOut;
        uint256 collateralOutValue; // at the oracle price when it moved
        uint256 debtCanceled;
        uint256 scaledIn; // each flow in over the supply index when it moved; the fee recipient's fees count here
        uint256 scaledOut; // each flow out, loan assets or settled debt, over the supply index when it moved
        uint256 ops;
        uint256 cuts;
    }

    /// @dev What a borrower put in, took out, lost to liquidations and settlements, and had written off.
    struct BorrowerLedger {
        uint256 collateralFunded;
        uint256 collateralIn;
        uint256 collateralOut;
        uint256 collateralSeized;
        uint256 loanBorrowed;
        uint256 loanRoutedAway; // borrowed straight to another account
        uint256 loanReceived; // another borrower's loan routed here
        uint256 loanRepaid;
        uint256 loanFunded;
        uint256 liqRepaid;
        uint256 liqSeizedValue;
        uint256 liquidations;
        uint256 settleCanceled;
        uint256 settleSeizedValue;
        uint256 badDebt;
        uint256 settlementLtv; // the personal settlement target last set; zero opts out
        bool forced; // a liquidation or settlement cut since the debt last cleared; lifts the floor check
    }

    /// @dev Market-wide totals the test computes itself and later compares with the protocol's books.
    struct Globals {
        uint256 loanMinted;
        uint256 collateralMinted;
        uint256 interest;
        uint256 feeAmount;
        uint256 badDebt;
        uint256 supplyIndex; // worth of a loan-asset unit supplied at the start, scaled by INDEX_SCALE
        uint256 minPrice;
        uint256 maxPrice;
        uint256 crashes;
        uint256 moves;
        uint256 cuts;
        uint256 accruals;
        uint256 badDebtGate; // settle attempts the bad-debt gate stopped
        uint256 pauses;
        uint256 caps;
        uint256 bans;
        uint256 donatedLoanToVault;
        uint256 donatedLoanToCore;
        uint256 donatedCollateralToCore;
        uint256 thirdPartyShares; // core supply shares gifted to the vault; nobody can claim them
        uint256 thirdPartyAssets;
        uint256 bookFilled;
        uint256 bookReceiver;
        uint256 bookReward;
        uint256 bookService;
    }

    Random.Context internal random;
    uint256 internal unit; // one whole loan token in raw units
    uint256 internal lltv;
    uint256 internal floor; // minActivationAmount: a position with debt keeps at least this much collateral
    uint256 internal minSettle; // smallest settle request: 100 loan tokens, always worth several collateral units

    address[] internal lenders; // through the vault
    address[] internal directLenders; // straight into the core
    address[] internal borrowers;
    /// @dev The borrowers the everyday repay, collateral-withdrawal and settlement-target draws range over. Leveraged
    ///      borrowers are absent by archetype, not by eligibility.
    address[] internal unleveragedBorrowers;
    address[] internal keepers; // liquidators, exit-book fillers, donors
    address internal feeRecipient;
    address internal bookService;
    address internal guardian2; // the second guardian; with this contract it makes the quorum of two
    Erc4626ExitBook internal book;
    mapping(address => bool) internal instant; // borrowers whose collateral activates at once
    /// @dev The spec's activation state machine: it predicts each collateral move, and the controller must equal it.
    ActivationModel.State internal activation;
    /// @dev Whether each top-level test call is its own transaction: true on forge 1.8.x, false on 1.7.x. The model
    ///      closes transactions where forge does, so its reductions give back the same inflow as the controller's.
    bool internal perCallTransactions;
    /// @dev Leveraged borrowers; `_supplyCollateral` never draws them, so only their own borrow move adds collateral.
    mapping(address => bool) internal leveraged;

    mapping(address => LenderLedger) internal lender; // vault lenders, direct lenders and the fee recipient
    mapping(address => BorrowerLedger) internal borrower;
    Globals internal g;

    /// @dev When the last pause began and how long it runs. `_fireDue` draws the `Resume` offset from these, not from
    ///      the `Pause` entry's due time, so the resume lands inside the real pause.
    uint256 internal pauseStart;
    uint256 internal pauseDuration;
    /// @dev The pause and the guardian bans as the model predicts them, which every gate reads: the pause lapses at
    ///      `pauseUntil`, set by `_pauseFor` and cut to now by a resume; a ban is latched by the quorum flag and
    ///      cleared by the unban. `_advanceSlot` checks the contracts agree every slot.
    uint256 internal pauseUntil;
    mapping(address => bool) internal bannedModel;
    /// @dev When the run began and how long it lasts. The guardians time their incidents from the start and take no
    ///      incident step past the end.
    uint256 internal runStart;
    uint256 internal runDuration;

    /// @dev Each rare family's occurrence this run, drawn by `_scheduleEvents` and fired by `_fireDue`.
    Scheduled[] internal schedule;

    mapping(Action => uint256) internal bps; // chance per iteration
    mapping(Action => uint256) internal count; // successful moves
    mapping(Action => uint256) internal amount; // raw units moved
    mapping(Action => uint256) internal noEligible; // draws with nobody able to act
    mapping(Action => uint256) internal predicted; // draws that hit a predicted revert

    // ---
    // SETUP
    // ---

    function _loanDecimals() internal pure virtual returns (uint8);

    /// @dev Where the collateral price starts, in the core's `1e36 * 10 ** (loanDecimals - 18)` scale. The seed picks a
    ///      value in `[low, high)`, the band of the market the suite is named for.
    function _priceBand() internal pure virtual returns (uint256 low, uint256 high);

    /// @dev Next oracle price from the current one. The market decides the shape of the walk.
    function _stepPrice(uint256 current) internal virtual returns (uint256);

    /// @dev The crash's multiplier on the price, in WAD; `WAD` means the market never crashes and none is scheduled.
    function _crashFactor() internal view virtual returns (uint256);

    /// @dev Human-readable name of an action, for logs and for a schedule entry that never came due.
    function _name(Action a) internal pure virtual returns (string memory);

    /// @dev The interest-rate model the market runs on: the fixed rate, whose interest the model derives on its
    ///      own, or the adaptive curve, whose pre-accrual quote the model takes as its one outside input.
    function _irmKind() internal pure virtual returns (IrmKind) {
        return IrmKind.Fixed;
    }

    /// @dev Deploys the market with a protocol fee, a two-guardian quorum and an exit book, then the actors and odds.
    function _setUpSimulation(Counts memory c) internal {
        irmKind = _irmKind();
        _initSeed();
        // Two top-level calls: the value survives from one to the next only inside a single transaction.
        TransientProbe probe = new TransientProbe();
        probe.set(1);
        perCallTransactions = probe.get() == 0;
        unit = 10 ** _loanDecimals();
        minSettle = 100 * unit;
        (uint256 low, uint256 high) = _priceBand();
        oraclePrice = low + oraclePrice % (high - low);
        MockERC20 loan = new MockERC20("Loan", "LOAN", _loanDecimals());
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        guardian2 = _actor("guardian2");
        cfg.guardians = new address[](2);
        cfg.guardians[0] = address(this);
        cfg.guardians[1] = guardian2;
        cfg.quorum = 2;
        _deployProtocol(cfg);

        Market storage m = _m();
        lltv = m.params.lltv;
        floor = m.controller.collateralActivationConfig().minActivationAmount;

        feeRecipient = _actor("feeRecipient");
        protocol.core.setFeeRecipient(feeRecipient);
        protocol.core.setFee(m.params, FEE);
        assertEq(m.core.market(m.id).fee, FEE, "setup: fee not stored");

        bookService = _actor("bookService");
        book = new Erc4626ExitBook(address(this), BOOK_LIFETIME);
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), address(this));
        book.grantRole(book.FEE_MANAGER_ROLE(), address(this));
        book.grantRole(book.PAUSER_ROLE(), address(this));
        book.grantRole(book.RESUMER_ROLE(), address(this));
        book.setVaultAllowed(IERC4626(address(m.vault)), true);
        book.setServiceFee(bookService, BOOK_SERVICE_FEE);

        for (uint256 i; i < c.lenders; ++i) {
            address l = _actor(string.concat("lender", vm.toString(i)));
            lenders.push(l);
            vm.prank(l);
            m.vault.approve(address(book), type(uint256).max);
        }
        for (uint256 i; i < c.directLenders; ++i) {
            directLenders.push(_actor(string.concat("direct", vm.toString(i))));
        }
        for (uint256 i; i < c.borrowers; ++i) {
            address b = _actor(string.concat("borrower", vm.toString(i)));
            borrowers.push(b);
            if (i % 4 != 2) unleveragedBorrowers.push(b);
            if (i % 4 == 0) {
                m.setInstantActivation(b, true);
                instant[b] = true;
            } else if (i % 4 == 2) {
                // Instant, so it re-levers in one slot after a liquidation; seeded with collateral only.
                leveraged[b] = true;
                m.setInstantActivation(b, true);
                instant[b] = true;
                _mintCollateral(b, LEVERAGE_TOP_UP);
                borrower[b].collateralFunded += LEVERAGE_TOP_UP;
                _modelSupply(b, LEVERAGE_TOP_UP, true);
                m.supplyCollateralInstant(b, b, LEVERAGE_TOP_UP);
                _assertActivation(b);
                borrower[b].collateralIn += LEVERAGE_TOP_UP;
            }
        }
        for (uint256 i; i < c.keepers; ++i) {
            keepers.push(_actor(string.concat("keeper", vm.toString(i))));
        }
        // Every keeper may borrow for every borrower, so a third-party borrow reaches the ban check on the debt owner.
        for (uint256 i; i < borrowers.length; ++i) {
            for (uint256 j; j < keepers.length; ++j) {
                vm.prank(borrowers[i]);
                protocol.core.setAuthorization(keepers[j], true);
            }
        }

        random = Random.create(seed);
        g.supplyIndex = INDEX_SCALE;
        g.minPrice = oraclePrice;
        g.maxPrice = oraclePrice;
        _setOdds();
    }

    /// @dev Chance of each move per iteration, in basis points. Scheduled families have none, `Crash` included.
    function _setOdds() internal virtual {
        bps[Action.Deposit] = 2500;
        bps[Action.Mint] = 500;
        bps[Action.Withdraw] = 2000;
        bps[Action.Redeem] = 1000;
        bps[Action.SupplyCollateral] = 3000;
        bps[Action.Borrow] = 3000;
        bps[Action.RepayPartial] = 1500;
        bps[Action.RepayFull] = 500;
        bps[Action.WithdrawCollateral] = 1000;
        bps[Action.SetSettlementLtv] = 500;
        bps[Action.Settle] = 500;
        bps[Action.FallbackExit] = 500;
        bps[Action.Liquidate] = 2000;
        bps[Action.LiquidateBadDebt] = 3000;
        bps[Action.PriceStep] = 2000;
        bps[Action.CoreSupply] = 500;
        bps[Action.CoreWithdraw] = 500;
        bps[Action.CoreSettle] = 200;
        bps[Action.PlaceExitRequest] = 500;
        bps[Action.FillExitRequest] = 1000;
        bps[Action.CancelExitRequest] = 200;
        bps[Action.CoreSettleNonRoot] = 200;
        bps[Action.TransferShares] = 300;
        bps[Action.Crash] = 0;
    }

    // ---
    // TIME
    // ---

    /// @dev One slot passes, the guardians run their routine, the pause and the incident's ban are checked against
    ///      the model, and the core accrues, matching the interest, fee and fee shares of `_pendingAccrual`. The
    ///      supply index moves with the accrual and the fee recipient is credited the fee. While paused the accrual
    ///      reverts; the first accrual after resume covers the whole span, which the model reproduces from
    ///      `lastUpdate`.
    function _advanceSlot() internal {
        Market storage m = _m();
        vm.warp(block.timestamp + SLOT);
        vm.roll(block.number + 1);
        address incident = _guardianRoutine();
        assertEq(IPausableUntil(address(m.controller)).isPaused(), _paused(), "slot: pause != model");
        if (incident != address(0)) {
            assertEq(m.guardianSignals.isBanned(m.id, incident), _isBanned(incident), "slot: ban != model");
        }
        if (_paused()) {
            vm.expectRevert(PausableUntil.ResumedExpected.selector);
            m.core.accrueInterest(m.params);
            return;
        }
        MorphoMarket memory mk = m.core.market(m.id);
        (uint256 interest, uint256 feeAmount, uint256 feeShares) = _pendingAccrual(mk);
        uint256 feeBefore = m.core.position(m.id, feeRecipient).supplyShares;

        m.accrueInterest();

        MorphoMarket memory post = m.core.market(m.id);
        assertEq(post.totalBorrowAssets, mk.totalBorrowAssets + interest, "accrue: borrow assets != model");
        assertEq(post.totalSupplyAssets, mk.totalSupplyAssets + interest, "accrue: supply assets != model");
        assertEq(post.totalSupplyShares, mk.totalSupplyShares + feeShares, "accrue: fee shares != model");
        assertEq(
            m.core.position(m.id, feeRecipient).supplyShares, feeBefore + feeShares, "accrue: fee recipient != model"
        );
        g.interest += interest;
        g.feeAmount += feeAmount;
        g.accruals++;
        g.supplyIndex = _indexAfter(mk, interest, feeShares);
        // The fee shares are worth the fee at the share price the accrual leaves.
        lender[feeRecipient].scaledIn += _toScaled(feeAmount);
    }

    /// @dev The interest the core books at its next accrual, from the fixed rate or the adaptive IRM's pre-accrual
    ///      quote, and the fee and the fee shares minted for it.
    function _pendingAccrual(MorphoMarket memory mk)
        internal
        view
        returns (uint256 interest, uint256 feeAmount, uint256 feeShares)
    {
        Market storage m = _m();
        uint256 rate = irmKind == IrmKind.Fixed ? fixedBorrowRate : IIrm(m.irm).borrowRateView(m.params, mk);
        interest = uint256(mk.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(block.timestamp - mk.lastUpdate));
        feeAmount = interest.wMulDown(FEE);
        feeShares = feeAmount.toSharesDown(uint256(mk.totalSupplyAssets) + interest - feeAmount, mk.totalSupplyShares);
    }

    /// @dev `g.supplyIndex` after an accrual of `interest` minting `feeShares` on the totals `mk`, which moves the
    /// share price net of the fee shares by `(A + i) / (S + f)` over `A / S`.
    function _indexAfter(MorphoMarket memory mk, uint256 interest, uint256 feeShares) internal view returns (uint256) {
        if (mk.totalSupplyAssets == 0) return g.supplyIndex;
        return Math.mulDiv(
            g.supplyIndex,
            (uint256(mk.totalSupplyAssets) + interest) * mk.totalSupplyShares,
            uint256(mk.totalSupplyAssets) * (uint256(mk.totalSupplyShares) + feeShares)
        );
    }

    /// @dev `g.supplyIndex` with the interest the core has not booked yet, which only a pause holds back. The vault
    ///      values its shares at the accrued totals even then, so every flow converts at this index.
    function _supplyIndexNow() internal view returns (uint256) {
        MorphoMarket memory mk = _m().core.market(_m().id);
        (uint256 interest,, uint256 feeShares) = _pendingAccrual(mk);
        return _indexAfter(mk, interest, feeShares);
    }

    // ---
    // SCHEDULE
    // ---

    /// @dev Draws one time in `[start + SCHEDULE_MARGIN, end - SCHEDULE_MARGIN]` for each single-shot rare family. The
    ///      five entries `_readyToFire` gates draw from windows that end earlier by their argued wait: the crash's in
    ///      `_assertPriceModelConsequences`, the scenarios' in `_assertCoverage`.
    function _scheduleEvents(uint256 start, uint256 end) internal {
        uint256 lo = start + SCHEDULE_MARGIN;
        uint256 hi = end - SCHEDULE_MARGIN;
        if (_crashFactor() < WAD) {
            schedule.push(Scheduled({action: Action.Crash, at: random.between(lo, end - 26 days), fired: false}));
        }
        schedule.push(Scheduled({action: Action.SetSettlementConfig, at: random.between(lo, hi), fired: false}));
        schedule.push(Scheduled({action: Action.SetActivationConfig, at: random.between(lo, hi), fired: false}));
        schedule.push(Scheduled({action: Action.ThirdPartySupply, at: random.between(lo, hi), fired: false}));
        schedule.push(Scheduled({action: Action.DonateLoanToVault, at: random.between(lo, hi), fired: false}));
        schedule.push(Scheduled({action: Action.DonateLoanToCore, at: random.between(lo, hi), fired: false}));
        schedule.push(Scheduled({action: Action.DonateCollateralToCore, at: random.between(lo, hi), fired: false}));
        // Scenarios: families whose odds cannot carry a coverage floor. Each prepares its state and waits until the
        // model says its move goes through; the pauses end the fallback exit's window 12 slots early, the fill's 80.
        schedule.push(
            Scheduled({action: Action.FallbackExitScenario, at: random.between(lo, hi - 12 * SLOT), fired: false})
        );
        schedule.push(
            Scheduled({action: Action.FillExitRequestScenario, at: random.between(lo, hi - 80 * SLOT), fired: false})
        );
        // A settlement scenario waits out the pause, freeze and cap windows (148 slots) and a bad-debt root, which the
        // write-offs clear within `5 * borrowers.length + 44` iterations of 3.3 slots.
        uint256 settleHi = hi - 148 * SLOT - (5 * borrowers.length + 44) * 10 * SLOT / 3;
        schedule.push(Scheduled({action: Action.SettleScenario, at: random.between(lo, settleHi), fired: false}));
        schedule.push(Scheduled({action: Action.CoreSettleScenario, at: random.between(lo, settleHi), fired: false}));

        // The resume lands 1 to 11 slots into the pause, inside the shortest one; other closers need only spacing.
        _scheduleOpener(Action.Pause, lo, hi, 11);
        _scheduleOpener(Action.SetSupplyCap, lo, hi, 48);
        _scheduleOpener(Action.Freeze, lo, hi, 48);
        _scheduleOpener(Action.PauseBook, lo, hi, 48);
    }

    /// @dev Schedules `opener` in `[lo, hi - SCHEDULE_MARGIN - maxSlots * SLOT]`: its closer comes up to `maxSlots`
    ///      slots after its actual fire, and the extra margin covers a late opener.
    function _scheduleOpener(Action opener, uint256 lo, uint256 hi, uint256 maxSlots) internal {
        uint256 at = random.between(lo, hi - SCHEDULE_MARGIN - maxSlots * SLOT);
        schedule.push(Scheduled({action: opener, at: at, fired: false}));
    }

    /// @dev The closer `opener` schedules when it fires and the slot range of its offset; `maxSlots == 0` means none.
    function _closerFor(Action opener) internal pure returns (Action closer, uint256 minSlots, uint256 maxSlots) {
        if (opener == Action.Pause) return (Action.Resume, 1, 11);
        if (opener == Action.SetSupplyCap) return (Action.RemoveSupplyCap, 1, 48);
        if (opener == Action.Freeze) return (Action.Unfreeze, 1, 48);
        if (opener == Action.PauseBook) return (Action.ResumeBook, 1, 48);
    }

    /// @dev Fires each due entry, one per slot, rescanning after every fire so the slot a fire costs strands no entry.
    ///      An opener schedules its closer from when its effect began. An entry must move or hit a predicted revert,
    ///      and a scenario must move (`_mustSucceed`); a `_nobody` is a schedule bug.
    function _fireDue() internal {
        for (uint256 i = _nextDue(); i != NOTHING_DUE; i = _nextDue()) {
            Scheduled storage s = schedule[i];
            s.fired = true;
            Action a = s.action;
            if (a == Action.Resume) _assertStillPaused();
            bool mustSucceed = _mustSucceed(a);
            uint256 before = mustSucceed ? count[a] : count[a] + predicted[a];
            _execute(a);
            uint256 moved = mustSucceed ? count[a] : count[a] + predicted[a];
            assertGt(
                moved,
                before,
                string.concat("schedule: ", _name(a), mustSucceed ? " did not go through" : " did not fire")
            );
            (Action closer, uint256 minSlots, uint256 maxSlots) = _closerFor(a);
            if (maxSlots != 0) {
                uint256 from = a == Action.Pause ? pauseStart : block.timestamp;
                if (a == Action.Pause) maxSlots = Math.min(maxSlots, pauseDuration / SLOT - 1);
                schedule.push(
                    Scheduled({action: closer, at: from + random.between(minSlots, maxSlots) * SLOT, fired: false})
                );
            }
            _advanceSlot();
        }
    }

    /// @dev The entry `_fireDue` fires next: a due `Resume` first, the one entry with a deadline a burst could push it
    ///      past, then the first other due entry.
    function _nextDue() internal view returns (uint256 next) {
        next = NOTHING_DUE;
        for (uint256 i; i < schedule.length; ++i) {
            Scheduled storage s = schedule[i];
            if (s.fired || s.at > block.timestamp) continue;
            if (!_readyToFire(s.action)) continue;
            if (s.action == Action.Resume) return i;
            if (next == NOTHING_DUE) next = i;
        }
    }

    /// @dev Whether a due entry may fire now. For five families `at` is a not-before time: the crash waits for a
    ///      leveraged borrower it would sink past rescue, each scenario for a slot where its move goes through.
    function _readyToFire(Action a) internal view returns (bool) {
        if (a == Action.Crash) return _crashReady();
        if (a == Action.FallbackExitScenario) return _fallbackExitReady();
        if (a == Action.FillExitRequestScenario) return _fillExitRequestReady();
        if (a == Action.SettleScenario) return _settleScenarioOpen() && _vaultMaxDeposit(lenders[0]) >= 2 * minSettle;
        if (a == Action.CoreSettleScenario) return _settleScenarioOpen() && _supplyGate(2 * minSettle).length == 0;
        return true;
    }

    /// @dev True for the scenarios, which `_readyToFire` holds until their move goes through.
    function _mustSucceed(Action a) internal pure returns (bool) {
        return a == Action.FallbackExitScenario || a == Action.FillExitRequestScenario || a == Action.SettleScenario
            || a == Action.CoreSettleScenario;
    }

    /// @dev The scheduled `Resume` must find the market paused: its offset was drawn inside the pause, so a failure
    ///      means it fired late. The message gives the slots since the pause began, its length and its start.
    function _assertStillPaused() internal view {
        assertTrue(
            _paused(),
            string.concat(
                "schedule: resume ",
                vm.toString((block.timestamp - pauseStart) / SLOT),
                " slots into a pause of ",
                vm.toString(pauseDuration / SLOT),
                " slots laid down at ",
                vm.toString(pauseStart)
            )
        );
    }

    // ---
    // MOVES
    // ---

    function _execute(Action a) internal {
        if (a == Action.Deposit) _deposit();
        else if (a == Action.Mint) _mint();
        else if (a == Action.Withdraw) _withdraw();
        else if (a == Action.Redeem) _redeem();
        else if (a == Action.SupplyCollateral) _supplyCollateral();
        else if (a == Action.Borrow) _borrow();
        else if (a == Action.RepayPartial) _repay(false);
        else if (a == Action.RepayFull) _repay(true);
        else if (a == Action.WithdrawCollateral) _withdrawCollateral();
        else if (a == Action.SetSettlementLtv) _setSettlementLtv();
        else if (a == Action.Settle) _settle();
        else if (a == Action.FallbackExit) _fallbackExit();
        else if (a == Action.Liquidate) _liquidate();
        else if (a == Action.LiquidateBadDebt) _liquidateBadDebt();
        else if (a == Action.PriceStep) _priceStep();
        else if (a == Action.Pause) _pause();
        else if (a == Action.Resume) _resume();
        else if (a == Action.Freeze) _freeze();
        else if (a == Action.Unfreeze) _unfreeze();
        else if (a == Action.SetSupplyCap) _setSupplyCap();
        else if (a == Action.CoreSupply) _coreSupply();
        else if (a == Action.CoreWithdraw) _coreWithdraw();
        else if (a == Action.CoreSettle) _coreSettle();
        else if (a == Action.DonateLoanToVault) _donateLoanToVault();
        else if (a == Action.DonateLoanToCore) _donateLoanToCore();
        else if (a == Action.DonateCollateralToCore) _donateCollateralToCore();
        else if (a == Action.ThirdPartySupply) _thirdPartySupply();
        else if (a == Action.PlaceExitRequest) _placeExitRequest();
        else if (a == Action.FillExitRequest) _fillExitRequest();
        else if (a == Action.CancelExitRequest) _cancelExitRequest();
        else if (a == Action.CoreSettleNonRoot) _coreSettleNonRoot();
        else if (a == Action.TransferShares) _transferShares();
        else if (a == Action.SetSettlementConfig) _setSettlementConfig();
        else if (a == Action.SetActivationConfig) _setActivationConfig();
        else if (a == Action.PauseBook) _pauseBook();
        else if (a == Action.ResumeBook) _resumeBook();
        else if (a == Action.Crash) _crash();
        else if (a == Action.FallbackExitScenario) _fallbackExitScenario();
        else if (a == Action.FillExitRequestScenario) _fillExitRequestScenario();
        else if (a == Action.RemoveSupplyCap) _removeSupplyCap();
        else if (a == Action.SettleScenario) _settleScenario();
        else if (a == Action.CoreSettleScenario) _coreSettleScenario();
    }

    // ── Vault lenders ──

    /// @dev A lender puts 1 to 1000 loan tokens into the vault.
    function _deposit() internal {
        _depositBy(lenders[random.index(lenders.length)], random.between(1, 1000) * unit);
    }

    /// @dev `l` deposits `assets` freshly minted loan tokens; above the vault's limit, paused or capped, it must fail.
    function _depositBy(address l, uint256 assets) internal {
        Market storage m = _m();
        _mintLoan(l, assets);
        uint256 max = _vaultMaxDeposit(l);
        if (assets > max) {
            vm.prank(l);
            vm.expectRevert(
                abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, l, assets, max)
            );
            m.vault.deposit(assets, l);
            predicted[Action.Deposit]++;
            return;
        }
        m.vaultDeposit(l, assets);
        _bookIn(l, assets);
        _lenderOp(l, Action.Deposit, assets);
    }

    /// @dev A lender mints vault shares worth 1 to 1000 loan tokens. Above the vault's limit it must fail.
    function _mint() internal {
        Market storage m = _m();
        address l = lenders[random.index(lenders.length)];
        // Sizes the draw and the loan tokens the actor brings; the limit the call is judged against is the model's.
        uint256 shares = Math.max(1, random.between(m.vault.previewDeposit(unit), m.vault.previewDeposit(1000 * unit)));
        _mintLoan(l, m.vault.previewMint(shares));
        uint256 max = _vaultMaxMint(l);
        if (shares > max) {
            vm.prank(l);
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, l, shares, max));
            m.vault.mint(shares, l);
            predicted[Action.Mint]++;
            return;
        }
        uint256 paid = m.vaultMint(l, shares);
        _bookIn(l, paid);
        _lenderOp(l, Action.Mint, paid);
    }

    /// @dev A lender with shares withdraws up to what liquidity allows. With nothing withdrawable (paused or the market
    ///      fully lent out) even one unit must fail.
    function _withdraw() internal {
        Market storage m = _m();
        address l = _pick(lenders, _hasVaultShares);
        if (l == address(0)) return _nobody(Action.Withdraw);
        uint256 max = _vaultMaxWithdraw(l);
        if (max == 0) {
            vm.prank(l);
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, l, 1, 0));
            m.vault.withdraw(1, l, l);
            predicted[Action.Withdraw]++;
            return;
        }
        uint256 assets = random.between(1, max);
        m.vaultWithdraw(l, assets);
        _bookOut(l, assets);
        _lenderOp(l, Action.Withdraw, assets);
    }

    /// @dev A lender with shares redeems up to what liquidity allows. Same limit rule as `_withdraw`.
    function _redeem() internal {
        Market storage m = _m();
        address l = _pick(lenders, _hasVaultShares);
        if (l == address(0)) return _nobody(Action.Redeem);
        uint256 max = _vaultMaxRedeem(l);
        if (max == 0) {
            vm.prank(l);
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, l, 1, 0));
            m.vault.redeem(1, l, l);
            predicted[Action.Redeem]++;
            return;
        }
        uint256 assets = m.vaultRedeem(l, random.between(1, max));
        _bookOut(l, assets);
        _lenderOp(l, Action.Redeem, assets);
    }

    /// @dev An unleveraged borrower sets its personal settlement target: one time in four 0 (opt out), else 30% to 75%.
    function _setSettlementLtv() internal {
        address b = _any(unleveragedBorrowers);
        uint256 ltv = random.chance(2500) ? 0 : random.between(0.3e18, 0.75e18);
        _m().setSettlementLtv(b, ltv);
        borrower[b].settlementLtv = ltv;
        _move(Action.SetSettlementLtv, ltv);
    }

    /// @dev A lender trades vault shares worth part of one to three opted-in borrowers' slices for their collateral at
    ///      par. One draw in ten names none (lender-settlement.md "Targeted vault settlement").
    function _settle() internal {
        address l = _any(lenders);
        (address[] memory targets, uint256 slices) = _settleTargets();
        if (random.chance(1000)) targets = new address[](0);
        uint256 shares = _settleShares(l, slices);
        (address caller, address receiver) = _operatorFor(l, shares);
        _settleExecute(ExitRequest(caller, l, receiver, shares, 0), targets, Action.Settle);
    }

    /// @dev The share request `l` posts against a target list worth `slices` loan assets: one draw in ten, or with
    ///      no shares, one share above its balance; otherwise shares for a random amount from `minSettle` up to what
    ///      its shares and those slices cover, or a single share when that is under `minSettle`. The two previews
    ///      only size the draw.
    function _settleShares(address l, uint256 slices) internal returns (uint256) {
        Market storage m = _m();
        uint256 bal = m.vault.balanceOf(l);
        if (bal == 0 || random.chance(1000)) return bal + 1;
        uint256 cap = Math.min(slices, m.vault.previewRedeem(bal));
        if (cap < minSettle) return 1;
        return Math.max(1, Math.min(bal, m.vault.previewWithdraw(random.between(minSettle, cap))));
    }

    /// @dev Runs the targeted settle of `x.shares` against `targets` under `a`, predicting the vault's rejections in
    ///      its check order. On success every cut is booked from the core's events and must sum to the vault's totals.
    function _settleExecute(ExitRequest memory x, address[] memory targets, Action a) internal {
        Market storage m = _m();
        (MarketActions.SettlementExpectation memory e, uint256[] memory cuts) =
            m.expectedPersonalSettlements(x.shares, targets);
        uint256 balance = m.vault.balanceOf(x.owner);
        bytes memory err;
        if (targets.length == 0) {
            err = abi.encodeWithSelector(ILidoLendERC4626.EmptyBorrowers.selector);
        } else if (x.shares > balance) {
            err = abi.encodeWithSelector(ILidoLendERC4626.ExceededBalance.selector, x.owner, x.shares, balance);
        } else if (_redemptionBudget(x.shares) == 0) {
            err = abi.encodeWithSelector(ILidoLendERC4626.ZeroMorphoSupplyShares.selector);
        } else if (e.cutBorrowShares == 0) {
            err = abi.encodeWithSelector(ILidoLendERC4626.NothingSettled.selector);
        } else {
            err = _settleListGate(targets, cuts);
        }
        if (err.length != 0) {
            vm.prank(x.caller);
            vm.expectRevert(err);
            m.vault.settle(x.shares, targets, x.receiver, x.owner);
            predicted[a]++;
            return;
        }
        vm.recordLogs();
        (, uint256 seized, uint256 canceled) = m.settleBy(x.caller, x.owner, x.shares, targets, x.receiver);
        (uint256 loggedSeized, uint256 loggedCanceled,,) = _bookCuts(x.owner, vm.getRecordedLogs());
        assertEq(loggedSeized, seized, "settle: seized != sum of cuts");
        assertEq(loggedCanceled, canceled, "settle: canceled != sum of cuts");
        _lenderOp(x.owner, a, canceled);
    }

    /// @dev One to three distinct borrowers with a personal slice worth at least one settle request, scanned from a
    ///      random start, and the sum of their slices.
    function _settleTargets() internal returns (address[] memory targets, uint256 slices) {
        uint256 want = random.between(1, 3);
        address[] memory found = new address[](want);
        uint256 n;
        uint256 off = random.index(borrowers.length);
        for (uint256 i; i < borrowers.length && n < want; ++i) {
            address b = borrowers[(off + i) % borrowers.length];
            if (!_hasPersonalSlice(b)) continue;
            found[n++] = b;
            (, uint256 slice) = _m().controller.settlementLtv(b);
            slices += slice;
        }
        targets = new address[](n);
        for (uint256 i; i < n; ++i) {
            targets[i] = found[i];
        }
    }

    /// @dev One exit in five is run by a keeper the owner approved for exactly `shares`, and paid to that keeper.
    function _operatorFor(address owner, uint256 shares) internal returns (address caller, address receiver) {
        if (!random.chance(2000)) return (owner, owner);
        caller = keepers[random.index(keepers.length)];
        vm.prank(owner);
        _m().vault.approve(caller, shares);
        receiver = caller;
    }

    /// @dev A lender leaves through `fallbackExit`: free liquidity pays first (the liquid leg) and the rest settles
    ///      against the riskiest borrowers at par (the settle leg). One draw in twenty names the zero receiver; one in
    ///      ten, and any draw the legs cannot size, asks for one share over the balance. The vault rejects both, in
    ///      that order (lender-settlement.md "Vault fallback exit").
    function _fallbackExit() internal {
        Market storage m = _m();
        address l = _any(lenders);
        uint256 bal = m.vault.balanceOf(l);
        uint256 shares = _fallbackShares(l);
        bool overBalance = shares == 0 || random.chance(1000);
        if (overBalance) shares = bal + 1;
        (address caller, address receiver) = _operatorFor(l, shares);
        if (random.chance(500)) receiver = address(0);
        bytes memory err;
        if (receiver == address(0)) err = abi.encodeWithSelector(ILidoLendERC4626.ZeroAddress.selector);
        else if (overBalance) err = abi.encodeWithSelector(ILidoLendERC4626.ExceededBalance.selector, l, shares, bal);
        if (err.length != 0) {
            vm.prank(caller);
            vm.expectRevert(err);
            m.vault.fallbackExit(shares, receiver, l, 0);
            predicted[Action.FallbackExit]++;
            return;
        }
        uint256 liquid = _freeLiquidity();
        if (caller == l && Erc4626Math.toAssets(m.vault, shares, Math.Rounding.Floor) <= liquid) {
            uint256 paid = m.fallbackExitLiquid(l, shares, l);
            _bookOut(l, paid);
            _lenderOp(l, Action.FallbackExit, paid);
            return;
        }
        _fallbackSettleLeg(ExitRequest(caller, l, receiver, shares, liquid), Action.FallbackExit);
    }

    /// @dev The scheduled fallback exit: a lender exits its whole balance in one call, a random one after depositing
    ///      100 to 1000 tokens if none can. It waits for `_fallbackExitReady`, so a revert is a model error.
    function _fallbackExitScenario() internal {
        Market storage m = _m();
        address l = _pick(lenders, _canExitWholeBalance);
        if (l == address(0)) {
            l = lenders[random.index(lenders.length)];
            _depositBy(l, random.between(100, 1000) * unit);
        }
        uint256 shares = m.vault.balanceOf(l);
        uint256 liquid = _freeLiquidity();
        if (liquid > 0) {
            uint256 paid = m.fallbackExitLiquid(l, shares, l);
            _bookOut(l, paid);
            _lenderOp(l, Action.FallbackExitScenario, paid);
            return;
        }
        _fallbackSettleLeg(ExitRequest(l, l, l, shares, 0), Action.FallbackExitScenario);
    }

    /// @dev Whether `l`'s whole balance can leave in one `fallbackExit` now: free liquidity covers it, or with none
    ///      free the settle leg passes `_exitBlocked`. Liquidity covering part of the balance is excluded, since the
    ///      model cannot predict it: the vault rounds the remainder, and one whose budget rounds to zero reverts.
    function _canExitWholeBalance(address l) internal view returns (bool) {
        Market storage m = _m();
        uint256 bal = m.vault.balanceOf(l);
        if (bal == 0) return false;
        uint256 liquid = _freeLiquidity();
        return liquid > 0 ? Erc4626Math.toAssets(m.vault, bal, Math.Rounding.Floor) <= liquid : !_exitBlocked(bal);
    }

    /// @dev Whether the scheduled fallback exit would go through: unpaused, and a whole-balance exit or an empty vault.
    function _fallbackExitReady() internal view returns (bool) {
        if (_paused()) return false;
        for (uint256 i; i < lenders.length; ++i) {
            if (_canExitWholeBalance(lenders[i])) return true;
        }
        return _emptyVaultAcceptsDeposit();
    }

    /// @dev The scheduled exit-book fill: a lender the market can pay out posts a request and a keeper fills it, after
    ///      a random lender deposits if none can. It fires once `_fillExitRequestReady` holds.
    function _fillExitRequestScenario() internal {
        address l = _pick(lenders, _canFundExitRequest);
        if (l == address(0)) {
            l = lenders[random.index(lenders.length)];
            _depositBy(l, random.between(100, 1000) * unit);
        }
        _fillRequest(_placeRequestFor(l, false), Action.FillExitRequestScenario);
    }

    /// @dev Whether `l` can post a request the market fills at once: a position worth posting and liquidity for the 99%
    ///      a request asks at most. At one share price the fill cannot cross the request's share-burn budget.
    function _canFundExitRequest(address l) internal view returns (bool) {
        Market storage m = _m();
        if (!_canPlaceRequest(l)) return false;
        uint256 position = Erc4626Math.toAssets(m.vault, m.vault.balanceOf(l), Math.Rounding.Floor);
        return _vaultMaxWithdraw(l) >= position * 99 / 100;
    }

    /// @dev Whether the scheduled fill would go through: market and book unpaused, a fundable lender or an empty vault.
    function _fillExitRequestReady() internal view returns (bool) {
        if (_paused() || book.paused()) return false;
        for (uint256 i; i < lenders.length; ++i) {
            if (_canFundExitRequest(lenders[i])) return true;
        }
        return _emptyVaultAcceptsDeposit();
    }

    /// @dev Whether a scenario's deposit goes through into an empty vault, with no shares and no core shares beyond the
    ///      gifts. Only there is the new position worth the deposit, so its liquidity pays the exit out.
    function _emptyVaultAcceptsDeposit() internal view returns (bool) {
        Market storage m = _m();
        if (m.vault.totalSupply() != 0) return false;
        if (m.core.position(m.id, address(m.vault)).supplyShares != g.thirdPartyShares) return false;
        return _vaultMaxDeposit(lenders[0]) >= 1000 * unit;
    }

    /// @dev The scheduled targeted vault settle: a lender deposits `2 * minSettle`, its budget and the target's borrow
    ///      liquidity, `_prepareSettleTarget` readies a borrower, and the lender settles its balance against it.
    function _settleScenario() internal {
        address l = lenders[random.index(lenders.length)];
        _depositBy(l, 2 * minSettle);
        address[] memory targets = new address[](1);
        targets[0] = _prepareSettleTarget();
        _settleExecute(ExitRequest(l, l, l, _m().vault.balanceOf(l), 0), targets, Action.SettleScenario);
    }

    /// @dev The scheduled core settle: a direct lender supplies `2 * minSettle` and cuts `minSettle` of debt from a
    ///      borrower `_prepareSettleTarget` readies, within its allowance, so the settleable-supply limit never binds.
    function _coreSettleScenario() internal {
        address l = directLenders[random.index(directLenders.length)];
        _coreSupplyBy(l, 2 * minSettle);
        address b = _prepareSettleTarget();
        MorphoMarket memory mk = _m().core.market(_m().id);
        uint256 personalShares = _personalAllowedShares(b);
        uint256 cut = Math.min(personalShares, minSettle.toSharesDown(mk.totalBorrowAssets, mk.totalBorrowShares));
        _coreSettlePersonal(l, b, cut, personalShares, Action.CoreSettleScenario);
    }

    /// @dev Picks an unleveraged borrower `_canBeSettleTarget` accepts and makes its personal slice worth at least
    ///      `minSettle`. The preparing borrow fits the collateral supplied with it and the lender's new liquidity. A
    ///      target of half the LTV makes the slice `(debt - target * value) / (1 - target)` at least half the debt.
    function _prepareSettleTarget() internal returns (address b) {
        Market storage m = _m();
        b = _pick(unleveragedBorrowers, _canBeSettleTarget);
        assertTrue(b != address(0), "settle scenario: no borrower to settle");
        if (_debtUp(b) < 2 * minSettle) {
            _supplyInstant(b, Math.mulDiv(8 * minSettle, ORACLE_SCALE, _price()));
            uint256 amt = 2 * minSettle;
            MorphoMarket memory mk = m.core.market(m.id);
            bytes memory err = _borrowGate(b, b, b, amt, amt.toSharesUp(mk.totalBorrowAssets, mk.totalBorrowShares));
            assertEq(err.length, 0, "settle scenario: the model blocks the borrow it prepared");
            m.borrow(b, amt);
            _syncModel(b);
            _assertActivation(b);
            borrower[b].loanBorrowed += amt;
            _move(Action.Borrow, amt);
        }
        uint256 target = _debtUp(b) * WAD / Math.mulDiv(m.core.position(m.id, b).collateral, _price(), ORACLE_SCALE) / 2;
        m.setSettlementLtv(b, target);
        borrower[b].settlementLtv = target;
        _move(Action.SetSettlementLtv, target);
    }

    /// @dev Whether `_prepareSettleTarget` can use `b`: solvent, so a seizure stays inside the collateral, with
    ///      `2 * minSettle` of debt or else instant, unbanned and in an unfrozen market.
    function _canBeSettleTarget(address b) internal view returns (bool) {
        if (_isUnderwater(b)) return false;
        if (_debtUp(b) >= 2 * minSettle) return _m().core.position(_m().id, b).collateral > 0;
        return instant[b] && !_isBanned(b) && !_m().controller.isFrozen();
    }

    /// @dev What both settlement scenarios need besides their lender's funding: the market open, the queue root
    ///      not bad debt, a `minSettle` cut clear of the borrow-share ceiling, and a borrower to prepare.
    function _settleScenarioOpen() internal view returns (bool) {
        if (_paused() || _rootBadDebt()) return false;
        MorphoMarket memory mk = _m().core.market(_m().id);
        if (_rateGate(minSettle.toSharesDown(mk.totalBorrowAssets, mk.totalBorrowShares))) return false;
        for (uint256 i; i < unleveragedBorrowers.length; ++i) {
            if (_canBeSettleTarget(unleveragedBorrowers[i])) return true;
        }
        return false;
    }

    /// @dev One vault exit.
    struct ExitRequest {
        address caller;
        address owner;
        address receiver;
        uint256 shares;
        uint256 liquid; // fallback exit only: the loan assets the market can pay out now
    }

    /// @dev Shares to request: covered by free liquidity or leaving a settle leg of at least `minSettle`, else zero.
    function _fallbackShares(address l) internal returns (uint256) {
        Market storage m = _m();
        uint256 bal = m.vault.balanceOf(l);
        // These reads only size the draw; `_fallbackExit` predicts from the model, so a wrong preview cannot hide.
        uint256 full = m.vault.previewRedeem(bal);
        uint256 liquid = m.controller.maxWithdrawableAssets(address(m.vault));
        uint256 assets;
        if (full < minSettle) return 0; // the position is not worth a whole settle request on either leg
        if (full <= liquid) assets = random.between(minSettle, full);
        else if (full >= liquid + minSettle) assets = random.between(liquid + minSettle, full);
        else if (liquid >= minSettle + 2) assets = random.between(minSettle, liquid - 2); // share rounding may add 1
        else return 0;
        return Math.min(bal, m.vault.previewWithdraw(assets));
    }

    /// @dev The settle leg of a fallback exit: the root's cut is quoted against the budget left after the liquid leg
    ///      and must pass the settle gates; no cut and no liquidity means nothing burns. Only the first of up to 50
    ///      cuts is gated: the pause holds for the call, and a cut at par lowers a solvent root's LTV while every other
    ///      risk key is at most the root's, so each later root is solvent. Not argued: two borrowers with equal rounded
    ///      keys, one underwater, and a later cut crossing the borrow-share ceiling; either fails the run.
    function _fallbackSettleLeg(ExitRequest memory x, Action a) internal {
        Market storage m = _m();
        (address root, uint256 cut) = _rootCutAfterLiquid(x.shares, x.liquid);
        bytes memory err;
        if (cut == 0 && x.liquid == 0) err = abi.encodeWithSelector(ILidoLendERC4626.NothingSettled.selector);
        else if (cut != 0) err = _settleGate(root, cut);
        if (err.length != 0) {
            vm.prank(x.caller);
            vm.expectRevert(err);
            m.vault.fallbackExit(x.shares, x.receiver, x.owner, 0);
            predicted[a]++;
            return;
        }
        _fallbackExitSucceeds(x, a);
    }

    /// @dev Runs a fallback exit that must go through and checks that the logged cuts sum to the vault's totals, that
    ///      with no liquid leg the burn is the ceiling of the settled fraction, and the payout (`_assertExitPayout`).
    function _fallbackExitSucceeds(ExitRequest memory x, Action a) internal {
        Market storage m = _m();
        ExitCheck memory e;
        e.assetsBefore = m.vault.totalAssets();
        e.supplyBefore = m.vault.totalSupply();
        e.settling = _redemptionBudget(x.shares);

        vm.recordLogs();
        (e.burned, e.loanAssets, e.seized, e.canceled) = m.fallbackExitBy(x.caller, x.owner, x.shares, x.receiver, 0);
        _bookOut(x.owner, e.loanAssets);
        (uint256 loggedSeized, uint256 loggedCanceled, uint256 settled, uint256 cuts) =
            _bookCuts(x.owner, vm.getRecordedLogs());
        assertEq(loggedSeized, e.seized, "fallbackExit: seized != sum of cuts");
        assertEq(loggedCanceled, e.canceled, "fallbackExit: canceled != sum of cuts");
        if (x.liquid == 0) {
            uint256 expectedBurn =
                settled == e.settling ? x.shares : Math.mulDiv(x.shares, settled, e.settling, Math.Rounding.Ceil);
            assertEq(e.burned, expectedBurn, "fallbackExit: settle-leg burn != ceil of the settled fraction");
        }
        _assertExitPayout(e, cuts, x.liquid == 0 ? 0 : 2);
        _lenderOp(x.owner, a, e.loanAssets + e.canceled);
    }

    /// @dev Snapshot and results of one exit, in one struct so they take one stack slot (via_ir = false).
    struct ExitCheck {
        uint256 assetsBefore;
        uint256 supplyBefore;
        uint256 settling;
        uint256 burned;
        uint256 loanAssets;
        uint256 seized;
        uint256 canceled;
    }

    /// @dev `payout <= worth + slack` and `worth <= payout + rounding`: both share burns round up, and each cut loses a
    ///      debt unit and a supply share up and under a collateral unit down. `slack` covers the share-price shift a
    ///      liquid leg makes before the settle leg is valued.
    function _assertExitPayout(ExitCheck memory e, uint256 cuts, uint256 slack) internal view {
        uint256 worth = Math.mulDiv(
            e.burned, e.assetsBefore + 1, e.supplyBefore + 10 ** (18 - _loanDecimals()), Math.Rounding.Floor
        );
        uint256 payout = e.loanAssets + Math.mulDiv(e.seized, _price(), ORACLE_SCALE, Math.Rounding.Ceil);
        assertLe(payout, worth + slack, "exit: paid more than the shares were worth");
        uint256 unitsPerCollateral = Math.mulDiv(1, _price(), ORACLE_SCALE, Math.Rounding.Ceil);
        assertLe(worth, payout + 4 + cuts * (2 + unitsPerCollateral), "exit: paid less than the shares were worth");
    }

    // ── Borrowers ──

    /// @dev An unleveraged borrower adds collateral, mostly 10 to 500 tokens. The rest probes the deposit rules: under
    ///      the minimum, a sub-floor lot, and two exact edges an off-by-one would break, the minimum itself and what
    ///      lifts pending dust to the floor. Paused, the hook rejects it before classifying; the model stays as is.
    function _supplyCollateral() internal {
        Market storage m = _m();
        address b = _pick(borrowers, _notLeveraged);
        if (b == address(0)) return _nobody(Action.SupplyCollateral);
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        uint256 roll = random.between(0, 49);
        uint256 amt;
        if (roll == 0) {
            amt = random.between(1, cfg.minDepositAmount - 1);
        } else if (roll < 3) {
            amt = cfg.minDepositAmount;
        } else if (roll < 9) {
            // Prefer an empty position, which then matures holding exactly the floor a borrow needs.
            address fresh = _pick(borrowers, _emptyPosition);
            if (fresh != address(0)) b = fresh;
            amt = floor - activation.lots[b].dust;
        } else if (roll < 13) {
            amt = random.between(cfg.minDepositAmount, floor - 1);
        } else {
            amt = random.between(10 ether, 500 ether);
        }
        _mintCollateral(b, amt);
        borrower[b].collateralFunded += amt;
        bytes memory err = _paused()
            ? abi.encodeWithSelector(PausableUntil.ResumedExpected.selector)
            : _modelSupply(b, amt, instant[b]);
        if (err.length != 0) {
            vm.prank(b);
            vm.expectRevert(err);
            m.core.supplyCollateral(m.params, amt, b, "");
            predicted[Action.SupplyCollateral]++;
            return;
        }
        if (instant[b]) m.supplyCollateralInstant(b, b, amt);
        else m.supplyCollateral(b, amt);
        _assertActivation(b);
        borrower[b].collateralIn += amt;
        _move(Action.SupplyCollateral, amt);
    }

    /// @dev Any borrower borrows between one token and its room (`_borrowRoom`), for itself or another account, by
    ///      assets or by shares; a single share buys nothing and is rejected. Under a token of room it asks for one
    ///      unit more, rejected on capacity only without headroom. Keepers run some draws, testing the owner's own ban.
    ///      A leveraged borrower under `LEVERAGE_FLOOR` is topped up, then takes 90% to 100% of its room.
    function _borrow() internal {
        Market storage m = _m();
        address b = _any(borrowers);
        if (leveraged[b] && !_paused() && m.core.position(m.id, b).collateral < LEVERAGE_FLOOR) {
            _supplyInstant(b, LEVERAGE_TOP_UP);
        }
        uint256 room = _borrowRoom(b);
        uint256 amt = room < unit
            ? room + 1
            : (leveraged[b] ? random.between(room * 90 / 100, room) : random.between(unit, room));
        address receiver = leveraged[b] ? b : (random.chance(2500) ? _anyone() : b);
        address caller = random.chance(2500) ? keepers[random.index(keepers.length)] : b;
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 shares; // nonzero: the borrow is anchored on shares
        if (receiver == b && random.chance(2500)) {
            shares = random.chance(100) ? 1 : amt.toSharesDown(mk.totalBorrowAssets, mk.totalBorrowShares);
            amt = shares.toAssetsDown(mk.totalBorrowAssets, mk.totalBorrowShares);
        }
        uint256 minted = shares != 0 ? shares : amt.toSharesUp(mk.totalBorrowAssets, mk.totalBorrowShares);
        bytes memory err = _borrowGate(b, caller, receiver, amt, minted);
        if (err.length != 0) {
            vm.prank(caller);
            vm.expectRevert(err);
            m.core.borrow(m.params, shares != 0 ? 0 : amt, shares, b, receiver);
            predicted[Action.Borrow]++;
            return;
        }
        amt = _borrowExecute(caller, b, amt, shares, receiver);
        _syncModel(b); // the borrow hook matures the lot before it measures the active balance
        _assertActivation(b);
        borrower[b].loanBorrowed += amt;
        if (receiver != b) {
            borrower[b].loanRoutedAway += amt;
            borrower[receiver].loanReceived += amt;
        }
        _move(Action.Borrow, amt);
    }

    /// @dev Instant caller `b` supplies `amt` fresh collateral, booked as a `SupplyCollateral` move. Called only while
    ///      unpaused, where an instant supply meets no gate.
    function _supplyInstant(address b, uint256 amt) internal {
        _mintCollateral(b, amt);
        borrower[b].collateralFunded += amt;
        _modelSupply(b, amt, true);
        _m().supplyCollateralInstant(b, b, amt);
        _assertActivation(b);
        borrower[b].collateralIn += amt;
        _move(Action.SupplyCollateral, amt);
    }

    /// @dev Why `caller`'s borrow of `amt` assets and `minted` shares for `b`, paid to `receiver`, must fail now, in
    ///      check order (market-controller.md "Borrower gating"); empty when it goes through.
    function _borrowGate(address b, address caller, address receiver, uint256 amt, uint256 minted)
        internal
        view
        returns (bytes memory)
    {
        Market storage m = _m();
        if (_paused()) return abi.encodeWithSelector(PausableUntil.ResumedExpected.selector);
        if (m.controller.isFrozen()) return abi.encodeWithSelector(ILidoLendMarketController.MarketIsFrozen.selector);
        if (amt == 0) return abi.encodeWithSelector(ILidoLendMarketController.ZeroBorrowAssets.selector);
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 postAssets = uint256(mk.totalBorrowAssets) + amt;
        uint256 postShares = uint256(mk.totalBorrowShares) + minted;
        if (_rateOver(postAssets, postShares)) {
            return abi.encodeWithSelector(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        }
        if (_isBanned(caller) || _isBanned(receiver) || _isBanned(b)) {
            return abi.encodeWithSelector(ILidoLendMarketController.AddressBanned.selector);
        }
        if (_overCapacity(b, amt)) {
            return abi.encodeWithSelector(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        }
        Position memory p = m.core.position(m.id, b);
        // The core prices debt at post-borrow totals against all collateral, active or not; only rounding fails here.
        uint256 debt = (uint256(p.borrowShares) + minted).toAssetsUp(postAssets, postShares);
        if (debt > Math.mulDiv(p.collateral, _price(), ORACLE_SCALE).wMulDown(lltv)) {
            return bytes(ErrorsLib.INSUFFICIENT_COLLATERAL);
        }
        if (postAssets > mk.totalSupplyAssets) return bytes(ErrorsLib.INSUFFICIENT_LIQUIDITY);
        return "";
    }

    /// @dev Whether a borrow of `amt` exceeds what `b`'s active collateral grants after the hook's sync: its debt
    ///      rounded up plus the request, against `_capacity`.
    function _overCapacity(address b, uint256 amt) internal view returns (bool) {
        Market storage m = _m();
        ActivationModel.Lot memory lot = _syncedLot(b);
        uint256 active = m.core.position(m.id, b).collateral - lot.dust - lot.activating;
        return _debtUp(b) + amt > _capacity(active);
    }

    /// @dev Runs the borrow and returns the assets paid out: through the asserting `MarketActions` helpers for the
    ///      borrower itself, or under the keeper's prank with the payout and the debt-share delta checked here.
    function _borrowExecute(address caller, address b, uint256 amt, uint256 shares, address receiver)
        internal
        returns (uint256)
    {
        Market storage m = _m();
        if (caller == b) {
            if (shares != 0) return m.borrowByShares(b, shares);
            m.borrowTo(b, amt, receiver);
            return amt;
        }
        uint256 loanBefore = m.loanToken.balanceOf(receiver);
        uint128 sharesBefore = m.core.position(m.id, b).borrowShares;
        vm.prank(caller);
        (uint256 assets, uint256 mintedShares) = m.core.borrow(m.params, shares != 0 ? 0 : amt, shares, b, receiver);
        assertEq(m.loanToken.balanceOf(receiver), loanBefore + assets, "borrow: loan not received");
        assertEq(m.core.position(m.id, b).borrowShares, sharesBefore + mintedShares, "borrow: borrowShares delta");
        return assets;
    }

    function _anyone() internal returns (address) {
        uint256 kind = random.index(3);
        if (kind == 0) return lenders[random.index(lenders.length)];
        if (kind == 1) return keepers[random.index(keepers.length)];
        return borrowers[random.index(borrowers.length)];
    }

    /// @dev An unleveraged borrower repays part or all of its shares, or one partial repay in three an asset amount
    ///      from one share's worth to just under its debt. Without debt it names one share it lacks, and under one
    ///      asset unit of debt even the smallest amount converts to more shares than held. The hook rejects both on the
    ///      position accounting, after the pause and the borrow-share ceiling.
    function _repay(bool full) internal {
        Market storage m = _m();
        Action a = full ? Action.RepayFull : Action.RepayPartial;
        address b = _any(unleveragedBorrowers);
        uint256 bs = m.core.position(m.id, b).borrowShares;
        uint256 shares = full || bs < 2 ? Math.max(bs, 1) : random.between(1, bs - 1);
        uint256 owed = m.repayAssets(shares);
        MorphoMarket memory mk = m.core.market(m.id);
        bool byAssets = !full && random.chance(3300);
        if (byAssets) {
            uint256 oneShare = m.repayAssets(1);
            uint256 debtDown = bs == 0 ? 0 : (bs - 1).toAssetsDown(mk.totalBorrowAssets, mk.totalBorrowShares);
            owed = debtDown >= oneShare ? random.between(oneShare, debtDown) : oneShare;
            shares = owed.toSharesDown(mk.totalBorrowAssets, mk.totalBorrowShares);
        }
        borrower[b].loanFunded += _ensureLoan(b, owed);
        bytes memory err;
        if (_paused()) {
            err = abi.encodeWithSelector(PausableUntil.ResumedExpected.selector);
        } else if (_rateBlocked(mk.totalBorrowAssets, mk.totalBorrowShares, owed, shares)) {
            err = abi.encodeWithSelector(ILidoLendMarketController.BorrowShareRateExceeded.selector);
        } else if (shares > bs) {
            err = abi.encodeWithSelector(ILidoLendMarketController.PositionAccountingMismatch.selector);
        }
        if (err.length != 0) {
            vm.prank(b);
            vm.expectRevert(err);
            if (byAssets) m.core.repay(m.params, owed, 0, b, "");
            else m.core.repay(m.params, 0, shares, b, "");
            predicted[a]++;
            return;
        }
        if (byAssets) m.repayByAssets(b, owed);
        else m.repay(b, shares);
        borrower[b].loanRepaid += owed;
        _syncForced(b);
        _move(a, owed);
    }

    /// @dev An unleveraged borrower takes collateral out within `_collateralWithdrawRange`, or with nothing spare part
    ///      of what it holds, or with nothing a unit it lacks. Three times in ten the draw instead probes the lock or
    ///      the rule that the inactive balance clears whole (market-controller.md "Borrower gating").
    function _withdrawCollateral() internal {
        Market storage m = _m();
        address b = _any(unleveragedBorrowers);
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        ActivationModel.Lot memory lot = _syncedLot(b);
        uint256 coll = m.core.position(m.id, b).collateral;
        uint256 inactive = lot.dust + lot.activating;
        (uint256 lo, uint256 hi) = _collateralWithdrawRange(b);
        uint256 amt = hi >= lo ? random.between(lo, hi) : (coll == 0 ? 1 : random.between(1, coll));
        bytes memory err;
        if (_paused()) {
            err = abi.encodeWithSelector(PausableUntil.ResumedExpected.selector);
        } else if (m.controller.isFrozen() && _hasDebt(b)) {
            err = abi.encodeWithSelector(ILidoLendMarketController.MarketIsFrozen.selector);
        } else if (amt > coll) {
            err = abi.encodeWithSelector(ILidoLendMarketController.PositionAccountingMismatch.selector);
        } else {
            bool locked = ActivationModel.lockBinds(lot, cfg, block.timestamp);
            if (locked && random.chance(3000)) amt = random.between(coll - inactive + 1, coll);
            else if (!locked && inactive > 1 && random.chance(3000)) amt = random.between(1, inactive - 1);
            bool clears;
            (err, clears) = ActivationModel.withdrawOutcome(lot, cfg, coll - inactive, amt, block.timestamp);
            // The hook debits first and then measures what is left: a draw the buckets allow can still leave
            // too little active collateral behind for the debt.
            if (err.length == 0 && _hasDebt(b) && _debtUp(b) > _capacity(coll - (clears ? 0 : inactive) - amt)) {
                err = abi.encodeWithSelector(ILidoLendMarketController.InsufficientActiveCollateral.selector);
            }
        }
        if (err.length != 0) {
            vm.prank(b);
            vm.expectRevert(err);
            m.core.withdrawCollateral(m.params, amt, b, b);
            predicted[Action.WithdrawCollateral]++;
            return;
        }
        _withdrawAndBook(b, amt);
        _move(Action.WithdrawCollateral, amt);
    }

    // ── Keepers ──

    /// @dev A keeper liquidates part of a position, at most collateral worth the debt and never all of it, so no bad
    ///      debt is written off; one call in three is anchored on repaid shares within that bound. The core checks
    ///      health before the hook, so a healthy borrower is rejected even while paused. A position allowing no partial
    ///      seizure is asked for one unit more than it holds and rejected. Keepers search for a target, any borrower
    ///      standing in when none qualifies: a uniform draw would let unhealthy positions drift into bad debt.
    function _liquidate() internal {
        Market storage m = _m();
        address b = _pick(borrowers, _partlyLiquidatable);
        if (b == address(0)) b = _any(borrowers);
        address k = keepers[random.index(keepers.length)];
        uint256 coll = m.core.position(m.id, b).collateral;
        bool healthy = _isHealthy(b);
        uint256 maxSeize = _partialSeize(b);
        uint256 seize = maxSeize == 0 ? coll + 1 : random.between(1, maxSeize);
        uint256 repaidShares;
        if (maxSeize != 0 && random.chance(3300)) {
            uint256 want = random.between(1, m.core.position(m.id, b).borrowShares);
            (uint256 wouldSeize,,) = m.expectedLiquidation(0, want);
            if (wouldSeize != 0 && wouldSeize <= maxSeize) (seize, repaidShares) = (0, want);
        }
        bytes memory err;
        if (healthy) {
            err = bytes(ErrorsLib.HEALTHY_POSITION);
        } else if (_paused()) {
            err = abi.encodeWithSelector(PausableUntil.ResumedExpected.selector);
        } else if (maxSeize == 0) {
            err = abi.encodeWithSelector(ILidoLendMarketController.PositionAccountingMismatch.selector);
        }
        if (err.length != 0) {
            vm.prank(k);
            vm.expectRevert(err);
            m.core.liquidate(m.params, b, seize, repaidShares, "");
            predicted[Action.Liquidate]++;
            return;
        }
        _move(Action.Liquidate, _liquidateSolvent(k, b, seize, repaidShares));
    }

    /// @dev Keeper `k`'s partial liquidation of `b` by `seize` collateral or `repaidShares` shares, funded and booked.
    function _liquidateSolvent(address k, address b, uint256 seize, uint256 repaidShares)
        internal
        returns (uint256 repaid)
    {
        Market storage m = _m();
        (, uint256 repaidAssets,) = m.expectedLiquidation(seize, repaidShares);
        _ensureLoan(k, repaidAssets);
        (uint256 seized, uint256 r) = m.liquidate(k, b, seize, repaidShares);
        repaid = r;
        _bookLiquidation(b, seized, repaid);
    }

    /// @dev A keeper seizes all of a borrower's collateral where that leaves a loss, searching as `_liquidate` does;
    ///      the unpaid debt is written off against every supplier. A seizure leaving no loss, on a solvent or empty
    ///      position, is rejected on the position accounting: it cancels more debt shares than the position holds, or
    ///      takes one collateral unit more than it has.
    function _liquidateBadDebt() internal {
        Market storage m = _m();
        address b = _pick(borrowers, _writeOffReady);
        if (b == address(0)) b = _any(borrowers);
        address k = keepers[random.index(keepers.length)];
        uint256 coll = m.core.position(m.id, b).collateral; // read before the expectation: it must bind to `liquidate`
        uint256 seize = coll == 0 ? 1 : coll;
        bytes memory err;
        if (_isHealthy(b)) {
            err = bytes(ErrorsLib.HEALTHY_POSITION);
        } else if (_paused()) {
            err = abi.encodeWithSelector(PausableUntil.ResumedExpected.selector);
        } else if (coll == 0) {
            err = abi.encodeWithSelector(ILidoLendMarketController.PositionAccountingMismatch.selector);
        } else {
            (, uint256 repaidAssets, uint256 repaid) = m.expectedLiquidation(coll, 0);
            uint256 bs = m.core.position(m.id, b).borrowShares;
            if (_socializedLoss(bs, repaidAssets, repaid) == 0) {
                if (repaid <= bs) seize = coll + 1; // the seizure would close the position, so overshoot instead
                err = abi.encodeWithSelector(ILidoLendMarketController.PositionAccountingMismatch.selector);
            }
        }
        if (err.length != 0) {
            vm.prank(k);
            vm.expectRevert(err);
            m.core.liquidate(m.params, b, seize, 0, "");
            predicted[Action.LiquidateBadDebt]++;
            return;
        }
        _move(Action.LiquidateBadDebt, _writeOff(k, b));
    }

    /// @dev The loss a full seizure socializes on `bs` debt shares repaying `repaidAssets` and `repaid` shares: the
    ///      shares left at the post-repay totals, capped by the debt left. Zero means the seizure closes the position.
    function _socializedLoss(uint256 bs, uint256 repaidAssets, uint256 repaid) internal view returns (uint256) {
        if (repaid >= bs) return 0;
        MorphoMarket memory mk = _m().core.market(_m().id);
        uint256 afterAssets = Math.saturatingSub(mk.totalBorrowAssets, repaidAssets);
        return Math.min(afterAssets, (bs - repaid).toAssetsUp(afterAssets, mk.totalBorrowShares - repaid));
    }

    /// @dev Full seizure of `b` by keeper `k`, funded and booked. Returns the bad debt written off.
    function _writeOff(address k, address b) internal returns (uint256 bad) {
        Market storage m = _m();
        uint256 coll = m.core.position(m.id, b).collateral;
        (, uint256 repaidAssets,) = m.expectedLiquidation(coll, 0);
        _ensureLoan(k, repaidAssets);
        uint256 supplyBefore = m.core.market(m.id).totalSupplyAssets;
        (uint256 seized, uint256 repaid) = m.liquidateBadDebt(k, b, coll, 0);
        bad = supplyBefore - m.core.market(m.id).totalSupplyAssets;
        _bookLiquidation(b, seized, repaid);
        borrower[b].badDebt += bad;
        g.badDebt += bad;
        g.supplyIndex = Math.mulDiv(g.supplyIndex, supplyBefore - bad, supplyBefore);
    }

    // ── Market ──

    /// @dev The oracle moves by the market's walk, capped at eight times the seed price and floored at one eighth while
    ///      at or above it: the scheduled crash may drop below the floor, and nothing pulls the walk back.
    function _priceStep() internal {
        Market storage m = _m();
        uint256 current = _price();
        uint256 p = _stepPrice(current);
        if (current >= oraclePrice / 8) p = Math.max(p, oraclePrice / 8);
        p = Math.min(p, oraclePrice * 8);
        MockPriceOracle(address(m.oracle)).setPrice(p);
        g.minPrice = Math.min(g.minPrice, p);
        g.maxPrice = Math.max(g.maxPrice, p);
        _move(Action.PriceStep, p);
    }

    /// @dev True when the crash would sink a leveraged borrower more than `CRASH_MARGIN` (20%) under water. Undoing 20%
    ///      takes ten upward 2% price steps before the first write-off draw, about 1e-7. Only leveraged borrowers
    ///      count: they never repay, withdraw or opt into settlement, and at or above `LEVERAGE_FLOOR` they get no
    ///      top-up and no seizure below it, so a keeper's write-off is their only way out.
    function _crashReady() internal view returns (bool) {
        uint256 newPrice = _price() * _crashFactor() / WAD;
        for (uint256 i; i < borrowers.length; ++i) {
            address b = borrowers[i];
            if (!leveraged[b]) continue;
            uint256 coll = _m().core.position(_m().id, b).collateral;
            if (coll < LEVERAGE_FLOOR || !_hasDebt(b)) continue;
            if (_debtUp(b) * WAD > Math.mulDiv(coll, newPrice, ORACLE_SCALE) * CRASH_MARGIN) return true;
        }
        return false;
    }

    /// @dev The scheduled crash: multiplies the price by the crash factor once, with no band clamp. `_crashReady` held,
    ///      so a leveraged borrower must be underwater, which beyond rounding makes it ready for a write-off. It stays
    ///      so: a seizure repays less debt than the collateral value it takes, and settlements stop while the queue
    ///      root is bad debt. The root has the highest risk key, so it is underwater whenever any borrower is.
    function _crash() internal virtual {
        uint256 f = _crashFactor();
        require(f < WAD, "crash: no factor");
        Market storage m = _m();
        uint256 newPrice = _price() * f / WAD;
        MockPriceOracle(address(m.oracle)).setPrice(newPrice);
        g.minPrice = Math.min(g.minPrice, newPrice);
        g.crashes++;
        bool drowns;
        for (uint256 i; i < borrowers.length && !drowns; ++i) {
            if (leveraged[borrowers[i]]) drowns = _isUnderwater(borrowers[i]);
        }
        assertTrue(drowns, "crash: no borrower drowns at the crashed price");
        _move(Action.Crash, f);
    }

    // ── Governance and guardians ──

    /// @dev Governance pauses every hook for 12 to 24 slots. Nothing moves until resume or expiry.
    function _pause() internal {
        if (_paused()) return _nobody(Action.Pause);
        uint256 duration = random.between(12, 24) * SLOT;
        _pauseFor(duration);
        (pauseStart, pauseDuration) = (block.timestamp, duration);
        g.pauses++;
        _move(Action.Pause, duration);
    }

    /// @dev Pauses the controller for `duration` and records when the model's pause lapses, which the controller must
    ///      report as its resume timestamp.
    function _pauseFor(uint256 duration) internal {
        _m().pause(duration);
        pauseUntil = block.timestamp + duration;
        assertEq(
            IPausableUntil(address(_m().controller)).getResumeSinceTimestamp(),
            pauseUntil,
            "pause: resume time != model"
        );
    }

    /// @dev Governance lifts a pause before it expires.
    function _resume() internal {
        if (!_paused()) return _nobody(Action.Resume);
        _m().resume();
        pauseUntil = block.timestamp;
        _move(Action.Resume, 0);
    }

    /// @dev Governance freezes the market: no new borrows, no collateral out of positions with debt.
    function _freeze() internal {
        if (_m().controller.isFrozen()) return _nobody(Action.Freeze);
        _m().freeze();
        _move(Action.Freeze, 0);
    }

    function _unfreeze() internal {
        if (!_m().controller.isFrozen()) return _nobody(Action.Unfreeze);
        _m().unfreeze();
        _move(Action.Unfreeze, 0);
    }

    /// @dev Governance moves the supply cap: one time in three it removes it, one time in three it sets it at or below
    ///      the current supply (new deposits must then fail), otherwise above.
    function _setSupplyCap() internal {
        Market storage m = _m();
        uint256 supply = m.core.market(m.id).totalSupplyAssets;
        uint256 roll = random.between(0, 2);
        uint256 cap;
        if (roll == 1) cap = supply - random.between(0, supply / 2);
        else if (roll == 2) cap = supply + random.between(1, 1000) * unit;
        m.setSupplyCap(cap);
        g.caps++;
        _move(Action.SetSupplyCap, cap);
    }

    /// @dev Governance lifts the supply cap. Left under the live supply, a cap would refuse all later deposits and core
    ///      supply and starve borrowing for the rest of the run. Unconditional so it always fires.
    function _removeSupplyCap() internal {
        _m().setSupplyCap(0);
        g.caps++;
        _move(Action.RemoveSupplyCap, 0);
    }

    /// @dev The guardians' routine, the same in every run: it draws nothing and costs no slot. Every slot both
    ///      guardians report the previous block, the latest a heartbeat can name, so the quorum frontier trails the
    ///      clock by one slot. Every `INCIDENT_PERIOD` the next ordinary borrower (odd index: neither instant nor
    ///      leveraged) goes through one incident: this guardian's suspect report on day 1 and flag on day 2, the
    ///      second guardian's flag on day 3, which reaches the quorum and bans it, and governance's unban on day 4.
    ///      The target is ordinary so a ban never blocks a lever the crash waits on or a borrower a settlement
    ///      scenario prepares. The model bans the target with the quorum flag and clears it with the unban. Returns
    ///      the current incident's target, or none past the end.
    function _guardianRoutine() internal returns (address b) {
        Market storage m = _m();
        uint256 scanned = block.timestamp - SLOT;
        m.heartbeatAt(address(this), scanned);
        m.heartbeatAt(guardian2, scanned);
        assertEq(m.guardianSignals.getQuorumFrontier(), scanned, "guardians: frontier != the block both scanned");
        uint256 elapsed = block.timestamp - runStart;
        if (elapsed > runDuration) return address(0);
        b = borrowers[(2 * (elapsed / INCIDENT_PERIOD) + 1) % borrowers.length];
        uint256 day = elapsed % INCIDENT_PERIOD;
        if (day == 1 days) {
            m.suspectAs(address(this), b);
        } else if (day == 2 days) {
            m.flagAs(address(this), b);
        } else if (day == 3 days) {
            m.flagAs(guardian2, b);
            bannedModel[b] = true;
            assertTrue(m.guardianSignals.isBanned(m.id, b), "guardians: the quorum flag did not ban");
            g.bans++;
        } else if (day == 4 days) {
            m.unban(b);
            bannedModel[b] = false;
        }
    }

    /// @dev Governance re-tunes the root settlement policy within its ranges: the debt fraction, the absolute floor,
    ///      the full-close threshold and the LTV step. Later root quotes are checked against the new values.
    function _setSettlementConfig() internal {
        SettlementConfig memory cfg = SettlementConfig({
            sliceFloorBps: uint16(random.between(0, 500)),
            sliceFloorAssets: uint96(random.chance(5000) ? 0 : random.between(1, 100) * unit),
            fullCutBelowCollateral: uint96(random.chance(3000) ? 0 : random.between(1, 50) * 1 ether),
            ltvStepBps: uint16(random.between(0, 300))
        });
        _m().setSettlementConfig(cfg);
        _move(Action.SetSettlementConfig, cfg.sliceFloorBps);
    }

    /// @dev Governance switches the activating lock and the guardian-quorum gate on or off, each independently, so
    ///      lots mature and withdraw under every combination of the two.
    function _setActivationConfig() internal {
        CollateralActivationConfig memory cfg = _m().controller.collateralActivationConfig();
        cfg.activatingLockDuration = random.chance(5000) ? 0 : 3 hours;
        cfg.maxGuardiansQuorumDelay = random.chance(5000) ? 0 : 3 hours;
        _m().setActivationConfig(cfg);
        _move(Action.SetActivationConfig, cfg.activatingLockDuration + cfg.maxGuardiansQuorumDelay);
    }

    /// @dev The book's pauser stops new requests and fills; cancels stay open.
    function _pauseBook() internal {
        if (book.paused()) return _nobody(Action.PauseBook);
        book.pause();
        assertTrue(book.paused(), "book: not paused");
        _move(Action.PauseBook, 0);
    }

    function _resumeBook() internal {
        if (!book.paused()) return _nobody(Action.ResumeBook);
        book.resume();
        assertFalse(book.paused(), "book: still paused");
        _move(Action.ResumeBook, 0);
    }

    /// @dev A lender hands vault shares to another lender, booked as value out and in at today's share price.
    function _transferShares() internal {
        Market storage m = _m();
        address from = _pick(lenders, _hasVaultShares);
        if (from == address(0)) return _nobody(Action.TransferShares);
        address to = lenders[random.index(lenders.length)];
        if (to == from) to = lenders[(random.index(lenders.length) + 1) % lenders.length];
        if (to == from) return _nobody(Action.TransferShares);
        uint256 shares = random.between(1, m.vault.balanceOf(from));
        uint256 value = Erc4626Math.toAssets(m.vault, shares, Math.Rounding.Floor);
        uint256 fromBefore = m.vault.balanceOf(from);
        uint256 toBefore = m.vault.balanceOf(to);
        vm.prank(from);
        m.vault.transfer(to, shares);
        assertEq(m.vault.balanceOf(from), fromBefore - shares, "transfer: sender shares");
        assertEq(m.vault.balanceOf(to), toBefore + shares, "transfer: receiver shares");
        _bookOut(from, value);
        lender[from].ops++;
        _bookIn(to, value);
        _lenderOp(to, Action.TransferShares, value);
    }

    // ── Direct core lenders ──

    /// @dev A direct lender supplies 1 to 1000 loan tokens straight to the core.
    function _coreSupply() internal {
        address l = directLenders[random.index(directLenders.length)];
        _coreSupplyBy(l, random.between(1, 1000) * unit);
    }

    /// @dev `l` supplies `assets` minted loan tokens straight to the core; the pause and cap rejections are predicted.
    function _coreSupplyBy(address l, uint256 assets) internal {
        Market storage m = _m();
        _mintLoan(l, assets);
        bytes memory err = _supplyGate(assets);
        if (err.length != 0) {
            vm.prank(l);
            vm.expectRevert(err);
            m.core.supply(m.params, assets, 0, l, "");
            predicted[Action.CoreSupply]++;
            return;
        }
        m.coreSupply(l, assets);
        _bookIn(l, assets);
        _lenderOp(l, Action.CoreSupply, assets);
    }

    /// @dev A direct lender withdraws up to the smaller of its position and the free liquidity, or one unit when it
    ///      cannot. The core debits shares before checking liquidity, so a position under one unit fails on underflow.
    function _coreWithdraw() internal {
        Market storage m = _m();
        address l = _any(directLenders);
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 free = mk.totalSupplyAssets - mk.totalBorrowAssets;
        uint256 needed = uint256(1).toSharesUp(mk.totalSupplyAssets, mk.totalSupplyShares);
        bytes memory err;
        if (_paused()) err = abi.encodeWithSelector(PausableUntil.ResumedExpected.selector);
        else if (needed > m.core.position(m.id, l).supplyShares) err = stdError.arithmeticError;
        else if (free == 0) err = bytes(ErrorsLib.INSUFFICIENT_LIQUIDITY);
        if (err.length != 0) {
            vm.prank(l);
            vm.expectRevert(err);
            m.core.withdraw(m.params, 1, 0, l, l);
            predicted[Action.CoreWithdraw]++;
            return;
        }
        uint256 assets = random.between(1, Math.min(_supplyAssetsDown(l), free));
        m.coreWithdrawAssets(l, assets);
        _bookOut(l, assets);
        _lenderOp(l, Action.CoreWithdraw, assets);
    }

    /// @dev A direct lender settles the queue root under the root policy, with its supply shares as budget. A budget
    ///      buying no cut (no supply, an empty queue, a quote under the seizure floor) leaves a zero-share settle,
    ///      which the core rejects (lender-settlement.md "Seizure floor"). A cut above the root's personal allowance
    ///      must fit the lender's settleable supply ("Controller execution rules").
    function _coreSettle() internal {
        Market storage m = _m();
        address l = _any(directLenders);
        (address root, uint256 cut) = _rootCutFor(m.core.position(m.id, l).supplyShares);
        bytes memory err;
        if (cut == 0) err = bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL);
        else if (_burnExceedsSupply(l, cut)) err = bytes(ErrorsLib.SETTLEMENT_EXCEEDS_SUPPLY);
        else err = _settleGate(root, cut);
        if (err.length == 0 && _tailGate(l, root, cut)) {
            err = abi.encodeWithSelector(ILidoLendMarketController.SettlementExceedsSettleableSupply.selector);
        }
        if (err.length != 0) {
            vm.prank(l);
            vm.expectRevert(err);
            m.core.settle(m.params, cut, l, root, l);
            predicted[Action.CoreSettle]++;
            return;
        }
        (uint256 seized, uint256 canceled) = m.coreSettle(l, root, cut, l);
        _bookCut(l, root, seized, canceled);
        _lenderOp(l, Action.CoreSettle, canceled);
    }

    /// @dev A direct lender with supply settles a borrower that is not the queue root. A cut within that borrower's
    ///      personal allowance is a personal settlement; one share above it is rejected as exceeding the allowance.
    function _coreSettleNonRoot() internal {
        address l = _pick(directLenders, _hasCoreSupply);
        if (l == address(0)) return _nobody(Action.CoreSettleNonRoot);
        address b = _nonRootBorrower();
        if (b == address(0)) return _nobody(Action.CoreSettleNonRoot);
        (uint256 cut, uint256 personalShares) = _nonRootCut(l, b);
        _coreSettlePersonal(l, b, cut, personalShares, Action.CoreSettleNonRoot);
    }

    /// @dev `l`'s direct settle of `cut` shares of `b`, with personal allowance `personalShares`, booked under `a`. The
    ///      `_nonRootGate` order also holds for the root: a cut within the allowance is personal whoever the root is.
    function _coreSettlePersonal(address l, address b, uint256 cut, uint256 personalShares, Action a) internal {
        Market storage m = _m();
        bytes memory err = _nonRootGate(l, b, cut, personalShares);
        if (err.length != 0) {
            vm.prank(l);
            vm.expectRevert(err);
            m.core.settle(m.params, cut, l, b, l);
            predicted[a]++;
            return;
        }
        (uint256 seized, uint256 canceled) = m.coreSettle(l, b, cut, l);
        _bookCut(l, b, seized, canceled);
        _lenderOp(l, a, canceled);
    }

    /// @dev The cut `l` tries on the non-root `b`, with `b`'s personal allowance in borrow shares: seven times in ten
    ///      a cut between the smallest one that buys a collateral unit and the largest the lender's shares fund,
    ///      within the allowance; otherwise, or when the allowance or the lender's shares cannot fund that smallest
    ///      cut, one share above the allowance. Never more than the debt.
    function _nonRootCut(address l, address b) internal returns (uint256 cut, uint256 personalShares) {
        MorphoMarket memory mk = _m().core.market(_m().id);
        personalShares = _personalAllowedShares(b);
        uint256 unitAssets = Math.mulDiv(1, _price(), ORACLE_SCALE, Math.Rounding.Ceil);
        uint256 floorCut = unitAssets.toSharesUp(mk.totalBorrowAssets, mk.totalBorrowShares) + 1;
        uint256 affordable = _supplyAssetsDown(l).toSharesDown(mk.totalBorrowAssets, mk.totalBorrowShares);
        if (random.chance(3000) || personalShares < floorCut || affordable < floorCut) cut = personalShares + 1;
        else cut = random.between(floorCut, Math.min(personalShares, affordable));
        cut = Math.min(cut, uint256(_m().core.position(_m().id, b).borrowShares));
    }

    /// @dev Whether the core's burn for a cut of `cut` borrow shares exceeds `l`'s supply shares: it derives the burn
    ///      from the canceled debt, rounded up twice, so a cut quoted against a whole budget can overshoot it.
    function _burnExceedsSupply(address l, uint256 cut) internal view returns (bool) {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 canceled = cut.toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
        return canceled.toSharesUp(mk.totalSupplyAssets, mk.totalSupplyShares) > m.core.position(m.id, l).supplyShares;
    }

    /// @dev Why `l`'s settle of `cut` shares of the non-root `b` must fail, in check order; empty when it goes through.
    function _nonRootGate(address l, address b, uint256 cut, uint256 personalShares) internal returns (bytes memory) {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        if (_burnExceedsSupply(l, cut)) return bytes(ErrorsLib.SETTLEMENT_EXCEEDS_SUPPLY);
        if (cut.toAssetsDown(mk.totalBorrowAssets, mk.totalBorrowShares).mulDivDown(ORACLE_SCALE, _price()) == 0) {
            return bytes(ErrorsLib.SETTLEMENT_SLICE_TOO_SMALL);
        }
        bytes memory err = _settleGate(b, cut);
        if (err.length == 0 && cut > personalShares) {
            return abi.encodeWithSelector(ILidoLendMarketController.SettlementExceedsAllowed.selector);
        }
        return err;
    }

    /// @dev A random borrower with debt and collateral other than the queue root, preferably with a slice worth a
    ///      settle request. Any with the top risk key is excluded: equal keys are unordered, so any may be the root.
    function _nonRootBorrower() internal returns (address other) {
        Market storage m = _m();
        (address root,) = m.controller.nextSettlementBorrower(0);
        _assertRoot(root);
        (, uint256 rootKey,) = _modelRoot();
        uint256 n = borrowers.length;
        uint256 off = random.index(n);
        for (uint256 i; i < n; ++i) {
            address b = borrowers[(off + i) % n];
            Position memory p = m.core.position(m.id, b);
            if (p.borrowShares == 0 || p.collateral == 0) continue;
            if (Math.mulDiv(p.borrowShares, WAD, p.collateral) == rootKey) continue;
            if (_hasPersonalSlice(b)) return b;
            if (other == address(0)) other = b;
        }
    }

    /// @dev Whether a cut of `cut` borrow shares would cross the borrow-share ceiling from below.
    function _rateGate(uint256 cut) internal view returns (bool) {
        MorphoMarket memory mk = _m().core.market(_m().id);
        return _rateBlocked(
            mk.totalBorrowAssets, mk.totalBorrowShares, cut.toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares), cut
        );
    }

    /// @dev Whether a root cut of `cut` shares by `l` exceeds the root's personal allowance and does not fit `l`'s
    ///      illiquid tail, the settleable supply: its supply minus the market's free liquidity.
    function _tailGate(address l, address root, uint256 cut) internal view returns (bool) {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 canceled = cut.toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
        uint256 free = mk.totalSupplyAssets - mk.totalBorrowAssets;
        return cut > _personalAllowedShares(root) && canceled > Math.saturatingSub(_supplyAssetsDown(l), free);
    }

    /// @dev `b`'s personal allowance in borrow shares (lender-settlement.md "Personal settlement target"):
    ///      `(debt * WAD - target * collateralValue) / (WAD - target)` at the recorded target and the accrued totals,
    ///      capped at the debt and rounded up into shares; zero without a target or at or under it.
    function _personalAllowedShares(address b) internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory mk = m.accruedMarket();
        Position memory pos = m.core.position(m.id, b);
        uint256 target = borrower[b].settlementLtv;
        uint256 debt = uint256(pos.borrowShares).toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
        uint256 collateralValue = Math.mulDiv(pos.collateral, _price(), ORACLE_SCALE);
        if (target == 0 || collateralValue == 0 || debt * WAD <= target * collateralValue) return 0;
        uint256 slice = Math.min((debt * WAD - target * collateralValue) / (WAD - target), debt);
        return slice.toSharesUp(mk.totalBorrowAssets, mk.totalBorrowShares);
    }

    /// @dev Why a core supply of `assets` must fail right now: paused, or over the cap.
    function _supplyGate(uint256 assets) internal view returns (bytes memory) {
        Market storage m = _m();
        if (_paused()) return abi.encodeWithSelector(PausableUntil.ResumedExpected.selector);
        uint256 cap = LidoLendMarketController(address(m.controller)).supplyCap();
        // The core accrues before it calls the hook, so the total the cap is measured against is the accrued one.
        uint256 attempted = m.accruedMarket().totalSupplyAssets + assets;
        if (cap != 0 && attempted > cap) {
            return abi.encodeWithSelector(ILidoLendMarketController.SupplyCapExceeded.selector, cap, attempted);
        }
        return "";
    }

    // ── Accidental transfers ──

    /// @dev A keeper gifts the vault 1 to 100 loan tokens; it values only its core position, so lenders see no change.
    function _donateLoanToVault() internal {
        Market storage m = _m();
        address k = keepers[random.index(keepers.length)];
        uint256 amt = random.between(1, 100) * unit;
        _mintLoan(k, amt);
        uint256 before = m.vault.totalAssets();
        vm.prank(k);
        m.loanToken.transfer(address(m.vault), amt);
        assertEq(m.vault.totalAssets(), before, "donation: vault counted a gift");
        g.donatedLoanToVault += amt;
        _move(Action.DonateLoanToVault, amt);
    }

    /// @dev A keeper sends loan tokens straight to the core. The books do not move.
    function _donateLoanToCore() internal {
        Market storage m = _m();
        address k = keepers[random.index(keepers.length)];
        uint256 amt = random.between(1, 100) * unit;
        _mintLoan(k, amt);
        MorphoMarket memory before = m.core.market(m.id);
        vm.prank(k);
        m.loanToken.transfer(address(m.core), amt);
        MorphoMarket memory after_ = m.core.market(m.id);
        assertEq(after_.totalSupplyAssets, before.totalSupplyAssets, "donation: core counted a gift");
        g.donatedLoanToCore += amt;
        _move(Action.DonateLoanToCore, amt);
    }

    /// @dev A keeper sends collateral straight to the core. No position moves.
    function _donateCollateralToCore() internal {
        Market storage m = _m();
        address k = keepers[random.index(keepers.length)];
        uint256 amt = random.between(1 ether, 100 ether);
        _mintCollateral(k, amt);
        vm.prank(k);
        m.collateralToken.transfer(address(m.core), amt);
        g.donatedCollateralToCore += amt;
        _move(Action.DonateCollateralToCore, amt);
    }

    /// @dev A keeper supplies loan tokens to the core on the vault's behalf. The vault's core position grows, but its
    ///      managed shares do not, and its total assets move by rounding only: nobody can claim the gift.
    function _thirdPartySupply() internal {
        Market storage m = _m();
        address k = keepers[random.index(keepers.length)];
        uint256 assets = random.between(1, 100) * unit;
        _mintLoan(k, assets);
        bytes memory err = _supplyGate(assets);
        if (err.length != 0) {
            vm.prank(k);
            vm.expectRevert(err);
            m.core.supply(m.params, assets, 0, address(m.vault), "");
            predicted[Action.ThirdPartySupply]++;
            return;
        }
        Approvals.approve(address(m.loanToken), k, address(m.core), assets);
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 expectedShares = assets.toSharesDown(mk.totalSupplyAssets, mk.totalSupplyShares);
        uint256 posBefore = m.core.position(m.id, address(m.vault)).supplyShares;
        uint256 managedBefore = m.vault.managedSupplyShares();
        uint256 assetsBefore = m.vault.totalAssets();
        vm.prank(k);
        m.core.supply(m.params, assets, 0, address(m.vault), "");
        assertEq(m.core.position(m.id, address(m.vault)).supplyShares, posBefore + expectedShares, "gift: shares");
        assertEq(m.vault.managedSupplyShares(), managedBefore, "gift: managed shares moved");
        assertGe(m.vault.totalAssets(), assetsBefore, "gift: vault value fell");
        assertLe(m.vault.totalAssets() - assetsBefore, 2, "gift: vault value rose beyond rounding");
        g.thirdPartyShares += expectedShares;
        g.thirdPartyAssets += assets;
        _move(Action.ThirdPartySupply, assets);
    }

    // ── Exit book ──

    /// @dev Any lender posts a standing exit request for up to 99% of its position, with a random fee ramp and
    ///      deadline, and three times in ten a share-burn budget equal to today's quote. Nothing moves yet.
    function _placeExitRequest() internal {
        _placeRequestFor(_any(lenders), true);
    }

    /// @dev `l` posts a request and returns its id, or zero after a predicted revert. With `probe` it may cross a bound
    ///      (`_placeProbe`); the scheduled fill never probes, firing only where its model says the fill goes through.
    function _placeRequestFor(address l, bool probe) internal returns (uint256) {
        Market storage m = _m();
        // The preview only sizes the request; the backing is judged against the model's quote. The stored request is
        // asserted against the inputs, so later fills and cancels read back values the test chose.
        uint256 assets = _placeAssets(l);
        uint256 quote = Erc4626Math.toShares(m.vault, assets, Math.Rounding.Ceil);
        uint256 maxShareBurn = random.chance(3000) ? quote : 0;
        PriorityRamp memory ramp;
        ramp.endRate = random.between(0, book.MAX_PRIORITY_FEE());
        ramp.startRate = random.between(0, ramp.endRate);
        ramp.rampEnd = random.between(0, 7 days);
        ramp.rampStart = random.between(0, ramp.rampEnd);
        uint256 minFill = random.between(0, assets);
        uint256 deadline = block.timestamp + random.between(ramp.rampEnd + 1, BOOK_LIFETIME);
        if (probe) (ramp.endRate, deadline, maxShareBurn) = _placeProbe(quote, ramp.endRate, deadline, maxShareBurn);
        bytes memory err = _placeGate(l, quote, maxShareBurn, ramp.endRate, deadline);
        if (err.length != 0) {
            vm.prank(l);
            vm.expectRevert(err);
            book.placeExitRequest(IERC4626(address(m.vault)), assets, l, minFill, maxShareBurn, ramp, deadline);
            predicted[Action.PlaceExitRequest]++;
            return 0;
        }
        vm.prank(l);
        uint256 id = book.placeExitRequest(IERC4626(address(m.vault)), assets, l, minFill, maxShareBurn, ramp, deadline);
        {
            Request memory r = book.getExitRequest(id);
            assertEq(r.owner, l, "place: owner");
            assertEq(r.receiver, l, "place: receiver");
            assertEq(r.createdAt, block.timestamp, "place: creation time");
            assertEq(r.deadline, deadline, "place: deadline");
            assertEq(r.assetsTotal, assets, "place: total");
            assertEq(r.assetsRemaining, assets, "place: size");
            assertEq(r.minFillAssets, minFill, "place: minimum fill");
            assertEq(r.maxShareBurn, maxShareBurn, "place: share-burn budget");
            assertEq(r.startRate, ramp.startRate, "place: start rate");
            assertEq(r.endRate, ramp.endRate, "place: end rate");
            assertEq(r.rampStart, ramp.rampStart, "place: ramp start");
            assertEq(r.rampEnd, ramp.rampEnd, "place: ramp end");
            assertEq(uint8(r.status), uint8(ExitStatus.Open), "place: open");
        }
        _move(Action.PlaceExitRequest, assets);
        return id;
    }

    /// @dev What `l` asks for: one token up to 99% of its position, or one token when 99% is worth less, which the
    ///      owner may not be able to back.
    function _placeAssets(address l) internal returns (uint256) {
        uint256 most = _m().vault.previewRedeem(_m().vault.balanceOf(l)) * 99 / 100;
        return most < unit ? unit : random.between(unit, most);
    }

    /// @dev One draw in twenty each swaps a valid input for one just past its bound (exit-books.md "Placement and
    ///      backing", "Share-burn protection").
    function _placeProbe(uint256 quote, uint256 endRate, uint256 deadline, uint256 maxShareBurn)
        internal
        returns (uint256, uint256, uint256)
    {
        uint256 roll = random.between(0, 19);
        if (roll == 0) return (book.MAX_PRIORITY_FEE() + 1, deadline, maxShareBurn);
        if (roll == 1) return (endRate, block.timestamp, maxShareBurn);
        if (roll == 2) return (endRate, block.timestamp + BOOK_LIFETIME + 1, maxShareBurn);
        if (roll == 3 && quote > 1) return (endRate, deadline, quote - 1);
        return (endRate, deadline, maxShareBurn);
    }

    /// @dev Why `l`'s placement, quoted at `quote` vault shares, must fail right now, in the book's own check
    ///      order. The allowance never binds: every lender approved the book without limit in setup.
    function _placeGate(address l, uint256 quote, uint256 maxShareBurn, uint256 endRate, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        if (book.paused()) return abi.encodeWithSelector(ExitBookBase.EnforcedPause.selector);
        if (_m().vault.balanceOf(l) < quote) {
            return abi.encodeWithSelector(Erc4626ExitBook.InsufficientBacking.selector);
        }
        if (maxShareBurn != 0 && maxShareBurn < quote) {
            return abi.encodeWithSelector(ExitBookBase.MaxShareBurnBelowQuote.selector, maxShareBurn, quote);
        }
        if (endRate > book.MAX_PRIORITY_FEE()) return abi.encodeWithSelector(ExitBookBase.PriorityFeeTooHigh.selector);
        if (deadline <= block.timestamp) return abi.encodeWithSelector(ExitBookBase.DeadlineInPast.selector);
        if (deadline > block.timestamp + BOOK_LIFETIME) {
            return abi.encodeWithSelector(ExitBookBase.DeadlineTooFar.selector);
        }
        return "";
    }

    /// @dev A keeper fills part of a request drawn from every id the book issued, open or closed.
    function _fillExitRequest() internal {
        uint256 id = _anyRequest();
        if (id == 0) return _nobody(Action.FillExitRequest);
        _fillRequest(id, Action.FillExitRequest);
    }

    /// @dev A keeper's fill of request `id` under `a`, its revert predicted in check order (exit-books.md "Fill state
    ///      machine", "Share-burn protection"). A failed fill leaves the request untouched; an expired one is
    ///      cancelled. Only everyday fills probe, one draw in ten each, over the remainder and under the minimum.
    function _fillRequest(uint256 id, Action a) internal {
        Market storage m = _m();
        Request memory r = book.getExitRequest(id);
        bool probe = a == Action.FillExitRequest;
        uint256 remaining = r.assetsRemaining;
        uint256 fill;
        if (remaining == 0 || (probe && random.chance(1000))) {
            fill = remaining + 1;
        } else if (probe && r.minFillAssets > 1 && r.minFillAssets < remaining && random.chance(1000)) {
            fill = random.between(1, r.minFillAssets - 1);
        } else {
            fill = random.between(Math.max(1, Math.min(r.minFillAssets, remaining)), remaining);
        }
        address k = keepers[random.index(keepers.length)];
        bytes memory err;
        uint256 max = _vaultMaxWithdraw(r.owner);
        uint256 burn = Erc4626Math.toShares(m.vault, fill, Math.Rounding.Ceil);
        uint256 burnCap = r.maxShareBurn == 0
            ? type(uint256).max
            : Math.mulDiv(r.maxShareBurn, fill, r.assetsTotal, Math.Rounding.Ceil);
        if (book.paused()) {
            err = abi.encodeWithSelector(ExitBookBase.EnforcedPause.selector);
        } else if (r.status != ExitStatus.Open) {
            err = abi.encodeWithSelector(ExitBookLib.RequestClosed.selector);
        } else if (block.timestamp > r.deadline) {
            err = abi.encodeWithSelector(ExitBookLib.RequestExpired.selector);
        } else if (fill > remaining) {
            err = abi.encodeWithSelector(ExitBookBase.FillExceedsRemaining.selector, fill, remaining);
        } else if (fill < r.minFillAssets && fill < remaining) {
            err = abi.encodeWithSelector(ExitBookBase.FillBelowMinimum.selector, fill, r.minFillAssets);
        } else if (fill > max) {
            err = abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, r.owner, fill, max);
        } else if (burn > burnCap) {
            err = abi.encodeWithSelector(ExitBookBase.ShareBurnExceedsMaximum.selector, burn, burnCap);
        }
        if (err.length != 0) {
            vm.prank(k);
            vm.expectRevert(err);
            book.fillExitRequest(id, fill, k);
            assertEq(book.getExitRequest(id).assetsRemaining, remaining, "fill: failed fill moved the request");
            if (r.status == ExitStatus.Open && block.timestamp > r.deadline) _cancel(id);
            predicted[a]++;
            return;
        }
        _fill(id, r, fill, k);
        _lenderOp(r.owner, a, fill);
    }

    /// @dev A fill asserted to the unit: the owner burns shares for `fill`, the receiver gets `fill - fee`, the filler
    ///      `fee - service`, the service `service`; the request is `Filled` exactly when emptied.
    function _fill(uint256 id, Request memory r, uint256 fill, address k) internal {
        Market storage m = _m();
        uint256 fee = Math.mulDiv(fill, _priorityRate(r), WAD);
        uint256 service = Math.mulDiv(fee, BOOK_SERVICE_FEE, WAD);
        uint256 burn = Erc4626Math.toShares(m.vault, fill, Math.Rounding.Ceil);
        uint256[4] memory before = [
            m.loanToken.balanceOf(r.receiver),
            m.loanToken.balanceOf(k),
            m.loanToken.balanceOf(bookService),
            m.vault.balanceOf(r.owner)
        ];
        vm.prank(k);
        book.fillExitRequest(id, fill, k);
        assertEq(m.loanToken.balanceOf(r.receiver) - before[0], fill - fee, "fill: receiver");
        assertEq(m.loanToken.balanceOf(k) - before[1], fee - service, "fill: filler reward");
        assertEq(m.loanToken.balanceOf(bookService) - before[2], service, "fill: service cut");
        assertEq(before[3] - m.vault.balanceOf(r.owner), burn, "fill: shares burned");
        Request memory filled = book.getExitRequest(id);
        assertEq(r.assetsRemaining - filled.assetsRemaining, fill, "fill: request debit");
        ExitStatus status = fill == r.assetsRemaining ? ExitStatus.Filled : ExitStatus.Open;
        assertEq(uint8(filled.status), uint8(status), "fill: status");
        assertEq(m.loanToken.balanceOf(address(book)), 0, "fill: book kept assets");
        _bookOut(r.owner, fill);
        g.bookFilled += fill;
        g.bookReceiver += fill - fee;
        g.bookReward += fee - service;
        g.bookService += service;
    }

    /// @dev The owner cancels a random request. One draw in five names a random account instead; any caller but the
    ///      owner is rejected before the status check, and a filled or cancelled request is rejected on the status.
    function _cancelExitRequest() internal {
        uint256 id = _anyRequest();
        if (id == 0) return _nobody(Action.CancelExitRequest);
        Request memory r = book.getExitRequest(id);
        address caller = random.chance(2000) ? _anyone() : r.owner;
        bytes memory err;
        if (caller != r.owner) err = abi.encodeWithSelector(ExitBookLib.NotOwner.selector);
        else if (r.status != ExitStatus.Open) err = abi.encodeWithSelector(ExitBookLib.RequestClosed.selector);
        if (err.length != 0) {
            vm.prank(caller);
            vm.expectRevert(err);
            book.cancelExitRequest(id);
            predicted[Action.CancelExitRequest]++;
            return;
        }
        _cancel(id);
        _move(Action.CancelExitRequest, 0);
    }

    function _cancel(uint256 id) internal {
        vm.prank(book.getExitRequest(id).owner);
        book.cancelExitRequest(id);
        Request memory r = book.getExitRequest(id);
        assertEq(uint8(r.status), uint8(ExitStatus.Cancelled), "cancel: status");
        assertEq(r.assetsRemaining, 0, "cancel: remainder");
    }

    /// @dev The book's fee: `startRate` until `rampStart`, linear to `endRate` at `rampEnd`, then `endRate`.
    function _priorityRate(Request memory r) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - r.createdAt;
        if (elapsed < r.rampStart) return r.startRate;
        if (elapsed >= r.rampEnd) return r.endRate;
        return r.startRate + (uint256(r.endRate) - r.startRate) * (elapsed - r.rampStart) / (r.rampEnd - r.rampStart);
    }

    /// @dev A random request id, open or closed, or zero while the book has issued none.
    function _anyRequest() internal returns (uint256) {
        uint256 n = book.lastRequestId();
        return n == 0 ? 0 : random.index(n) + 1;
    }

    // ---
    // ELIGIBILITY AND SIZING
    // ---

    function _hasVaultShares(address l) internal view returns (bool) {
        return _m().vault.balanceOf(l) > 0;
    }

    /// @dev The queue root and its borrow-share cut for `budget` core supply shares, both checked against the model.
    function _rootCutFor(uint256 budget) internal view returns (address root, uint256 cut) {
        SettlementSlice memory slice;
        (root, slice) = _m().controller.nextSettlementBorrower(budget);
        _assertRoot(root);
        cut = slice.borrowShares;
        uint256 expected = root == address(0) ? 0 : _m().expectedRootSettlement(root, budget);
        assertEq(cut, expected, "root cut: controller quote != spec recompute");
    }

    /// @dev The root cut a fallback exit of `shares` quotes for its settle leg: the shares left after the liquid
    ///      leg, valued at the vault and core totals that leg leaves behind, converted down into core supply shares.
    function _rootCutAfterLiquid(uint256 shares, uint256 liquid) internal view returns (address, uint256) {
        Market storage m = _m();
        MorphoMarket memory mk = m.accruedMarket();
        uint256 burnedByLiquid = liquid == 0 ? 0 : Erc4626Math.toShares(m.vault, liquid, Math.Rounding.Ceil);
        if (burnedByLiquid >= shares) return (address(0), 0); // the liquid leg covers the whole request
        uint256 coreBurned = liquid.toSharesUp(mk.totalSupplyAssets, mk.totalSupplyShares);
        uint256 supplyAssets = mk.totalSupplyAssets - liquid;
        uint256 supplyShares = mk.totalSupplyShares - coreBurned;
        uint256 vaultAssets = (m.vault.managedSupplyShares() - coreBurned).toAssetsDown(supplyAssets, supplyShares);
        uint256 vaultSupply = m.vault.totalSupply() - burnedByLiquid;
        uint256 redeemAssets = Math.mulDiv(
            shares - burnedByLiquid, vaultAssets + 1, vaultSupply + 10 ** (18 - _loanDecimals()), Math.Rounding.Floor
        );
        return _rootCutFor(redeemAssets.toSharesDown(supplyAssets, supplyShares));
    }

    /// @dev The core supply shares `shares` vault shares may settle against: their floor-rounded worth converted down
    ///      at the accrued totals (lender-settlement.md "Vault accounting boundary"). The vault rejects a zero budget.
    function _redemptionBudget(uint256 shares) internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory mk = m.accruedMarket();
        return Erc4626Math.toAssets(m.vault, shares, Math.Rounding.Floor)
            .toSharesDown(mk.totalSupplyAssets, mk.totalSupplyShares);
    }

    /// @dev Whether a whole-balance `fallbackExit` of `shares` with no liquid leg must revert: its redemption budget is
    ///      zero, the queue quotes no cut for it (an empty queue, a root with no allowance, or a cut under the seizure
    ///      floor, which is a head-of-line stall), or a settle gate rejects the cut.
    function _exitBlocked(uint256 shares) internal view returns (bool) {
        Market storage m = _m();
        if (_redemptionBudget(shares) == 0) return true;
        (address root, uint256 cut) = _rootCutAfterLiquid(shares, 0);
        if (cut == 0) return true;
        MorphoMarket memory accrued = m.accruedMarket();
        (bytes memory err,) = _settleGateAt(root, cut, accrued.totalBorrowAssets, accrued.totalBorrowShares);
        return err.length != 0;
    }

    /// @dev Whether 99% of `l`'s position, the most a request asks for, is worth at least one token, rounded down.
    function _canPlaceRequest(address l) internal view returns (bool) {
        return Erc4626Math.toAssets(_m().vault, _m().vault.balanceOf(l), Math.Rounding.Floor) * 99 / 100 >= unit;
    }

    /// @dev The borrower opted in and sits far enough above its target for one settle request.
    function _hasPersonalSlice(address b) internal view returns (bool) {
        (, uint256 slice) = _m().controller.settlementLtv(b);
        return slice >= minSettle;
    }

    function _hasCoreSupply(address l) internal view returns (bool) {
        return _supplyAssetsDown(l) >= 1;
    }

    function _hasDebt(address b) internal view returns (bool) {
        return _m().core.position(_m().id, b).borrowShares > 0;
    }

    function _notLeveraged(address b) internal view returns (bool) {
        return !leveraged[b];
    }

    /// @dev A borrower with no collateral whose supply goes through activation, neither instant nor leveraged. A supply
    ///      of exactly `minActivationAmount` then matures into exactly the active floor a borrow needs.
    function _emptyPosition(address b) internal view returns (bool) {
        return !leveraged[b] && !instant[b] && _m().core.position(_m().id, b).collateral == 0;
    }

    function _isBanned(address b) internal view returns (bool) {
        return bannedModel[b];
    }

    /// @dev Loan `b` can still take: 99% of its `_capacity` headroom after the hook's sync, capped by free liquidity.
    function _borrowRoom(address b) internal view returns (uint256) {
        Market storage m = _m();
        ActivationModel.Lot memory lot = _syncedLot(b);
        uint256 active = m.core.position(m.id, b).collateral - lot.dust - lot.activating;
        uint256 maxBorrow = _capacity(active);
        uint256 debt = _debtUp(b);
        if (maxBorrow <= debt) return 0;
        MorphoMarket memory mk = m.core.market(m.id);
        return Math.min((maxBorrow - debt) * 99 / 100, mk.totalSupplyAssets - mk.totalBorrowAssets);
    }

    /// @dev Loan assets `active` collateral units can back at the market LLTV, and nothing at all below the
    ///      activation floor, where the controller grants no capacity (market-controller.md "Borrower gating").
    function _capacity(uint256 active) internal view returns (uint256) {
        return active < floor ? 0 : Math.mulDiv(active, _price(), ORACLE_SCALE).wMulDown(lltv);
    }

    /// @dev The core's health test: debt rounded up at the accrued totals against the LLTV value of all collateral,
    ///      active or not. Only an unhealthy position, which has debt, can be liquidated.
    function _isHealthy(address b) internal view returns (bool) {
        Market storage m = _m();
        Position memory p = m.core.position(m.id, b);
        if (p.borrowShares == 0) return true;
        MorphoMarket memory mk = m.accruedMarket();
        uint256 debt = uint256(p.borrowShares).toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
        return Math.mulDiv(p.collateral, _price(), ORACLE_SCALE).wMulDown(lltv) >= debt;
    }

    /// @dev The withdrawal range: 90% of the collateral above what the debt needs at LLTV and the floor, within the
    ///      active balance while the lock binds, else at least the whole inactive balance.
    function _collateralWithdrawRange(address b) internal view returns (uint256 lo, uint256 hi) {
        Market storage m = _m();
        uint256 coll = m.core.position(m.id, b).collateral;
        if (coll == 0) return (1, 0);
        uint256 debt = _debtUp(b);
        uint256 keep;
        if (debt > 0) {
            uint256 needed = Math.mulDiv(
                Math.mulDiv(debt, WAD, lltv, Math.Rounding.Ceil), ORACLE_SCALE, _price(), Math.Rounding.Ceil
            );
            keep = Math.max(needed, floor);
        }
        ActivationModel.Lot memory lot = _syncedLot(b);
        uint256 inactive = lot.dust + lot.activating;
        if (ActivationModel.lockBinds(lot, m.controller.collateralActivationConfig(), block.timestamp)) {
            uint256 active = coll - inactive;
            return active <= keep ? (1, 0) : (1, (active - keep) * 9 / 10);
        }
        if (coll <= keep) return (1, 0);
        lo = Math.max(1, inactive);
        hi = (coll - keep) * 9 / 10;
    }

    /// @dev Debt above the LLTV line but below the collateral value: a partial liquidation loses nothing.
    function _isUnhealthySolvent(address b) internal view returns (bool) {
        uint256 coll = _m().core.position(_m().id, b).collateral;
        if (coll < 2 || !_hasDebt(b)) return false;
        uint256 debt = _debtUp(b);
        uint256 value = Math.mulDiv(coll, _price(), ORACLE_SCALE);
        return debt > value.wMulDown(lltv) && debt <= value && _maxSolventSeize(b) > 0;
    }

    /// @dev The most collateral one partial liquidation of `b` may take: none from a healthy or empty position,
    ///      otherwise `_maxSolventSeize`, but never taking a leveraged borrower under `LEVERAGE_FLOOR`, where `_borrow`
    ///      would top it up and rescue a borrower the crash needs written off.
    function _partialSeize(address b) internal view returns (uint256) {
        uint256 coll = _m().core.position(_m().id, b).collateral;
        if (coll == 0 || _isHealthy(b)) return 0;
        uint256 max = _maxSolventSeize(b);
        return leveraged[b] ? Math.min(max, Math.saturatingSub(coll, LEVERAGE_FLOOR)) : max;
    }

    function _partlyLiquidatable(address b) internal view returns (bool) {
        return _partialSeize(b) != 0;
    }

    /// @dev Whether seizing all of `b`'s collateral leaves debt to write off, as `_liquidateBadDebt`'s move requires:
    ///      the position is unhealthy, holds collateral, and a full seizure socializes a loss.
    function _writeOffReady(address b) internal view returns (bool) {
        Market storage m = _m();
        uint256 coll = m.core.position(m.id, b).collateral;
        if (coll == 0 || _isHealthy(b)) return false;
        (, uint256 repaidAssets, uint256 repaid) = m.expectedLiquidation(coll, 0);
        return _socializedLoss(m.core.position(m.id, b).borrowShares, repaidAssets, repaid) != 0;
    }

    /// @dev Most collateral a solvent liquidation may take: worth the debt at face value, and never the whole position.
    function _maxSolventSeize(address b) internal view returns (uint256) {
        uint256 coll = _m().core.position(_m().id, b).collateral;
        return Math.min(Math.mulDiv(_debtUp(b), ORACLE_SCALE, _price()), coll - 1);
    }

    /// @dev Debt above the collateral value, so seizing everything still leaves debt. The debt is taken at the accrued
    ///      totals the core reaches before any hook, so the answer holds mid-pause, when the stored totals lag.
    function _isUnderwater(address b) internal view returns (bool) {
        Market storage m = _m();
        Position memory p = m.core.position(m.id, b);
        if (p.collateral == 0 || p.borrowShares == 0) return false;
        MorphoMarket memory mk = m.accruedMarket();
        uint256 debt = uint256(p.borrowShares).toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
        return debt > Math.mulDiv(p.collateral, _price(), ORACLE_SCALE);
    }

    /// @dev The queue root the spec implies (lender-settlement.md "Risk queue and bad-debt gate"): of the `tracked`
    ///      borrowers with debt and collateral, the one with the highest risk key `borrowShares * 1e18 / collateral`,
    ///      rounded down. Equal keys are unordered, so `_assertRoot` checks the key, not the address.
    function _modelRoot() internal view returns (address root, uint256 rootKey, uint256 tracked) {
        Market storage m = _m();
        for (uint256 i; i < borrowers.length; ++i) {
            Position memory p = m.core.position(m.id, borrowers[i]);
            if (p.borrowShares == 0 || p.collateral == 0) continue;
            tracked++;
            uint256 key = Math.mulDiv(p.borrowShares, WAD, p.collateral);
            if (root == address(0) || key > rootKey) (root, rootKey) = (borrowers[i], key);
        }
    }

    /// @dev The controller's queue root `root` against the model: none exactly when the model tracks nobody,
    ///      otherwise a borrower with debt and collateral carrying the model's highest risk key.
    function _assertRoot(address root) internal view {
        (, uint256 rootKey, uint256 tracked) = _modelRoot();
        if (tracked == 0) return assertEq(root, address(0), "queue: root without tracked borrowers");
        Position memory r = _m().core.position(_m().id, root);
        assertTrue(r.borrowShares > 0 && r.collateral > 0, "queue: root has no position");
        assertEq(Math.mulDiv(r.borrowShares, WAD, r.collateral), rootKey, "queue: root is not the riskiest");
    }

    /// @dev The bad-debt gate: the model's queue root is underwater (lender-settlement.md "Risk queue and bad-debt
    ///      gate"). Not argued: an underwater and a solvent borrower tied on the key, which fails as a missed revert or
    ///      in `_checkQueueRoot`.
    function _rootBadDebt() internal view returns (bool) {
        (address root,,) = _modelRoot();
        return _isUnderwater(root);
    }

    /// @dev Borrow-share ceiling: `shares + 1e6 > 1e7 * (assets + 1)`.
    function _rateOver(uint256 borrowAssets, uint256 borrowShares) internal view returns (bool) {
        return borrowShares + SharesMathLib.VIRTUAL_SHARES
            > _m().controller.MAX_BORROW_SHARE_RATE() * (borrowAssets + SharesMathLib.VIRTUAL_ASSETS);
    }

    /// @dev A debt reduction is rejected only when it crosses the ceiling from below (market-controller.md
    ///      "Borrow-share-rate transition guard").
    function _rateBlocked(uint256 preAssets, uint256 preShares, uint256 dAssets, uint256 dShares)
        internal
        view
        returns (bool)
    {
        return _rateOver(Math.saturatingSub(preAssets, dAssets), Math.saturatingSub(preShares, dShares))
            && !_rateOver(preAssets, preShares);
    }

    // ---
    // ACTIVATION MODEL
    // ---

    /// @dev The model's side of a collateral supply: the revert the classification owes, or else the hook's maturation
    ///      sync and the classification. A rejected supply reverts the sync too, so the model skips it.
    function _modelSupply(address b, uint256 amt, bool instantCaller) internal returns (bytes memory err) {
        CollateralActivationConfig memory cfg = _m().controller.collateralActivationConfig();
        err = ActivationModel.supplyOutcome(activation.lots[b], cfg, amt, instantCaller);
        if (err.length != 0) return err;
        _syncModel(b);
        ActivationModel.classify(activation, cfg, b, amt, instantCaller);
    }

    /// @dev The maturation sync the collateral-supply, collateral-withdrawal and borrow hooks run before anything else.
    function _syncModel(address b) internal {
        Market storage m = _m();
        ActivationModel.sync(
            activation,
            m.controller.collateralActivationConfig(),
            b,
            m.guardianSignals.getOpinion(m.id, b),
            m.controller.isFrozen()
        );
    }

    /// @dev `b`'s lot after the next hook's sync: stored, with an activating balance that matures counted as active.
    function _syncedLot(address b) internal view returns (ActivationModel.Lot memory lot) {
        Market storage m = _m();
        lot = activation.lots[b];
        bool matured = ActivationModel.matures(
            lot,
            m.controller.collateralActivationConfig(),
            m.guardianSignals.getOpinion(m.id, b),
            m.controller.isFrozen(),
            block.timestamp
        );
        if (matured) (lot.activating, lot.start, lot.baseDelay) = (0, 0, 0);
    }

    /// @dev Runs and books a voluntary withdrawal the model allows. The lot matures first, as in the hook, and a draw
    ///      that had to cover the inactive balance clears both buckets.
    function _withdrawAndBook(address b, uint256 amt) internal {
        Market storage m = _m();
        ActivationModel.Lot memory lot = _syncedLot(b);
        uint256 active = m.core.position(m.id, b).collateral - lot.dust - lot.activating;
        (bytes memory err, bool clears) = ActivationModel.withdrawOutcome(
            lot, m.controller.collateralActivationConfig(), active, amt, block.timestamp
        );
        assertEq(err.length, 0, "withdraw: the model blocks a withdrawal the test takes for granted");
        m.withdrawCollateral(b, amt, b);
        _syncModel(b);
        ActivationModel.reduce(activation, b, clears ? 0 : active, amt);
        _assertActivation(b);
        borrower[b].collateralOut += amt;
    }

    /// @dev Books a forced reduction of `b`'s collateral: a seizure leaves `min(inactive, collateral left)` inactive,
    ///      dust first, which `reduce` reproduces given the collateral left as active and the whole inactive total as
    ///      the amount. It reads the position after the call, so a second cut of the same call trims nothing more.
    function _reduceModel(address b) internal {
        ActivationModel.Lot memory lot = activation.lots[b];
        ActivationModel.reduce(activation, b, _m().core.position(_m().id, b).collateral, lot.dust + lot.activating);
    }

    /// @dev Asserts the controller's activation state equal to the model's after a collateral move: both inactive
    ///      buckets, the active balance, a live lot's unlock time (none when banned) and the market inflow.
    function _assertActivation(address b) internal view {
        Market storage m = _m();
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        GuardiansOpinion memory opinion = m.guardianSignals.getOpinion(m.id, b);
        ILidoLendMarketController.BorrowerPosition memory p = m.controller.positionOf(b);
        ActivationModel.Lot memory lot = activation.lots[b];
        uint256 coll = m.core.position(m.id, b).collateral;
        assertEq(p.dust, lot.dust, "activation: dust != model");
        assertEq(p.activating, lot.activating, "activation: activating != model");
        // The three buckets partition the core's collateral, which ties the controller's accounting to the core's.
        assertEq(p.active, coll - lot.dust - lot.activating, "activation: active != core collateral minus buckets");
        if (lot.activating > 0 && !opinion.banned) {
            assertEq(p.unlockTime, ActivationModel.unlockTime(lot, cfg, opinion), "activation: unlock != model");
        }
        assertEq(
            m.controller.currentInflow(),
            ActivationModel.decayedInflow(activation, cfg, block.timestamp),
            "activation: inflow != model"
        );
    }

    // ---
    // BOOKKEEPING
    // ---

    function _bookLiquidation(address b, uint256 seized, uint256 repaid) internal {
        BorrowerLedger storage L = borrower[b];
        L.collateralSeized += seized;
        L.liqRepaid += repaid;
        L.liqSeizedValue += Math.mulDiv(seized, _price(), ORACLE_SCALE);
        L.liquidations++;
        L.forced = true;
        _syncForced(b);
        _reduceModel(b);
        _assertActivation(b);
    }

    /// @dev `forced` ends once `b` is debt-free, since its next borrow must rebuild the active floor.
    function _syncForced(address b) internal {
        if (_m().core.position(_m().id, b).borrowShares == 0) borrower[b].forced = false;
    }

    /// @dev Books one settlement cut: lender `l` got `seized` collateral, at today's price, for `canceled` debt of `b`.
    function _bookCut(address l, address b, uint256 seized, uint256 canceled) internal {
        uint256 value = Math.mulDiv(seized, _price(), ORACLE_SCALE);
        LenderLedger storage L = lender[l];
        L.collateralOut += seized;
        L.collateralOutValue += value;
        L.debtCanceled += canceled;
        L.scaledOut += _toScaled(canceled);
        L.cuts++;
        BorrowerLedger storage B = borrower[b];
        B.collateralSeized += seized;
        B.settleCanceled += canceled;
        B.settleSeizedValue += value;
        B.forced = true;
        _syncForced(b);
        _reduceModel(b);
        _assertActivation(b);
        g.cuts++;
    }

    /// @dev Books every core `Settle` event of the last call as a cut; returns the totals seized and canceled, the
    ///      core supply shares burned, and the number of cuts.
    function _bookCuts(address l, Vm.Log[] memory logs)
        internal
        returns (uint256 seized, uint256 canceled, uint256 settled, uint256 cuts)
    {
        bytes32 topic = keccak256("Settle(bytes32,address,address,address,address,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(_m().core) || logs[i].topics[0] != topic) continue;
            address b = address(uint160(uint256(logs[i].topics[3])));
            (,, uint256 burned, uint256 cutCanceled,, uint256 cutSeized) =
                abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint256));
            _bookCut(l, b, cutSeized, cutCanceled);
            seized += cutSeized;
            canceled += cutCanceled;
            settled += burned;
            cuts++;
        }
    }

    /// @dev Why a settle of `cut` shares of `b` must fail at the accrued totals: the core rejects a seizure above the
    ///      collateral before its hook checks the pause, the ceiling and the bad-debt root. Counts a bad-debt stop.
    function _settleGate(address b, uint256 cut) internal returns (bytes memory err) {
        MorphoMarket memory mk = _m().accruedMarket();
        bool badDebt;
        (err, badDebt) = _settleGateAt(b, cut, mk.totalBorrowAssets, mk.totalBorrowShares);
        if (badDebt) g.badDebtGate++;
    }

    /// @dev `_settleGate` at explicit borrow totals, for a cut that follows earlier cuts in the same call. `badDebt`
    ///      flags the bad-debt gate as the reason, so a caller that counts stopped attempts can count it.
    function _settleGateAt(address b, uint256 cut, uint256 borrowAssets, uint256 borrowShares)
        internal
        view
        returns (bytes memory, bool badDebt)
    {
        Market storage m = _m();
        uint256 seized = cut.toAssetsDown(borrowAssets, borrowShares).mulDivDown(ORACLE_SCALE, _price());
        if (seized > m.core.position(m.id, b).collateral) {
            return (bytes(ErrorsLib.SETTLEMENT_EXCEEDS_COLLATERAL), false);
        }
        if (_paused()) return (abi.encodeWithSelector(PausableUntil.ResumedExpected.selector), false);
        if (_rateBlocked(borrowAssets, borrowShares, cut.toAssetsUp(borrowAssets, borrowShares), cut)) {
            return (abi.encodeWithSelector(ILidoLendMarketController.BorrowShareRateExceeded.selector), false);
        }
        if (_rootBadDebt()) {
            return (abi.encodeWithSelector(ILidoLendMarketController.SettlementBadDebt.selector), true);
        }
        return ("", false);
    }

    /// @dev The first revert the vault's cuts hit in list order, each judged against the borrow totals the earlier
    ///      cuts leave behind; empty when they all go through.
    function _settleListGate(address[] memory targets, uint256[] memory cuts) internal returns (bytes memory err) {
        MorphoMarket memory mk = _m().accruedMarket();
        for (uint256 i; i < targets.length; ++i) {
            if (cuts[i] == 0) continue;
            bool badDebt;
            (err, badDebt) = _settleGateAt(targets[i], cuts[i], mk.totalBorrowAssets, mk.totalBorrowShares);
            if (badDebt) g.badDebtGate++;
            if (err.length != 0) return err;
            uint256 canceled = cuts[i].toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
            mk.totalBorrowAssets = uint128(Math.saturatingSub(mk.totalBorrowAssets, canceled));
            mk.totalBorrowShares -= uint128(cuts[i]);
        }
    }

    /// @dev Books `assets` put in on `l`'s behalf, as loan assets and scaled.
    function _bookIn(address l, uint256 assets) internal {
        lender[l].loanIn += assets;
        lender[l].scaledIn += _toScaled(assets);
    }

    /// @dev Books `assets` taken out on `l`'s behalf, as loan assets and scaled.
    function _bookOut(address l, uint256 assets) internal {
        lender[l].loanOut += assets;
        lender[l].scaledOut += _toScaled(assets);
    }

    /// @dev `assets` over the supply index now, carried with 18 more decimals than the loan asset so that the
    ///      conversion loses no unit a check could see. Interest and bad debt then move what they are worth exactly as
    ///      they move a supplier's position.
    function _toScaled(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets * WAD, INDEX_SCALE, _supplyIndexNow());
    }

    function _scaledWorth(uint256 scaled) internal view returns (uint256) {
        return Math.mulDiv(scaled, _supplyIndexNow(), INDEX_SCALE * WAD);
    }

    function _lenderOp(address l, Action a, uint256 amt) internal {
        lender[l].ops++;
        _move(a, amt);
    }

    function _move(Action a, uint256 amt) internal {
        count[a]++;
        amount[a] += amt;
        g.moves++;
    }

    function _nobody(Action a) internal {
        noEligible[a]++;
    }

    // ---
    // HELPERS
    // ---

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _paused() internal view returns (bool) {
        return block.timestamp < pauseUntil;
    }

    function _price() internal view returns (uint256) {
        return _m().oracle.price();
    }

    /// @dev Borrower debt in loan assets, rounded up like the core does.
    function _debtUp(address b) internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        return uint256(m.core.position(m.id, b).borrowShares).toAssetsUp(mk.totalBorrowAssets, mk.totalBorrowShares);
    }

    /// @dev A direct supplier's position in loan assets, rounded down like the core does.
    function _supplyAssetsDown(address l) internal view returns (uint256) {
        Market storage m = _m();
        MorphoMarket memory mk = m.core.market(m.id);
        return uint256(m.core.position(m.id, l).supplyShares).toAssetsDown(mk.totalSupplyAssets, mk.totalSupplyShares);
    }

    // ── The vault's four ERC-4626 limits, modeled ──
    //
    // Restated from the specs so a prediction never grades the vault by its own view. Share conversions use
    // `Erc4626Math` on the vault's live totals; `_checkBooks` pins the total they rest on, `totalAssets()`.

    /// @dev The loan assets the vault's core position can pay out now, gifted shares included: the smaller of its worth
    ///      and the market's supply minus borrow, or nothing while paused (lender-settlement.md "Vault fallback exit").
    function _freeLiquidity() internal view returns (uint256) {
        if (_paused()) return 0;
        Market storage m = _m();
        MorphoMarket memory mk = m.accruedMarket();
        uint256 position = uint256(m.core.position(m.id, address(m.vault)).supplyShares)
            .toAssetsDown(mk.totalSupplyAssets, mk.totalSupplyShares);
        return Math.min(position, mk.totalSupplyAssets - mk.totalBorrowAssets);
    }

    /// @dev The assets the vault still admits, whoever deposits: nothing while paused, no limit while uncapped,
    ///      otherwise the room the cap leaves over the accrued supply (market-controller.md "Lender supply cap").
    function _vaultMaxDeposit(address) internal view returns (uint256) {
        if (_paused()) return 0;
        Market storage m = _m();
        uint256 cap = LidoLendMarketController(address(m.controller)).supplyCap();
        if (cap == 0) return type(uint256).max;
        return Math.saturatingSub(cap, m.accruedMarket().totalSupplyAssets);
    }

    /// @dev `_vaultMaxDeposit` in shares, floored; the uncapped sentinel is returned unconverted.
    function _vaultMaxMint(address receiver) internal view returns (uint256) {
        uint256 maxAssets = _vaultMaxDeposit(receiver);
        if (maxAssets == type(uint256).max) return maxAssets;
        return Erc4626Math.toShares(_m().vault, maxAssets, Math.Rounding.Floor);
    }

    /// @dev What `l` can withdraw right now: its shares' floor-rounded worth (lender-settlement.md "Vault
    ///      accounting boundary"), capped by the liquidity that would pay it out.
    function _vaultMaxWithdraw(address l) internal view returns (uint256) {
        Market storage m = _m();
        return Math.min(Erc4626Math.toAssets(m.vault, m.vault.balanceOf(l), Math.Rounding.Floor), _freeLiquidity());
    }

    /// @dev `_vaultMaxWithdraw` in shares: zero without liquidity, the whole balance when liquidity covers it, else the
    ///      liquidity floored into shares; the remainder leaves through `fallbackExit`.
    function _vaultMaxRedeem(address l) internal view returns (uint256) {
        uint256 liquid = _freeLiquidity();
        if (liquid == 0) return 0;
        Market storage m = _m();
        uint256 bal = m.vault.balanceOf(l);
        return Erc4626Math.toAssets(m.vault, bal, Math.Rounding.Floor) <= liquid
            ? bal
            : Erc4626Math.toShares(m.vault, liquid, Math.Rounding.Floor);
    }

    /// @dev A random account from `list` in any state, so the move must predict every outcome.
    function _any(address[] storage list) internal returns (address) {
        return list[random.index(list.length)];
    }

    /// @dev First account, scanning from a random start, that passes `ok`; zero when none does.
    function _pick(address[] storage list, function(address) internal view returns (bool) ok)
        internal
        returns (address)
    {
        uint256 n = list.length;
        uint256 off = random.index(n);
        for (uint256 i; i < n; ++i) {
            address a = list[(off + i) % n];
            if (ok(a)) return a;
        }
        return address(0);
    }

    /// @dev Every token the test creates is recorded, so token conservation can be checked exactly.
    function _mintLoan(address to, uint256 amt) internal {
        _fund(_m().loanToken, to, _m().loanToken.balanceOf(to) + amt);
        g.loanMinted += amt;
    }

    function _mintCollateral(address to, uint256 amt) internal {
        _fund(_m().collateralToken, to, _m().collateralToken.balanceOf(to) + amt);
        g.collateralMinted += amt;
    }

    /// @dev Tops `to` up to `need` loan tokens; returns what was minted.
    function _ensureLoan(address to, uint256 need) internal returns (uint256 minted) {
        uint256 bal = _m().loanToken.balanceOf(to);
        if (bal >= need) return 0;
        minted = need - bal;
        _mintLoan(to, minted);
    }
}
