// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Market as MorphoMarket, Position as MorphoPosition} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementConfig, SettlementQuote} from "../../src/types/SettlementTypes.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// forge-config: default.fuzz.runs = 128
/// @notice Direct-core coverage of the controller's settlement execution rules.
contract DirectSettlementPolicyMatrixTest is LidoLendSetup {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint16 private constant ROOT_POLICY_BPS = 5_000;
    uint256 private constant ROOT_PERSONAL_LTV = 0.45e18;
    uint256 private constant NON_ROOT_PERSONAL_LTV = 0.05e18;
    uint256 private constant LIVE_PRICE = 1e36;
    uint256 private constant BAD_DEBT_PRICE = 0.4e36;

    uint256 private constant LIQUID_SUPPLY = 250 ether;
    uint256 private constant TAIL_SUPPLY = 1_000 ether;
    uint256 private constant ROOT_COLLATERAL = 600 ether;
    uint256 private constant ROOT_BORROW = 300 ether;
    uint256 private constant NON_ROOT_COLLATERAL = 1_000 ether;
    uint256 private constant NON_ROOT_BORROW = 100 ether;

    struct MatrixState {
        address liquidSupplier;
        address tailSupplier;
        address root;
        address nonRoot;
    }

    struct PolicyCase {
        address borrower;
        address supplier;
        uint256 personalAllowedShares;
        uint256 rootAllowedShares;
        uint256 cutShares;
    }

    struct SettlementExecution {
        uint256 borrowerSharesBefore;
        uint256 supplierSharesBefore;
        uint256 expectedAssets;
        uint256 seizedAssets;
        uint256 canceledAssets;
        uint256 canceledShares;
        uint256 burnedSupplyShares;
    }

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    /// @dev Exercises every execution branch at its exact boundary through the real core.
    function test_coreSettle_policyMatrixBoundaries() public {
        MatrixState memory state = _seedMatrix(0);

        _assertNonRootBoundaries(state);
        _assertRootWithoutPersonalBoundaries(state);
        _assertRootWithPersonalBoundaries(state);
        _assertBadDebtGate(state);
    }

    /// @dev Varies accrued share prices and independently applies the controller's execution predicate to an
    ///      arbitrary root/non-root, personal/no-personal, zero-tail/positive-tail combination.
    function testFuzz_coreSettle_matchesPolicyMatrix(
        uint40 elapsedSeed,
        bool targetRoot,
        bool personalEnabled,
        bool zeroTailSupplier,
        uint256 cutSeed
    ) public {
        uint256 elapsed = bound(uint256(elapsedSeed), 0, 30 days);
        MatrixState memory state = _seedMatrix(elapsed);
        _assertFuzzCase(state, targetRoot, personalEnabled, zeroTailSupplier, cutSeed);
    }

    function _assertFuzzCase(
        MatrixState memory state,
        bool targetRoot,
        bool personalEnabled,
        bool zeroTailSupplier,
        uint256 cutSeed
    ) private {
        Market storage m = _m();
        PolicyCase memory policyCase = _buildFuzzCase(m, state, targetRoot, personalEnabled, zeroTailSupplier, cutSeed);
        uint256 maxAllowedShares = Math.max(policyCase.personalAllowedShares, policyCase.rootAllowedShares);
        MorphoMarket memory market_ = m.core.market(m.id);
        uint256 canceledAssets = policyCase.cutShares.toAssetsUp(market_.totalBorrowAssets, market_.totalBorrowShares);
        uint256 tailAssets = _tailAssets(m, policyCase.supplier);

        if (policyCase.cutShares <= policyCase.personalAllowedShares) {
            _settleAndAssert(m, policyCase.supplier, policyCase.borrower, policyCase.cutShares);
        } else if (policyCase.cutShares > maxAllowedShares) {
            _expectSettlementExceedsAllowed(m, policyCase.supplier, policyCase.borrower, policyCase.cutShares);
        } else if (canceledAssets > tailAssets) {
            _expectSettlementExceedsTail(m, policyCase.supplier, policyCase.borrower, policyCase.cutShares);
        } else {
            _settleAndAssert(m, policyCase.supplier, policyCase.borrower, policyCase.cutShares);
        }
    }

    function _buildFuzzCase(
        Market storage m,
        MatrixState memory state,
        bool targetRoot,
        bool personalEnabled,
        bool zeroTailSupplier,
        uint256 cutSeed
    ) private returns (PolicyCase memory policyCase) {
        policyCase.borrower = targetRoot ? state.root : state.nonRoot;
        policyCase.supplier = zeroTailSupplier ? state.liquidSupplier : state.tailSupplier;

        uint256 personalLtv = targetRoot ? ROOT_PERSONAL_LTV : NON_ROOT_PERSONAL_LTV;
        if (personalEnabled) m.setSettlementLtv(policyCase.borrower, personalLtv);

        policyCase.personalAllowedShares =
            personalEnabled ? _expectedPersonalShares(m, policyCase.borrower, personalLtv) : 0;
        policyCase.rootAllowedShares = targetRoot ? _expectedRootShares(m, policyCase.borrower) : 0;

        SettlementQuote memory quote = m.controller.settlementFor(policyCase.borrower);
        assertEq(
            quote.personal.borrowShares,
            policyCase.personalAllowedShares,
            "personal quote matches the independent model"
        );
        if (targetRoot) {
            assertEq(
                quote.queueRoot.borrowShares, policyCase.rootAllowedShares, "root quote matches the independent model"
            );
        }

        MorphoPosition memory position = m.core.position(m.id, policyCase.borrower);
        MorphoMarket memory market_ = m.core.market(m.id);
        uint256 marginShares = uint256(10 ether).toSharesUp(market_.totalBorrowAssets, market_.totalBorrowShares);
        uint256 maxAllowedShares = Math.max(policyCase.personalAllowedShares, policyCase.rootAllowedShares);
        uint256 upperCut = Math.min(uint256(position.borrowShares), maxAllowedShares + marginShares);
        policyCase.cutShares = bound(cutSeed, 1, upperCut);
    }

    function _m() private view returns (Market storage) {
        return protocol.markets[0];
    }

    function _seedMatrix(uint256 elapsed) private returns (MatrixState memory state) {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(LIVE_PRICE);

        state.liquidSupplier = _actor("liquid supplier");
        state.tailSupplier = _actor("tail supplier");
        state.root = _actor("root borrower");
        state.nonRoot = _actor("non-root borrower");

        _supplyDirect(m, state.liquidSupplier, LIQUID_SUPPLY);
        _supplyDirect(m, state.tailSupplier, TAIL_SUPPLY);

        _fund(m.collateralToken, state.root, ROOT_COLLATERAL);
        m.supplyCollateral(state.root, ROOT_COLLATERAL);
        _fund(m.collateralToken, state.nonRoot, NON_ROOT_COLLATERAL);
        m.supplyCollateral(state.nonRoot, NON_ROOT_COLLATERAL);
        m.activateCollateral();

        m.borrow(state.root, ROOT_BORROW);
        m.borrow(state.nonRoot, NON_ROOT_BORROW);

        m.controller
            .setSettlementConfig(
                SettlementConfig({
                    sliceFloorBps: ROOT_POLICY_BPS, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 0
                })
            );

        if (elapsed != 0) {
            vm.warp(block.timestamp + elapsed);
            m.accrueInterest();
        }

        (address root,) = m.controller.nextSettlementBorrower();
        assertEq(root, state.root, "higher-LTV borrower is the queue root");
        assertEq(_tailAssets(m, state.liquidSupplier), 0, "liquid supplier has no lender tail");
        assertGe(
            _tailAssets(m, state.tailSupplier),
            _expectedRootShares(m, state.root)
                .toAssetsUp(m.core.market(m.id).totalBorrowAssets, m.core.market(m.id).totalBorrowShares),
            "tail supplier can execute the full root allowance"
        );
    }

    function _assertNonRootBoundaries(MatrixState memory state) private {
        Market storage m = _m();
        SettlementQuote memory quote = m.controller.settlementFor(state.nonRoot);
        assertEq(quote.personal.borrowShares, 0, "non-root starts without personal allowance");
        _expectSettlementExceedsAllowed(m, state.liquidSupplier, state.nonRoot, 1);

        m.setSettlementLtv(state.nonRoot, NON_ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, state.nonRoot, NON_ROOT_PERSONAL_LTV);
        quote = m.controller.settlementFor(state.nonRoot);
        assertEq(quote.personal.borrowShares, personalShares, "non-root personal allowance");

        _settleAndRestore(m, state.liquidSupplier, state.nonRoot, personalShares);
        _expectSettlementExceedsAllowed(m, state.liquidSupplier, state.nonRoot, personalShares + 1);
    }

    function _assertRootWithoutPersonalBoundaries(MatrixState memory state) private {
        Market storage m = _m();
        SettlementQuote memory quote = m.controller.settlementFor(state.root);
        uint256 rootShares = _expectedRootShares(m, state.root);
        assertEq(quote.personal.borrowShares, 0, "root starts without personal allowance");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root allowance");

        _settleAndRestore(m, state.tailSupplier, state.root, rootShares);
        _expectSettlementExceedsTail(m, state.liquidSupplier, state.root, rootShares);
    }

    function _assertRootWithPersonalBoundaries(MatrixState memory state) private {
        Market storage m = _m();
        m.setSettlementLtv(state.root, ROOT_PERSONAL_LTV);

        uint256 personalShares = _expectedPersonalShares(m, state.root, ROOT_PERSONAL_LTV);
        uint256 rootShares = _expectedRootShares(m, state.root);
        SettlementQuote memory quote = m.controller.settlementFor(state.root);
        assertEq(quote.personal.borrowShares, personalShares, "root personal allowance");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root policy allowance");
        assertGt(personalShares, 0, "personal allowance is positive");
        assertLt(personalShares, rootShares, "personal allowance is below root allowance");

        _settleAndRestore(m, state.liquidSupplier, state.root, personalShares);
        _settleAndRestore(m, state.tailSupplier, state.root, rootShares);
        _expectSettlementExceedsTail(m, state.liquidSupplier, state.root, rootShares);
        _expectSettlementExceedsAllowed(m, state.tailSupplier, state.root, rootShares + 1);
    }

    function _assertBadDebtGate(MatrixState memory state) private {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(BAD_DEBT_PRICE);
        assertTrue(m.controller.hasBadDebt(), "queue root is bad debt");

        (, uint256 nonRootCollateralValue) = _positionValues(m, state.nonRoot);
        (uint256 nonRootDebt,) = _positionValues(m, state.nonRoot);
        assertLe(nonRootDebt, nonRootCollateralValue, "non-root target remains solvent");

        uint256 rootCut = uint256(m.core.position(m.id, state.root).borrowShares) / 10;
        uint256 nonRootCut = uint256(m.core.position(m.id, state.nonRoot).borrowShares) / 10;
        _expectSettlementBadDebt(m, state.tailSupplier, state.root, rootCut);
        _expectSettlementBadDebt(m, state.tailSupplier, state.nonRoot, nonRootCut);
    }

    function _supplyDirect(Market storage m, address supplier, uint256 assets) private {
        _fund(m.loanToken, supplier, assets);
        vm.startPrank(supplier);
        m.loanToken.approve(address(m.core), assets);
        m.core.supply(m.params, assets, 0, supplier, "");
        vm.stopPrank();
    }

    function _settleAndRestore(Market storage m, address supplier, address borrower, uint256 cutShares) private {
        uint256 snapshot = vm.snapshotState();
        _settleAndAssert(m, supplier, borrower, cutShares);
        assertTrue(vm.revertToState(snapshot), "settlement state restored");
    }

    function _settleAndAssert(Market storage m, address supplier, address borrower, uint256 cutShares) private {
        MorphoMarket memory marketBefore = m.core.market(m.id);
        SettlementExecution memory execution;
        execution.supplierSharesBefore = m.core.position(m.id, supplier).supplyShares;
        execution.borrowerSharesBefore = m.core.position(m.id, borrower).borrowShares;
        execution.expectedAssets = cutShares.toAssetsUp(marketBefore.totalBorrowAssets, marketBefore.totalBorrowShares);

        vm.prank(supplier);
        (execution.seizedAssets, execution.canceledAssets, execution.canceledShares, execution.burnedSupplyShares) =
            m.core.settle(m.params, 0, cutShares, supplier, borrower, supplier);

        assertEq(execution.canceledAssets, execution.expectedAssets, "core derives the expected canceled assets");
        assertEq(execution.canceledShares, cutShares, "borrow anchor cancels the requested shares");
        assertGt(execution.seizedAssets, 0, "settlement seizes collateral");
        assertEq(
            execution.borrowerSharesBefore - m.core.position(m.id, borrower).borrowShares,
            cutShares,
            "borrower shares decrease by the requested cut"
        );
        assertEq(
            execution.supplierSharesBefore - m.core.position(m.id, supplier).supplyShares,
            execution.burnedSupplyShares,
            "supplier shares decrease by the core burn"
        );
    }

    function _expectSettlementExceedsAllowed(Market storage m, address supplier, address borrower, uint256 cutShares)
        private
    {
        vm.prank(supplier);
        vm.expectRevert(ILidoLendMarketController.SettlementExceedsAllowed.selector);
        m.core.settle(m.params, 0, cutShares, supplier, borrower, supplier);
    }

    function _expectSettlementExceedsTail(Market storage m, address supplier, address borrower, uint256 cutShares)
        private
    {
        vm.prank(supplier);
        vm.expectRevert(ILidoLendMarketController.SettlementExceedsSettleableSupply.selector);
        m.core.settle(m.params, 0, cutShares, supplier, borrower, supplier);
    }

    function _expectSettlementBadDebt(Market storage m, address supplier, address borrower, uint256 cutShares) private {
        vm.prank(supplier);
        vm.expectRevert(ILidoLendMarketController.SettlementBadDebt.selector);
        m.core.settle(m.params, 0, cutShares, supplier, borrower, supplier);
    }

    function _expectedPersonalShares(Market storage m, address borrower, uint256 targetLtv)
        private
        view
        returns (uint256)
    {
        (uint256 debtAssets, uint256 collateralValue) = _positionValues(m, borrower);
        uint256 sliceAssets = (debtAssets * WAD - targetLtv * collateralValue) / (WAD - targetLtv);
        MorphoMarket memory market_ = m.core.market(m.id);
        return sliceAssets.toSharesUp(market_.totalBorrowAssets, market_.totalBorrowShares);
    }

    function _expectedRootShares(Market storage m, address borrower) private view returns (uint256) {
        (uint256 debtAssets,) = _positionValues(m, borrower);
        uint256 sliceAssets = Math.mulDiv(debtAssets, ROOT_POLICY_BPS, BPS);
        MorphoMarket memory market_ = m.core.market(m.id);
        return sliceAssets.toSharesUp(market_.totalBorrowAssets, market_.totalBorrowShares);
    }

    function _positionValues(Market storage m, address borrower)
        private
        view
        returns (uint256 debtAssets, uint256 collateralValue)
    {
        MorphoMarket memory market_ = m.core.market(m.id);
        MorphoPosition memory position = m.core.position(m.id, borrower);
        debtAssets = uint256(position.borrowShares).toAssetsUp(market_.totalBorrowAssets, market_.totalBorrowShares);
        collateralValue =
            Math.mulDiv(position.collateral, MockPriceOracle(address(m.oracle)).price(), ORACLE_PRICE_SCALE);
    }

    function _tailAssets(Market storage m, address supplier) private view returns (uint256) {
        MorphoMarket memory market_ = m.core.market(m.id);
        uint256 supplierAssets = uint256(m.core.position(m.id, supplier).supplyShares)
            .toAssetsDown(market_.totalSupplyAssets, market_.totalSupplyShares);
        uint256 freeLiquidity = Math.saturatingSub(market_.totalSupplyAssets, market_.totalBorrowAssets);
        return Math.saturatingSub(supplierAssets, freeLiquidity);
    }
}
