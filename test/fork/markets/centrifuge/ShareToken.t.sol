// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WAD} from "../../../../src/libs/Constants.sol";
import {Market} from "../../../setup/Types.sol";
import {MarketActions} from "../../../setup/MarketActions.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @notice A market whose collateral is a Centrifuge share token that lets only members of its list receive it, as
///         JTRSY's and JAAA's hooks do, on every such market. The core and the suites' actors are members, so the
///         market works; collateral goes out only to a member.
contract ShareTokenForkTest is ForkStack {
    using MarketActions for Market;

    address internal OUTSIDER;

    function setUp() public {
        _setUpTarget();
        if (!_restrictsReceivers()) vm.skip(true, "ShareToken: the collateral lets any account receive it");
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

    /// @dev Whether the share token refuses a receiver outside its list: a transfer to one, rolled back.
    function _restrictsReceivers() private returns (bool restricted) {
        uint256 snapshot = vm.snapshotState();
        address source = makeAddr("shareToken.probeSource");
        deal(address(market.collateralToken), source, 1);
        vm.prank(source);
        (bool ok, bytes memory returned) = address(market.collateralToken)
            .call(abi.encodeCall(IERC20.transfer, (makeAddr("shareToken.probeOutsider"), 1)));
        restricted = !ok || (returned.length == 32 && !abi.decode(returned, (bool)));
        vm.revertToState(snapshot);
    }
}
