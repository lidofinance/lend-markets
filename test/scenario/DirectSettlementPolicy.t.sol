// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {MarketParams, Market as MorphoMarket, Position as MorphoPosition} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {MorphoBalancesLib} from "@lido-lend/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {SettlementConfig, SettlementSlice, SettlementQuote} from "../../src/types/SettlementTypes.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @dev Borrows for `onBehalf`, cuts `root` with `onBehalf`'s supply, and repays, all in one transaction.
///      `onBehalf` must authorize this contract on the core.
contract SameTransactionRootCut {
    function run(
        ILidoLend core,
        MarketParams calldata params,
        address onBehalf,
        address root,
        uint256 borrowAssets,
        uint256 cutShares
    ) external returns (uint256 debtCanceled) {
        (, uint256 borrowShares) = core.borrow(params, borrowAssets, 0, onBehalf, address(this));
        (, debtCanceled,,) = core.settle(params, cutShares, onBehalf, root, onBehalf);
        IERC20(params.loanToken).approve(address(core), type(uint256).max);
        core.repay(params, 0, borrowShares, onBehalf, "");
    }
}

/// @notice Direct-core coverage of the controller's settlement execution rules.
contract DirectSettlementPolicyTest is LidoLendSetup {
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
    /// @dev Lets the liquid supplier borrow all free liquidity at a lower LTV than the root, so the root stays root.
    uint256 private constant SUPPLIER_COLLATERAL = 2_000 ether;

    struct Actors {
        address liquidSupplier;
        address tailSupplier;
        address root;
        address nonRoot;
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

    /// @dev Checks the non-root personal limit at its exact boundaries.
    function test_nonRootPolicy_boundaries() public {
        Actors memory actors = _seed();
        Market storage m = _m();

        SettlementQuote memory quote = m.controller.settlementFor(actors.nonRoot, 0);
        assertEq(quote.personal.borrowShares, 0, "personal cut is zero");
        _expectSettlementExceedsAllowed(m, actors.liquidSupplier, actors.nonRoot, _minimumExecutableBorrowShares(m));

        m.setSettlementLtv(actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        quote = m.controller.settlementFor(actors.nonRoot, 0);
        assertEq(quote.personal.borrowShares, personalShares, "personal cut matches the model");
        assertGt(personalShares, 0, "personal cut is not zero");

        _settleAndRestore(m, actors.liquidSupplier, actors.nonRoot, personalShares);
        _expectSettlementExceedsAllowed(m, actors.liquidSupplier, actors.nonRoot, personalShares + 1);
    }

    /// @dev Checks the personal and root limits at their exact boundaries.
    function test_rootPolicy_boundaries() public {
        Actors memory actors = _seed();
        Market storage m = _m();

        m.setSettlementLtv(actors.root, ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, actors.root, ROOT_PERSONAL_LTV);
        uint256 rootShares = _expectedRootShares(m, actors.root);
        SettlementQuote memory quote = m.controller.settlementFor(actors.root, 0);
        assertEq(quote.personal.borrowShares, personalShares, "personal cut matches the model");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root cut matches the model");
        assertGt(personalShares, 0, "personal cut is not zero");
        assertLt(personalShares, rootShares, "personal cut is smaller");

        _settleAndRestore(m, actors.liquidSupplier, actors.root, personalShares);
        _expectSettlementExceedsTail(m, actors.liquidSupplier, actors.root, personalShares + 1);
        _settleAndRestore(m, actors.tailSupplier, actors.root, rootShares);
        _expectSettlementExceedsTail(m, actors.liquidSupplier, actors.root, rootShares);
        _expectSettlementExceedsAllowed(m, actors.tailSupplier, actors.root, rootShares + 1);
    }

    /// @dev The dust rule makes the root cut equal the full debt.
    ///      This borrower is not the root, so only its personal cut applies.
    function test_nonRootWithDust_usesOnlyPersonalLimit() public {
        Actors memory actors = _seed();
        Market storage m = _m();

        m.controller
            .setSettlementConfig(
                SettlementConfig({
                    sliceFloorBps: ROOT_POLICY_BPS,
                    sliceFloorAssets: 0,
                    fullCutBelowCollateral: uint96(NON_ROOT_COLLATERAL),
                    ltvStepBps: 0
                })
            );
        m.setSettlementLtv(actors.nonRoot, NON_ROOT_PERSONAL_LTV);

        uint256 personalShares = _expectedPersonalShares(m, actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        MorphoPosition memory position = m.core.position(m.id, actors.nonRoot);
        SettlementQuote memory quote = m.controller.settlementFor(actors.nonRoot, 0);

        assertEq(quote.personal.borrowShares, personalShares, "personal cut matches the model");
        assertGt(quote.personal.borrowShares, 0, "personal cut is not zero");
        assertGt(quote.personal.remainingBorrowShares, 0, "personal cut is partial");
        assertEq(quote.queueRoot.borrowShares, position.borrowShares, "root cut uses all debt shares");
        assertEq(quote.queueRoot.remainingBorrowShares, 0, "root cut is a full close");

        _settleAndRestore(m, actors.liquidSupplier, actors.nonRoot, personalShares);
        _expectSettlementExceedsAllowed(m, actors.liquidSupplier, actors.nonRoot, personalShares + 1);
    }

    /// @dev A non-root borrower without a personal limit cannot be settled.
    function testFuzz_nonRootWithoutPersonal_reverts(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        SettlementQuote memory quote = m.controller.settlementFor(actors.nonRoot, 0);
        assertEq(quote.personal.borrowShares, 0, "personal cut is zero");

        uint256 debtShares = m.core.position(m.id, actors.nonRoot).borrowShares;
        uint256 cutShares = bound(cutSeed, _minimumExecutableBorrowShares(m), debtShares);
        _expectSettlementExceedsAllowed(m, actors.liquidSupplier, actors.nonRoot, cutShares);
    }

    /// @dev A non-root cut up to the personal limit succeeds.
    function testFuzz_nonRootWithinPersonalLimit_succeeds(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        m.setSettlementLtv(actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        assertEq(
            m.controller.settlementFor(actors.nonRoot, 0).personal.borrowShares,
            personalShares,
            "personal cut matches the model"
        );

        uint256 cutShares = bound(cutSeed, _minimumExecutableBorrowShares(m), personalShares);
        _settleAndAssert(m, actors.liquidSupplier, actors.nonRoot, cutShares);
    }

    /// @dev A non-root cut above the personal limit is rejected.
    function testFuzz_nonRootAbovePersonalLimit_reverts(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        m.setSettlementLtv(actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        uint256 debtShares = m.core.position(m.id, actors.nonRoot).borrowShares;
        assertEq(
            m.controller.settlementFor(actors.nonRoot, 0).personal.borrowShares,
            personalShares,
            "personal cut matches the model"
        );
        assertLt(personalShares, debtShares, "personal cut is partial");

        uint256 cutShares = bound(cutSeed, personalShares + 1, debtShares);
        _expectSettlementExceedsAllowed(m, actors.liquidSupplier, actors.nonRoot, cutShares);
    }

    /// @dev A root cut up to the root limit succeeds when the lender has enough tail.
    function testFuzz_rootWithinRootLimit_withTail_succeeds(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        uint256 rootShares = _expectedRootShares(m, actors.root);
        SettlementQuote memory quote = m.controller.settlementFor(actors.root, 0);
        assertEq(quote.personal.borrowShares, 0, "personal cut is zero");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root cut matches the model");

        uint256 cutShares = bound(cutSeed, _minimumExecutableBorrowShares(m), rootShares);
        _settleAndAssert(m, actors.tailSupplier, actors.root, cutShares);
    }

    /// @dev A root cut needs lender tail when there is no personal limit.
    function testFuzz_rootWithinRootLimit_withoutTail_reverts(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        uint256 rootShares = _expectedRootShares(m, actors.root);
        SettlementQuote memory quote = m.controller.settlementFor(actors.root, 0);
        assertEq(quote.personal.borrowShares, 0, "personal cut is zero");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root cut matches the model");

        uint256 cutShares = bound(cutSeed, _minimumExecutableBorrowShares(m), rootShares);
        _expectSettlementExceedsTail(m, actors.liquidSupplier, actors.root, cutShares);
    }

    /// @dev A root cut above the root limit is rejected.
    function testFuzz_rootAboveRootLimit_reverts(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        uint256 rootShares = _expectedRootShares(m, actors.root);
        uint256 debtShares = m.core.position(m.id, actors.root).borrowShares;
        SettlementQuote memory quote = m.controller.settlementFor(actors.root, 0);
        assertEq(quote.personal.borrowShares, 0, "personal cut is zero");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root cut matches the model");
        assertLt(rootShares, debtShares, "root cut is partial");

        uint256 cutShares = bound(cutSeed, rootShares + 1, debtShares);
        _expectSettlementExceedsAllowed(m, actors.tailSupplier, actors.root, cutShares);
    }

    /// @dev A root cut up to the personal limit does not need lender tail.
    function testFuzz_rootWithinPersonalLimit_withoutTail_succeeds(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        m.setSettlementLtv(actors.root, ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, actors.root, ROOT_PERSONAL_LTV);
        uint256 rootShares = _expectedRootShares(m, actors.root);
        SettlementQuote memory quote = m.controller.settlementFor(actors.root, 0);
        assertEq(quote.personal.borrowShares, personalShares, "personal cut matches the model");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root cut matches the model");
        assertLt(personalShares, rootShares, "personal cut is smaller");

        uint256 cutShares = bound(cutSeed, _minimumExecutableBorrowShares(m), personalShares);
        _settleAndAssert(m, actors.liquidSupplier, actors.root, cutShares);
    }

    /// @dev A cut between the personal and root limits succeeds with lender tail.
    function testFuzz_rootAbovePersonalWithinRootLimit_withTail_succeeds(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        m.setSettlementLtv(actors.root, ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, actors.root, ROOT_PERSONAL_LTV);
        uint256 rootShares = _expectedRootShares(m, actors.root);
        SettlementQuote memory quote = m.controller.settlementFor(actors.root, 0);
        assertEq(quote.personal.borrowShares, personalShares, "personal cut matches the model");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root cut matches the model");
        assertLt(personalShares, rootShares, "personal cut is smaller");

        uint256 cutShares = bound(cutSeed, personalShares + 1, rootShares);
        _settleAndAssert(m, actors.tailSupplier, actors.root, cutShares);
    }

    /// @dev A cut between the personal and root limits fails without lender tail.
    function testFuzz_rootAbovePersonalWithinRootLimit_withoutTail_reverts(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        m.setSettlementLtv(actors.root, ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, actors.root, ROOT_PERSONAL_LTV);
        uint256 rootShares = _expectedRootShares(m, actors.root);
        SettlementQuote memory quote = m.controller.settlementFor(actors.root, 0);
        assertEq(quote.personal.borrowShares, personalShares, "personal cut matches the model");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root cut matches the model");
        assertLt(personalShares, rootShares, "personal cut is smaller");

        uint256 cutShares = bound(cutSeed, personalShares + 1, rootShares);
        _expectSettlementExceedsTail(m, actors.liquidSupplier, actors.root, cutShares);
    }

    /// @dev A cut above the personal and root limits is rejected.
    function testFuzz_rootAbovePersonalAndRootLimits_reverts(uint40 elapsedSeed, uint256 cutSeed) public {
        Actors memory actors = _seedAfterInterest(elapsedSeed);
        Market storage m = _m();

        m.setSettlementLtv(actors.root, ROOT_PERSONAL_LTV);
        uint256 personalShares = _expectedPersonalShares(m, actors.root, ROOT_PERSONAL_LTV);
        uint256 rootShares = _expectedRootShares(m, actors.root);
        uint256 debtShares = m.core.position(m.id, actors.root).borrowShares;
        SettlementQuote memory quote = m.controller.settlementFor(actors.root, 0);
        assertEq(quote.personal.borrowShares, personalShares, "personal cut matches the model");
        assertEq(quote.queueRoot.borrowShares, rootShares, "root cut matches the model");
        assertLt(personalShares, rootShares, "personal cut is smaller");
        assertLt(rootShares, debtShares, "root cut is partial");

        uint256 cutShares = bound(cutSeed, rootShares + 1, debtShares);
        _expectSettlementExceedsAllowed(m, actors.tailSupplier, actors.root, cutShares);
    }

    /// @dev A personal quote executes without booking pending interest first.
    function testFuzz_pendingInterest_personalQuoteExecutes(uint40 elapsedSeed) public {
        Actors memory actors = _seedPendingInterest(elapsedSeed);
        Market storage m = _m();

        m.setSettlementLtv(actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        assertLt(m.core.market(m.id).lastUpdate, block.timestamp, "interest is pending");
        uint256 storedBorrowAssets = m.core.market(m.id).totalBorrowAssets;
        (,, uint256 borrowAssetsWithInterest,) = MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        assertGt(borrowAssetsWithInterest, storedBorrowAssets, "pending interest is not zero");

        (address root,) = m.controller.nextSettlementBorrower(0);
        assertNotEq(root, actors.nonRoot, "borrower is not the root");

        SettlementQuote memory quote = m.controller.settlementFor(actors.nonRoot, 0);
        uint256 personalShares = _expectedPersonalShares(m, actors.nonRoot, NON_ROOT_PERSONAL_LTV);
        assertEq(quote.personal.borrowShares, personalShares, "personal cut matches the model");
        assertGt(quote.personal.borrowShares, 0, "personal cut is not zero");
        assertGt(quote.personal.remainingBorrowShares, 0, "personal cut is partial");

        _settleAndAssert(m, actors.liquidSupplier, actors.nonRoot, quote.personal.borrowShares);
        assertEq(m.core.market(m.id).lastUpdate, block.timestamp, "settle booked the interest");
    }

    /// @dev A root quote executes without booking pending interest first.
    function testFuzz_pendingInterest_rootQuoteExecutes(uint40 elapsedSeed) public {
        Actors memory actors = _seedPendingInterest(elapsedSeed);
        Market storage m = _m();

        assertLt(m.core.market(m.id).lastUpdate, block.timestamp, "interest is pending");
        uint256 storedBorrowAssets = m.core.market(m.id).totalBorrowAssets;
        (,, uint256 borrowAssetsWithInterest,) = MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        assertGt(borrowAssetsWithInterest, storedBorrowAssets, "pending interest is not zero");

        (address root, SettlementSlice memory slice) = m.controller.nextSettlementBorrower(0);
        uint256 rootShares = _expectedRootShares(m, actors.root);
        assertEq(root, actors.root, "borrower is the root");
        assertEq(slice.borrowShares, rootShares, "root cut matches the model");
        assertGt(slice.borrowShares, 0, "root cut is not zero");
        assertGt(slice.remainingBorrowShares, 0, "root cut is partial");

        _settleAndAssert(m, actors.tailSupplier, actors.root, slice.borrowShares);
        assertEq(m.core.market(m.id).lastUpdate, block.timestamp, "settle booked the interest");
    }

    /// @dev Bad debt blocks settlement of the root borrower.
    function test_badDebt_blocksRootSettlement() public {
        Actors memory actors = _seed();
        Market storage m = _m();

        MockPriceOracle(address(m.oracle)).setPrice(BAD_DEBT_PRICE);
        assertTrue(m.controller.hasBadDebt(), "root has bad debt");

        uint256 cutShares = uint256(m.core.position(m.id, actors.root).borrowShares) / 10;
        _expectSettlementBadDebt(m, actors.tailSupplier, actors.root, cutShares);
    }

    /// @dev Bad debt at the root also blocks settlement of another borrower.
    function test_badDebt_blocksNonRootSettlement() public {
        Actors memory actors = _seed();
        Market storage m = _m();

        MockPriceOracle(address(m.oracle)).setPrice(BAD_DEBT_PRICE);
        assertTrue(m.controller.hasBadDebt(), "root has bad debt");
        (uint256 debtAssets, uint256 collateralValue) = _positionValues(m, actors.nonRoot);
        assertLe(debtAssets, collateralValue, "non-root borrower is solvent");

        uint256 cutShares = uint256(m.core.position(m.id, actors.nonRoot).borrowShares) / 10;
        _expectSettlementBadDebt(m, actors.tailSupplier, actors.nonRoot, cutShares);
    }

    /// @dev Pins open finding F4-C05: a supplier with no settleable supply at the start of a transaction borrows the
    ///      free liquidity, cuts the root by its whole root-policy slice, and repays in the same transaction. A fix
    ///      changes this outcome; update this test with the fix.
    function test_F4C05_sameTxBorrowRootCutRepay_bypassesLenderTail() public {
        Actors memory actors = _seed();
        Market storage m = _m();
        address supplier = actors.liquidSupplier;
        _fund(m.collateralToken, supplier, SUPPLIER_COLLATERAL);
        m.supplyCollateral(supplier, SUPPLIER_COLLATERAL);
        m.activateCollateral();
        m.accrueInterest();
        assertEq(_tailAssets(m, supplier), 0, "setup: no settleable supply at the transaction start");
        _expectSettlementExceedsTail(m, supplier, actors.root, _expectedRootShares(m, actors.root));

        MorphoMarket memory market_ = m.core.market(m.id);
        uint256 free = market_.totalSupplyAssets - market_.totalBorrowAssets;
        (uint256 cutShares, uint256 expectedDebt) = _rootSliceAfterBorrow(m, actors.root, free);
        uint256 rootSharesBefore = m.core.position(m.id, actors.root).borrowShares;

        SameTransactionRootCut runner = new SameTransactionRootCut();
        _fund(m.loanToken, address(runner), 1); // the share-based repay may round up by one asset
        vm.prank(supplier);
        m.core.setAuthorization(address(runner), true);

        uint256 debtCanceled = runner.run(m.core, m.params, supplier, actors.root, free, cutShares);

        assertEq(debtCanceled, expectedDebt, "the whole root-policy slice is cut");
        assertGt(debtCanceled, 0, "the cut exceeds the zero settleable supply at the transaction start");
        assertEq(
            rootSharesBefore - m.core.position(m.id, actors.root).borrowShares, cutShares, "root debt shares decrease"
        );
        assertEq(m.core.position(m.id, supplier).borrowShares, 0, "the supplier repaid its borrow");
    }

    function _m() private view returns (Market storage) {
        return protocol.markets[0];
    }

    function _seed() private returns (Actors memory actors) {
        actors = _seedState();
        _assertSeed(actors);
    }

    function _seedAfterInterest(uint40 elapsedSeed) private returns (Actors memory actors) {
        actors = _seedState();

        uint256 elapsed = bound(uint256(elapsedSeed), 1, 30 days);
        vm.warp(block.timestamp + elapsed);
        _m().accrueInterest();

        _assertSeed(actors);
    }

    function _seedPendingInterest(uint40 elapsedSeed) private returns (Actors memory actors) {
        actors = _seed();
        vm.warp(block.timestamp + bound(uint256(elapsedSeed), 1, 30 days));
    }

    function _seedState() private returns (Actors memory actors) {
        Market storage m = _m();
        MockPriceOracle(address(m.oracle)).setPrice(LIVE_PRICE);

        actors.liquidSupplier = _actor("liquid supplier");
        actors.tailSupplier = _actor("tail supplier");
        actors.root = _actor("root borrower");
        actors.nonRoot = _actor("non-root borrower");

        _supplyDirect(m, actors.liquidSupplier, LIQUID_SUPPLY);
        _supplyDirect(m, actors.tailSupplier, TAIL_SUPPLY);

        _fund(m.collateralToken, actors.root, ROOT_COLLATERAL);
        m.supplyCollateral(actors.root, ROOT_COLLATERAL);
        _fund(m.collateralToken, actors.nonRoot, NON_ROOT_COLLATERAL);
        m.supplyCollateral(actors.nonRoot, NON_ROOT_COLLATERAL);
        m.activateCollateral();

        m.borrow(actors.root, ROOT_BORROW);
        m.borrow(actors.nonRoot, NON_ROOT_BORROW);

        m.controller
            .setSettlementConfig(
                SettlementConfig({
                    sliceFloorBps: ROOT_POLICY_BPS, sliceFloorAssets: 0, fullCutBelowCollateral: 0, ltvStepBps: 0
                })
            );
    }

    function _assertSeed(Actors memory actors) private {
        Market storage m = _m();
        (address root,) = m.controller.nextSettlementBorrower(0);
        assertEq(root, actors.root, "higher-LTV borrower is the queue root");
        assertEq(_tailAssets(m, actors.liquidSupplier), 0, "liquid supplier has no lender tail");
        assertGe(
            _tailAssets(m, actors.tailSupplier),
            _expectedRootShares(m, actors.root)
                .toAssetsUp(m.core.market(m.id).totalBorrowAssets, m.core.market(m.id).totalBorrowShares),
            "tail supplier can execute the full root allowance"
        );
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
        SettlementExecution memory execution;
        execution.supplierSharesBefore = m.core.position(m.id, supplier).supplyShares;
        execution.borrowerSharesBefore = m.core.position(m.id, borrower).borrowShares;
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        execution.expectedAssets = cutShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);

        vm.prank(supplier);
        (execution.seizedAssets, execution.canceledAssets, execution.canceledShares, execution.burnedSupplyShares) =
            m.core.settle(m.params, cutShares, supplier, borrower, supplier);

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
        m.core.settle(m.params, cutShares, supplier, borrower, supplier);
    }

    function _expectSettlementExceedsTail(Market storage m, address supplier, address borrower, uint256 cutShares)
        private
    {
        vm.prank(supplier);
        vm.expectRevert(ILidoLendMarketController.SettlementExceedsSettleableSupply.selector);
        m.core.settle(m.params, cutShares, supplier, borrower, supplier);
    }

    function _expectSettlementBadDebt(Market storage m, address supplier, address borrower, uint256 cutShares) private {
        vm.prank(supplier);
        vm.expectRevert(ILidoLendMarketController.SettlementBadDebt.selector);
        m.core.settle(m.params, cutShares, supplier, borrower, supplier);
    }

    function _expectedPersonalShares(Market storage m, address borrower, uint256 targetLtv)
        private
        view
        returns (uint256)
    {
        (uint256 debtAssets, uint256 collateralValue) = _positionValues(m, borrower);
        uint256 sliceAssets = (debtAssets * WAD - targetLtv * collateralValue) / (WAD - targetLtv);
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        return sliceAssets.toSharesUp(totalBorrowAssets, totalBorrowShares);
    }

    function _expectedRootShares(Market storage m, address borrower) private view returns (uint256) {
        (uint256 debtAssets,) = _positionValues(m, borrower);
        uint256 sliceAssets = Math.mulDiv(debtAssets, ROOT_POLICY_BPS, BPS);
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        return sliceAssets.toSharesUp(totalBorrowAssets, totalBorrowShares);
    }

    /// @dev The root-policy cut and its debt on the stored totals after a borrow of `borrowAssets`.
    function _rootSliceAfterBorrow(Market storage m, address root, uint256 borrowAssets)
        private
        view
        returns (uint256 cutShares, uint256 debtCanceled)
    {
        MorphoMarket memory market_ = m.core.market(m.id);
        uint256 totalBorrowAssets = market_.totalBorrowAssets + borrowAssets;
        uint256 totalBorrowShares =
            market_.totalBorrowShares + borrowAssets.toSharesUp(market_.totalBorrowAssets, market_.totalBorrowShares);
        uint256 rootDebt =
            uint256(m.core.position(m.id, root).borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        cutShares = Math.mulDiv(rootDebt, ROOT_POLICY_BPS, BPS).toSharesUp(totalBorrowAssets, totalBorrowShares);
        debtCanceled = cutShares.toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    function _positionValues(Market storage m, address borrower)
        private
        view
        returns (uint256 debtAssets, uint256 collateralValue)
    {
        MorphoPosition memory position = m.core.position(m.id, borrower);
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        debtAssets = uint256(position.borrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
        collateralValue =
            Math.mulDiv(position.collateral, MockPriceOracle(address(m.oracle)).price(), ORACLE_PRICE_SCALE);
    }

    function _tailAssets(Market storage m, address supplier) private view returns (uint256) {
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        uint256 supplierAssets =
            uint256(m.core.position(m.id, supplier).supplyShares).toAssetsDown(totalSupplyAssets, totalSupplyShares);
        uint256 freeLiquidity = Math.saturatingSub(totalSupplyAssets, totalBorrowAssets);
        return Math.saturatingSub(supplierAssets, freeLiquidity);
    }

    function _minimumExecutableBorrowShares(Market storage m) private view returns (uint256) {
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(m.core, m.params);
        return uint256(1).toSharesUp(totalBorrowAssets, totalBorrowShares);
    }
}
