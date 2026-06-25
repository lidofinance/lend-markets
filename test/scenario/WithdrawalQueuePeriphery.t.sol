// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WithdrawalQueue} from "../../src/periphery/WithdrawalQueue.sol";
import {WithdrawalQueueLib} from "../../src/libs/WithdrawalQueueLib.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice L2 suite for the `WithdrawalQueue` periphery contract (the two libraries it composes are unit-
///         tested in §8/§9). Deployed over a fresh market; covers config/validation reverts, Vault-mode
///         escrow, the fill split crediting lender/keeper/protocol claimables, escrow refund on
///         cancel/prune, and claim.
contract WithdrawalQueuePeripheryTest is LidoLendSetup {
    using MarketActions for Market;

    WithdrawalQueue internal wq;
    address internal owner = address(0x053E5);
    address internal feeRecipient = address(0xFEE);

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
        Market storage m = protocol.markets[0];
        wq = new WithdrawalQueue(address(m.vault), address(m.core), m.params, owner, feeRecipient, 50);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender deposits to the vault and gets `shares`, then approves the queue (max, so the exact
    ///      escrowed amount — `convertToShares(assets)`, which may round above the deposit shares — never
    ///      reverts on allowance). The real escrowed amount is read per-request from `getRequest().sizeTotal`.
    function _lenderWithShares(uint256 assets) internal returns (address lender, uint256 shares) {
        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, assets);
        shares = m.vaultDeposit(lender, assets);
        vm.prank(lender);
        IERC20(address(m.vault)).approve(address(wq), type(uint256).max);
    }

    // ── constructor / config ──

    function testRevert_constructor_zeroVault() public {
        Market storage m = _m();
        vm.expectRevert(WithdrawalQueue.ZeroAddress.selector);
        new WithdrawalQueue(address(0), address(m.core), m.params, owner, feeRecipient, 0);
    }

    function testRevert_setProtocolFee_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert(WithdrawalQueue.FeeTooHigh.selector);
        wq.setProtocolFee(feeRecipient, 101); // > MAX_PROTOCOL_FEE_BPS (100)
    }

    function testRevert_setProtocolFee_recipientRequired() public {
        vm.prank(owner);
        vm.expectRevert(WithdrawalQueue.FeeRecipientRequired.selector);
        wq.setProtocolFee(address(0), 50); // nonzero bps with no recipient
    }

    function test_setProtocolFee_zeroBpsZeroRecipient_ok() public {
        vm.prank(owner);
        wq.setProtocolFee(address(0), 0); // disabling the fee needs no recipient
        assertEq(wq.protocolFeeBps(), 0, "fee cleared");
    }

    function testRevert_setProtocolFee_notOwner() public {
        vm.prank(_actor("nobody"));
        vm.expectRevert();
        wq.setProtocolFee(feeRecipient, 10);
    }

    // ── requestWithdrawal ──

    function testRevert_request_zeroSize() public {
        vm.expectRevert(WithdrawalQueue.ZeroSize.selector);
        wq.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 0, 0, block.timestamp + 1 days, false);
    }

    function testRevert_request_deadlineInPast() public {
        vm.expectRevert(WithdrawalQueue.DeadlineInPast.selector);
        wq.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 1 ether, 0, block.timestamp, false);
    }

    function test_request_vaultMode_escrowsShares() public {
        (address lender,) = _lenderWithShares(100 ether);
        Market storage m = _m();
        uint256 lenderBefore = m.vault.balanceOf(lender);
        vm.prank(lender);
        uint256 id =
            wq.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 100 ether, 1 ether, block.timestamp + 1 days, false);

        // The escrow takes exactly `convertToShares(assets)` — read it back from the request rather than
        // assuming it equals the deposit shares (a different rounding).
        uint256 escrowed = wq.getRequest(id).sizeTotal;
        assertEq(m.vault.balanceOf(address(wq)), escrowed, "queue holds exactly the escrowed shares");
        assertEq(lenderBefore - m.vault.balanceOf(lender), escrowed, "lender debited exactly the escrowed shares");
        assertEq(wq.activeRequestCount(), 1, "one active request");
    }

    // ── cancel refunds the escrow ──

    function test_cancel_vaultMode_refundsEscrowedShares() public {
        (address lender,) = _lenderWithShares(100 ether);
        Market storage m = _m();
        uint256 lenderBefore = m.vault.balanceOf(lender);
        vm.prank(lender);
        uint256 id =
            wq.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 100 ether, 1 ether, block.timestamp + 1 days, false);
        vm.prank(lender);
        wq.cancelWithdrawal(id);
        assertEq(m.vault.balanceOf(lender), lenderBefore, "escrow returned in full -> lender made whole");
        assertEq(wq.activeRequestCount(), 0, "request closed");
    }

    function test_pruneExpired_refundsEscrow_andSkipsLive() public {
        (address lender,) = _lenderWithShares(100 ether);
        Market storage m = _m();
        uint256 lenderBefore = m.vault.balanceOf(lender);
        vm.prank(lender);
        uint256 id =
            wq.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 100 ether, 1 ether, block.timestamp + 1 days, false);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        wq.pruneExpired(ids); // not yet expired -> no-op
        assertEq(wq.activeRequestCount(), 1, "live request not pruned");

        vm.warp(block.timestamp + 2 days);
        wq.pruneExpired(ids); // now expired -> refund
        assertEq(m.vault.balanceOf(lender), lenderBefore, "expired escrow refunded -> lender made whole");
        assertEq(wq.activeRequestCount(), 0, "pruned");
    }

    // ── fill split + claim ──

    function test_fill_splitsAndCredits_thenClaim() public {
        (address lender,) = _lenderWithShares(100 ether);
        Market storage m = _m();
        vm.prank(lender);
        uint256 id =
            wq.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 100 ether, 1 ether, block.timestamp + 1 days, false);
        uint256 sizeTotal = wq.getRequest(id).sizeTotal;
        uint256 pricePerShare = wq.getRequest(id).pricePerShare;

        // Idle covers the redeem (no borrow), so a plain process fully fills it.
        address keeper = _actor("keeper");
        vm.prank(keeper);
        wq.processWithdrawal(id);

        // Filled in the SAME block -> the Dutch ramp fee is 0, so lenderAssets == owed. But `owed` is a
        // DOUBLE floor of the price while `assetsOut` (the redeem) is a SINGLE floor, so a few wei of pure
        // rounding "yield" flows to the keeper (net of the protocol cut). Recompute every leg exactly.
        uint256 assetsOut = m.loanToken.balanceOf(address(wq));
        uint256 owed = Math.min(Math.mulDiv(sizeTotal, pricePerShare, 1e18), assetsOut);
        uint256 roundingYield = assetsOut - owed;
        uint256 protocolFee = roundingYield * 50 / 10_000; // protocolFeeBps == 50
        assertEq(wq.claimable(lender), owed, "lender credited owed (fee 0 at ramp 0)");
        assertEq(wq.claimable(feeRecipient), protocolFee, "protocol == 50bps of the rounding yield");
        assertEq(wq.claimable(keeper), roundingYield - protocolFee, "keeper == rounding yield net of protocol cut");
        assertEq(
            wq.claimable(lender) + wq.claimable(keeper) + wq.claimable(feeRecipient),
            assetsOut,
            "exact conservation: the three credits sum to the redeemed assets"
        );
        assertEq(wq.activeRequestCount(), 0, "request fully filled and closed");

        // Claim moves exactly the lender's owed to it.
        uint256 before = m.loanToken.balanceOf(lender);
        vm.prank(lender);
        uint256 claimed = wq.claim();
        assertEq(claimed, owed, "claim transfers the full lender claimable");
        assertEq(m.loanToken.balanceOf(lender) - before, owed, "lender received exactly its owed");
        assertEq(wq.claimable(lender), 0, "claimable zeroed");
    }

    function test_claim_nothing_returnsZero() public {
        vm.prank(_actor("nobody"));
        assertEq(wq.claim(), 0, "claiming with no balance returns 0");
    }

    /// @dev At the deadline the Dutch ramp is full (BPS), so the keeper earns the whole priority fee — the
    ///      path that actually exercises the lender/keeper/protocol split wiring. Every leg recomputed exactly.
    function test_fill_atDeadline_creditsFullPriorityFee() public {
        (address lender,) = _lenderWithShares(100 ether);
        Market storage m = _m();
        uint256 deadline = block.timestamp + 1 days;
        vm.prank(lender);
        uint256 id = wq.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 100 ether, 1 ether, deadline, false);
        uint256 sizeTotal = wq.getRequest(id).sizeTotal;
        uint256 price = wq.getRequest(id).pricePerShare;

        vm.warp(deadline); // now == deadline -> feeRampBps == BPS -> full priority fee

        vm.prank(_actor("keeper"));
        wq.processWithdrawal(id);

        uint256 assetsOut = m.loanToken.balanceOf(address(wq));
        uint256 owed = Math.min(Math.mulDiv(sizeTotal, price, 1e18), assetsOut);
        uint256 fee = Math.min(1 ether, owed); // maxFee * (filled/total = 1) * (BPS/BPS = 1), capped at owed
        uint256 keeperGross = (assetsOut - owed) + fee;
        uint256 protocolFee = keeperGross * 50 / 10_000;
        assertEq(wq.claimable(lender), owed - fee, "lender == owed - full priority fee");
        assertEq(wq.claimable(feeRecipient), protocolFee, "protocol == 50bps of the keeper gross");
        assertEq(wq.claimable(_actor("keeper")), keeperGross - protocolFee, "keeper == gross net of the protocol cut");
        assertEq(
            wq.claimable(lender) + wq.claimable(_actor("keeper")) + wq.claimable(feeRecipient),
            assetsOut,
            "exact conservation across all three credits"
        );
    }

    function testRevert_process_nothingAvailable() public {
        (address lender,) = _lenderWithShares(100 ether);
        Market storage m = _m();
        // Drain the idle: a borrower takes all the supplied liquidity, so the redeem finds nothing.
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 1000 ether);
        m.supplyCollateral(borrower, 1000 ether);
        m.activateCollateral();
        m.borrow(borrower, 100 ether); // idle -> 0

        vm.prank(lender);
        uint256 id =
            wq.requestWithdrawal(WithdrawalQueueLib.Mode.Vault, 100 ether, 1 ether, block.timestamp + 1 days, false);
        vm.expectRevert(WithdrawalQueue.NothingAvailable.selector);
        wq.processWithdrawal(id);
    }

    function testRevert_request_directMode_notAuthorized() public {
        // Direct mode requires the caller to have authorized this contract on the core first.
        vm.prank(_actor("lender"));
        vm.expectRevert(WithdrawalQueue.NotAuthorizedOnCore.selector);
        wq.requestWithdrawal(WithdrawalQueueLib.Mode.Direct, 1 ether, 0, block.timestamp + 1 days, false);
    }
}
