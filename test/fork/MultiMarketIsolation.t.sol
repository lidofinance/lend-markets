// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";

import {IPausableUntil} from "../../src/interfaces/IPausableUntil.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkStack} from "./helpers/ForkStack.sol";
import {MarketDeploymentResult, MarketDeployConfig} from "../../script/deployment/DeployMarketBase.s.sol";

/// @notice One core hosts both deployed markets; their per-market state must stay apart. A full flow on one leaves
///         the other's stored market, settlement queue and the borrower's position untouched, and a pause, freeze,
///         ban or cap lands on the named market only — a ban is keyed by market, so this holds whether the markets
///         share a guardian registry or not. The red case is a provisioning change that shares a controller between
///         markets.
contract MultiMarketIsolationForkTest is ForkStack {
    using MarketActions for Market;

    /// @dev The second market: the target's market script at a lower LLTV over the same oracle and guardian
    ///      registry; `market` (from the base) is the first.
    Market internal other;

    function setUp() public {
        _onlyOnWethWsteth();
        _setUpTarget();
        MarketDeployConfig memory p = parameters;
        p.market.lltv -= 0.01e18;
        p.wrapper.symbol = string.concat(p.wrapper.symbol, "2");
        MarketDeploymentResult memory second = script.deploy(protocol, p);
        _createMarket(second);
        other = _marketHandle(second);

        require(address(market.controller) != address(other.controller), "MultiMarket: markets share a controller");
        require(address(market.core) == address(other.core), "MultiMarket: markets do not share the core");

        LENDER = _freshActor(market, "multi.lender");
        BORROWER = _freshActor(market, "multi.borrower");
    }

    // ---
    // A FULL FLOW ON ONE MARKET LEAVES THE OTHER'S STATE UNTOUCHED
    // ---

    function test_flowOnSecondMarket_leavesFirstUntouched() public {
        _supplyCollateralAsBystander(market);
        bytes32 before = _fingerprint(market);
        _roundTrip(other);
        assertEq(_fingerprint(market), before, "first market's stored state unchanged");
    }

    function test_flowOnFirstMarket_leavesSecondUntouched() public {
        _supplyCollateralAsBystander(other);
        bytes32 before = _fingerprint(other);
        _roundTrip(market);
        assertEq(_fingerprint(other), before, "second market's stored state unchanged");
    }

    // ---
    // CONTROLS LAND ON THE NAMED MARKET ONLY
    // ---

    function test_resealPauseOnOne_leavesOtherLive() public {
        _pauseViaResealManager(1 days);
        assertFalse(IPausableUntil(address(other.controller)).isPaused(), "other market still live");
    }

    function test_stewardFreezeOnOne_leavesOtherUnfrozen_andStewardCannotFreezeIt() public {
        address steward = _appointSteward("multi.steward");
        _freezeViaSteward(steward);
        assertFalse(other.controller.isFrozen(), "other market not frozen");

        vm.prank(steward);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        _dashboard().freezeMarket(other.id);
    }

    function test_banOnOneMarket_invisibleOnOther() public {
        market.banVia(_quorumGuardians(), BORROWER);
        assertFalse(other.guardianSignals.isBanned(other.id, BORROWER), "ban is per market");
        assertFalse(other.controller.positionOf(BORROWER).banned, "other controller does not see it");
    }

    function test_facadeCap_targetsOnlyTheNamedMarket() public {
        uint256 otherCapBefore = LidoLendMarketController(address(other.controller)).supplyCap();
        _setSupplyCap(market.core.market(market.id).totalSupplyAssets + _oneLoanToken());
        assertEq(LidoLendMarketController(address(other.controller)).supplyCap(), otherCapBefore, "other cap unchanged");
    }

    // ---
    // HELPERS
    // ---

    /// @dev Deposit, post a lot, mature it, borrow, repay, reclaim, redeem: every hooked action once.
    function _roundTrip(Market storage target) internal {
        uint256 lotSize = 2 * uint256(_activationConfig(target).minActivationAmount);
        uint256 borrowAssets = _maxBorrow(target, lotSize, target.oracle.price()) / 2;
        uint256 deposit = borrowAssets * 2;
        _requireSupplyHeadroom(target, deposit);

        deal(address(target.loanToken), LENDER, deposit);
        uint256 shares = target.vaultDeposit(LENDER, deposit);
        collateralIssuer.dealCollateral(BORROWER, lotSize);
        target.supplyCollateral(BORROWER, lotSize);
        target.activateCollateral();
        uint256 debt = target.borrow(BORROWER, borrowAssets);
        deal(address(target.loanToken), BORROWER, target.repayAssets(debt));
        target.repay(BORROWER, debt);
        target.withdrawCollateral(BORROWER, lotSize, BORROWER);
        target.vaultRedeem(LENDER, shares);
    }

    /// @dev Recent collateral supply by someone else, as on a live market: the untouched market starts the flow with
    ///      a non-zero, decaying inflow.
    function _supplyCollateralAsBystander(Market storage target) internal {
        address bystander = _freshActor(target, "multi.bystander");
        uint256 lotSize = 2 * uint256(_activationConfig(target).minActivationAmount);
        collateralIssuer.dealCollateral(bystander, lotSize);
        target.supplyCollateral(bystander, lotSize);
    }

    /// @dev The stored market struct, the controller's queue size and the flow's borrower as this market sees it:
    ///      anything a flow on the OTHER market could conceivably touch by mistake. Inflow is left out because it
    ///      decays with the flow's warp; a misrouted collateral hook still shows up in the borrower's position.
    function _fingerprint(Market storage target) internal view returns (bytes32) {
        MorphoMarket memory stored = target.core.market(target.id);
        return keccak256(
            abi.encode(stored, target.controller.settlementBorrowersCount(), target.controller.positionOf(BORROWER))
        );
    }
}
