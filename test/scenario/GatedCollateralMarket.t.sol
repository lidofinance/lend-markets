// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @dev Transfer-gated collateral (USDY/treasuries style): any transfer TO a blocked address reverts. Models
///      an allowlisted RWA token where the protocol must fail cleanly when collateral would move to a
///      blocked recipient (a seizing keeper or a fallback-exit receiver), never strand or mis-credit it.
contract GatedCollateral is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Gated Collateral", "gCOLL", 18) {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "transfer reverted");
        super._update(from, to, value);
    }
}

/// @notice L2 scenario for a market with TRANSFER-GATED collateral (the USDY case the per-method
///         suites never reach). The borrower posts gated collateral and goes unhealthy; the gate must reject
///         a liquidation seizing to a blocked keeper and a fallbackExit seizing to a blocked receiver, while
///         allowlisted recipients are serviced normally.
contract GatedCollateralMarketTest is LidoLendSetup {
    using MarketActions for Market;

    GatedCollateral internal gated;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        gated = new GatedCollateral();
        _deployProtocol(_defaultConfig(address(loan), address(gated), address(gated)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender liquidity + a borrower at ~99% LLTV on gated collateral, then a -10% crash → unhealthy
    ///      (but solvent, so liquidation is clean).
    function _seedUnhealthy() internal returns (address borrower) {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        uint256 maxBorrow = 100 ether * oraclePrice / 1e36 * 80 / 100;
        m.borrow(borrower, maxBorrow * 99 / 100);
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 9 / 10);
    }

    /// @dev Liquidating into a keeper the gated collateral blocks reverts on the seized-collateral transfer.
    function testRevert_liquidate_seizeToBlockedKeeper() public {
        Market storage m = _m();
        address borrower = _seedUnhealthy();

        address keeper = _actor("keeper");
        gated.setBlocked(keeper, true); // collateral cannot move to this keeper
        _fund(m.loanToken, keeper, 1000 ether);
        vm.prank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);

        vm.prank(keeper);
        vm.expectRevert("transfer reverted"); // the seized-collateral transfer to the blocked keeper reverts
        m.core.liquidate(m.params, borrower, 10 ether, 0, "");
    }

    /// @dev An allowlisted keeper liquidates and receives exactly the seized gated collateral.
    function test_liquidate_toAllowlistedKeeper_succeeds() public {
        Market storage m = _m();
        address borrower = _seedUnhealthy();

        address keeper = _actor("keeper"); // not blocked
        _fund(m.loanToken, keeper, 1000 ether);
        (uint256 seized,) = m.liquidate(keeper, borrower, 10 ether, 0);

        assertEq(seized, 10 ether, "allowlisted keeper seizes the gated collateral");
        assertEq(gated.balanceOf(keeper), seized, "keeper received the seized collateral");
    }

    /// @dev A fallbackExit whose settle leg would move gated collateral to a blocked receiver reverts on transfer.
    function testRevert_fallbackExit_seizeToBlockedReceiver() public {
        Market storage m = _m();
        address lender = _actor("lender2");
        _fund(m.loanToken, lender, 100 ether);
        uint256 shares = m.vaultDeposit(lender, 100 ether);

        // A borrower draws most of the new liquidity so the lender's exit needs the settle leg (seizing
        // gated collateral).
        address borrower = _actor("borrower2");
        _fund(m.collateralToken, borrower, 400 ether);
        m.supplyCollateral(borrower, 400 ether);
        m.activateCollateral();
        m.borrow(borrower, 80 ether);

        address receiver = _actor("receiver");
        gated.setBlocked(receiver, true); // gated collateral cannot land on this receiver

        vm.prank(lender);
        vm.expectRevert("transfer reverted"); // the settle leg's collateral transfer to the receiver reverts
        m.vault.fallbackExit(shares, receiver, lender, 0);
    }

    /// @dev A fallbackExit to an allowlisted receiver engages the settle leg and delivers exactly the seized
    /// collateral.
    function test_fallbackExit_toAllowlistedReceiver_seizesCollateral() public {
        Market storage m = _m();
        address lender = _actor("lender3");
        _fund(m.loanToken, lender, 100 ether);
        uint256 shares = m.vaultDeposit(lender, 100 ether);

        address borrower = _actor("borrower3");
        _fund(m.collateralToken, borrower, 400 ether);
        m.supplyCollateral(borrower, 400 ether);
        m.activateCollateral();
        m.borrow(borrower, 80 ether); // drain most liquidity -> exit needs the settle leg

        address receiver = _actor("receiver3"); // not blocked
        uint256 balBefore = gated.balanceOf(receiver);
        vm.prank(lender);
        (,, uint256 collateralSeized,) = m.vault.fallbackExit(shares, receiver, lender, 0);

        assertGt(collateralSeized, 0, "settle leg engaged (not a pure idle redeem)");
        assertEq(
            gated.balanceOf(receiver) - balBefore,
            collateralSeized,
            "allowlisted receiver got exactly the seized collateral"
        );
    }
}
