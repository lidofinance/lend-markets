// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @notice L2 settlement scenarios: a lender exits when ordinary liquidity is short. `fallbackExit` first
///         redeems whatever ordinary liquidity (idle + withdrawable) covers, then settles the remainder
///         against the controller's risk queue — seizing borrower collateral and cancelling debt. `settle`
///         is the liquidity-neutral targeted variant. Magnitudes are recomputed exactly: the ordinary leg
///         equals the idle liquidity, the seized collateral equals the cancelled debt valued at the oracle
///         price, and a targeted cut either matches `settlementFor` or is capped to the requested shares' value above
///         current free liquidity.
contract SettlementTest is LidoLendSetup {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    // 400 collateral keeps an 80 borrow within LLTV-max even at the lowest seeded price (400*0.24 = 96 > 80).
    uint256 internal constant COLLAT = 400 ether;
    uint256 internal constant BORROW = 80 ether;

    struct RequestTailSettlementState {
        address alice;
        address bob;
        address borrower;
        address receiver;
        uint256 aliceShares;
        uint256 bobShares;
        uint256 vaultSupplyShares;
        uint256 availableLiquidity;
        uint256 settlementClaim;
        uint256 requestAssets;
        uint256 requestTailBudget;
        uint256 proRataGlobalTailBudget;
        uint256 expectedBurn;
        uint256 bobValue;
        uint256 borrowerDebtShares;
    }

    struct RequestBoundaryState {
        address alice;
        address borrower;
        uint256 aliceShares;
        uint256 availableLiquidity;
        uint256 settlementClaim;
        uint256 budget;
        uint256 bobShares;
        uint256 bobValue;
        uint256 vaultSupplyShares;
    }

    struct NothingSettledState {
        uint256 ownerShares;
        uint256 vaultSupplyShares;
        uint256 borrowerDebtShares;
        uint256 borrowerCollateral;
        uint256 availableLiquidity;
    }

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender supplies 100; borrower draws 80, leaving exactly 20 idle. Returns the lender's shares.
    function _seedShortLiquidity(address lender, address borrower) internal returns (uint256 shares) {
        return _seedShortLiquidity(lender, borrower, 100 ether, BORROW, COLLAT);
    }

    function _seedShortLiquidity(
        address lender,
        address borrower,
        uint256 lendAssets,
        uint256 borrowAssets,
        uint256 collateralAssets
    ) internal returns (uint256 shares) {
        Market storage m = _m();
        _fund(m.loanToken, lender, lendAssets);
        shares = m.vaultDeposit(lender, lendAssets);
        _fund(m.collateralToken, borrower, collateralAssets);
        m.supplyCollateral(borrower, collateralAssets);
        m.activateCollateral();
        m.borrow(borrower, borrowAssets);
    }

    /// @dev Makes the queue-root policy close the selected borrower in one borrow-anchored cut.
    function _setFullClosePolicy() internal {
        Market storage m = _m();
        SettlementConfig memory config = m.controller.settlementConfig();
        config.sliceFloorBps = 10_000;
        config.sliceFloorAssets = 0;
        config.fullCutBelowCollateral = 0;
        config.ltvStepBps = 0;
        m.controller.setSettlementConfig(config);
    }

    function _assertExactFullCloseQuote(address borrower) internal view {
        Market storage m = _m();
        (uint256 quotedSupplyShares, uint256 quotedBorrowShares, uint256 remainingBorrowShares) =
            m.controller.settlementFor(borrower);
        uint256 supplyBudget = m.core.position(m.id, address(m.vault)).supplyShares;
        assertEq(remainingBorrowShares, 0, "policy selects a full close");
        assertGt(quotedBorrowShares, 0, "full close is borrow-anchored");
        assertEq(quotedSupplyShares, supplyBudget, "full-close quote exactly exhausts the budget");
    }

    function _seedRequestTailSettlement() internal returns (RequestTailSettlementState memory state) {
        Market storage m = _m();
        state.alice = _actor("alice");
        state.bob = _actor("bob");
        state.borrower = _actor("borrower");
        state.receiver = _actor("receiver");

        _fund(m.loanToken, state.alice, 20 ether);
        state.aliceShares = m.vaultDeposit(state.alice, 20 ether);
        _fund(m.loanToken, state.bob, 80 ether);
        state.bobShares = m.vaultDeposit(state.bob, 80 ether);

        _fund(m.collateralToken, state.borrower, COLLAT);
        m.supplyCollateral(state.borrower, COLLAT);
        m.activateCollateral();
        m.borrow(state.borrower, 90 ether);

        vm.warp(block.timestamp + 30 days);
        m.accrueInterest();
        _setFullClosePolicy();

        MorphoMarket memory market_ = m.core.market(m.id);
        state.vaultSupplyShares = m.core.position(m.id, address(m.vault)).supplyShares;
        uint256 vaultSupplyAssets =
            state.vaultSupplyShares.toAssetsDown(market_.totalSupplyAssets, market_.totalSupplyShares);
        state.availableLiquidity = market_.totalSupplyAssets - market_.totalBorrowAssets;
        uint256 settleableSupplyShares = (vaultSupplyAssets - state.availableLiquidity)
        .toSharesDown(market_.totalSupplyAssets, market_.totalSupplyShares);
        uint256 vaultTotalSupply = m.vault.totalSupply();
        state.settlementClaim = Math.mulDiv(state.vaultSupplyShares, state.aliceShares, vaultTotalSupply);
        uint256 vaultTotalAssets = m.vault.totalAssets();
        state.requestAssets = Math.mulDiv(state.aliceShares, vaultTotalAssets + 1, vaultTotalSupply + 1);
        assertEq(state.requestAssets, m.vault.previewRedeem(state.aliceShares), "independent request-value model");
        assertNotEq(
            mulmod(state.aliceShares, vaultTotalAssets + 1, vaultTotalSupply + 1),
            0,
            "request-value conversion is non-round"
        );
        uint256 requestTailAssets = Math.saturatingSub(state.requestAssets, state.availableLiquidity);
        uint256 convertedTail =
            Math.mulDiv(requestTailAssets, market_.totalSupplyShares + 1e6, market_.totalSupplyAssets + 1);
        assertNotEq(
            mulmod(requestTailAssets, market_.totalSupplyShares + 1e6, market_.totalSupplyAssets + 1),
            0,
            "request-tail conversion is non-round"
        );
        state.requestTailBudget = Math.min(state.settlementClaim, convertedTail);
        state.proRataGlobalTailBudget = Math.mulDiv(settleableSupplyShares, state.aliceShares, vaultTotalSupply);
        state.expectedBurn =
            Math.mulDiv(state.aliceShares, state.requestTailBudget, state.settlementClaim, Math.Rounding.Ceil);
        state.bobValue = m.vault.previewRedeem(state.bobShares);
        state.borrowerDebtShares = m.core.position(m.id, state.borrower).borrowShares;
    }

    /// @dev At parity, Alice owns 20 of the vault's 100 assets and the market has exactly 10 assets of free liquidity.
    function _seedRequestLiquidityBoundary()
        internal
        returns (address alice, address borrower, uint256 aliceShares, uint256 availableLiquidity)
    {
        Market storage m = _m();
        alice = _actor("alice");
        address bob = _actor("bob");
        borrower = _actor("borrower");

        _fund(m.loanToken, alice, 20 ether);
        aliceShares = m.vaultDeposit(alice, 20 ether);
        _fund(m.loanToken, bob, 80 ether);
        m.vaultDeposit(bob, 80 ether);

        _fund(m.collateralToken, borrower, COLLAT);
        m.supplyCollateral(borrower, COLLAT);
        m.activateCollateral();
        m.borrow(borrower, 90 ether);
        _setFullClosePolicy();

        MorphoMarket memory market_ = m.core.market(m.id);
        availableLiquidity = market_.totalSupplyAssets - market_.totalBorrowAssets;
        assertEq(availableLiquidity, 10 ether, "boundary setup has exactly 10 free assets");
    }

    function _requestTailBudget(uint256 shares)
        internal
        view
        returns (uint256 settlementClaim, uint256 requestAssets, uint256 availableLiquidity, uint256 budget)
    {
        Market storage m = _m();
        MorphoMarket memory market_ = m.core.market(m.id);
        settlementClaim =
            Math.mulDiv(m.core.position(m.id, address(m.vault)).supplyShares, shares, m.vault.totalSupply());
        requestAssets = m.vault.previewRedeem(shares);
        availableLiquidity = market_.totalSupplyAssets - market_.totalBorrowAssets;
        budget = Math.min(
            settlementClaim,
            Math.saturatingSub(requestAssets, availableLiquidity)
                .toSharesDown(market_.totalSupplyAssets, market_.totalSupplyShares)
        );
    }

    function _assertSettleRevertsNothingSettled(address alice, address borrower, uint256 shares) internal {
        Market storage m = _m();
        NothingSettledState memory before;
        before.ownerShares = m.vault.balanceOf(alice);
        before.vaultSupplyShares = m.core.position(m.id, address(m.vault)).supplyShares;
        before.borrowerDebtShares = m.core.position(m.id, borrower).borrowShares;
        before.borrowerCollateral = m.core.position(m.id, borrower).collateral;
        MorphoMarket memory market_ = m.core.market(m.id);
        before.availableLiquidity = market_.totalSupplyAssets - market_.totalBorrowAssets;

        vm.expectRevert(ILidoLendERC4626.NothingSettled.selector);
        vm.prank(alice);
        m.vault.settle(shares, _singleton(borrower), alice, alice);

        assertEq(m.vault.balanceOf(alice), before.ownerShares, "owner shares unchanged");
        assertEq(
            m.core.position(m.id, address(m.vault)).supplyShares,
            before.vaultSupplyShares,
            "vault core position unchanged"
        );
        assertEq(m.core.position(m.id, borrower).borrowShares, before.borrowerDebtShares, "borrower debt unchanged");
        assertEq(m.core.position(m.id, borrower).collateral, before.borrowerCollateral, "borrower collateral unchanged");
        MorphoMarket memory marketAfter = m.core.market(m.id);
        assertEq(
            marketAfter.totalSupplyAssets - marketAfter.totalBorrowAssets,
            before.availableLiquidity,
            "free liquidity unchanged"
        );
    }

    /// @dev Collateral seized for `debt` loan-assets, valued at the oracle price (settle has no incentive).
    function _collateralFor(uint256 debt) internal view returns (uint256) {
        return debt * 1e36 / oraclePrice;
    }

    /// @dev `fallbackExit` redeems the idle liquidity first, then one settle cut equal to the predicted slice; the
    ///      seized collateral equals the cancelled debt valued at the oracle price.
    function test_fallbackExit_redeemsIdleThenSettlesOneCut() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        uint256 shares = _seedShortLiquidity(_actor("lender"), borrower);

        // Ordinary leg redeems exactly the idle (100 - 80); one settle cut (maxIterations=1) then follows,
        // which must equal the controller's predicted slice — so every magnitude is pinned exactly.
        uint256 sliceAssets = m.controller.positionOf(borrower).slice;
        uint128 colBefore = m.core.position(m.id, borrower).collateral;

        (, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            m.fallbackExit(_actor("lender"), shares, _actor("lender"), 1);

        assertEq(loanAssets, 20 ether, "ordinary leg redeems exactly the 20 idle (100 - 80)");
        assertEq(debtCanceled, sliceAssets, "the single settle cut == settlementFor.sliceAssets");
        assertEq(collateralSeized, colBefore - m.core.position(m.id, borrower).collateral, "collateral delta exact");
        assertApproxEqAbs(collateralSeized, _collateralFor(debtCanceled), 1, "seized == debt valued at price");
    }

    /// @dev Targeted `settle` cancels exactly the controller's predicted slice, seizing collateral worth the
    ///      cancelled debt at the oracle price.
    function test_settle_cutsExactlyThePredictedSlice() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        uint256 shares = _seedShortLiquidity(_actor("lender"), borrower);

        // The controller predicts the exact slice it will cut; the action must match it.
        uint256 sliceAssets = m.controller.positionOf(borrower).slice;
        uint128 colBefore = m.core.position(m.id, borrower).collateral;

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        (,, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(_actor("lender"), shares, borrowers, _actor("lender"));

        assertEq(debtCanceled, sliceAssets, "debtCanceled == settlementFor.sliceAssets (exact predicted cut)");
        assertEq(collateralSeized, colBefore - m.core.position(m.id, borrower).collateral, "collateral delta exact");
        assertApproxEqAbs(collateralSeized, _collateralFor(debtCanceled), 1, "seized == debt valued at price");
    }

    function testFuzz_settle_requestCoveredByLiquidityRevertsNothingSettled(uint96 sharesSeed) public {
        (address alice, address borrower, uint256 aliceShares, uint256 availableLiquidity) =
            _seedRequestLiquidityBoundary();
        Market storage m = _m();

        uint256 maxLiquidShares = Math.min(aliceShares, m.vault.convertToShares(availableLiquidity));
        uint256 shares = bound(uint256(sharesSeed), 1, maxLiquidShares);
        (uint256 settlementClaim, uint256 requestAssets,, uint256 budget) = _requestTailBudget(shares);
        assertGt(settlementClaim, 0, "request has a core-share claim");
        assertLe(requestAssets, availableLiquidity, "request is fully liquid");
        assertEq(budget, 0, "fully liquid request has no settlement budget");

        _assertSettleRevertsNothingSettled(alice, borrower, shares);
    }

    function test_settle_requestAtLiquidityBoundaryRevertsNothingSettled() public {
        (address alice, address borrower, uint256 aliceShares, uint256 availableLiquidity) =
            _seedRequestLiquidityBoundary();
        Market storage m = _m();

        uint256 shares = Math.min(aliceShares, m.vault.convertToShares(availableLiquidity));
        (, uint256 requestAssets,, uint256 budget) = _requestTailBudget(shares);
        assertEq(requestAssets, availableLiquidity, "request lands exactly on the liquidity boundary");
        assertEq(budget, 0, "boundary request has no settlement budget");

        _assertSettleRevertsNothingSettled(alice, borrower, shares);
    }

    function test_settle_requestAboveLiquidityUsesOnlyRequestTail() public {
        RequestBoundaryState memory state;
        (state.alice, state.borrower, state.aliceShares, state.availableLiquidity) = _seedRequestLiquidityBoundary();
        Market storage m = _m();
        state.bobShares = m.vault.balanceOf(_actor("bob"));
        state.bobValue = m.vault.previewRedeem(state.bobShares);

        uint256 requestAssets;
        (state.settlementClaim, requestAssets,, state.budget) = _requestTailBudget(state.aliceShares);
        assertEq(requestAssets, 20 ether, "full Alice request is worth 20 assets");
        assertEq(requestAssets - state.availableLiquidity, 10 ether, "request tail is exactly 10 assets");
        assertEq(
            state.budget.toAssetsDown(m.core.market(m.id).totalSupplyAssets, m.core.market(m.id).totalSupplyShares),
            10 ether,
            "budget represents only the request tail"
        );

        state.vaultSupplyShares = m.core.position(m.id, address(m.vault)).supplyShares;
        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(state.alice, state.aliceShares, _singleton(state.borrower), state.alice);

        assertEq(
            state.vaultSupplyShares - m.core.position(m.id, address(m.vault)).supplyShares, state.budget, "exact budget"
        );
        assertEq(
            sharesBurned,
            Math.mulDiv(state.aliceShares, state.budget, state.settlementClaim, Math.Rounding.Ceil),
            "burn matches the serviced fraction"
        );
        assertEq(m.vault.balanceOf(state.alice), state.aliceShares - sharesBurned, "Alice retains the liquid part");
        assertEq(m.vault.balanceOf(_actor("bob")), state.bobShares, "Bob shares unchanged");
        assertGe(m.vault.previewRedeem(state.bobShares), state.bobValue, "Bob is not diluted");
        assertGt(collateralSeized, 0, "request tail seizes collateral");
        assertGt(debtCanceled, 0, "request tail cancels debt");
        MorphoMarket memory marketAfter = m.core.market(m.id);
        assertEq(
            marketAfter.totalSupplyAssets - marketAfter.totalBorrowAssets,
            state.availableLiquidity,
            "settle preserves free liquidity"
        );

        uint256 remainingShares = m.vault.balanceOf(state.alice);
        (, uint256 remainingRequestAssets,, uint256 remainingBudget) = _requestTailBudget(remainingShares);
        assertLe(remainingRequestAssets, state.availableLiquidity, "Alice retains only a liquid request");
        assertEq(remainingBudget, 0, "the serviced tail cannot be settled twice");
        _assertSettleRevertsNothingSettled(state.alice, state.borrower, remainingShares);
    }

    /// @dev With all supplied liquidity borrowed, a full-close quote that exactly exhausts the lender's supply-share
    ///      budget succeeds across fuzzed asset magnitudes and closes both positions to zero.
    function testFuzz_settle_fullCloseSucceedsAtExactSupplyBudget(uint96 assetsSeed) public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        uint256 assets = bound(uint256(assetsSeed), 1 ether, BORROW);

        _setFullClosePolicy();
        uint256 shares = _seedShortLiquidity(lender, borrower, assets, assets, COLLAT);
        _assertExactFullCloseQuote(borrower);

        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(lender, shares, _singleton(borrower), lender);

        assertEq(sharesBurned, shares, "all vault shares burned");
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "debt canceled");
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "borrower fully closed");
        assertEq(m.core.position(m.id, address(m.vault)).supplyShares, 0, "supply budget fully consumed");
    }

    /// @dev The same exact-budget boundary through `fallbackExit`: with zero idle liquidity it goes directly to the
    ///      settlement leg, consumes the whole budget, and closes both positions to zero.
    function testFuzz_fallbackExit_fullCloseSucceedsAtExactSupplyBudget(uint96 assetsSeed) public {
        Market storage m = _m();
        address lender = _actor("lender");
        address borrower = _actor("borrower");
        uint256 assets = bound(uint256(assetsSeed), 1 ether, BORROW);

        _setFullClosePolicy();
        uint256 shares = _seedShortLiquidity(lender, borrower, assets, assets, COLLAT);
        _assertExactFullCloseQuote(borrower);

        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            m.fallbackExit(lender, shares, lender, 1);

        assertEq(sharesBurned, shares, "all vault shares burned");
        assertEq(loanAssets, 0, "zero idle liquidity to redeem");
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "debt canceled");
        assertEq(m.core.position(m.id, borrower).borrowShares, 0, "borrower fully closed");
        assertEq(m.core.position(m.id, address(m.vault)).supplyShares, 0, "supply budget fully consumed");
    }

    /// @dev Two lenders share a yield-bearing vault. Alice requests her whole position while some of that request is
    ///      covered by free liquidity. Only the request-specific remainder can settle, rather than Alice's fraction of
    ///      the vault-wide illiquid tail; the other lender is not diluted.
    function test_settle_capsMultiLenderExitToRequestIlliquidTail() public {
        Market storage m = _m();
        RequestTailSettlementState memory state = _seedRequestTailSettlement();

        (uint256 fullCloseSupplyShares,, uint256 remainingBorrowShares) = m.controller.settlementFor(state.borrower);
        assertEq(remainingBorrowShares, 0, "policy quotes a full close");
        assertGt(
            fullCloseSupplyShares, state.requestTailBudget, "Alice cannot afford the full close from her request tail"
        );
        assertGt(state.requestAssets, state.availableLiquidity, "request extends above free liquidity");
        assertGt(
            state.proRataGlobalTailBudget,
            state.requestTailBudget,
            "request tail is smaller than the old pro-rata global-tail budget"
        );
        assertGt(m.vault.previewRedeem(1 ether), 1 ether, "interest makes the vault share price non-parity");

        (uint256 sharesBurned,, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(state.alice, state.aliceShares, _singleton(state.borrower), state.receiver);

        MorphoMarket memory marketAfter = m.core.market(m.id);
        uint256 vaultSupplySharesAfter = m.core.position(m.id, address(m.vault)).supplyShares;
        uint256 borrowerDebtSharesAfter = m.core.position(m.id, state.borrower).borrowShares;

        assertEq(
            state.vaultSupplyShares - vaultSupplySharesAfter,
            state.requestTailBudget,
            "exact request-specific tail budget consumed"
        );
        assertEq(sharesBurned, state.expectedBurn, "vault burn matches the independently computed request service");
        assertEq(
            m.vault.balanceOf(state.alice), state.aliceShares - state.expectedBurn, "Alice retains her liquid claim"
        );
        assertEq(m.vault.balanceOf(state.bob), state.bobShares, "Bob's shares are untouched");
        assertGe(m.vault.previewRedeem(state.bobShares), state.bobValue, "Bob is not diluted");
        assertEq(
            marketAfter.totalSupplyAssets - marketAfter.totalBorrowAssets,
            state.availableLiquidity,
            "targeted settlement preserves free liquidity"
        );
        assertGt(collateralSeized, 0, "collateral seized");
        assertGt(debtCanceled, 0, "debt canceled");
        assertLt(borrowerDebtSharesAfter, state.borrowerDebtShares, "borrower debt reduced");
        assertGt(borrowerDebtSharesAfter, 0, "unaffordable full close remains partial");
    }

    /// @dev The risk queue keys each borrower by borrow-shares-per-collateral and surfaces the riskiest as
    ///      the root. Both borrowers draw the same 80 in the same block (equal shares), so with half the
    ///      collateral `risky`'s key is exactly twice `safe`'s — and `risky` is the root.
    function test_settlementQueue_rootIsTheRiskiest() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);

        address safe = _actor("safe"); // shares / 800
        address risky = _actor("risky"); // shares / 400  -> 2x the key
        _fund(m.collateralToken, safe, 800 ether);
        m.supplyCollateral(safe, 800 ether);
        _fund(m.collateralToken, risky, 400 ether);
        m.supplyCollateral(risky, 400 ether);
        m.activateCollateral();
        m.borrow(safe, BORROW);
        m.borrow(risky, BORROW);

        // Both are enqueued by the Borrow hook (upsert), and the keys are exactly 2:1.
        (address[] memory bs, uint256[] memory keys) = m.controller.settlementBorrowers(0, 10);
        assertEq(bs.length, 2, "both borrowers enqueued by the Borrow hook");
        uint256 riskyKey;
        uint256 safeKey;
        for (uint256 i; i < bs.length; i++) {
            if (bs[i] == risky) riskyKey = keys[i];
            if (bs[i] == safe) safeKey = keys[i];
        }
        assertEq(riskyKey, 2 * safeKey, "risky key == 2x safe (equal shares, half the collateral)");

        (address root,,,) = m.controller.nextSettlementBorrower();
        assertEq(root, risky, "queue root == riskiest (highest shares/collateral)");
    }

    function _singleton(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
