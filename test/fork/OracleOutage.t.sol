// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

/// @notice The deployed market during an outage of its oracle's price source: every priced action fails with the
///         source's own error, bubbled unchanged; unpriced actions (supplying and withdrawing liquidity, repaying,
///         topping up collateral, a debt-free exit, a fallback exit inside free liquidity) keep working; and the
///         halt ends with the outage.
abstract contract OracleOutageForkBase is ForkMarketStack {
    using MarketActions for Market;

    address internal FREE_HOLDER;
    address internal KEEPER;

    constructor(string memory role) ForkMarketStack(role) {}

    function setUp() public {
        _fork();
        _bindRole();
        _seedLenderAndBorrower();
        market.setSettlementLtv(BORROWER, 0.05e18);

        FREE_HOLDER = _freshActor(deployed, "outage.freeHolder");
        deal(address(deployed.collateralToken), FREE_HOLDER, lot);
        market.supplyCollateral(FREE_HOLDER, lot);

        KEEPER = _freshActor(deployed, "outage.keeper");
        deal(address(deployed.loanToken), KEEPER, 2 * _maxBorrow(deployed, lot, deployed.oracle.price()));
        _approve(address(deployed.loanToken), KEEPER, address(deployed.core), type(uint256).max);
    }

    // ---
    // PRICED ACTIONS HALT
    // ---

    function testRevert_oracleDown_borrow() public {
        bytes memory err = _mockOracleRevert(deployed);
        vm.prank(BORROWER);
        vm.expectRevert(err);
        deployed.core.borrow(deployed.params, 1, 0, BORROWER, BORROWER);
    }

    function testRevert_oracleDown_debtBearingWithdrawCollateral() public {
        bytes memory err = _mockOracleRevert(deployed);
        vm.prank(BORROWER);
        vm.expectRevert(err);
        deployed.core.withdrawCollateral(deployed.params, 1, BORROWER, BORROWER);
    }

    function testRevert_oracleDown_liquidate() public {
        bytes memory err = _mockOracleRevert(deployed);
        uint256 seize = lot / 10;
        vm.prank(KEEPER);
        vm.expectRevert(err);
        deployed.core.liquidate(deployed.params, BORROWER, seize, 0, "");
    }

    function testRevert_oracleDown_vaultSettle() public {
        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        uint256 shares = lenderShares / 2;
        bytes memory err = _mockOracleRevert(deployed);
        vm.prank(LENDER);
        vm.expectRevert(err);
        deployed.vault.settle(shares, borrowers, LENDER, LENDER);
    }

    /// @dev Pinned below the request BEFORE the outage, so the exit must reach the settle leg, which prices
    ///      collateral; a later resize cannot make this vacuous by letting liquidity cover the whole request.
    function testRevert_oracleDown_fallbackExitBeyondLiquidity() public {
        _pinFreeLiquidity(deployed, Erc4626Math.toAssets(deployed.vault, lenderShares, Math.Rounding.Floor) / 2);
        assertGt(
            deployed.vault.previewRedeem(lenderShares),
            _freeLiquidity(deployed),
            "setup: the exit outgrows free liquidity"
        );

        bytes memory err = _mockOracleRevert(deployed);
        vm.prank(LENDER);
        vm.expectRevert(err);
        deployed.vault.fallbackExit(lenderShares, LENDER, LENDER, 0);
    }

    // ---
    // UNPRICED ACTIONS RUN
    // ---

    function test_oracleDown_vaultDepositAndWithdrawWithinLiquidity() public {
        _mockOracleRevert(deployed);
        uint256 topUp = _loanUnit(deployed);
        deal(address(deployed.loanToken), LENDER, topUp);
        market.vaultDeposit(LENDER, topUp);
        market.vaultWithdraw(LENDER, topUp);
    }

    function test_oracleDown_coreSupplyAndWithdraw() public {
        _mockOracleRevert(deployed);
        uint256 assets = _loanUnit(deployed);
        deal(address(deployed.loanToken), KEEPER, assets);
        market.coreSupply(KEEPER, assets);
        market.coreWithdraw(KEEPER, assets);
    }

    function test_oracleDown_repay() public {
        deal(address(deployed.loanToken), BORROWER, market.repayAssets(borrowShares / 2));
        _mockOracleRevert(deployed);
        market.repay(BORROWER, borrowShares / 2);
    }

    /// @dev Raw core calls: the `MarketActions` collateral helpers read `positionOf`, which is itself priced.
    function test_oracleDown_supplyCollateral() public {
        deal(address(deployed.collateralToken), BORROWER, lot);
        _approve(address(deployed.collateralToken), BORROWER, address(deployed.core), lot);
        uint128 before = deployed.core.position(deployed.id, BORROWER).collateral;
        _mockOracleRevert(deployed);

        vm.prank(BORROWER);
        deployed.core.supplyCollateral(deployed.params, lot, BORROWER, "");
        assertEq(
            deployed.core.position(deployed.id, BORROWER).collateral, before + lot, "collateral booked without a price"
        );
    }

    function test_oracleDown_debtFreeWithdrawCollateral() public {
        _mockOracleRevert(deployed);
        vm.prank(FREE_HOLDER);
        deployed.core.withdrawCollateral(deployed.params, lot, FREE_HOLDER, FREE_HOLDER);
        assertEq(deployed.collateralToken.balanceOf(FREE_HOLDER), lot, "debt-free holder took collateral back");
    }

    function test_oracleDown_fallbackExitWithinLiquidity_liquidLegOnly() public {
        _mockOracleRevert(deployed);
        market.fallbackExitLiquid(LENDER, lenderShares / 4, LENDER);
    }

    // ---
    // RECOVERY
    // ---

    function test_oracleRestored_borrowWorksAgain() public {
        _mockOracleRevert(deployed);
        vm.clearMockedCalls();
        market.borrow(BORROWER, _loanUnit(deployed) / 10);
    }
}

contract OracleOutageWethWstethForkTest is OracleOutageForkBase("weth-wsteth") {}

contract OracleOutageUsdyUsdtForkTest is OracleOutageForkBase("usdy-usdt") {}
