// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Call} from "@bundler3/src/interfaces/IBundler3.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {BundlerSetup} from "../setup/BundlerSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {Market} from "../setup/Types.sol";

/// @notice Borrow ban checks against bundled borrows: the controller checks the core borrow's caller, debt owner and
///         receiver, so a borrow through the general adapter has that shared adapter as its caller, and the receiver
///         may be the adapter that forwards the loan.
contract BundlerAdapterBanTest is BundlerSetup {
    using MarketActions for Market;

    address internal borrower;
    uint256 internal borrowerKey;

    function setUp() public {
        Market storage m = _deployBundledMarket();
        (borrower, borrowerKey) = makeAddrAndKey("borrower");

        address lender = _actor("lender");
        _fund(m.loanToken, lender, 50 ether);
        m.vaultDeposit(lender, 50 ether);
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
    }

    /// @dev Authorizes the adapter, borrows `amount` to the adapter, and forwards the loan to `recipient`.
    function _bundledBorrow(uint256 amount, address recipient) internal view returns (Call[] memory bundle) {
        Market storage m = protocol.markets[0];
        bundle = new Call[](3);
        bundle[0] = _authorizationCall(borrowerKey, address(adapter));
        bundle[1] = _adapterCall(abi.encodeCall(adapter.morphoBorrow, (m.params, amount, 0, 0, address(adapter))));
        bundle[2] =
            _adapterCall(abi.encodeCall(adapter.erc20Transfer, (address(m.loanToken), recipient, type(uint256).max)));
    }

    /// @dev Specified behaviour: anyone can supply collateral on behalf of the general adapter, so a guardian that
    ///      flags the owners of tainted supplies can ban it. The ban reverts every borrow the adapter makes in the
    ///      market, while the same borrow straight on the core works. `guardian-signals.md` describes it.
    function test_adapterBan_revertsBundledBorrow_directBorrowWorks() public {
        Market storage m = protocol.markets[0];
        address stranger = _actor("stranger");
        uint256 amount = m.controller.collateralActivationConfig().minDepositAmount;
        _fund(m.collateralToken, stranger, amount);
        vm.startPrank(stranger);
        m.collateralToken.approve(address(m.core), amount);
        m.core.supplyCollateral(m.params, amount, address(adapter), "");
        vm.stopPrank();
        assertEq(
            m.core.position(m.id, address(adapter)).collateral, amount, "a stranger's supply is booked on the adapter"
        );

        m.flagAs(address(this), address(adapter)); // the sole guardian, quorum 1
        assertTrue(m.guardianSignals.isBanned(m.id, address(adapter)), "setup: the adapter is banned");
        assertFalse(m.guardianSignals.isBanned(m.id, borrower), "setup: the borrower is not");

        // The loan goes straight to the unbanned borrower, so only the caller check can reject it.
        Call[] memory bundle = new Call[](2);
        bundle[0] = _authorizationCall(borrowerKey, address(adapter));
        bundle[1] = _adapterCall(abi.encodeCall(adapter.morphoBorrow, (m.params, 1 ether, 0, 0, borrower)));
        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        bundler3.multicall(bundle);

        m.borrow(borrower, 1 ether);
    }

    /// @dev Specified behaviour: the receiver check binds only the core borrow's receiver, so a bundle that borrows to
    ///      the adapter and forwards the loan delivers it to a banned address, with the debt on the unbanned borrower.
    ///      `guardian-signals.md` describes it.
    function test_receiverBan_forwardedLoanReachesBannedAddress() public {
        Market storage m = protocol.markets[0];
        address bannedRecipient = _actor("bannedRecipient");
        m.flagAs(address(this), bannedRecipient);

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        m.core.borrow(m.params, 1 ether, 0, borrower, bannedRecipient);

        _exec(borrower, 0, _bundledBorrow(1 ether, bannedRecipient));
        assertEq(m.loanToken.balanceOf(bannedRecipient), 1 ether, "the loan reached the banned address");
        assertGt(m.core.position(m.id, borrower).borrowShares, 0, "the debt is on the unbanned borrower");
    }
}
