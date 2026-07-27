// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

interface IWETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function deposit() external payable;
}

interface IStETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

interface IWstETH {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function getStETHByWstETH(uint256 wstETHAmount) external view returns (uint256);
    function wrap(uint256 stETHAmount) external returns (uint256);
}

/// @notice Mainnet-fork scenarios for the vault's two settle-backed exits, `fallbackExit` and `settle`, run
///         against the ALREADY-DEPLOYED `weth-wsteth` market (bound via {ForkStack}, never re-deployed).
///         Each shows the redeem-first design: the exit first pays out whatever ordinary liquidity
///         (idle + Morpho-withdrawable) covers, then settles the remainder against an unhealthy-but-
///         solvent borrower for collateral. This also removes the front-run griefing vector — a
///         top-up of idle before the call just flows to the owner instead of reverting the settle.
///
///         State-robustness contract (a shared deployed market may already carry supply/borrow):
///         idle is MEASURED (`_freeLiquidity`) after pinning it to a known target, never assumed from the
///         deposits; the negative rebase is derived from the live position so the borrower lands strictly
///         inside `(LLTV, 1)` whatever the live wstETH rate is; and each settle path loudly requires the test
///         borrower to be the settlement-queue root, so a pre-existing riskier borrower cannot hijack the cut.
contract VaultFallbackExitTest is ForkStack {
    BoundMarket internal m;

    // Rebound from the bound market in `setUp` so the tests read like the freshly-deployed variant did.
    ILidoLend internal core;
    ILidoLendERC4626 internal vault;
    MarketParams internal params;
    Id internal marketId;

    IWETH internal WETH;
    IStETH internal STETH;
    IWstETH internal WSTETH;

    // Fresh, market-clean actors (start at zero position and zero vault shares), so per-actor balance
    // assertions double as deltas.
    address internal LENDER;
    address internal BORROWER;

    /// @dev The mocked post-rebase wstETH rate (ETH per wstETH, scaled by `ORACLE_PRICE_SCALE`), computed in
    ///      `_setupExitWithIdle` from the live position. Collateral-seizure expectations recompute from THIS,
    ///      never from a stale constant.
    uint256 internal mockedPrice;

    uint256 internal constant LENDER_DEPOSIT = 20 ether;
    uint256 internal constant BORROW_ASSETS = 18 ether;
    uint256 internal constant COLLATERAL_ETH = 25 ether;
    uint256 internal constant IDLE_TARGET = 2 ether;

    /// @dev Post-rebase target LTV for the test borrower: strictly inside `(LLTV, 1)`, so the position is
    ///      unhealthy but solvent — settle-eligible with no bad debt. Only known post-bind (it depends on the
    ///      live market's LLTV), so it is set in `setUp` rather than a compile-time constant.
    uint256 internal targetPostRebaseLtv;

    function setUp() public {
        _fork();
        m = _bindMarket("fork-weth-wsteth");
        _pokeAccrue(m); // fold in pending interest up front so the exact idle/liquidity math below holds

        core = m.core;
        vault = m.vault;
        params = m.params;
        marketId = m.id;

        // Midpoint of (LLTV, 1e18): strictly inside the unhealthy-but-solvent band regardless of the live LLTV.
        targetPostRebaseLtv = (params.lltv + WAD) / 2;

        WETH = IWETH(address(m.loanToken));
        STETH = IStETH(_ext("stEth"));
        WSTETH = IWstETH(address(m.collateralToken));

        LENDER = _freshActor(m, "vaultFallbackExit.lender");
        BORROWER = _freshActor(m, "vaultFallbackExit.borrower");
    }

    /// @dev Lender funds the vault, a borrower draws most of it, then a negative rebase makes the borrower
    ///      unhealthy but solvent — settle-eligible, no bad debt. Returns the idle WETH left in the market
    ///      (what the redeem leg can pay out), MEASURED after pinning, not inferred from the deposits.
    function _setupExitWithIdle() internal returns (uint256 idle) {
        _requireDepositHeadroom(m, LENDER_DEPOSIT);
        _mintWETH(LENDER, LENDER_DEPOSIT);
        vm.prank(LENDER);
        vault.deposit(LENDER_DEPOSIT, LENDER);

        uint256 collateral = _mintWstETH(BORROWER, COLLATERAL_ETH);
        vm.prank(BORROWER);
        core.supplyCollateral(params, collateral, BORROWER, "");

        _warpPastActivation(m);
        vm.prank(BORROWER);
        core.borrow(params, BORROW_ASSETS, 0, BORROWER, BORROWER); // healthy at the live rate

        // Pin free liquidity to a known target and MEASURE the result: a shared deployed market may already
        // carry idle, which would break `loanAssets ~= idle` and could let the redeem leg cover the whole exit
        // (collateralSeized == 0). The pin borrower is over-collateralized, so it never outranks BORROWER below.
        _pinFreeLiquidity(m, IDLE_TARGET);
        idle = _freeLiquidity(m);

        // Real, relative negative rebase. The deployed oracle (WstEthRateOracle) prices wstETH via
        // `getStETHByWstETH(1e36)`, so THAT is mocked (nothing in src reads `stEthPerToken`). Derive the mocked
        // rate from the live position so BORROWER lands at targetPostRebaseLtv — inside (LLTV, 1) — regardless
        // of the live wstETH rate.
        uint256 livePrice = m.oracle.price();
        uint256 debtAssets = m.controller.positionOf(BORROWER).debtAssets;
        uint256 rawCollateral = core.position(marketId, BORROWER).collateral;
        // Collateral value that makes LTV == target, then the rate that yields that value.
        uint256 valueAtTarget = Math.mulDiv(debtAssets, WAD, targetPostRebaseLtv);
        mockedPrice = Math.mulDiv(valueAtTarget, ORACLE_PRICE_SCALE, rawCollateral);
        vm.mockCall(
            address(WSTETH),
            abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector, ORACLE_PRICE_SCALE),
            abi.encode(mockedPrice)
        );

        // Sanity: the rebase drops the rate (negative), pushes BORROWER above LLTV (unhealthy) yet leaves its
        // collateral worth more than its debt (solvent) — so it is settle-eligible with no bad debt.
        assertLt(mockedPrice, livePrice, "rebase is negative");
        assertGt(debtAssets, _maxBorrow(rawCollateral, mockedPrice), "borrower unhealthy (LTV > LLTV)");
        assertGt(Math.mulDiv(rawCollateral, mockedPrice, ORACLE_PRICE_SCALE), debtAssets, "borrower solvent");
        assertFalse(m.controller.hasBadDebt(), "no bad debt after rebase");

        // Both settle paths below cut BORROWER (fallbackExit head-first via the queue root; settle by naming it),
        // which needs BORROWER to be the queue root. A near-max debt keeps it the riskiest on a quiet market;
        // assert it so a pre-existing riskier borrower cannot silently hijack the cut.
        (address root,,,) = m.controller.nextSettlementBorrower();
        require(
            root == BORROWER,
            "VaultFallbackExit: a pre-existing riskier borrower outranks the test borrower in the settle queue"
        );
    }

    /// @dev Asserts a vault exit ran both phases: redeemed idle as loan assets AND settled collateral. The
    ///      seized collateral is recomputed from the mocked oracle rate (approx: fallbackExit accumulates many
    ///      per-cut floors), never from a hardcoded price.
    function _assertBothPhases(uint256 idle, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled)
        internal
        view
    {
        assertGt(loanAssets, 0, "redeem leg paid loan assets");
        assertApproxEqAbs(loanAssets, idle, 1e15, "redeem leg drained the available idle");
        assertGt(collateralSeized, 0, "settle leg seized collateral for the remainder");
        assertApproxEqAbs(
            collateralSeized, debtCanceled * ORACLE_PRICE_SCALE / mockedPrice, 1e6, "collateral seized at mocked rate"
        );
        assertEq(WETH.balanceOf(LENDER), loanAssets, "receiver got the loan assets");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
    }

    /* fallbackExit: redeem available, then settle the remainder via the risk queue */

    function test_fallbackExit_redeemsAvailableThenSettles() public {
        uint256 idle = _setupExitWithIdle();

        // Request more than idle covers, so the redeem leg pays the idle and the settle leg covers the rest.
        uint256 shares = vault.balanceOf(LENDER) / 2;
        vm.prank(LENDER);
        (, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            vault.fallbackExit(shares, LENDER, LENDER, 0);

        _assertBothPhases(idle, loanAssets, collateralSeized, debtCanceled);
    }

    /* settle: liquidity-neutral targeted cut — seizes collateral, withdraws NO ordinary liquidity */

    function test_settle_seizesCollateralWithoutWithdrawingLiquidity() public {
        _setupExitWithIdle();

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;

        uint256 wethBefore = WETH.balanceOf(LENDER); // fresh lender holds no idle WETH (all deposited)

        uint256 shares = vault.balanceOf(LENDER) / 2;
        vm.prank(LENDER);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            vault.settle(shares, borrowers, LENDER, LENDER);

        // Pure settle: the cut seizes collateral to the receiver and burns the matching shares, but the
        // ordinary liquidity is left untouched — no redeem leg, so no loan assets are paid out.
        assertGt(collateralSeized, 0, "settle seized collateral for the cut");
        assertGt(sharesBurned, 0, "shares burned for the settled slice");
        assertEq(loanAssets, 0, "settle withdrew no ordinary liquidity");
        assertEq(collateralSeized, debtCanceled * ORACLE_PRICE_SCALE / mockedPrice, "collateral seized at mocked rate");
        assertEq(WETH.balanceOf(LENDER), wethBefore, "receiver got no loan assets");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
    }

    /* settle covers a cut below the market's ordinary liquidity. The new core gate allows settling up
       to onBehalf's supply minus free liquidity (here equal to the borrower's debt), so a sub-liquidity
       cut that the old `debtCanceled > availableLiquidity` gate rejected now goes through. */

    function test_settle_smallCutBelowLiquiditySucceeds() public {
        _setupExitWithIdle(); // IDLE_TARGET of ordinary liquidity sits in the market

        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;

        uint256 wethBefore = WETH.balanceOf(LENDER);
        uint256 shares = vault.balanceOf(LENDER) / 40; // ~0.5 WETH worth, well below the idle liquidity
        vm.prank(LENDER);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            vault.settle(shares, borrowers, LENDER, LENDER);

        assertGt(collateralSeized, 0, "sub-liquidity settle seized collateral under the new gate");
        assertGt(sharesBurned, 0, "shares burned for the slice");
        assertEq(loanAssets, 0, "settle withdrew no ordinary liquidity");
        assertEq(collateralSeized, debtCanceled * ORACLE_PRICE_SCALE / mockedPrice, "collateral seized at mocked rate");
        assertEq(WETH.balanceOf(LENDER), wethBefore, "receiver got no loan assets");
        assertEq(WSTETH.balanceOf(LENDER), collateralSeized, "receiver got the seized collateral");
    }

    /// @dev Largest debt (loan assets) borrowable against `collateral` at `price`, at the market LLTV.
    function _maxBorrow(uint256 collateral, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(collateral, price, ORACLE_PRICE_SCALE), params.lltv, WAD);
    }

    function _mintWETH(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.startPrank(user);
        WETH.deposit{value: amount}();
        WETH.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _mintWstETH(address user, uint256 ethAmount) internal returns (uint256 wstETHAmount) {
        vm.deal(user, ethAmount);
        vm.startPrank(user);
        STETH.submit{value: ethAmount}(address(0));
        STETH.approve(address(WSTETH), STETH.balanceOf(user));
        wstETHAmount = WSTETH.wrap(STETH.balanceOf(user));
        WSTETH.approve(address(core), type(uint256).max);
        vm.stopPrank();
    }
}
