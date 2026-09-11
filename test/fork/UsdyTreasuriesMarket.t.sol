// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {IRWADynamicOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {ForkStack} from "./helpers/ForkStack.sol";
import {IERC20NoReturn} from "./helpers/ForkTokens.sol";

interface IUsdyBlocklist {
    function owner() external view returns (address);
    function addToBlocklist(address[] calldata accounts) external;
    function isBlocked(address account) external view returns (bool);
}

/// @notice Mainnet-fork scenario for the USD/Treasuries market on the ALREADY-DEPLOYED, ALREADY-ACTIVATED
///         `fork-usdy-usdt` market (USDY collateral, USDT loan), bound via {ForkStack} — never re-deployed, and the
///         `UsdyStableOracle`-over-Ondo-NAV + Chainlink-USDT/USD stack is provisioning's, not the test's.
///         Verifies the market's core constraint: USDY's transfer restriction means a blocklisted address cannot
///         RECEIVE seized collateral — so it can neither liquidate (core `liquidate`) nor be a fallback-exit
///         receiver (vault `fallbackExit` -> settle) — while an eligible (non-blocklisted) address can.
///
///         State-robustness contract (a shared deployed market may already carry supply/borrow):
///         - actors are fresh + market-clean (`_freshActor`), so every per-actor balance check is a delta;
///         - the NAV crash is derived from the LIVE position (its debt/collateral and the live oracle price), so
///           the borrower lands at an exact target LTV band — clearly-underwater for liquidate, unhealthy-but-
///           solvent for settle — regardless of the live USDY NAV, and every expected seizure is recomputed from
///           the mocked oracle price read back after the mock;
///         - idle is MEASURED after pinning free liquidity to a known target (`_pinFreeLiquidity`), never assumed;
///         - the settle leg loudly requires the test borrower to be the queue root and the market to carry no bad
///           debt, so a pre-existing riskier borrower cannot hijack the cut and a bad-debt position cannot block it.
contract UsdyTreasuriesMarketTest is ForkStack {
    BoundMarket internal m;

    // Rebound from the bound market in `setUp` so the tests read like the freshly-deployed variant did.
    ILidoLend internal core;
    ILidoLendERC4626 internal vault;
    MarketParams internal params;
    Id internal marketId;

    // Real mainnet external addresses, resolved from the run's network config.
    address internal USDY; // 18 dec, transfer-gated
    address internal USDT; // 6 dec, nonstandard (no-return approve/transfer)
    address internal ONDO_ORACLE; // USDY NAV source, getPrice() scaled by 1e18
    address internal USDY_BLOCKLIST; // Ownable transfer-gate registry

    // Fresh, market-clean actors (zero position, zero vault shares), so per-actor balance checks double as deltas.
    address internal LENDER;
    address internal BORROWER;
    address internal KEEPER_GOOD; // eligible (not blocklisted)
    address internal KEEPER_BAD; // will be blocklisted

    /// @dev Opening (healthy) LTV for the test borrower, below the live LLTV. The crash targets are expressed
    ///      relative to this, so the post-crash health band is exact at any live NAV.
    uint256 internal constant OPEN_LTV = 0.7e18;
    /// @dev Crash target for the liquidate test: underwater (LTV > 1) — collateral worth less than debt, so the
    ///      position is clearly unhealthy and liquidatable (bad debt is acceptable for `liquidate`) at any NAV.
    uint256 internal constant CRASH_LTV_LIQUIDATE = 1.4e18;
    /// @dev Crash target for the settle/fallbackExit test: strictly inside `(LLTV, 1)` — unhealthy but solvent, so
    ///      the position is settle-eligible with no bad debt at any NAV.
    uint256 internal constant CRASH_LTV_SETTLE = 0.93e18;

    // Loan-token (USDT, 6 dec) sizes. Deliberately modest; every borrow clears DUST_MARKET_MIN_BORROW (1e5).
    uint256 internal constant BORROW_LIQUIDATE = 500e6;
    uint256 internal constant LENDER_SUPPLY_LIQUIDATE = 1_000e6;
    uint256 internal constant KEEPER_USDT = 1_000e6;
    uint256 internal constant LENDER_DEPOSIT_SETTLE = 600e6;
    uint256 internal constant BORROW_SETTLE = 550e6;
    uint256 internal constant IDLE_TARGET = 40e6;

    function setUp() public {
        _fork();
        string memory market_ = _marketForRole("usdy-usdt");
        if (bytes(market_).length == 0) return; // not applicable to this deployment
        m = _bindMarket(market_);
        _pokeAccrue(m); // fold in pending interest up front so the sizing/liquidity math below is exact

        core = m.core;
        vault = m.vault;
        params = m.params;
        marketId = m.id;

        USDY = address(m.collateralToken);
        USDT = address(m.loanToken);
        ONDO_ORACLE = _ext("ondoOracle");
        USDY_BLOCKLIST = _ext("usdyBlocklist");

        // Artifact/market coherence: the bound market must be the USDY-collateral / USDT-loan market the suite
        // targets, not some other market a mis-named artifact pointed at.
        require(params.loanToken == _ext("usdt"), "UsdyTreasuries: bound loan token is not USDT");
        require(params.collateralToken == _ext("usdy"), "UsdyTreasuries: bound collateral token is not USDY");

        // The crash targets must be in-band against the LIVE LLTV (not a hardcoded assumption): opens healthy,
        // the settle band lies strictly inside (LLTV, 1), the liquidate band is underwater.
        require(OPEN_LTV < params.lltv, "UsdyTreasuries: OPEN_LTV must open healthy below the live LLTV");
        require(
            params.lltv < CRASH_LTV_SETTLE && CRASH_LTV_SETTLE < WAD,
            "UsdyTreasuries: settle crash target must sit inside (LLTV, 1)"
        );
        require(CRASH_LTV_LIQUIDATE > WAD, "UsdyTreasuries: liquidate crash target must be underwater");

        LENDER = _freshActor(m, "usdyTreasuries.lender");
        BORROWER = _freshActor(m, "usdyTreasuries.borrower");
        KEEPER_GOOD = _freshActor(m, "usdyTreasuries.keeperEligible");
        KEEPER_BAD = _freshActor(m, "usdyTreasuries.keeperBlocklisted");
    }

    /// @dev Borrower posts USDY collateral sized so the opening position sits at `OPEN_LTV` at the live price
    ///      (floored at twice the live activation dust so the lot both matures and carries real borrow capacity),
    ///      waits out the live activation delay, and borrows `borrowUsdt`.
    function _openBorrow(uint256 borrowUsdt) internal {
        uint256 valueNeeded = Math.mulDiv(borrowUsdt, WAD, OPEN_LTV, Math.Rounding.Ceil);
        uint256 collateral = Math.mulDiv(valueNeeded, ORACLE_PRICE_SCALE, m.oracle.price(), Math.Rounding.Ceil);
        uint256 dustFloor = 2 * uint256(m.activation.minActivationAmount);
        if (collateral < dustFloor) collateral = dustFloor;

        deal(USDY, BORROWER, collateral);
        vm.startPrank(BORROWER);
        IERC20NoReturn(USDY).approve(address(core), type(uint256).max);
        core.supplyCollateral(params, collateral, BORROWER, "");
        vm.stopPrank();

        _warpPastActivation(m);
        vm.prank(BORROWER);
        core.borrow(params, borrowUsdt, 0, BORROWER, BORROWER);
    }

    /// @dev Drop USDY's NAV so the LIVE test position lands exactly at `targetLtvWad`. `UsdyStableOracle.price()`
    ///      is `getPrice() * scale / usdtUsdPrice` — linear in the Ondo NAV, with the USDT/USD feed leg untouched
    ///      — so back out the NAV that yields the price putting BORROWER at the target LTV, then mock the exact
    ///      call the oracle makes (`getPrice()`). Returns the post-mock oracle price read back for expectations.
    function _crashNavToTargetLtv(uint256 targetLtvWad) internal returns (uint256 mockedPrice) {
        uint256 livePrice = m.oracle.price();
        uint256 liveNav = IRWADynamicOracle(ONDO_ORACLE).getPrice();
        uint256 debtAssets = m.controller.positionOf(BORROWER).debtAssets;
        uint256 rawCollateral = core.position(marketId, BORROWER).collateral;

        // Collateral value (loan units) that puts LTV == target, the oracle price for it, then the NAV for it.
        uint256 valueAtTarget = Math.mulDiv(debtAssets, WAD, targetLtvWad);
        uint256 targetPrice = Math.mulDiv(valueAtTarget, ORACLE_PRICE_SCALE, rawCollateral);
        uint256 mockNav = Math.mulDiv(liveNav, targetPrice, livePrice);
        vm.mockCall(ONDO_ORACLE, abi.encodeWithSelector(IRWADynamicOracle.getPrice.selector), abi.encode(mockNav));

        // Use the ACTUAL post-mock price (not `targetPrice`) for every downstream expectation — this absorbs the
        // integer rounding in the NAV round-trip and matches exactly what the core reads during liquidate/settle.
        mockedPrice = m.oracle.price();
        assertLt(mockedPrice, livePrice, "crash is a negative NAV move");
        core.accrueInterest(params);
    }

    /// @dev Blocklist `account` on USDY by pranking the real transfer-gate registry owner.
    function _blocklist(address account) internal {
        IUsdyBlocklist bl = IUsdyBlocklist(USDY_BLOCKLIST);
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(bl.owner());
        bl.addToBlocklist(accounts);
        assertTrue(bl.isBlocked(account), "account blocklisted on USDY");
    }

    /// @dev Largest debt (loan assets) borrowable against `collateral` at `price`, at the live market LLTV.
    function _maxBorrow(uint256 collateral, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(collateral, price, ORACLE_PRICE_SCALE), params.lltv, WAD);
    }

    /* T1 — liquidation respects USDY's blocklist */

    function test_liquidate_blocklistedCannot_allowlistedCan() public {
        // Lender funds the market with USDT liquidity (direct core supply); gated by the live supply-cap headroom.
        _requireSupplyHeadroom(m, LENDER_SUPPLY_LIQUIDATE);
        deal(USDT, LENDER, LENDER_SUPPLY_LIQUIDATE);
        vm.startPrank(LENDER);
        IERC20NoReturn(USDT).approve(address(core), type(uint256).max);
        core.supply(params, LENDER_SUPPLY_LIQUIDATE, 0, LENDER, "");
        vm.stopPrank();

        _openBorrow(BORROW_LIQUIDATE);
        uint256 mockedPrice = _crashNavToTargetLtv(CRASH_LTV_LIQUIDATE);

        // Provably in the liquidate band at the mocked price: unhealthy (debt > max borrowable) AND underwater
        // (collateral worth less than debt), so `liquidate` is enabled and bad debt is tolerated at any live NAV.
        uint256 rawCollateral = core.position(marketId, BORROWER).collateral;
        uint256 debtAssets = m.controller.positionOf(BORROWER).debtAssets;
        assertGt(debtAssets, _maxBorrow(rawCollateral, mockedPrice), "borrower unhealthy at mocked price");
        assertGt(debtAssets, Math.mulDiv(rawCollateral, mockedPrice, ORACLE_PRICE_SCALE), "borrower underwater");

        // Both keepers hold USDT to repay; KEEPER_BAD is blocklisted on USDY.
        deal(USDT, KEEPER_GOOD, KEEPER_USDT);
        deal(USDT, KEEPER_BAD, KEEPER_USDT);
        vm.prank(KEEPER_GOOD);
        IERC20NoReturn(USDT).approve(address(core), type(uint256).max);
        vm.prank(KEEPER_BAD);
        IERC20NoReturn(USDT).approve(address(core), type(uint256).max);
        _blocklist(KEEPER_BAD);

        // Seize a small slice of the live collateral — well within the balance, so `seized` == requested.
        uint256 seize = rawCollateral / 10;
        require(seize != 0 && seize < rawCollateral, "seize sized within the borrower's collateral");

        // Blocklisted keeper: the seized-collateral safeTransfer to it reverts, so liquidate reverts (USDY's
        // "USDY: 'to' address blocked" is wrapped by the core's SafeTransferLib).
        vm.prank(KEEPER_BAD);
        vm.expectRevert("transfer reverted");
        core.liquidate(params, BORROWER, seize, 0, "");

        // Eligible keeper: liquidation succeeds and it receives exactly the seized USDY (a delta from clean).
        uint256 balBefore = IERC20NoReturn(USDY).balanceOf(KEEPER_GOOD);
        vm.prank(KEEPER_GOOD);
        (uint256 seized,) = core.liquidate(params, BORROWER, seize, 0, "");
        assertEq(seized, seize, "seized the requested amount");
        assertEq(
            IERC20NoReturn(USDY).balanceOf(KEEPER_GOOD) - balBefore, seize, "eligible keeper received the seized USDY"
        );
    }

    /* T2 — vault fallback exit respects USDY's blocklist on the receiver */

    function test_fallbackExit_blocklistedReceiverCannot_allowlistedCan() public {
        // Lender deposits USDT into the vault (the vault supplies it to the market); gated by supply-cap headroom.
        _requireSupplyHeadroom(m, LENDER_DEPOSIT_SETTLE);
        deal(USDT, LENDER, LENDER_DEPOSIT_SETTLE);
        vm.startPrank(LENDER);
        IERC20NoReturn(USDT).approve(address(vault), type(uint256).max);
        vault.deposit(LENDER_DEPOSIT_SETTLE, LENDER);
        vm.stopPrank();

        // Borrower draws down against USDY collateral, then pin free liquidity to a known low target so an
        // ordinary (idle) withdrawal cannot satisfy the exit — forcing the settle leg. The pin borrower is
        // over-collateralized, so it stays healthy through the crash and never outranks BORROWER in the queue.
        _openBorrow(BORROW_SETTLE);
        _pinFreeLiquidity(m, IDLE_TARGET);

        uint256 mockedPrice = _crashNavToTargetLtv(CRASH_LTV_SETTLE);

        // Provably in the settle band at the mocked price: unhealthy (debt > max borrowable) yet solvent
        // (collateral worth more than debt → no bad debt), so BORROWER is settle-eligible at any live NAV.
        uint256 rawCollateral = core.position(marketId, BORROWER).collateral;
        uint256 debtAssets = m.controller.positionOf(BORROWER).debtAssets;
        assertGt(debtAssets, _maxBorrow(rawCollateral, mockedPrice), "borrower unhealthy at mocked price");
        assertGt(Math.mulDiv(rawCollateral, mockedPrice, ORACLE_PRICE_SCALE), debtAssets, "borrower solvent");

        // Loud preconditions for the settle leg: it cuts the queue ROOT head-first, so our borrower must be it;
        // and a bad-debt position anywhere in the queue would block settlement — assert neither is the case.
        (address root,) = m.controller.nextSettlementBorrower(0);
        require(root == BORROWER, "UsdyTreasuries: a pre-existing riskier borrower outranks the test borrower");
        require(!m.controller.hasBadDebt(), "UsdyTreasuries: unexpected bad debt blocks the settle leg");

        _blocklist(KEEPER_BAD);

        uint256 shares = vault.balanceOf(LENDER) / 2; // more than IDLE_TARGET covers → the settle leg engages

        // Blocklisted receiver: the settle leg's collateral transfer to it reverts, so fallbackExit reverts.
        vm.prank(LENDER);
        vm.expectRevert("transfer reverted");
        vault.fallbackExit(shares, KEEPER_BAD, LENDER, 0);

        // Eligible receiver: succeeds and receives exactly the seized USDY collateral (a delta from clean).
        uint256 balBefore = IERC20NoReturn(USDY).balanceOf(KEEPER_GOOD);
        vm.prank(LENDER);
        (,, uint256 collateralSeized, uint256 debtCanceled) = vault.fallbackExit(shares, KEEPER_GOOD, LENDER, 0);
        assertGt(collateralSeized, 0, "collateral seized via the settle leg");
        // Recompute from the mocked oracle price: settle seizes `debtCanceled` valued at par (no incentive),
        // `debtCanceled * ORACLE_PRICE_SCALE / price`. The exit may cut the borrower across several iterations, so
        // allow the summed per-cut floor rounding (bounded by the iteration count).
        assertApproxEqAbs(
            collateralSeized,
            Math.mulDiv(debtCanceled, ORACLE_PRICE_SCALE, mockedPrice),
            1e4,
            "collateral seized matches debt canceled at the mocked price"
        );
        assertEq(
            IERC20NoReturn(USDY).balanceOf(KEEPER_GOOD) - balBefore, collateralSeized, "eligible receiver got the USDY"
        );
    }
}
