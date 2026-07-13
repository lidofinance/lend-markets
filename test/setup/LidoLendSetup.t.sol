// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LidoLendSetup} from "./LidoLendSetup.sol";
import {IrmKind, Market} from "./Types.sol";
import {MarketActions} from "./MarketActions.sol";
import {MockERC20, MockPriceOracle} from "./Mocks.sol";

/// @notice Smoke test for the `LidoLendSetup` base: deploys a market over mock ERC-20s with `new` (no
///         getCode, no fork), checks the singleton/market structure, the proxy dual-fields, the seeded
///         non-parity oracle price, the config, the library action helpers, and config-driven IRM choice.
contract LidoLendSetupSmokeTest is LidoLendSetup {
    using MarketActions for Market;

    MockERC20 internal loan;
    MockERC20 internal collateral;

    function setUp() public {
        loan = new MockERC20("Loan", "LOAN", 18);
        collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    /// @dev A shared core/guardian singleton hosts exactly one market, and that market points back at the core.
    function test_structure_singletonsAndMarket() public {
        // Singletons.
        assertTrue(address(protocol.core) != address(0), "core singleton");
        assertTrue(address(protocol.guardianSignals) != address(0), "guardian singleton");
        assertTrue(protocol.coreProxy.proxy__getImplementation() != address(0), "core impl");
        // One market hosted on the core.
        assertEq(protocol.markets.length, 1, "one market");
        Market storage m = protocol.markets[0];
        assertEq(address(m.core), address(protocol.core), "market points at the singleton core");
        assertTrue(
            address(m.vault) != address(0) && address(m.controller) != address(0) && m.irm != address(0),
            "market contracts"
        );
    }

    /// @dev Each proxied market contract (vault/oracle/controller) exposes a live implementation behind its admin.
    function test_proxyDualFields() public {
        Market storage m = protocol.markets[0];
        assertTrue(m.vaultProxy.proxy__getImplementation() != address(0), "vault impl");
        assertTrue(m.oracleProxy.proxy__getImplementation() != address(0), "oracle impl");
        assertEq(m.controllerProxy.proxy__getImplementation(), m.controllerImpl, "controller impl matches");
    }

    /// @dev Protocol- and market-level config (loan token, lltv, oracle) reads back the values setup deployed with.
    function test_config_reachable() public {
        assertEq(protocol.config.loanToken, address(loan), "protocol.config");
        Market storage m = protocol.markets[0];
        assertEq(m.config.lltv, 0.8e18, "market.config.lltv");
        assertEq(m.params.oracle, address(m.oracle), "market.params.oracle");
    }

    /// @dev The oracle price is seeded to a non-1e36 value within the expected range and the oracle returns it exactly.
    function test_oraclePrice_isSeededNonParity() public view {
        assertTrue(seed != 0, "seed set");
        assertTrue(oraclePrice != 1e36, "oracle price must not be parity");
        assertEq(protocol.markets[0].oracle.price(), oraclePrice, "oracle returns the seeded price");
        assertGe(oraclePrice, 3e35, "price in seeded range (low)");
        assertLt(oraclePrice, 3e36, "price in seeded range (high)");
    }

    /// @dev The MarketActions helpers drive a full lender-deposit then supply/activate/borrow/repay/withdraw flow.
    function test_actionHelpers_lenderAndBorrowerFlow() public {
        Market storage m = protocol.markets[0];

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1_000 ether);
        m.vaultDeposit(lender, 1_000 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        uint256 shares = m.borrow(borrower, 10 ether); // safe vs LLTV at any seeded price

        _fund(m.loanToken, borrower, m.repayAssets(shares) + 1); // fund the repay (deal sets the balance)
        m.repay(borrower, shares);
        m.withdrawCollateral(borrower, 100 ether, borrower);
    }

    /// @dev Selecting the Fixed `IrmKind` deploys a second market with a fixed IRM on the same shared core.
    function test_irmSelection_fixed() public {
        irmKind = IrmKind.Fixed;
        MockERC20 l2 = new MockERC20("Loan2", "LOAN2", 18);
        MockERC20 c2 = new MockERC20("Coll2", "COLL2", 18);
        Market storage m = _deployProtocol(_defaultConfig(address(l2), address(c2), address(c2)));
        assertTrue(m.irm != address(0), "fixed irm deployed");
        // A second market on the same core.
        assertEq(protocol.markets.length, 2, "core hosts a second market");
    }

    /// @dev A lender can mint an exact share amount then redeem the full balance back to zero shares.
    function test_mintAndRedeem() public {
        Market storage m = protocol.markets[0];
        address lender = _actor("lender");
        uint256 wantShares = 100 ether;
        _fund(m.loanToken, lender, m.vault.previewMint(wantShares));
        m.vaultMint(lender, wantShares);
        m.vaultRedeem(lender, m.vault.balanceOf(lender));
        assertEq(m.vault.balanceOf(lender), 0, "redeemed all shares");
    }

    /// @dev A borrower's per-position settlement LTV can be set through the market helper.
    function test_setSettlementLtv() public {
        protocol.markets[0].setSettlementLtv(_actor("borrower"), 0.5e18);
    }

    /// @dev Lender liquidity + a borrower at 20% LTV (safe at any seeded price), then crash the price.
    function _distressedBorrower(Market storage m, uint256 crashPrice) internal returns (address borrower) {
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1_000 ether);
        m.vaultDeposit(lender, 1_000 ether);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, 20 ether); // value >= 30 at any seed, max borrow >= 24 → safe

        MockPriceOracle(address(m.oracle)).setPrice(crashPrice);
        m.accrueInterest();
    }

    /// @dev A partial seize on an unhealthy-but-solvent borrower liquidates without realizing bad debt.
    function test_liquidate_noBadDebt() public {
        Market storage m = protocol.markets[0];
        address borrower = _distressedBorrower(m, 0.22e36); // value 22: unhealthy (<25) but solvent (>=20)
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000 ether);
        m.liquidate(keeper, borrower, 5 ether, 0); // partial seize → no bad debt
    }

    /// @dev Seizing all collateral of an insolvent borrower realizes and socializes bad debt.
    function test_liquidate_badDebt() public {
        Market storage m = protocol.markets[0];
        address borrower = _distressedBorrower(m, 0.1e36); // value 10 < debt 20 → insolvent
        uint128 col = m.core.position(m.id, borrower).collateral;
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1_000 ether);
        m.liquidateBadDebt(keeper, borrower, col, 0); // seize all collateral → bad debt socialized
    }

    /// @dev A short-liquidity lender's fallbackExit redeems idle first then settles collateral to cover the shortfall.
    function test_fallbackExit_redeemThenSettle() public {
        Market storage m = protocol.markets[0];
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, 20 ether); // 80 idle remains

        MockPriceOracle(address(m.oracle)).setPrice(0.22e36); // unhealthy but solvent → settle-eligible
        m.accrueInterest();

        (,, uint256 colSeized,) = m.fallbackExit(lender, m.vault.balanceOf(lender), lender, 0);
        assertGt(colSeized, 0, "fallbackExit reached the settle leg");
    }
}
