// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "../../../../src/libs/Constants.sol";
import {Market} from "../../../setup/Types.sol";
import {MarketActions} from "../../../setup/MarketActions.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @dev Ondo's USDY: its transfer blocklist.
interface IUsdy {
    function blocklist() external view returns (address);
}

interface IUsdyBlocklist {
    function owner() external view returns (address);
    function addToBlocklist(address[] calldata accounts) external;
    function isBlocked(address account) external view returns (bool);
}

/// @notice A market whose collateral is Ondo's USDY, whatever its oracle: USDY's blocklist means a blocklisted
///         address cannot receive seized collateral, so it can neither liquidate (core `liquidate`) nor be a
///         fallback-exit receiver (vault `fallbackExit` -> settle), while an eligible address can. Nor can a
///         blocklisted borrower post collateral, or anyone withdraw collateral to a blocklisted receiver; a borrower
///         blocklisted after it borrows can still be liquidated. On every market whose collateral has a USDY
///         blocklist.
///
///         State-robustness (a deployed market may already carry supply and borrow): actors are fresh and
///         market-clean, so balance checks are deltas; the borrow is sized off the live price and dust threshold;
///         the crash is derived from the live position, so the borrower lands at an exact LTV whatever the NAV;
///         idle is pinned to a known target; the settle leg requires the test borrower at the queue root and no bad
///         debt.
contract UsdyForkTest is ForkStack {
    using MarketActions for Market;

    address internal USDY;
    address internal LOAN;
    address internal USDY_BLOCKLIST;

    address internal KEEPER_GOOD; // eligible (not blocklisted)
    address internal KEEPER_BAD; // will be blocklisted

    /// @dev Opening (healthy) LTV for the test borrower, below the live LLTV.
    uint256 internal constant OPEN_LTV = 0.7e18;
    /// @dev Crash target for the liquidate test: underwater, so the position is liquidatable at any NAV.
    uint256 internal constant CRASH_LTV_LIQUIDATE = 1.4e18;

    function setUp() public {
        _setUpTarget();
        (bool ok, bytes memory returned) =
            address(market.collateralToken).staticcall(abi.encodeCall(IUsdy.blocklist, ()));
        if (!ok || returned.length != 32) vm.skip(true, "Usdy: the collateral has no USDY blocklist");
        USDY_BLOCKLIST = abi.decode(returned, (address));

        _accrueInterest();
        USDY = address(market.collateralToken);
        LOAN = address(market.loanToken);
        require(OPEN_LTV < market.params.lltv, "Usdy: OPEN_LTV must open healthy below the live LLTV");

        LENDER = _freshActor(market, "usdy.lender");
        BORROWER = _freshActor(market, "usdy.borrower");
        KEEPER_GOOD = _freshActor(market, "usdy.keeperEligible");
        KEEPER_BAD = _freshActor(market, "usdy.keeperBlocklisted");
    }

    /// @dev What the borrower draws: `lot` of USDY at `OPEN_LTV` of its live value.
    function _borrowAssets() internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(lot, market.oracle.price(), ORACLE_PRICE_SCALE), OPEN_LTV, WAD);
    }

    /// @dev Crash target for the settle test: halfway between the live LLTV and 1, unhealthy but solvent.
    function _settleLtv() internal view returns (uint256) {
        return (market.params.lltv + WAD) / 2;
    }

    /// @dev The borrower posts `lot` of USDY, waits out the live activation delay and borrows `borrowAssets`.
    function _openBorrow(uint256 borrowAssets) internal {
        collateralIssuer.dealCollateral(BORROWER, lot);
        _approve(USDY, BORROWER, address(market.core), type(uint256).max);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, lot, BORROWER, "");

        _warpPastActivation();
        vm.prank(BORROWER);
        market.core.borrow(market.params, borrowAssets, 0, BORROWER, BORROWER);
    }

    /// @dev Blocklist `account` on USDY by pranking the blocklist's owner.
    function _blocklist(address account) internal {
        IUsdyBlocklist bl = IUsdyBlocklist(USDY_BLOCKLIST);
        address[] memory accounts = new address[](1);
        accounts[0] = account;
        vm.prank(bl.owner());
        bl.addToBlocklist(accounts);
        assertTrue(bl.isBlocked(account), "account blocklisted on USDY");
    }

    /// @dev The lender supplies `assets` straight to the core.
    function _supplyLiquidity(uint256 assets) internal {
        _requireSupplyHeadroom(market, assets);
        deal(LOAN, LENDER, assets);
        _approve(LOAN, LENDER, address(market.core), type(uint256).max);
        vm.prank(LENDER);
        market.core.supply(market.params, assets, 0, LENDER, "");
    }

    function test_liquidate_blocklistedCannot_allowlistedCan() public {
        uint256 borrowAssets = _borrowAssets();
        _supplyLiquidity(2 * borrowAssets);
        _openBorrow(borrowAssets);
        uint256 price = _setPriceForLtv(BORROWER, CRASH_LTV_LIQUIDATE);

        // Unhealthy and underwater at the crashed price, so `liquidate` is enabled at any live NAV.
        uint256 rawCollateral = market.core.position(market.id, BORROWER).collateral;
        uint256 debtAssets = market.controller.positionOf(BORROWER).debtAssets;
        assertGt(debtAssets, _maxBorrow(market, rawCollateral, price), "borrower unhealthy at the crashed price");
        assertGt(debtAssets, Math.mulDiv(rawCollateral, price, ORACLE_PRICE_SCALE), "borrower underwater");

        deal(LOAN, KEEPER_GOOD, borrowAssets);
        deal(LOAN, KEEPER_BAD, borrowAssets);
        _approve(LOAN, KEEPER_GOOD, address(market.core), type(uint256).max);
        _approve(LOAN, KEEPER_BAD, address(market.core), type(uint256).max);
        _blocklist(KEEPER_BAD);

        uint256 seize = rawCollateral / 10;
        require(seize != 0 && seize < rawCollateral, "seize sized within the borrower's collateral");

        // The seized-collateral transfer to the blocklisted keeper reverts, wrapped by the core's SafeTransferLib.
        vm.prank(KEEPER_BAD);
        vm.expectRevert("transfer reverted");
        market.core.liquidate(market.params, BORROWER, seize, 0, "");

        uint256 balBefore = IERC20(USDY).balanceOf(KEEPER_GOOD);
        vm.prank(KEEPER_GOOD);
        (uint256 seized,) = market.core.liquidate(market.params, BORROWER, seize, 0, "");
        assertEq(seized, seize, "seized the requested amount");
        assertEq(IERC20(USDY).balanceOf(KEEPER_GOOD) - balBefore, seize, "eligible keeper received the seized USDY");
    }

    function test_fallbackExit_blocklistedReceiverCannot_allowlistedCan() public {
        uint256 borrowAssets = _borrowAssets();
        uint256 deposit = borrowAssets * 12 / 11;
        _requireSupplyHeadroom(market, deposit);
        deal(LOAN, LENDER, deposit);
        _approve(LOAN, LENDER, address(market.vault), type(uint256).max);
        vm.prank(LENDER);
        market.vault.deposit(deposit, LENDER);

        // Idle pinned low, so an ordinary withdrawal cannot satisfy the exit and the settle leg engages. The pin
        // borrower is over-collateralized, so it stays healthy through the crash and never outranks BORROWER.
        _openBorrow(borrowAssets);
        _setFreeLiquidity(borrowAssets / 14);

        uint256 price = _setPriceForLtv(BORROWER, _settleLtv());

        // Unhealthy yet solvent at the crashed price, so BORROWER is settle-eligible at any live NAV.
        uint256 rawCollateral = market.core.position(market.id, BORROWER).collateral;
        uint256 debtAssets = market.controller.positionOf(BORROWER).debtAssets;
        assertGt(debtAssets, _maxBorrow(market, rawCollateral, price), "borrower unhealthy at the crashed price");
        assertGt(Math.mulDiv(rawCollateral, price, ORACLE_PRICE_SCALE), debtAssets, "borrower solvent");

        (address root,) = market.controller.nextSettlementBorrower(0);
        require(root == BORROWER, "Usdy: a pre-existing riskier borrower outranks the test borrower");
        require(!market.controller.hasBadDebt(), "Usdy: unexpected bad debt blocks the settle leg");

        _blocklist(KEEPER_BAD);

        uint256 shares = market.vault.balanceOf(LENDER) / 2; // more than the pinned idle covers

        vm.prank(LENDER);
        vm.expectRevert("transfer reverted");
        market.vault.fallbackExit(shares, KEEPER_BAD, LENDER, 0);

        uint256 balBefore = IERC20(USDY).balanceOf(KEEPER_GOOD);
        vm.prank(LENDER);
        (,, uint256 collateralSeized, uint256 debtCanceled) = market.vault.fallbackExit(shares, KEEPER_GOOD, LENDER, 0);
        assertGt(collateralSeized, 0, "collateral seized via the settle leg");
        // Settle seizes `debtCanceled` at par, `debtCanceled * ORACLE_PRICE_SCALE / price`; the exit may cut the
        // borrower across several iterations, so allow the summed per-cut floor rounding.
        assertApproxEqAbs(
            collateralSeized,
            Math.mulDiv(debtCanceled, ORACLE_PRICE_SCALE, price),
            1e4,
            "collateral seized matches debt canceled at the crashed price"
        );
        assertEq(IERC20(USDY).balanceOf(KEEPER_GOOD) - balBefore, collateralSeized, "eligible receiver got the USDY");
    }

    /// @dev A blocklisted borrower cannot post its USDY: the core cannot pull it.
    function testRevert_supplyCollateral_fromABlocklistedBorrower() public {
        collateralIssuer.dealCollateral(BORROWER, lot);
        _approve(USDY, BORROWER, address(market.core), lot);
        _blocklist(BORROWER);
        vm.prank(BORROWER);
        vm.expectRevert(bytes("transferFrom reverted"));
        market.core.supplyCollateral(market.params, lot, BORROWER, "");
    }

    /// @dev A borrower cannot withdraw its USDY to a blocklisted receiver, and can to itself.
    function testRevert_withdrawCollateral_toABlocklistedReceiver() public {
        collateralIssuer.dealCollateral(BORROWER, lot);
        _approve(USDY, BORROWER, address(market.core), lot);
        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, lot, BORROWER, "");
        _blocklist(KEEPER_BAD);

        vm.prank(BORROWER);
        vm.expectRevert(bytes("transfer reverted"));
        market.core.withdrawCollateral(market.params, lot, BORROWER, KEEPER_BAD);

        vm.prank(BORROWER);
        market.core.withdrawCollateral(market.params, lot, BORROWER, BORROWER);
        assertEq(IERC20(USDY).balanceOf(BORROWER), lot, "the borrower got its USDY back");
    }

    /// @dev A borrower blocklisted after it borrows can still be liquidated: the seized USDY goes from the core to the
    ///      keeper, not through the borrower.
    function test_liquidate_aBorrowerBlocklistedAfterBorrowing() public {
        uint256 borrowAssets = _borrowAssets();
        _supplyLiquidity(2 * borrowAssets);
        _openBorrow(borrowAssets);
        _blocklist(BORROWER);
        _setPriceForLtv(BORROWER, _settleLtv());

        uint256 shares = market.core.position(market.id, BORROWER).borrowShares / 4;
        deal(LOAN, KEEPER_GOOD, market.repayAssets(shares));
        (uint256 seized,) = market.liquidate(KEEPER_GOOD, BORROWER, 0, shares);
        assertGt(seized, 0, "the keeper seized the blocklisted borrower's USDY");
    }
}
