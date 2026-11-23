// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Call, IBundler3} from "@bundler3/src/interfaces/IBundler3.sol";

import {WAD} from "../../../../src/libs/Constants.sol";
import {IGeneralAdapter1} from "../../../setup/IGeneralAdapter1.sol";
import {Market} from "../../../setup/Types.sol";
import {MarketActions} from "../../../setup/MarketActions.sol";
import {ICentrifugeMemberHook, ICentrifugeShareToken} from "../../helpers/ForkCollateralIssuerCentrifuge.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @notice A market whose collateral is a Centrifuge share token that lets only members of its list receive it, as
///         JTRSY's and JAAA's hooks do, on every such market. The core and the suites' actors are members, so the
///         market works; collateral goes out only to a member, and only while its membership lasts, though a member
///         keeper can still liquidate a borrower whose membership ended. The list never holds the bundler's adapters,
///         so a bundle cannot move the collateral through them.
contract ShareTokenForkTest is ForkStack {
    using MarketActions for Market;

    address internal OUTSIDER;

    function setUp() public {
        _setUpTarget();
        if (_collateralAdmits(makeAddr("shareToken.probeOutsider"))) {
            vm.skip(true, "ShareToken: the collateral lets any account receive it");
        }
        _seedLenderAndBorrower();
        OUTSIDER = makeAddr("shareToken.outsider");
    }

    /// @dev A keeper outside the list cannot liquidate: the seized collateral cannot reach it.
    function testRevert_liquidate_keeperOutsideTheMemberList() public {
        _setPriceForLtv(BORROWER, (market.params.lltv + WAD) / 2);
        deal(address(market.loanToken), OUTSIDER, market.repayAssets(borrowShares));
        _approve(address(market.loanToken), OUTSIDER, address(market.core), type(uint256).max);
        vm.prank(OUTSIDER);
        vm.expectRevert(bytes("transfer reverted"));
        market.core.liquidate(market.params, BORROWER, 0, borrowShares / 4, "");
    }

    /// @dev A lender cannot settle to a receiver outside the list: the collateral cannot reach it.
    function testRevert_settle_receiverOutsideTheMemberList() public {
        market.setSettlementLtv(BORROWER, 0.5e18);
        address[] memory borrowers = new address[](1);
        borrowers[0] = BORROWER;
        vm.prank(LENDER);
        vm.expectRevert(bytes("transfer reverted"));
        market.vault.settle(lenderShares / 10, borrowers, OUTSIDER, LENDER);
    }

    /// @dev A borrower cannot withdraw collateral to a receiver outside the list.
    function testRevert_withdrawCollateral_toAReceiverOutsideTheMemberList() public {
        vm.prank(BORROWER);
        vm.expectRevert(bytes("transfer reverted"));
        market.core.withdrawCollateral(market.params, lot / 100, BORROWER, OUTSIDER);
    }

    /// @dev Once its membership expires, the borrower itself can no longer receive its collateral.
    function testRevert_withdrawCollateral_afterTheMembershipExpires() public {
        _expireMembership(BORROWER);
        vm.prank(BORROWER);
        vm.expectRevert(bytes("transfer reverted"));
        market.core.withdrawCollateral(market.params, lot / 100, BORROWER, BORROWER);
    }

    /// @dev A borrower whose membership expires can still be liquidated by a member keeper: the seized collateral goes
    ///      from the core to the keeper, not through the borrower.
    function test_liquidate_aBorrowerWhoseMembershipExpired() public {
        _expireMembership(BORROWER);
        _setPriceForLtv(BORROWER, (market.params.lltv + WAD) / 2);
        address keeper = _freshActor(market, "shareToken.keeper");
        uint256 shares = borrowShares / 4;
        deal(address(market.loanToken), keeper, market.repayAssets(shares));
        (uint256 seized,) = market.liquidate(keeper, BORROWER, 0, shares);
        assertGt(seized, 0, "the member keeper seized the collateral");
    }

    /// @dev The frontend guide's way to post collateral moves it through the general adapter, which the list does not
    ///      hold, so the bundle reverts; the same collateral goes in directly.
    function testRevert_bundle_postCollateral_throughTheGeneralAdapter() public {
        if (bundler.bundler == address(0)) vm.skip(true, "ShareToken: the network records no bundler");
        assertFalse(_collateralAdmits(bundler.generalAdapter), "the general adapter is not on the list");
        address poster = _freshActor(market, "shareToken.poster");
        collateralIssuer.dealCollateral(poster, lot);
        _approve(address(market.collateralToken), poster, bundler.generalAdapter, lot);
        Call[] memory bundle = new Call[](2);
        bundle[0] = Call({
            to: bundler.generalAdapter,
            data: abi.encodeCall(
                IGeneralAdapter1.erc20TransferFrom, (address(market.collateralToken), bundler.generalAdapter, lot)
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        bundle[1] = Call({
            to: bundler.generalAdapter,
            data: abi.encodeCall(
                IGeneralAdapter1.morphoSupplyCollateral, (market.params, type(uint256).max, poster, "")
            ),
            value: 0,
            skipRevert: false,
            callbackHash: bytes32(0)
        });
        vm.prank(poster);
        vm.expectRevert();
        IBundler3(bundler.bundler).multicall(bundle);

        market.supplyCollateral(poster, lot);
        assertEq(market.core.position(market.id, poster).collateral, lot, "the collateral goes in directly");
    }

    /// @dev The hook's root ends `member`'s membership in a day, and a warp of two days passes it.
    function _expireMembership(address member) internal {
        ICentrifugeMemberHook hook =
            ICentrifugeMemberHook(ICentrifugeShareToken(address(market.collateralToken)).hook());
        vm.prank(hook.root());
        hook.updateMember(address(market.collateralToken), member, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
    }
}
