// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Market as MorphoMarket, Position as MorphoPosition} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementConfig, SettlementSlice, SettlementQuote} from "../../src/types/SettlementTypes.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice L2 settlement scenarios. `fallbackExit` consumes free liquidity before applying root policy, while
///         targeted `settle` leaves liquidity untouched and only cuts borrowers with a positive personal
///         settlement-LTV slice.
contract SettlementTest is LidoLendSetup {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    // 400 collateral keeps an 80 borrow within LLTV-max even at the lowest seeded price (400 * 0.24 = 96 > 80).
    uint256 internal constant COLLAT = 400 ether;
    uint256 internal constant BORROW = 80 ether;
    uint256 internal constant CORE_VIRTUAL_ASSETS = 1;
    uint256 internal constant CORE_VIRTUAL_SHARES = 1e6;

    struct TargetedState {
        address lender;
        address borrower;
        uint256 shares;
        uint256 personalSlice;
        uint256 expectedDebt;
        uint256 freeBefore;
    }

    struct TailBoundaryState {
        address supplier;
        address borrower;
        uint256 exactAssets;
        uint256 exactSupplyShares;
        uint256 exactBorrowShares;
        uint256 plusOneBorrowShares;
    }

    struct TailExecutionState {
        MorphoMarket marketBefore;
        MorphoPosition borrowerBefore;
        uint256 supplierSharesBefore;
        uint256 collateralBalanceBefore;
        uint256 expectedBorrowSharesCanceled;
        uint256 expectedCollateralSeized;
        uint256 collateralSeized;
        uint256 debtCanceled;
        uint256 borrowSharesCanceled;
        uint256 supplySharesBurned;
    }

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender supplies 100; borrower draws 80, leaving exactly 20 free loan assets.
    function _seedShortLiquidity(address lender, address borrower) internal returns (uint256 shares) {
        Market storage m = _m();
        _fund(m.loanToken, lender, 100 ether);
        shares = m.vaultDeposit(lender, 100 ether);
        _fund(m.collateralToken, borrower, COLLAT);
        m.supplyCollateral(borrower, COLLAT);
        m.activateCollateral();
        m.borrow(borrower, BORROW);
    }

    function _setFullCloseRootPolicy() internal {
        Market storage m = _m();
        SettlementConfig memory config = m.controller.settlementConfig();
        config.sliceFloorBps = 10_000;
        config.sliceFloorAssets = 0;
        config.fullCutBelowCollateral = 0;
        config.ltvStepBps = 0;
        m.controller.setSettlementConfig(config);
    }

    function _setPositivePersonalLtv(address borrower) internal returns (uint256 sliceAssets) {
        Market storage m = _m();
        uint256 debtAssets = m.controller.positionOf(borrower).debtAssets;
        uint256 collateralValue = Math.mulDiv(COLLAT, oraclePrice, 1e36);
        uint256 currentLtv = Math.mulDiv(debtAssets, 1e18, collateralValue);
        m.setSettlementLtv(borrower, currentLtv - 0.01e18);
        (, sliceAssets) = m.controller.settlementLtv(borrower);
        assertGt(sliceAssets, 0, "personal target opens a positive slice");
        assertLt(sliceAssets, debtAssets, "personal target remains a partial cut");
    }

    function _supplyDirect(Market storage m, address supplier, uint256 assets) internal {
        _fund(m.loanToken, supplier, assets);
        vm.startPrank(supplier);
        m.loanToken.approve(address(m.core), assets);
        m.core.supply(m.params, assets, 0, supplier, "");
        vm.stopPrank();
    }

    function _freeLiquidity(Market storage m) internal view returns (uint256) {
        MorphoMarket memory market_ = m.core.market(m.id);
        return market_.totalSupplyAssets - market_.totalBorrowAssets;
    }

    function _supplyAssetsDown(uint256 shares, MorphoMarket memory market_) internal pure returns (uint256) {
        return Math.mulDiv(
            shares,
            uint256(market_.totalSupplyAssets) + CORE_VIRTUAL_ASSETS,
            uint256(market_.totalSupplyShares) + CORE_VIRTUAL_SHARES
        );
    }

    function _supplySharesUp(uint256 assets, MorphoMarket memory market_) internal pure returns (uint256) {
        return Math.mulDiv(
            assets,
            uint256(market_.totalSupplyShares) + CORE_VIRTUAL_SHARES,
            uint256(market_.totalSupplyAssets) + CORE_VIRTUAL_ASSETS,
            Math.Rounding.Ceil
        );
    }

    function _seedTailBoundary() internal returns (TailBoundaryState memory state) {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(1.3e36);

        state.supplier = _actor("tail-supplier");
        address otherSupplier = _actor("other-supplier");
        state.borrower = _actor("tail-borrower");
        _supplyDirect(m, state.supplier, 200 ether);
        _supplyDirect(m, otherSupplier, 100 ether);

        _fund(m.collateralToken, state.borrower, 1_000 ether);
        m.supplyCollateral(state.borrower, 1_000 ether);
        m.activateCollateral();
        m.borrow(state.borrower, 50 ether);

        vm.warp(block.timestamp + 30 days);
        m.accrueInterest();

        MorphoMarket memory accrued = m.core.market(m.id);
        assertNotEq(
            uint256(accrued.totalSupplyAssets) * CORE_VIRTUAL_SHARES,
            uint256(accrued.totalSupplyShares),
            "precondition: supply conversion is off parity"
        );
        assertNotEq(
            uint256(accrued.totalBorrowAssets) * CORE_VIRTUAL_SHARES,
            uint256(accrued.totalBorrowShares),
            "precondition: borrow conversion is off parity"
        );

        uint256 supplierShares = m.core.position(m.id, state.supplier).supplyShares;
        uint256 supplierAssets = _supplyAssetsDown(supplierShares, accrued);
        state.exactAssets = supplierAssets / 2;
        state.exactSupplyShares = _supplySharesUp(state.exactAssets, accrued);
        assertEq(
            _supplyAssetsDown(state.exactSupplyShares, accrued),
            state.exactAssets,
            "exact boundary is representable through core share conversion"
        );
        assertNotEq(
            state.exactSupplyShares,
            state.exactAssets * CORE_VIRTUAL_SHARES,
            "boundary uses the accrued, non-round supply conversion"
        );

        uint256 freeBefore = uint256(accrued.totalSupplyAssets) - uint256(accrued.totalBorrowAssets);
        uint256 targetFree = supplierAssets - state.exactAssets;
        assertGt(targetFree, 0, "precondition: free liquidity remains positive");
        assertGt(freeBefore, targetFree, "precondition: borrow can tune the lender tail");
        m.borrow(state.borrower, freeBefore - targetFree);

        MorphoMarket memory tuned = m.core.market(m.id);
        uint256 tunedSupplierAssets = _supplyAssetsDown(supplierShares, tuned);
        uint256 tunedFree = uint256(tuned.totalSupplyAssets) - uint256(tuned.totalBorrowAssets);
        assertEq(tunedSupplierAssets - tunedFree, state.exactAssets, "precondition: exact lender tail");
        state.exactBorrowShares =
            SharesMathLib.toSharesDown(state.exactAssets, tuned.totalBorrowAssets, tuned.totalBorrowShares);
        state.plusOneBorrowShares =
            SharesMathLib.toSharesDown(state.exactAssets + 1, tuned.totalBorrowAssets, tuned.totalBorrowShares);
        assertEq(
            SharesMathLib.toAssetsUp(state.exactBorrowShares, tuned.totalBorrowAssets, tuned.totalBorrowShares),
            state.exactAssets,
            "precondition: exact tail is representable by borrow shares"
        );
        assertEq(
            SharesMathLib.toAssetsUp(state.plusOneBorrowShares, tuned.totalBorrowAssets, tuned.totalBorrowShares),
            state.exactAssets + 1,
            "precondition: tail + 1 is representable by borrow shares"
        );
        assertGt(tunedFree, 0, "precondition: market retains free liquidity");
        assertNotEq(
            uint256(tuned.totalBorrowAssets) * CORE_VIRTUAL_SHARES,
            uint256(tuned.totalBorrowShares),
            "precondition: tuned borrow conversion remains off parity"
        );
        assertGt(m.core.position(m.id, otherSupplier).supplyShares, 0, "precondition: multiple suppliers");

        _setFullCloseRootPolicy();
        (address root,) = m.controller.nextSettlementBorrower(0);
        assertEq(root, state.borrower, "precondition: borrower is the queue root");
        SettlementQuote memory quote = m.controller.settlementFor(state.borrower, 0);
        assertEq(quote.personal.supplyShares, 0, "precondition: no personal supply quote");
        assertEq(quote.personal.borrowShares, 0, "precondition: root cut uses automatic policy only");
    }

    /// @dev The automatic quote exposes the root's absolute policy while liquidity exists. The fallback liquid leg
    ///      withdraws all 20 first, after which the vault's entire remaining supply is an executable illiquid tail.
    function test_fallbackExit_drainsLiquidityBeforeApplyingRootPolicy() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        _setFullCloseRootPolicy();
        uint256 shares = _seedShortLiquidity(lender, borrower);

        (address root, SettlementSlice memory slice) = m.controller.nextSettlementBorrower(0);
        assertEq(root, borrower, "sole borrower is root");
        assertGt(slice.supplyShares, 0, "absolute root policy exposes its supply cost");
        assertGt(slice.borrowShares, 0, "absolute root policy exposes its borrow anchor");
        assertEq(_freeLiquidity(m), 20 ether, "precondition: 20 free assets");

        (, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            m.fallbackExit(lender, shares, lender, 1);

        assertEq(loanAssets, 20 ether, "liquid leg withdraws all free assets");
        assertEq(debtCanceled, BORROW, "zero-liquidity root policy closes the debt");
        assertGt(collateralSeized, 0, "root settlement seizes collateral");
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "borrower closed");
        assertEq(_freeLiquidity(m), 0, "settlement preserves the zero-liquidity state");
    }

    /// @dev Targeted settlement is allowed by a positive personal LTV even though the request is fully serviceable
    ///      from free liquidity. It consumes no loan assets and preserves the market's free-liquidity amount.
    function test_settle_withPersonalLtv_ignoresFreeLiquidity() public {
        Market storage m = _m();
        TargetedState memory state;
        state.lender = _actor("lender");
        state.borrower = _actor("borrower");
        state.shares = _seedShortLiquidity(state.lender, state.borrower);
        state.personalSlice = _setPositivePersonalLtv(state.borrower);

        SettlementQuote memory quote = m.controller.settlementFor(state.borrower, 0);
        MorphoMarket memory marketBefore = m.core.market(m.id);
        state.expectedDebt =
            quote.personal.borrowShares.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
        state.freeBefore = _freeLiquidity(m);

        (uint256 sharesBurned, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(state.lender, state.shares, _singleton(state.borrower), state.lender);

        assertGt(sharesBurned, 0, "positive settlement burns vault shares");
        assertEq(debtCanceled, state.expectedDebt, "core consumes the controller's personal quote");
        assertLe(debtCanceled, state.personalSlice + 1, "borrow-share rounding adds at most one asset wei");
        assertGt(collateralSeized, 0, "personal settlement seizes collateral");
        assertEq(_freeLiquidity(m), state.freeBefore, "targeted settlement preserves free liquidity");
    }

    /// @dev Even for the live queue root, targeted settlement uses only the personal candidate. The collateral-dust
    ///      sweep promotes the automatic root candidate to a full close but cannot leak into the targeted vault path.
    function test_settle_actualRootWithLargerQueueQuote_usesOnlyPersonal() public {
        Market storage m = _m();
        TargetedState memory state;
        state.lender = _actor("lender");
        state.borrower = _actor("borrower");

        SettlementConfig memory config = m.controller.settlementConfig();
        config.sliceFloorBps = 5_000;
        config.sliceFloorAssets = 0;
        config.fullCutBelowCollateral = uint96(COLLAT + 1);
        config.ltvStepBps = 0;
        m.controller.setSettlementConfig(config);

        state.shares = _seedShortLiquidity(state.lender, state.borrower);
        _setPositivePersonalLtv(state.borrower);

        SettlementQuote memory quote = m.controller.settlementFor(state.borrower, 0);
        (address root, SettlementSlice memory automatic) = m.controller.nextSettlementBorrower(0);
        assertEq(root, state.borrower, "borrower is the live queue root");
        assertGt(quote.personal.supplyShares, 0, "personal candidate is positive");
        assertGt(quote.personal.remainingBorrowShares, 0, "personal target remains partial despite dust floor");
        assertEq(quote.queueRoot.remainingBorrowShares, 0, "queue-root dust sweep quotes a full close");
        assertGt(quote.queueRoot.supplyShares, quote.personal.supplyShares, "root candidate is larger");
        assertEq(automatic.supplyShares, quote.queueRoot.supplyShares, "automatic path selects root candidate");

        MorphoMarket memory marketBefore = m.core.market(m.id);
        uint256 expectedPersonalDebt =
            quote.personal.borrowShares.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
        uint256 rootDebt =
            quote.queueRoot.borrowShares.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);
        assertGt(rootDebt, expectedPersonalDebt, "root candidate cancels more debt");

        (,, uint256 debtCanceled) = m.settle(state.lender, state.shares, _singleton(state.borrower), state.lender);

        assertEq(debtCanceled, expectedPersonalDebt, "targeted settlement uses only personal candidate");
        assertLt(debtCanceled, rootDebt, "targeted settlement excludes larger root candidate");
    }

    /// @dev Root status alone never authorizes targeted settlement. With free liquidity and no positive personal
    ///      slice the controller returns a zero targeted quote and the vault reverts atomically.
    function testRevert_settle_rootWithoutPersonalLtv_settlesNothing() public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        uint256 shares = _seedShortLiquidity(lender, borrower);

        SettlementQuote memory quote = m.controller.settlementFor(borrower, 0);
        assertEq(quote.personal.supplyShares, 0, "no personal supply quote");
        assertEq(quote.personal.borrowShares, 0, "no personal borrow quote");
        assertEq(
            quote.personal.remainingBorrowShares,
            m.core.position(m.id, borrower).borrowShares,
            "zero quote reports the untouched debt"
        );

        vm.prank(lender);
        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        m.vault.settle(shares, _singleton(borrower), lender, lender);
    }

    /// @dev Removing the old liquidity-tail gate from core must not let a personal cut burn more supply shares than
    ///      `onBehalf` owns.
    function testRevert_coreSettle_personalCutExceedsSupplierPosition() public {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(1e36);

        address supplier = _actor("supplier");
        _supplyDirect(m, supplier, 10 ether);
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 200 ether);
        m.supplyCollateral(borrower, 200 ether);
        m.activateCollateral();
        m.borrow(borrower, BORROW);

        m.setSettlementLtv(borrower, 1);
        SettlementQuote memory quote = m.controller.settlementFor(borrower, 0);
        uint256 borrowShares = quote.personal.borrowShares;

        vm.prank(supplier);
        m.core.setAuthorization(address(this), true);
        vm.expectRevert(bytes("settlement exceeds supply"));
        m.core.settle(m.params, borrowShares, supplier, borrower, supplier);
    }

    /// @dev The controller, not core, caps automatic root settlement by the concrete supplier's live illiquid tail.
    ///      The exact tail succeeds while a one-asset-wei larger cut reverts, even with positive market liquidity,
    ///      multiple suppliers, and accrued non-round supply/borrow conversions.
    function test_coreSettle_rootPolicy_enforcesExactLenderTailBoundary() public {
        Market storage m = _m();
        TailBoundaryState memory state = _seedTailBoundary();
        uint256 freeBefore = _freeLiquidity(m);
        TailExecutionState memory execution;
        execution.supplierSharesBefore = m.core.position(m.id, state.supplier).supplyShares;

        vm.prank(state.supplier);
        vm.expectRevert(ILidoLendMarketController.SettlementExceedsSettleableSupply.selector);
        m.core.settle(m.params, state.plusOneBorrowShares, state.supplier, state.borrower, state.supplier);

        assertEq(
            m.core.position(m.id, state.supplier).supplyShares,
            execution.supplierSharesBefore,
            "tail + 1 revert preserves supplier shares"
        );

        execution.marketBefore = m.core.market(m.id);
        execution.borrowerBefore = m.core.position(m.id, state.borrower);
        execution.collateralBalanceBefore = m.collateralToken.balanceOf(state.supplier);
        execution.expectedBorrowSharesCanceled = state.exactBorrowShares;
        execution.expectedCollateralSeized = Math.mulDiv(
            SharesMathLib.toAssetsDown(
                state.exactBorrowShares,
                execution.marketBefore.totalBorrowAssets,
                execution.marketBefore.totalBorrowShares
            ),
            ORACLE_PRICE_SCALE,
            m.oracle.price()
        );

        vm.prank(state.supplier);
        (
            execution.collateralSeized,
            execution.debtCanceled,
            execution.borrowSharesCanceled,
            execution.supplySharesBurned
        ) = m.core.settle(m.params, state.exactBorrowShares, state.supplier, state.borrower, state.supplier);

        MorphoMarket memory marketAfter = m.core.market(m.id);
        MorphoPosition memory borrowerAfter = m.core.position(m.id, state.borrower);

        assertEq(execution.debtCanceled, state.exactAssets, "exact lender tail settles");
        assertEq(execution.supplySharesBurned, state.exactSupplyShares, "core burns the exact supply cost");
        assertEq(
            execution.borrowSharesCanceled, execution.expectedBorrowSharesCanceled, "borrow-share conversion is exact"
        );
        assertEq(execution.collateralSeized, execution.expectedCollateralSeized, "collateral conversion is exact");
        assertEq(
            m.core.position(m.id, state.supplier).supplyShares,
            execution.supplierSharesBefore - state.exactSupplyShares,
            "supplier position burns the exact supply shares"
        );
        assertEq(
            uint256(borrowerAfter.borrowShares),
            uint256(execution.borrowerBefore.borrowShares) - execution.expectedBorrowSharesCanceled,
            "borrower debt shares decrease"
        );
        assertEq(
            uint256(borrowerAfter.collateral),
            uint256(execution.borrowerBefore.collateral) - execution.expectedCollateralSeized,
            "borrower collateral decreases"
        );
        assertEq(
            uint256(marketAfter.totalSupplyAssets),
            uint256(execution.marketBefore.totalSupplyAssets) - state.exactAssets,
            "market supply assets decrease"
        );
        assertEq(
            uint256(marketAfter.totalSupplyShares),
            uint256(execution.marketBefore.totalSupplyShares) - state.exactSupplyShares,
            "market supply shares decrease"
        );
        assertEq(
            uint256(marketAfter.totalBorrowAssets),
            uint256(execution.marketBefore.totalBorrowAssets) - state.exactAssets,
            "market borrow assets decrease"
        );
        assertEq(
            uint256(marketAfter.totalBorrowShares),
            uint256(execution.marketBefore.totalBorrowShares) - execution.expectedBorrowSharesCanceled,
            "market borrow shares decrease"
        );
        assertEq(
            m.collateralToken.balanceOf(state.supplier) - execution.collateralBalanceBefore,
            execution.expectedCollateralSeized,
            "supplier receives seized collateral"
        );
        assertEq(_freeLiquidity(m), freeBefore, "settlement preserves positive free liquidity");
    }

    /// @dev Queue ordering remains risk based independently of current settlement eligibility.
    function test_settlementQueue_rootIsTheRiskiest() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        address safe = _actor("safe");
        address risky = _actor("risky");
        _fund(m.collateralToken, safe, 800 ether);
        m.supplyCollateral(safe, 800 ether);
        _fund(m.collateralToken, risky, 400 ether);
        m.supplyCollateral(risky, 400 ether);
        m.activateCollateral();
        m.borrow(safe, BORROW);
        m.borrow(risky, BORROW);

        (address[] memory borrowers, uint256[] memory keys) = m.controller.settlementBorrowers(0, 10);
        assertEq(borrowers.length, 2, "both borrowers tracked");
        uint256 riskyKey;
        uint256 safeKey;
        for (uint256 i; i < borrowers.length; ++i) {
            if (borrowers[i] == risky) riskyKey = keys[i];
            if (borrowers[i] == safe) safeKey = keys[i];
        }
        assertEq(riskyKey, 2 * safeKey, "equal debt and half collateral doubles risk key");

        (address root,) = m.controller.nextSettlementBorrower(0);
        assertEq(root, risky, "riskiest borrower remains root");
    }

    function _singleton(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
