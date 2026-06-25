// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @dev Verifies WHERE `coreLoanBalance - idle` dust originates (the 1-wei the invariant caught). Logs the
///      gap after each op so the mechanism is observed, not assumed.
contract RoundingDustTest is LidoLendSetup {
    address internal constant LP = address(0x9001);
    address internal constant B1 = address(0x9002);
    address internal constant B2 = address(0x9003);

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 coll = new MockERC20("Coll", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(coll), address(coll)));
        Market storage m = protocol.markets[0];
        m.controller.grantInstantActivation(B1);
        m.controller.grantInstantActivation(B2);
    }

    function _gap(string memory label) internal returns (uint256 dust) {
        Market storage m = protocol.markets[0];
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 idle = mk.totalSupplyAssets - mk.totalBorrowAssets;
        uint256 bal = m.loanToken.balanceOf(address(m.core));
        dust = bal - idle; // assertGe-safe direction
        emit log_named_uint(string.concat(label, " dust(bal-idle)"), dust);
        emit log_named_uint(string.concat(label, " totalBorrowAssets"), mk.totalBorrowAssets);
    }

    function _supplyCollateralAndBorrow(address who, uint256 collat, uint256 borrowAmt) internal {
        Market storage m = protocol.markets[0];
        _fund(m.collateralToken, who, collat);
        vm.startPrank(who);
        m.collateralToken.approve(address(m.core), collat);
        m.core.supplyCollateral(m.params, collat, who, "");
        m.core.borrow(m.params, borrowAmt, 0, who, who);
        vm.stopPrank();
    }

    function _repayShares(address who, uint256 shares) internal {
        Market storage m = protocol.markets[0];
        MorphoMarket memory mk = m.core.market(m.id);
        uint256 owed = shares * mk.totalBorrowAssets / mk.totalBorrowShares + 2;
        _fund(m.loanToken, who, owed);
        vm.startPrank(who);
        m.loanToken.approve(address(m.core), owed);
        m.core.repay(m.params, 0, shares, who, "");
        vm.stopPrank();
    }

    function test_traceDustOrigin() public {
        Market storage m = protocol.markets[0];

        _fund(m.loanToken, LP, 1000 ether);
        vm.startPrank(LP);
        m.loanToken.approve(address(m.vault), 1000 ether);
        m.vault.deposit(1000 ether, LP);
        vm.stopPrank();
        _gap("after supply  ");

        _supplyCollateralAndBorrow(B1, 100 ether, 40 ether);
        _gap("after borrow1 ");
        _supplyCollateralAndBorrow(B2, 100 ether, 30 ether);
        _gap("after borrow2 ");

        vm.warp(block.timestamp + 365 days);
        m.core.accrueInterest(m.params);
        _gap("after accrue  ");

        // B1 repays a FRACTION of its shares (toAssetsUp on a partial slice)
        _repayShares(B1, m.core.position(m.id, B1).borrowShares / 3);
        _gap("after partial ");

        // B1 repays the REST (last chunk -> exact, no clamp)
        _repayShares(B1, m.core.position(m.id, B1).borrowShares);
        _gap("after B1 full ");

        // B2 repays ALL -> now totalBorrow approaches 0; rounding-up vs clamp is most likely here
        _repayShares(B2, m.core.position(m.id, B2).borrowShares);
        uint256 finalDust = _gap("after B2 full ");

        // The property the invariant relies on: the core never holds LESS than idle.
        assertGe(finalDust, 0, "core balance >= idle (dust is non-negative)");
    }

    /// @dev The other suspect: bad-debt liquidation (seize-all → socialization). Trace the gap across it.
    function test_traceDustFromLiquidation() public {
        Market storage m = protocol.markets[0];

        _fund(m.loanToken, LP, 1000 ether);
        vm.startPrank(LP);
        m.loanToken.approve(address(m.vault), 1000 ether);
        m.vault.deposit(1000 ether, LP);
        vm.stopPrank();

        uint256 maxBorrow = 100 ether * oraclePrice / 1e36 * 80 / 100;
        _supplyCollateralAndBorrow(B1, 100 ether, maxBorrow * 99 / 100);
        _gap("before crash  ");

        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice / 2); // underwater -> bad debt on full seize
        m.core.accrueInterest(m.params);
        _gap("after crash   ");

        address keeper = address(0x9009);
        _fund(m.loanToken, keeper, type(uint128).max);
        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        m.core.liquidate(m.params, B1, 100 ether, 0, ""); // seize ALL -> realize bad debt
        vm.stopPrank();
        uint256 dust = _gap("after liq     ");
        emit log_named_uint("FINAL DUST (liquidation)", dust);
        assertGe(dust, 0);
    }

    /// @dev Partial liquidation (unhealthy-but-solvent) — the liquidation-incentive rounding is the last suspect.
    function test_traceDustFromPartialLiquidation() public {
        Market storage m = protocol.markets[0];

        _fund(m.loanToken, LP, 1000 ether);
        vm.startPrank(LP);
        m.loanToken.approve(address(m.vault), 1000 ether);
        m.vault.deposit(1000 ether, LP);
        vm.stopPrank();

        uint256 maxBorrow = 100 ether * oraclePrice / 1e36 * 80 / 100;
        _supplyCollateralAndBorrow(B1, 100 ether, maxBorrow * 80 / 100); // 80% of max
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 70 / 100); // unhealthy, still solvent
        m.core.accrueInterest(m.params);
        _gap("before partial");

        address keeper = address(0x9009);
        _fund(m.loanToken, keeper, type(uint128).max);
        vm.startPrank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        m.core.liquidate(m.params, B1, 7 ether, 0, ""); // partial seize: 7 collateral
        vm.stopPrank();
        uint256 dust = _gap("after partial ");
        emit log_named_uint("FINAL DUST (partial liq)", dust);
        assertGe(dust, 0);
    }
}
