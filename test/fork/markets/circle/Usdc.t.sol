// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {WAD} from "../../../../src/libs/Constants.sol";
import {Market} from "../../../setup/Types.sol";
import {MarketActions} from "../../../setup/MarketActions.sol";
import {ForkStack} from "../../helpers/ForkStack.sol";

/// @dev Circle's USDC: its blacklist and its pause.
interface IFiatToken {
    function blacklister() external view returns (address);
    function pauser() external view returns (address);
    function blacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
    function pause() external;
    function unpause() external;
}

/// @notice A market whose loan token is Circle's USDC, on every such market. USDC refuses to move to or from a
///         blacklisted account, so neither a borrow nor a vault withdrawal can pay one, while a borrower blacklisted
///         after it borrows can still be liquidated. A pause stops every USDC transfer, a liquidation's included, but
///         not interest accrual, and unpausing restores them.
contract UsdcForkTest is ForkStack {
    using MarketActions for Market;

    IFiatToken internal usdc;
    address internal BLACKLISTED;

    function setUp() public {
        _setUpTarget();
        (bool hasBlacklister, bytes memory blacklister) =
            address(market.loanToken).staticcall(abi.encodeCall(IFiatToken.blacklister, ()));
        (bool hasPauser, bytes memory pauser) =
            address(market.loanToken).staticcall(abi.encodeCall(IFiatToken.pauser, ()));
        if (!hasBlacklister || blacklister.length != 32 || !hasPauser || pauser.length != 32) {
            vm.skip(true, "Usdc: the loan token has no USDC blacklist and pause");
        }
        usdc = IFiatToken(address(market.loanToken));
        _seedLenderAndBorrower();
        BLACKLISTED = makeAddr("usdc.blacklisted");
    }

    /// @dev A borrower cannot borrow to a blacklisted receiver, and can to itself.
    function testRevert_borrow_toABlacklistedReceiver() public {
        uint256 assets = _maxBorrow(market, lot, market.oracle.price()) / 10;
        _blacklist(BLACKLISTED);
        vm.prank(BORROWER);
        vm.expectRevert(bytes("transfer reverted"));
        market.core.borrow(market.params, assets, 0, BORROWER, BLACKLISTED);

        market.borrow(BORROWER, assets);
    }

    /// @dev A lender cannot withdraw from the vault to a blacklisted receiver.
    function testRevert_vaultWithdraw_toABlacklistedReceiver() public {
        uint256 assets = market.vault.maxWithdraw(LENDER) / 10;
        _blacklist(BLACKLISTED);
        vm.prank(LENDER);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        market.vault.withdraw(assets, BLACKLISTED, LENDER);
    }

    /// @dev A borrower blacklisted after it borrows can still be liquidated: the keeper repays the core and takes the
    ///      collateral, and no USDC moves to or from the borrower.
    function test_liquidate_aBorrowerBlacklistedAfterBorrowing() public {
        _blacklist(BORROWER);
        _setPriceForLtv(BORROWER, (market.params.lltv + WAD) / 2);
        address keeper = _freshActor(market, "usdc.keeper");
        uint256 shares = borrowShares / 4;
        deal(address(usdc), keeper, market.repayAssets(shares));
        (uint256 seized,) = market.liquidate(keeper, BORROWER, 0, shares);
        assertGt(seized, 0, "the keeper seized the blacklisted borrower's collateral");
    }

    /// @dev While USDC is paused, a vault deposit, a repay and a liquidation revert, and interest still accrues;
    ///      unpaused, the liquidation and the deposit go through.
    function test_pause_stopsUsdcTransfersButNotAccrual() public {
        address depositor = _freshActor(market, "usdc.depositor");
        address keeper = _freshActor(market, "usdc.keeper");
        uint256 deposit = _oneLoanToken();
        uint256 shares = borrowShares / 4;
        // USDC refuses approvals while paused too, so every allowance is set first.
        deal(address(usdc), depositor, deposit);
        deal(address(usdc), keeper, 2 * market.repayAssets(shares));
        _approve(address(usdc), depositor, address(market.vault), deposit);
        _approve(address(usdc), keeper, address(market.core), type(uint256).max);
        _approve(address(usdc), BORROWER, address(market.core), type(uint256).max);

        vm.prank(usdc.pauser());
        usdc.pause();
        vm.prank(depositor);
        vm.expectRevert(bytes("Pausable: paused"));
        market.vault.deposit(deposit, depositor);
        vm.prank(BORROWER);
        vm.expectRevert(bytes("transferFrom reverted"));
        market.core.repay(market.params, 0, shares, BORROWER, "");

        uint256 debtBefore = market.core.market(market.id).totalBorrowAssets;
        vm.warp(block.timestamp + 1 days);
        _accrueInterest();
        assertGt(market.core.market(market.id).totalBorrowAssets, debtBefore, "interest accrues while paused");

        _setPriceForLtv(BORROWER, (market.params.lltv + WAD) / 2);
        vm.prank(keeper);
        vm.expectRevert(bytes("transferFrom reverted"));
        market.core.liquidate(market.params, BORROWER, 0, shares, "");

        vm.prank(usdc.pauser());
        usdc.unpause();
        (uint256 seized,) = market.liquidate(keeper, BORROWER, 0, shares);
        assertGt(seized, 0, "the liquidation goes through once unpaused");
        market.vaultDeposit(depositor, deposit);
    }

    /// @dev Blacklists `account` on USDC as its blacklister.
    function _blacklist(address account) internal {
        vm.prank(usdc.blacklister());
        usdc.blacklist(account);
        assertTrue(usdc.isBlacklisted(account), "account blacklisted on USDC");
    }
}
