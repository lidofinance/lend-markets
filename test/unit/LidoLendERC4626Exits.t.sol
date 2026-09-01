// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {IrmKind, Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice Model-first coverage of the `settle` / `fallbackExit` branches the end-to-end flows skip: the input
///         guards, the on-behalf allowance legs, and the queue-exhausted partial fill. Each test asserts the
///         intended behaviour (exact amounts, allowance spent, state), not merely that the branch was reached.
contract LidoLendERC4626ExitsTest is LidoLendSetup {
    using MarketActions for Market;

    bytes32 private constant SETTLED_SIG = keccak256("Settled(address,address,address,uint256,uint256,uint256)");
    bytes32 private constant FALLBACK_EXIT_SIG =
        keccak256("FallbackExit(address,address,address,uint256,uint256,uint256,uint256,uint256)");

    /// @dev Everything one settle/fallbackExit call touches, so `_assertExitEffects` can check the full state and
    ///      the event in one place. Pre-op snapshots + the returned amounts.
    struct ExitCheck {
        bytes32 sig; // Settled / FallbackExit
        address caller;
        address owner;
        address receiver;
        address borrower;
        uint256 borrowBefore; // core totalBorrowAssets before
        uint256 collatBefore; // borrower collateral before
        uint256 supplyBefore; // vault totalSupply before
        uint256 receiverCollatBefore;
        uint256 burned; // shares the call burned (both legs for fallbackExit) == the event's field == supply drop
        uint256 sharesSettled; // fallbackExit only: the settle leg's own share burn
        uint256 assetsWithdrawn; // fallbackExit only: loan assets the liquid leg paid out
        uint256 collateralSeized;
        uint256 debtCanceled;
    }

    function setUp() public {
        // Flat rate: the 120-day warp in `_distressFull` moves the share price without the adaptive curve running
        // away at 100% utilization.
        irmKind = IrmKind.Fixed;
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Assert everything a settle/fallbackExit moved, recomputed independently, and that the emitted event
    ///      carried exactly those amounts. The returned amounts must equal the on-chain deltas: debt cancelled ==
    ///      the core borrow-asset drop, collateral seized == the borrower's collateral debit == what the receiver
    ///      was credited, and the vault supply fell by exactly the shares burned. Requires `vm.recordLogs()` before
    ///      the call.
    function _assertExitEffects(ExitCheck memory c) private {
        Market storage m = _m();
        assertEq(c.debtCanceled, c.borrowBefore - m.core.market(m.id).totalBorrowAssets, "debtCanceled == borrow drop");
        assertEq(
            c.collateralSeized,
            c.collatBefore - m.core.position(m.id, c.borrower).collateral,
            "collateralSeized == borrower collateral debit"
        );
        assertEq(
            m.collateralToken.balanceOf(c.receiver),
            c.receiverCollatBefore + c.collateralSeized,
            "receiver credited exactly the seized collateral"
        );
        assertEq(m.vault.totalSupply(), c.supplyBefore - c.burned, "vault supply fell by exactly the burned shares");
        _assertExitEvent(c);
    }

    /// @dev Find the vault's settle/fallbackExit event in the recorded logs and check its topics and every data
    ///      field against the independently-derived amounts. Exactly one must be emitted per call.
    function _assertExitEvent(ExitCheck memory c) private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != c.sig || logs[i].emitter != address(_m().vault)) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), c.caller, "event caller");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), c.owner, "event owner");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), c.receiver, "event receiver");
            // `FallbackExit` splits the burn per leg and adds the liquid payout before the seizure; `Settled` does not.
            if (c.sig == FALLBACK_EXIT_SIG) {
                (uint256 sb, uint256 ss, uint256 aw, uint256 cs, uint256 dc) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                assertEq(sb, c.burned, "event sharesBurned");
                assertEq(ss, c.sharesSettled, "event sharesSettled");
                assertEq(aw, c.assetsWithdrawn, "event assetsWithdrawn");
                assertEq(cs, c.collateralSeized, "event collateralSeized");
                assertEq(dc, c.debtCanceled, "event debtCanceled");
            } else {
                (uint256 sb, uint256 cs, uint256 dc) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(sb, c.burned, "event sharesBurned");
                assertEq(cs, c.collateralSeized, "event collateralSeized");
                assertEq(dc, c.debtCanceled, "event debtCanceled");
            }
            ++matches;
        }
        assertEq(matches, 1, "exactly one exit event emitted");
    }

    /// @dev A vault lender plus a borrower who has borrowed the whole supply, accrued interest for 120 days (so the
    ///      share price has moved off parity and the debt off its principal), and then been crashed to
    ///      unhealthy-but-solvent — the market is illiquid and the borrower settle-eligible. A non-starting state, so
    ///      the settle amounts exercise a non-trivial share price and oracle price, not defaults.
    function _distressFull() internal returns (address lender, address borrower) {
        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 1_000 ether);
        m.supplyCollateral(borrower, 1_000 ether);
        m.activateCollateral();
        m.borrow(borrower, 100 ether); // borrow all supply -> idle 0

        m.warpAndAccrue(120 days); // move the share price off parity and grow the debt while still healthy

        // Crash relative to the grown debt (sole borrower -> debt == totalBorrowAssets): put the collateral worth
        // 110% of the debt — solvent, but under the 1/lltv = 125% health line, so settle-eligible without bad debt.
        // Widen the uint128 accumulator to uint256 before scaling by 1e36 (else the mul overflows uint128).
        uint256 debt = m.core.market(m.id).totalBorrowAssets;
        MockPriceOracle(address(m.oracle)).setPrice(debt * 1e36 / (1_000 ether) * 110 / 100);
        m.accrueInterest();
    }

    // ── settle input guards ──

    /// @dev Settling more shares than you own is rejected before any cut — you cannot settle beyond your stake.
    function test_settle_sharesAboveBalance_reverts() public {
        (address lender, address borrower) = _distressFull();
        Market storage m = _m();

        uint256 bal = m.vault.balanceOf(lender);
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;

        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ILidoLendERC4626.ExceededBalance.selector, lender, bal + 1, bal));
        m.vault.settle(bal + 1, borrowers, lender, lender);
    }

    // ── on-behalf allowance: the settle leg's own burn ──

    /// @dev On an illiquid market the whole `fallbackExit` runs through the settle leg, whose burn spends the
    ///      caller's allowance separately from the (unused here) redeem leg. Verifies the allowance is decremented
    ///      by exactly the settled shares — not more, not the redeem leg's.
    function test_fallbackExit_onBehalf_settleLeg_spendsExactAllowance() public {
        (address owner, address borrower) = _distressFull(); // owner is the sole lender; market idle == 0
        Market storage m = _m();
        uint256 shares = m.vault.balanceOf(owner);

        address caller = _actor("caller");
        vm.prank(owner);
        m.vault.approve(caller, shares + 1); // one extra, to prove the spend is exact

        ExitCheck memory c;
        c.sig = FALLBACK_EXIT_SIG;
        (c.caller, c.owner, c.receiver, c.borrower) = (caller, owner, caller, borrower);
        c.borrowBefore = m.core.market(m.id).totalBorrowAssets;
        c.collatBefore = m.core.position(m.id, borrower).collateral;
        c.supplyBefore = m.vault.totalSupply();
        c.receiverCollatBefore = m.collateralToken.balanceOf(caller);

        // The gas-sized default (0) stops before this book drains; each resumed call must spend
        // allowance for exactly what it settles, checked call by call against core deltas.
        uint256 totalBurned;
        // terminates: a call that burns nothing reverts NothingSettled
        while (m.vault.balanceOf(owner) != 0) {
            c.borrowBefore = m.core.market(m.id).totalBorrowAssets;
            c.collatBefore = m.core.position(m.id, borrower).collateral;
            c.supplyBefore = m.vault.totalSupply();
            c.receiverCollatBefore = m.collateralToken.balanceOf(caller);

            uint256 remaining = m.vault.balanceOf(owner); // read before prank: the prank binds to the next call
            vm.recordLogs();
            vm.prank(caller);
            uint256 loanAssets;
            (c.burned, loanAssets, c.collateralSeized, c.debtCanceled) =
                m.vault.fallbackExit(remaining, caller, owner, 0);

            // Idle is zero, so the redeem leg pays nothing and the whole call is the settle leg.
            c.assetsWithdrawn = loanAssets;
            c.sharesSettled = c.burned;
            assertEq(loanAssets, 0, "no idle: the redeem leg paid nothing");
            _assertExitEffects(c); // full state + the FallbackExit event, amounts recomputed from core deltas
            totalBurned += c.burned;
        }
        assertEq(totalBurned, shares, "the whole position exited via the settle leg");
        assertEq(m.vault.balanceOf(owner), 0, "owner's shares burned");
        assertEq(m.vault.allowance(owner, caller), 1, "settle-leg spent exactly the settled shares");
    }

    /// @dev With idle liquidity present both legs run, so the event's three amounts are three different numbers:
    ///      `sharesBurned` (whole call), `sharesSettled` (settle leg alone) and `assetsWithdrawn` (liquid leg alone).
    ///      The settle-leg-only test above cannot tell them apart, since there they coincide.
    function test_fallbackExit_bothLegs_eventSplitsTheLegs() public {
        (address owner, address borrower) = _distressFull();
        Market storage m = _m();

        // A second lender's deposit is idle liquidity the first lender's exit can redeem. It leaves the borrower's
        // health untouched, so the settle leg still finds an eligible root.
        address other = _actor("other");
        _fund(m.loanToken, other, 10 ether);
        m.vaultDeposit(other, 10 ether);

        uint256 shares = m.vault.balanceOf(owner);
        uint256 liquid = m.controller.maxWithdrawableAssets(address(m.vault));
        assertGt(liquid, 0, "there is idle liquidity for the liquid leg");
        assertGt(m.vault.previewRedeem(shares), liquid, "and the request outruns it, so the settle leg runs too");
        uint256 liquidBurn = m.vault.previewWithdraw(liquid);

        ExitCheck memory c;
        c.sig = FALLBACK_EXIT_SIG;
        (c.caller, c.owner, c.receiver, c.borrower) = (owner, owner, owner, borrower);
        c.borrowBefore = m.core.market(m.id).totalBorrowAssets;
        c.collatBefore = m.core.position(m.id, borrower).collateral;
        c.supplyBefore = m.vault.totalSupply();
        c.receiverCollatBefore = m.collateralToken.balanceOf(owner);

        vm.recordLogs();
        vm.prank(owner);
        (c.burned, c.assetsWithdrawn, c.collateralSeized, c.debtCanceled) =
            m.vault.fallbackExit(shares, owner, owner, 0);
        c.sharesSettled = c.burned - liquidBurn; // recomputed independently, not read back off the event

        assertEq(c.assetsWithdrawn, liquid, "the liquid leg paid out the whole idle amount");
        assertGt(c.sharesSettled, 0, "the settle leg burned shares of its own");
        assertLt(c.sharesSettled, c.burned, "so the settle-leg burn is strictly under the whole-call burn");
        assertGt(c.collateralSeized, 0, "the settle leg cut a position");
        _assertExitEffects(c);
    }

    /// @dev A request serviced entirely from liquidity never reaches the settle leg but still emits `FallbackExit`,
    ///      with both settle-leg amounts zero — one event per successful call regardless of the path taken.
    function test_fallbackExit_fullyLiquid_emitsEventWithZeroSettleLeg() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        uint256 shares = m.vault.balanceOf(lender);
        uint256 expectedAssets = m.vault.previewRedeem(shares);
        assertLe(expectedAssets, m.controller.maxWithdrawableAssets(address(m.vault)), "the whole request is liquid");
        uint256 recvLoanBefore = m.loanToken.balanceOf(lender);

        // `c.borrower` stays address(0) — the zero position never moves, matching the zero seizure — and
        // `c.sharesSettled` stays 0: the settle leg must not run.
        ExitCheck memory c;
        c.sig = FALLBACK_EXIT_SIG;
        (c.caller, c.owner, c.receiver) = (lender, lender, lender);
        c.borrowBefore = m.core.market(m.id).totalBorrowAssets;
        c.supplyBefore = m.vault.totalSupply();
        c.receiverCollatBefore = m.collateralToken.balanceOf(lender);

        vm.recordLogs();
        vm.prank(lender);
        (c.burned, c.assetsWithdrawn, c.collateralSeized, c.debtCanceled) =
            m.vault.fallbackExit(shares, lender, lender, 0);

        assertEq(c.burned, shares, "the liquid leg serviced the whole request");
        assertEq(c.assetsWithdrawn, expectedAssets, "paid the request's floor-rounded value");
        assertEq(m.loanToken.balanceOf(lender), recvLoanBefore + expectedAssets, "receiver got the loan assets");
        assertEq(c.collateralSeized, 0, "no settle leg, nothing seized");
        assertEq(c.debtCanceled, 0, "no settle leg, no debt canceled");
        _assertExitEffects(c);
    }

    /// @dev The same leg reverts when the caller's allowance is short of the settled shares.
    function test_fallbackExit_onBehalf_settleLeg_insufficientAllowance_reverts() public {
        (address owner,) = _distressFull();
        Market storage m = _m();
        uint256 shares = m.vault.balanceOf(owner);

        address caller = _actor("caller");
        vm.prank(owner);
        m.vault.approve(caller, shares - 1); // one short of the settled shares

        // The gas-sized default (0) partial-fills within the allowance; the resumed call settles
        // the full remainder, which exceeds what is left of the one-short allowance.
        vm.prank(caller);
        (uint256 firstBurn,,,) = m.vault.fallbackExit(shares, caller, owner, 0);
        assertLt(firstBurn, shares - 1, "first call stays within the allowance");

        uint256 remainder = shares - firstBurn;
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, caller, shares - 1 - firstBurn, remainder
            )
        );
        m.vault.fallbackExit(remainder, caller, owner, 0);
    }

    /// @dev Targeted `settle` on behalf of the owner spends the caller's allowance by exactly the shares burned.
    function test_settle_onBehalf_spendsExactAllowance() public {
        (address owner, address borrower) = _distressFull();
        Market storage m = _m();
        uint256 shares = m.vault.balanceOf(owner);

        vm.prank(borrower);
        m.controller.setSettlementLtv(1); // targeted settlement requires a positive personal slice

        address caller = _actor("caller");
        vm.prank(owner);
        m.vault.approve(caller, shares);

        // The settle + its liquidity/debt/collateral conservation checks run in a helper to keep this frame under
        // the stack limit (`via_ir = false`); it returns the shares burned so the allowance spend is checked here.
        uint256 sharesBurned = _settleOnBehalf(owner, borrower, caller, shares);

        assertEq(m.vault.balanceOf(owner), shares - sharesBurned, "owner's shares reduced by the burn");
        assertEq(m.vault.allowance(owner, caller), shares - sharesBurned, "allowance spent exactly the burned shares");
    }

    /// @dev Run a targeted on-behalf `settle` (collateral to the caller) and assert its full effects and the
    ///      `Settled` event via `_assertExitEffects`. Split out to keep the caller's frame under the stack limit
    ///      (`via_ir = false`); returns the shares burned so the allowance spend is checked at the call site.
    function _settleOnBehalf(address owner, address borrower, address caller, uint256 shares)
        private
        returns (uint256 sharesBurned)
    {
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;

        ExitCheck memory c;
        c.sig = SETTLED_SIG;
        (c.caller, c.owner, c.receiver, c.borrower) = (caller, owner, caller, borrower);
        c.borrowBefore = _m().core.market(_m().id).totalBorrowAssets;
        c.collatBefore = _m().core.position(_m().id, borrower).collateral;
        c.supplyBefore = _m().vault.totalSupply();
        c.receiverCollatBefore = _m().collateralToken.balanceOf(caller);

        vm.recordLogs();
        vm.prank(caller);
        (sharesBurned, c.collateralSeized, c.debtCanceled) = _m().vault.settle(shares, borrowers, caller, owner);
        c.burned = sharesBurned;

        _assertExitEffects(c);
    }
}
