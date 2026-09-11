// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";

import {IPausableUntil} from "../../src/interfaces/IPausableUntil.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

/// @notice One core hosts both deployed markets; their per-market state must stay apart. A full flow on one leaves
///         the other's stored market, settlement queue and inflow untouched, and a pause, freeze, ban or cap
///         lands on the named market only. The red case is a provisioning change that shares a controller or
///         registry between markets.
contract MultiMarketIsolationForkTest is ForkMarketStack("weth-wsteth") {
    using MarketActions for Market;

    /// @dev The second bound market; `deployed` / `market` (from the base) are the first.
    BoundMarket internal other;
    Market internal otherMarket;

    function setUp() public {
        _fork();
        _bindRole();
        other = _bindMarket(_marketForRole("usdy-usdt")); // a one-market deployment skips here
        _pokeAccrue(other);
        _copyMarket(otherMarket, other);

        require(address(deployed.controller) != address(other.controller), "MultiMarket: markets share a controller");
        require(
            address(deployed.guardianSignals) != address(other.guardianSignals), "MultiMarket: markets share a registry"
        );
        require(address(deployed.core) == address(other.core), "MultiMarket: markets do not share the core");

        LENDER = _freshActor(deployed, "multi.lender");
        BORROWER = _freshActor(deployed, "multi.borrower");
    }

    // ---
    // A FULL FLOW ON ONE MARKET LEAVES THE OTHER'S STATE UNTOUCHED
    // ---

    function test_flowOnSecondMarket_leavesFirstUntouched() public {
        bytes32 before = _fingerprint(deployed);
        _roundTrip(otherMarket, other);
        assertEq(_fingerprint(deployed), before, "first market's stored state unchanged");
    }

    function test_flowOnFirstMarket_leavesSecondUntouched() public {
        bytes32 before = _fingerprint(other);
        _roundTrip(market, deployed);
        assertEq(_fingerprint(other), before, "second market's stored state unchanged");
    }

    // ---
    // CONTROLS LAND ON THE NAMED MARKET ONLY
    // ---

    function test_resealPauseOnOne_leavesOtherLive() public {
        _pauseViaResealManager(deployed, 1 days);
        assertFalse(IPausableUntil(address(other.controller)).isPaused(), "other market still live");
    }

    function test_stewardFreezeOnOne_leavesOtherUnfrozen_andStewardCannotFreezeIt() public {
        address steward = _appointSteward(deployed, "multi.steward");
        _freezeViaSteward(deployed, steward);
        assertFalse(other.controller.isFrozen(), "other market not frozen");

        vm.prank(steward);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        _dashboard().freezeMarket(other.id);
    }

    function test_banOnOneRegistry_invisibleOnOther() public {
        market.banVia(_quorumGuardians(deployed), BORROWER);
        assertFalse(other.guardianSignals.isBanned(other.id, BORROWER), "ban is per registry");
        assertFalse(other.controller.positionOf(BORROWER).banned, "other controller does not see it");
    }

    function test_facadeCap_targetsOnlyTheNamedMarket() public {
        uint256 otherCapBefore = LidoLendMarketController(address(other.controller)).supplyCap();
        _setSupplyCap(deployed, deployed.core.market(deployed.id).totalSupplyAssets + _loanUnit(deployed));
        assertEq(LidoLendMarketController(address(other.controller)).supplyCap(), otherCapBefore, "other cap unchanged");
    }

    // ---
    // HELPERS
    // ---

    /// @dev Deposit, post a lot, mature it, borrow, repay, reclaim, redeem: every hooked action once.
    function _roundTrip(Market storage target, BoundMarket memory bound) internal {
        uint256 lotSize = 2 * uint256(bound.activation.minActivationAmount);
        uint256 borrowAssets = _maxBorrow(bound, lotSize, bound.oracle.price()) / 2;
        uint256 deposit = borrowAssets * 2;
        _requireSupplyHeadroom(bound, deposit);

        deal(address(bound.loanToken), LENDER, deposit);
        uint256 shares = target.vaultDeposit(LENDER, deposit);
        deal(address(bound.collateralToken), BORROWER, lotSize);
        target.supplyCollateral(BORROWER, lotSize);
        target.activateCollateral();
        uint256 debt = target.borrow(BORROWER, borrowAssets);
        deal(address(bound.loanToken), BORROWER, target.repayAssets(debt));
        target.repay(BORROWER, debt);
        target.withdrawCollateral(BORROWER, lotSize, BORROWER);
        target.vaultRedeem(LENDER, shares);
    }

    /// @dev The stored market struct plus the controller's queue size and inflow: anything a flow on the OTHER
    ///      market could conceivably touch by mistake.
    function _fingerprint(BoundMarket memory bound) internal view returns (bytes32) {
        MorphoMarket memory stored = bound.core.market(bound.id);
        return
            keccak256(abi.encode(stored, bound.controller.settlementBorrowersCount(), bound.controller.currentInflow()));
    }
}
