// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";
import {IWstETH} from "./helpers/ForkTokens.sol";

/// @notice Mainnet-fork scenario for the `weth-wsteth` market against the REAL mainnet wstETH, run on the
///         ALREADY-DEPLOYED stack (bound via {ForkMarketStack}, never re-deployed). Unlike the freshly-deployed
///         variant it once was, both the oracle under test and the market it prices are the production
///         instances: the deployed `WstEthRateOracle` proxy and the real WETH/wstETH tokens.
///
///         The two scenarios still read like the deployed variant did — deposit → supply collateral →
///         activate → borrow — because the {MarketActions} helper library drives the `Market` the binding
///         populates. State-robustness: fresh, market-clean actors; deposit gated by live supply headroom;
///         collateral sized off the live dust threshold; per-actor (delta) assertions, never absolute market
///         totals.
contract EthStethForkTest is ForkMarketStack("weth-wsteth") {
    using MarketActions for Market;

    /// @dev The market's real collateral token == mainnet wstETH, and the same wstETH the deployed oracle
    ///      prices — so `IWstETH(WSTETH)` queries hit the exact source `market.oracle.price()` reads.
    address internal WSTETH;

    uint256 internal constant LENDER_DEPOSIT = 20 ether;

    function setUp() public {
        _fork();
        _bindRole();
        WSTETH = address(deployed.collateralToken);
    }

    /// @dev The deployed oracle proxy reads the real wstETH rate at full precision.
    function test_oracle_readsRealWstEthRate_atFullPrecision() public view {
        uint256 price = market.oracle.price();

        // The deployed oracle price IS the live wstETH→stETH rate queried at the 1e36 point — full precision.
        assertEq(price, IWstETH(WSTETH).getStETHByWstETH(1e36), "oracle price == live wstETH rate @1e36");

        // That 1e36 query is exactly why the oracle avoids `stEthPerToken() * 1e18`: it preserves the
        // low-order bits the naive scaling truncates. So it is at least as large, by under one ULP (1e18).
        uint256 naive = IWstETH(WSTETH).stEthPerToken() * 1e18;
        assertGe(price, naive, "1e36 query never below the truncated naive rate");
        assertLt(price - naive, 1e18, "precision gained over the naive rate is under one ULP");
    }

    /// @dev Borrowing against real matured wstETH collateral yields exactly the loan amount sized by the live
    ///      wstETH rate and the market's live LLTV.
    function test_borrowAgainstRealWstEthCollateral() public {
        // Lender supplies real WETH liquidity, gated by the live supply headroom. `deal` mints WETH directly;
        // vaultDeposit approves and deposits, asserting the exact share/totalAssets deltas.
        _requireSupplyHeadroom(deployed, LENDER_DEPOSIT);
        address lender = _freshActor(deployed, "ethStethFork.lender");
        deal(address(market.loanToken), lender, LENDER_DEPOSIT);
        market.vaultDeposit(lender, LENDER_DEPOSIT);

        // Borrower posts REAL wstETH collateral and matures it. Size the lot off the live dust threshold
        // (`minActivationAmount`) so it clears activation at any deployed configuration.
        address borrower = _freshActor(deployed, "ethStethFork.borrower");
        uint256 collateral = 2 * uint256(deployed.activation.minActivationAmount);
        deal(WSTETH, borrower, collateral);
        market.supplyCollateral(borrower, collateral);
        market.activateCollateral();

        // Max borrow is set by the LIVE wstETH rate and the market's live LLTV; borrow half, well clear of the
        // gate. The rate is unchanged by the activation warp (it reads stETH accounting, not the clock).
        uint256 rate = IWstETH(WSTETH).getStETHByWstETH(1e36);
        uint256 maxBorrow = collateral * rate / 1e36 * market.params.lltv / 1e18;
        uint256 borrowAmt = maxBorrow / 2;

        // Liquidity precondition (delta, not absolute): the lender's own deposit must cover the borrow, so the
        // scenario holds whatever pre-existing supply the deployed market already carries.
        require(LENDER_DEPOSIT >= borrowAmt, "EthStethFork: lender deposit below borrow amount");

        market.borrow(borrower, borrowAmt);

        assertEq(market.loanToken.balanceOf(borrower), borrowAmt, "borrowed WETH against real wstETH at the live rate");
    }
}
