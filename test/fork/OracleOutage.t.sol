// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice The deployed market during an outage of its oracle's price source: every priced action fails with the
///         source's own error, bubbled unchanged; unpriced actions (supplying and withdrawing liquidity, repaying,
///         topping up collateral, a debt-free exit, a fallback exit inside free liquidity) keep working; and the
///         halt ends with the outage.
contract OracleOutageForkTest is ForkStack {
    using MarketActions for Market;

    /// @dev The revert of the downed source, which priced paths bubble.
    error OracleDown();

    address internal FREE_HOLDER;
    address internal KEEPER;

    function setUp() public {
        _onlyOnOneMarketPerKind();
        _setUpTarget();
        _seedLenderAndBorrower();
        market.setSettlementLtv(BORROWER, 0.05e18);

        FREE_HOLDER = _freshActor(market, "outage.freeHolder");
        collateralIssuer.dealCollateral(FREE_HOLDER, lot);
        market.supplyCollateral(FREE_HOLDER, lot);

        KEEPER = _freshActor(market, "outage.keeper");
        deal(address(market.loanToken), KEEPER, 2 * _maxBorrow(market, lot, market.oracle.price()));
        _approve(address(market.loanToken), KEEPER, address(market.core), type(uint256).max);
    }

    /// @dev The oracle's price source reverts; returns the revert that priced paths now bubble.
    function _revertOracleSource() private returns (bytes memory err) {
        err = abi.encodeWithSelector(OracleDown.selector);
        collateralIssuer.revertOracleSource(err);
    }

    // ---
    // PRICED ACTIONS HALT
    // ---

    function testRevert_oracleDown_borrow() public {
        bytes memory err = _revertOracleSource();
        vm.prank(BORROWER);
        vm.expectRevert(err);
        market.core.borrow(market.params, 1, 0, BORROWER, BORROWER);
    }

    function testRevert_oracleDown_debtBearingWithdrawCollateral() public {
        bytes memory err = _revertOracleSource();
        vm.prank(BORROWER);
        vm.expectRevert(err);
        market.core.withdrawCollateral(market.params, 1, BORROWER, BORROWER);
    }

    function testRevert_oracleDown_liquidate() public {
        bytes memory err = _revertOracleSource();
        uint256 seize = lot / 10;
        vm.prank(KEEPER);
        vm.expectRevert(err);
        market.core.liquidate(market.params, BORROWER, seize, 0, "");
    }

    function testRevert_oracleDown_vaultSettle() public {
        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        uint256 shares = lenderShares / 2;
        bytes memory err = _revertOracleSource();
        vm.prank(LENDER);
        vm.expectRevert(err);
        market.vault.settle(shares, borrowers, LENDER, LENDER);
    }

    /// @dev Pinned below the request BEFORE the outage, so the exit must reach the settle leg, which prices
    ///      collateral; a later resize cannot make this vacuous by letting liquidity cover the whole request.
    function testRevert_oracleDown_fallbackExitBeyondLiquidity() public {
        _setFreeLiquidity(Erc4626Math.toAssets(market.vault, lenderShares, Math.Rounding.Floor) / 2);
        assertGt(market.vault.previewRedeem(lenderShares), _freeLiquidity(), "setup: the exit outgrows free liquidity");

        bytes memory err = _revertOracleSource();
        vm.prank(LENDER);
        vm.expectRevert(err);
        market.vault.fallbackExit(lenderShares, LENDER, LENDER, 0);
    }

    // ---
    // UNPRICED ACTIONS RUN
    // ---

    function test_oracleDown_vaultDepositAndWithdrawWithinLiquidity() public {
        _revertOracleSource();
        uint256 topUp = _oneLoanToken();
        deal(address(market.loanToken), LENDER, topUp);
        market.vaultDeposit(LENDER, topUp);
        market.vaultWithdraw(LENDER, topUp);
    }

    function test_oracleDown_coreSupplyAndWithdraw() public {
        _revertOracleSource();
        uint256 assets = _oneLoanToken();
        deal(address(market.loanToken), KEEPER, assets);
        uint256 shares = market.coreSupply(KEEPER, assets);
        market.coreWithdraw(KEEPER, shares);
    }

    function test_oracleDown_repay() public {
        deal(address(market.loanToken), BORROWER, market.repayAssets(borrowShares / 2));
        _revertOracleSource();
        market.repay(BORROWER, borrowShares / 2);
    }

    /// @dev Raw core calls: the `MarketActions` collateral helpers read `positionOf`, which is itself priced.
    function test_oracleDown_supplyCollateral() public {
        collateralIssuer.dealCollateral(BORROWER, lot);
        _approve(address(market.collateralToken), BORROWER, address(market.core), lot);
        uint128 before = market.core.position(market.id, BORROWER).collateral;
        _revertOracleSource();

        vm.prank(BORROWER);
        market.core.supplyCollateral(market.params, lot, BORROWER, "");
        assertEq(
            market.core.position(market.id, BORROWER).collateral, before + lot, "collateral booked without a price"
        );
    }

    function test_oracleDown_debtFreeWithdrawCollateral() public {
        _revertOracleSource();
        vm.prank(FREE_HOLDER);
        market.core.withdrawCollateral(market.params, lot, FREE_HOLDER, FREE_HOLDER);
        assertEq(market.collateralToken.balanceOf(FREE_HOLDER), lot, "debt-free holder took collateral back");
    }

    function test_oracleDown_fallbackExitWithinLiquidity_liquidLegOnly() public {
        _revertOracleSource();
        market.fallbackExitLiquid(LENDER, lenderShares / 4, LENDER);
    }

    // ---
    // RECOVERY
    // ---

    function test_oracleRestored_borrowWorksAgain() public {
        _revertOracleSource();
        vm.clearMockedCalls(); // the source prices again
        market.borrow(BORROWER, _oneLoanToken() / 10);
    }
}
