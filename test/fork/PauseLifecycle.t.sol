// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IIrm} from "@lido-lend/src/interfaces/IIrm.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";

import {IPausableUntil} from "../../src/interfaces/IPausableUntil.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @dev The deployed emergency-pause manager (`lib/circuit-breaker`, own solc). `pause` is single-use per
///      registration: the pauser is unregistered as it fires.
interface ICircuitBreaker {
    error SenderNotPauser();

    event PauseTriggered(address indexed pausable, address indexed pauser, uint256 pauseDuration);

    function pause(address pausable) external;
    function getPauser(address pausable) external view returns (address);
    function isPauserLive(address pauser) external view returns (bool);
    function pauseDuration() external view returns (uint256);
}

/// @notice The deployed pause path on one market: the circuit breaker fires as its registered pauser, single-use,
///         and the reseal manager pauses and is the only resumer. Paused, hooked actions refuse, the vault's limits
///         read zero, share transfers still work, and interest is booked only on the first action after resume.
contract PauseLifecycleForkTest is ForkStack {
    using MarketActions for Market;
    using MathLib for uint256;

    uint256 internal constant SHORT_PAUSE = 1 days;

    ICircuitBreaker internal circuitBreaker;
    address internal resealManager;
    address internal STRANGER;

    function setUp() public {
        _onlyOnWethWsteth();
        _setUpTarget();
        circuitBreaker = ICircuitBreaker(protocol.circuitBreaker);
        resealManager = _resealManager();
        STRANGER = _freshActor(market, "pause.stranger");
        _seedLenderAndBorrower();
    }

    // ---
    // CIRCUIT BREAKER
    // ---

    /// @dev The registered pauser fires once: both contracts emit, the controller is paused for exactly
    ///      `pauseDuration`, and the registration is consumed.
    function test_cbPause_registeredPauserPausesForPauseDuration_registrationConsumed() public {
        address pauser = _livePauserOrSkip();
        uint256 duration = circuitBreaker.pauseDuration();

        vm.expectEmit(true, true, true, true, address(market.controller));
        emit PausableUntil.Paused(duration);
        vm.expectEmit(true, true, true, true, address(circuitBreaker));
        emit ICircuitBreaker.PauseTriggered(address(market.controller), pauser, duration);
        vm.prank(pauser);
        circuitBreaker.pause(address(market.controller));

        assertEq(
            IPausableUntil(address(market.controller)).getResumeSinceTimestamp(),
            block.timestamp + duration,
            "paused for exactly the circuit breaker's duration"
        );
        assertEq(circuitBreaker.getPauser(address(market.controller)), address(0), "registration consumed");
    }

    function testRevert_cbPause_secondPause_SenderNotPauser() public {
        address pauser = _pauseViaCircuitBreaker();
        _resume();

        vm.prank(pauser);
        vm.expectRevert(ICircuitBreaker.SenderNotPauser.selector);
        circuitBreaker.pause(address(market.controller));
    }

    function testRevert_cbPause_byStranger() public {
        vm.prank(STRANGER);
        vm.expectRevert(ICircuitBreaker.SenderNotPauser.selector);
        circuitBreaker.pause(address(market.controller));
    }

    // ---
    // RESEAL MANAGER
    // ---

    function test_resealPauseFor_thenResume() public {
        vm.expectEmit(true, true, true, true, address(market.controller));
        emit PausableUntil.Paused(SHORT_PAUSE);
        vm.prank(resealManager);
        market.controller.pauseFor(SHORT_PAUSE);
        assertEq(
            IPausableUntil(address(market.controller)).getResumeSinceTimestamp(),
            block.timestamp + SHORT_PAUSE,
            "paused for the requested duration"
        );

        vm.expectEmit(true, true, true, true, address(market.controller));
        emit PausableUntil.Resumed();
        _resume();
        assertFalse(IPausableUntil(address(market.controller)).isPaused(), "live again");
    }

    function test_resealResume_endsCbPause_depositWorksAgain() public {
        _pauseViaCircuitBreaker();
        _resume();

        uint256 topUp = _oneLoanToken();
        deal(address(market.loanToken), LENDER, topUp);
        market.vaultDeposit(LENDER, topUp);
    }

    function test_finitePause_expiresOnItsOwn() public {
        _pauseViaResealManager(SHORT_PAUSE);
        vm.warp(block.timestamp + SHORT_PAUSE + 1);

        assertFalse(IPausableUntil(address(market.controller)).isPaused(), "pause lapsed without a resume");
        uint256 topUp = _oneLoanToken();
        deal(address(market.loanToken), LENDER, topUp);
        market.vaultDeposit(LENDER, topUp);
    }

    // ---
    // WHILE PAUSED
    // ---

    /// @dev One hooked action stands for all of them: the controller's own error, from inside the core call.
    function testRevert_paused_borrow() public {
        _pauseViaResealManager(SHORT_PAUSE);
        vm.prank(BORROWER);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        market.core.borrow(market.params, 1, 0, BORROWER, BORROWER);
    }

    function test_paused_vaultLimitsAreZero() public {
        _pauseViaResealManager(SHORT_PAUSE);
        assertEq(market.vault.maxDeposit(LENDER), 0, "maxDeposit");
        assertEq(market.vault.maxMint(LENDER), 0, "maxMint");
        assertEq(market.vault.maxWithdraw(LENDER), 0, "maxWithdraw");
        assertEq(market.vault.maxRedeem(LENDER), 0, "maxRedeem");
    }

    function testRevert_paused_vaultDeposit_maxGuard() public {
        uint256 assets = _oneLoanToken();
        deal(address(market.loanToken), LENDER, assets);
        _approve(address(market.loanToken), LENDER, address(market.vault), assets);
        _pauseViaResealManager(SHORT_PAUSE);

        vm.prank(LENDER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, LENDER, assets, 0)
        );
        market.vault.deposit(assets, LENDER);
    }

    function test_paused_shareTransferStillWorks() public {
        _pauseViaResealManager(SHORT_PAUSE);
        uint256 amount = lenderShares / 3;
        vm.prank(LENDER);
        market.vault.transfer(STRANGER, amount);
        assertEq(market.vault.balanceOf(STRANGER), amount, "shares moved");
        assertEq(market.vault.balanceOf(LENDER), lenderShares - amount, "sender debited");
    }

    /// @dev Accrual is hooked, so a live pause refuses it; the first accrual after resume books the whole gap in one
    ///      step, sized by the IRM's rate for it.
    function test_paused_interestNotBookedUntilResume() public {
        MorphoMarket memory before = market.core.market(market.id);
        _pauseViaResealManager(3 days);
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        market.core.accrueInterest(market.params);
        _resume();

        uint256 elapsed = block.timestamp - before.lastUpdate;
        uint256 rate = IIrm(market.params.irm).borrowRateView(market.params, before);
        uint256 interest = uint256(before.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(elapsed));
        assertGt(interest, 0, "setup: the gap must carry interest");

        market.core.accrueInterest(market.params);
        MorphoMarket memory resumed = market.core.market(market.id);
        assertEq(resumed.totalBorrowAssets, before.totalBorrowAssets + interest, "gap booked in one step");
        assertEq(resumed.lastUpdate, block.timestamp, "clock caught up");
    }

    // ---
    // REFUSALS
    // ---

    function testRevert_resume_byAgent() public {
        _pauseViaResealManager(SHORT_PAUSE);
        address agent = _admin();
        bytes32 role = market.controller.RESUMER_ROLE();
        vm.prank(agent);
        vm.expectRevert(_missingRoleError(agent, role));
        market.controller.resume();
    }

    function testRevert_pauseFor_byExecutor() public {
        address executor = _executor();
        bytes32 role = market.controller.PAUSER_ROLE();
        vm.prank(executor);
        vm.expectRevert(_missingRoleError(executor, role));
        market.controller.pauseFor(SHORT_PAUSE);
    }

    // ---
    // HELPERS
    // ---

    /// @dev The controller's registered pauser, or a skip when its heartbeat has lapsed at the forked block: on a
    ///      production run that is the committee's liveness, not a code fact.
    function _livePauserOrSkip() internal returns (address pauser) {
        pauser = circuitBreaker.getPauser(address(market.controller));
        require(pauser != address(0), "PauseLifecycle: no pauser registered for the controller");
        if (!circuitBreaker.isPauserLive(pauser)) vm.skip(true, "PauseLifecycle: pauser heartbeat has lapsed");
    }

    function _pauseViaCircuitBreaker() internal returns (address pauser) {
        pauser = _livePauserOrSkip();
        vm.prank(pauser);
        circuitBreaker.pause(address(market.controller));
    }

    function _resume() internal {
        vm.prank(resealManager);
        market.controller.resume();
    }
}
