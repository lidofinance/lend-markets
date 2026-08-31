// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice ACT-05/06 end-to-end: a forced seizure through the controller (liquidation / settlement share the
///         `_activation.seize` hook path) reverses the same-tx activation inflow that the freshly supplied,
///         then seized, collateral added. Pre-fix the forced path left that inflow stale.
/// @dev The underwater borrower is primed in `setUp` — a SEPARATE transaction — on purpose: the fresh supply and
///      the seizure must be the only activation mutations in the TEST tx, so the accumulator's tx baseline is the
///      priming's already-decayed inflow (~0) and `net` carries only the fresh, seized amount. Priming in the
///      test tx instead would keep the original collateral's contribution in the same-tx `net` (a real tx is one
///      instant — no intra-tx decay), and the seizure would correctly leave it, defeating the observation.
contract ForcedSeizureActivationInflowTest is LidoLendSetup {
    using MarketActions for Market;

    address internal borrower;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
        Market storage m = protocol.markets[0];

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1_000 ether);
        m.vaultDeposit(lender, 1_000 ether);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral(); // warps past the activation delay: the supply's inflow decays back out
        uint256 maxBorrow = 100 ether * oraclePrice / 1e36 * 80 / 100;
        m.borrow(borrower, maxBorrow * 99 / 100); // ~99% of LLTV-max

        // -95%: deeply underwater, so the fresh top-up in the test cannot rescue the position.
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 5 / 100);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function test_forcedSeizure_reversesSameTxActivationInflow() public {
        Market storage m = _m();

        uint256 delayPre = m.controller.currentActivationDelay(0); // primed inflow has decayed -> the delay floor

        // Fresh, non-instant collateral enters `activating` and bumps the throttle (raising the delay).
        uint256 fresh = 1_000 ether;
        _fund(m.collateralToken, borrower, fresh);
        m.supplyCollateral(borrower, fresh);
        uint256 delayAfterSupply = m.controller.currentActivationDelay(0);
        assertGt(delayAfterSupply, delayPre, "fresh non-instant collateral raised the activation throttle");

        // A bad-debt liquidation in the SAME tx seizes the whole position; the seize drains the fresh activating
        // collateral and must reverse the inflow it added.
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, type(uint128).max);
        m.liquidateBadDebt(keeper, borrower, 100 ether + fresh, 0);

        uint256 delayAfterSeize = m.controller.currentActivationDelay(0);
        assertLt(delayAfterSeize, delayAfterSupply, "forced seizure reversed the throttle bump");
        assertEq(delayAfterSeize, delayPre, "inflow reconciled back to the pre-supply baseline (no stale amount)");
    }
}

/// @notice Settlement variant of the ACT-05/06 end-to-end, exercising the active-first seizure order: the
///         forced seizure comes from `vault.settle` (`_handleSettle` -> `_activation.seize`) rather than
///         liquidation. The borrower is primed solvent-but-unhealthy in `setUp` (a separate tx) with its
///         collateral matured into `active`, so the settlement's small LTV-driven cut below is absorbed
///         entirely by that matured balance and never reaches the fresh, still-activating top-up.
contract SettlementActivationInflowTest is LidoLendSetup {
    using MarketActions for Market;

    address internal lender;
    address internal borrower;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
        Market storage m = protocol.markets[0];

        lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral(); // decays this supply's inflow back out
        m.borrow(borrower, 20 ether);

        // Solvent-but-unhealthy and not bad debt (mirrors the vault suite's `_distress`). The personal target
        // makes the borrower eligible for the targeted settlement exercised below.
        MockPriceOracle(address(m.oracle)).setPrice(0.22e36);
        m.accrueInterest();
        m.setSettlementLtv(borrower, 0.8e18);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function test_settlement_seizureCoveredByActive_leavesFreshActivatingInflowUntouched() public {
        Market storage m = _m();

        uint256 delayPre = m.controller.currentActivationDelay(0);

        // Fresh, non-instant collateral (the minimum that enters `activating`) bumps the throttle. Small enough
        // that the borrower's LTV remains above its personal settlement target after the top-up.
        uint256 fresh = 10 ether;
        _fund(m.collateralToken, borrower, fresh);
        m.supplyCollateral(borrower, fresh);
        uint256 delayAfterSupply = m.controller.currentActivationDelay(0);
        assertGt(delayAfterSupply, delayPre, "fresh non-instant collateral raised the activation throttle");

        // A settlement in the SAME tx cuts the borrower through `_handleSettle` -> `seize`. Seizure now consumes
        // active collateral first, and the borrower's matured 100 ether from setUp comfortably covers this small
        // LTV-driven cut, so the fresh activating top-up is never touched and its inflow contribution survives.
        address[] memory bs = new address[](1);
        bs[0] = borrower;
        uint256 shares = m.vault.balanceOf(lender);
        m.settle(lender, shares, bs, lender);

        uint256 delayAfterSettle = m.controller.currentActivationDelay(0);
        assertEq(
            delayAfterSettle,
            delayAfterSupply,
            "a seizure covered by active collateral leaves the fresh activating inflow untouched"
        );
    }
}
