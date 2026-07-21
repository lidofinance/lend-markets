// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice L2 settlement scenarios: a lender exits when ordinary liquidity is short. `fallbackExit` first
///         redeems whatever ordinary liquidity (idle + withdrawable) covers, then settles the remainder
///         against the controller's risk queue — seizing borrower collateral and cancelling debt. `settle`
///         is the liquidity-neutral targeted variant. Magnitudes are recomputed exactly: the ordinary leg
///         equals the idle liquidity, the seized collateral equals the cancelled debt valued at the oracle
///         price, and the targeted cut equals the controller's `settlementFor` prediction.
contract SettlementTest is LidoLendSetup {
    using MarketActions for Market;

    // 400 collateral keeps an 80 borrow within LLTV-max even at the lowest seeded price (400*0.24 = 96 > 80).
    uint256 internal constant COLLAT = 400 ether;
    uint256 internal constant BORROW = 80 ether;

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
        Market storage m = _m();
        _fund(m.loanToken, lender, 100 ether);
        shares = m.vaultDeposit(lender, 100 ether);
        _fund(m.collateralToken, borrower, COLLAT);
        m.supplyCollateral(borrower, COLLAT);
        m.activateCollateral();
        m.borrow(borrower, BORROW);
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
}
