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
import {ForkMarketStack} from "./helpers/ForkMarketStack.sol";

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
abstract contract PauseLifecycleForkBase is ForkMarketStack {
    using MarketActions for Market;
    using MathLib for uint256;

    uint256 internal constant SHORT_PAUSE = 1 days;

    ICircuitBreaker internal circuitBreaker;
    address internal resealManager;
    address internal STRANGER;

    constructor(string memory role) ForkMarketStack(role) {}

    function setUp() public {
        _fork();
        _bindRole();
        circuitBreaker = ICircuitBreaker(_protocol("circuit_breaker"));
        resealManager = _resealManager();
        STRANGER = _freshActor(deployed, "pause.stranger");
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

        vm.expectEmit(true, true, true, true, address(deployed.controller));
        emit PausableUntil.Paused(duration);
        vm.expectEmit(true, true, true, true, address(circuitBreaker));
        emit ICircuitBreaker.PauseTriggered(address(deployed.controller), pauser, duration);
        vm.prank(pauser);
        circuitBreaker.pause(address(deployed.controller));

        assertEq(
            IPausableUntil(address(deployed.controller)).getResumeSinceTimestamp(),
            block.timestamp + duration,
            "paused for exactly the circuit breaker's duration"
        );
        assertEq(circuitBreaker.getPauser(address(deployed.controller)), address(0), "registration consumed");
    }

    function testRevert_cbPause_secondPause_SenderNotPauser() public {
        address pauser = _pauseViaCircuitBreaker();
        _resume();

        vm.prank(pauser);
        vm.expectRevert(ICircuitBreaker.SenderNotPauser.selector);
        circuitBreaker.pause(address(deployed.controller));
    }

    function testRevert_cbPause_byStranger() public {
        vm.prank(STRANGER);
        vm.expectRevert(ICircuitBreaker.SenderNotPauser.selector);
        circuitBreaker.pause(address(deployed.controller));
    }

    // ---
    // RESEAL MANAGER
    // ---

    function test_resealPauseFor_thenResume() public {
        vm.expectEmit(true, true, true, true, address(deployed.controller));
        emit PausableUntil.Paused(SHORT_PAUSE);
        vm.prank(resealManager);
        deployed.controller.pauseFor(SHORT_PAUSE);
        assertEq(
            IPausableUntil(address(deployed.controller)).getResumeSinceTimestamp(),
            block.timestamp + SHORT_PAUSE,
            "paused for the requested duration"
        );

        vm.expectEmit(true, true, true, true, address(deployed.controller));
        emit PausableUntil.Resumed();
        _resume();
        assertFalse(IPausableUntil(address(deployed.controller)).isPaused(), "live again");
    }

    function test_resealResume_endsCbPause_depositWorksAgain() public {
        _pauseViaCircuitBreaker();
        _resume();

        uint256 topUp = _loanUnit(deployed);
        deal(address(deployed.loanToken), LENDER, topUp);
        market.vaultDeposit(LENDER, topUp);
    }

    function test_finitePause_expiresOnItsOwn() public {
        _pauseViaResealManager(deployed, SHORT_PAUSE);
        vm.warp(block.timestamp + SHORT_PAUSE + 1);

        assertFalse(IPausableUntil(address(deployed.controller)).isPaused(), "pause lapsed without a resume");
        uint256 topUp = _loanUnit(deployed);
        deal(address(deployed.loanToken), LENDER, topUp);
        market.vaultDeposit(LENDER, topUp);
    }

    // ---
    // WHILE PAUSED
    // ---

    /// @dev One hooked action stands for all of them: the controller's own error, from inside the core call.
    function testRevert_paused_borrow() public {
        _pauseViaResealManager(deployed, SHORT_PAUSE);
        vm.prank(BORROWER);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        deployed.core.borrow(deployed.params, 1, 0, BORROWER, BORROWER);
    }

    function test_paused_vaultLimitsAreZero() public {
        _pauseViaResealManager(deployed, SHORT_PAUSE);
        assertEq(deployed.vault.maxDeposit(LENDER), 0, "maxDeposit");
        assertEq(deployed.vault.maxMint(LENDER), 0, "maxMint");
        assertEq(deployed.vault.maxWithdraw(LENDER), 0, "maxWithdraw");
        assertEq(deployed.vault.maxRedeem(LENDER), 0, "maxRedeem");
    }

    function testRevert_paused_vaultDeposit_maxGuard() public {
        uint256 assets = _loanUnit(deployed);
        deal(address(deployed.loanToken), LENDER, assets);
        _approve(address(deployed.loanToken), LENDER, address(deployed.vault), assets);
        _pauseViaResealManager(deployed, SHORT_PAUSE);

        vm.prank(LENDER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, LENDER, assets, 0)
        );
        deployed.vault.deposit(assets, LENDER);
    }

    function test_paused_shareTransferStillWorks() public {
        _pauseViaResealManager(deployed, SHORT_PAUSE);
        uint256 amount = lenderShares / 3;
        vm.prank(LENDER);
        deployed.vault.transfer(STRANGER, amount);
        assertEq(deployed.vault.balanceOf(STRANGER), amount, "shares moved");
        assertEq(deployed.vault.balanceOf(LENDER), lenderShares - amount, "sender debited");
    }

    /// @dev Accrual is hooked, so a live pause refuses it; the first accrual after resume books the whole gap in one
    ///      step, sized by the IRM's rate for it.
    function test_paused_interestNotBookedUntilResume() public {
        MorphoMarket memory before = deployed.core.market(deployed.id);
        _pauseViaResealManager(deployed, 3 days);
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        deployed.core.accrueInterest(deployed.params);
        _resume();

        uint256 elapsed = block.timestamp - before.lastUpdate;
        uint256 rate = IIrm(deployed.params.irm).borrowRateView(deployed.params, before);
        uint256 interest = uint256(before.totalBorrowAssets).wMulDown(rate.wTaylorCompounded(elapsed));
        assertGt(interest, 0, "setup: the gap must carry interest");

        deployed.core.accrueInterest(deployed.params);
        MorphoMarket memory resumed = deployed.core.market(deployed.id);
        assertEq(resumed.totalBorrowAssets, before.totalBorrowAssets + interest, "gap booked in one step");
        assertEq(resumed.lastUpdate, block.timestamp, "clock caught up");
    }

    // ---
    // REFUSALS
    // ---

    function testRevert_resume_byAgent() public {
        _pauseViaResealManager(deployed, SHORT_PAUSE);
        address agent = _admin();
        bytes32 role = deployed.controller.RESUMER_ROLE();
        vm.prank(agent);
        vm.expectRevert(_unauthorized(agent, role));
        deployed.controller.resume();
    }

    function testRevert_pauseFor_byExecutor() public {
        address executor = _executor();
        bytes32 role = deployed.controller.PAUSER_ROLE();
        vm.prank(executor);
        vm.expectRevert(_unauthorized(executor, role));
        deployed.controller.pauseFor(SHORT_PAUSE);
    }

    // ---
    // HELPERS
    // ---

    /// @dev The controller's registered pauser, or a skip when its heartbeat has lapsed at the forked block: on a
    ///      production run that is the committee's liveness, not a code fact.
    function _livePauserOrSkip() internal returns (address pauser) {
        pauser = circuitBreaker.getPauser(address(deployed.controller));
        require(pauser != address(0), "PauseLifecycle: no pauser registered for the controller");
        if (!circuitBreaker.isPauserLive(pauser)) vm.skip(true, "PauseLifecycle: pauser heartbeat has lapsed");
    }

    function _pauseViaCircuitBreaker() internal returns (address pauser) {
        pauser = _livePauserOrSkip();
        vm.prank(pauser);
        circuitBreaker.pause(address(deployed.controller));
    }

    function _resume() internal {
        vm.prank(resealManager);
        deployed.controller.resume();
    }
}

contract PauseLifecycleWethWstethForkTest is PauseLifecycleForkBase("weth-wsteth") {}

contract PauseLifecycleUsdyUsdtForkTest is PauseLifecycleForkBase("usdy-usdt") {}
