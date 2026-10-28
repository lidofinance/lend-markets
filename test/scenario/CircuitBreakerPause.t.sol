// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IPausableUntil} from "../../src/interfaces/IPausableUntil.sol";
import {PausableUntil} from "../../src/utils/PausableUntil.sol";
import {CircuitBreakerConfig, CircuitBreakerConfigFile} from "../../script/lib/CircuitBreakerConfigFile.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @dev ABI of `lib/circuit-breaker`'s CircuitBreaker. It compiles under its own solc, so the test deploys the
///      artifact instead of importing the source.
interface ICircuitBreaker {
    error SenderNotAdmin();
    error SenderNotPauser();
    error HeartbeatExpired();

    event PauseTriggered(address indexed pausable, address indexed pauser, uint256 pauseDuration);

    function MAX_PAUSE_DURATION() external view returns (uint256);
    function pauseDuration() external view returns (uint256);
    function heartbeatInterval() external view returns (uint256);
    function heartbeatExpiry(address pauser) external view returns (uint256);
    function getPauser(address pausable) external view returns (address);
    function isPauserLive(address pauser) external view returns (bool);
    function setPauseDuration(uint256 newPauseDuration) external;
    function registerPauser(address pausable, address newPauser) external;
    function heartbeat() external;
    function pause(address pausable) external;
}

/// @notice The real CircuitBreaker, deployed with the `lido-lend` profile bounds, on real market controllers. The
///         controllers get the roles the market factory grants: CircuitBreaker holds `PAUSER_ROLE`, and the Reseal
///         Manager holds `PAUSER_ROLE` and `RESUMER_ROLE`. A second market on the same core checks the pause scope.
///
///         The upstream suite tests CircuitBreaker against a mock pausable. This suite covers what only the real
///         controller decides: it rejects `pauseFor` while paused, and that revert rolls back the registration
///         consumption.
contract CircuitBreakerPauseTest is LidoLendSetup {
    using MarketActions for Market;

    ICircuitBreaker internal circuitBreaker;
    CircuitBreakerConfig internal profile;

    /// @dev CircuitBreaker `ADMIN`: the EVMScriptExecutor in production.
    address internal executor;
    /// @dev The pauser registered for market A only.
    address internal committee;
    /// @dev Stand-in for the Reseal Manager. Only its controller roles are modelled.
    address internal resealManager;
    address internal lender;

    function setUp() public {
        MockERC20 loanA = new MockERC20("LoanA", "LOANA", 18);
        MockERC20 collateralA = new MockERC20("CollateralA", "COLLA", 18);
        _deployProtocol(_defaultConfig(address(loanA), address(collateralA), address(collateralA)));
        MockERC20 loanB = new MockERC20("LoanB", "LOANB", 18);
        MockERC20 collateralB = new MockERC20("CollateralB", "COLLB", 18);
        _addMarket(_defaultConfig(address(loanB), address(collateralB), address(collateralB)));

        executor = _actor("executor");
        committee = _actor("pauserCommittee");
        resealManager = _actor("resealManager");
        lender = _actor("lender");

        profile = CircuitBreakerConfigFile.read("lido-lend");
        circuitBreaker = ICircuitBreaker(
            deployCode(
                "CircuitBreaker.sol:CircuitBreaker",
                abi.encode(
                    executor,
                    profile.minPauseDuration,
                    profile.maxPauseDuration,
                    profile.minHeartbeatInterval,
                    profile.maxHeartbeatInterval,
                    profile.initialPauseDuration,
                    profile.initialHeartbeatInterval
                )
            )
        );

        for (uint256 i; i < protocol.markets.length; ++i) {
            Market storage m = protocol.markets[i];
            m.controller.grantRole(m.controller.PAUSER_ROLE(), address(circuitBreaker));
            m.controller.grantRole(m.controller.PAUSER_ROLE(), resealManager);
            m.controller.grantRole(m.controller.RESUMER_ROLE(), resealManager);
        }

        vm.prank(executor);
        circuitBreaker.registerPauser(_controllerA(), committee);
    }

    function _a() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    function _b() internal view returns (Market storage) {
        return protocol.markets[1];
    }

    function _controllerA() internal view returns (address) {
        return address(_a().controller);
    }

    function _pausable(Market storage m) internal view returns (IPausableUntil) {
        return IPausableUntil(address(m.controller));
    }

    function _pauseA() internal returns (uint256 resumeSince) {
        vm.prank(committee);
        circuitBreaker.pause(_controllerA());
        resumeSince = _pausable(_a()).getResumeSinceTimestamp();
    }

    // ── Scope ──

    /// @dev One pause stops the registered controller for exactly the configured duration. The other market on the
    ///      same core keeps serving users, and the committee has no power over it.
    function test_cbPause_pausesOnlyRegisteredController_forExactDuration() public {
        Market storage a = _a();
        Market storage b = _b();
        uint256 duration = circuitBreaker.pauseDuration();
        assertEq(duration, profile.initialPauseDuration, "setup: profile duration");

        vm.expectEmit(true, true, true, true, address(a.controller));
        emit PausableUntil.Paused(duration);
        vm.expectEmit(true, true, true, true, address(circuitBreaker));
        emit ICircuitBreaker.PauseTriggered(address(a.controller), committee, duration);
        uint256 resumeSince = _pauseA();

        assertEq(resumeSince, block.timestamp + duration, "paused for exactly pauseDuration");
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        a.core.accrueInterest(a.params);

        assertFalse(_pausable(b).isPaused(), "market B untouched");
        _fund(b.loanToken, lender, 10 ether);
        b.vaultDeposit(lender, 10 ether);

        vm.prank(committee);
        vm.expectRevert(ICircuitBreaker.SenderNotPauser.selector);
        circuitBreaker.pause(address(b.controller));
    }

    // ── Single use ──

    /// @dev The pause consumes the registration and clears the committee's liveness. The market resumes at
    ///      `resumeSince` with no call, and the committee cannot pause it again.
    function test_cbPause_consumesRegistration_marketResumesOnItsOwn() public {
        uint256 resumeSince = _pauseA();

        assertEq(circuitBreaker.getPauser(_controllerA()), address(0), "registration consumed");
        assertEq(circuitBreaker.heartbeatExpiry(committee), 0, "liveness cleared");
        vm.prank(committee);
        vm.expectRevert(ICircuitBreaker.SenderNotPauser.selector);
        circuitBreaker.heartbeat();

        vm.warp(resumeSince - 1);
        assertTrue(_pausable(_a()).isPaused(), "paused through the last second");
        vm.warp(resumeSince);
        assertFalse(_pausable(_a()).isPaused(), "resumed at resumeSince");
        _a().accrueInterest();

        vm.prank(committee);
        vm.expectRevert(ICircuitBreaker.SenderNotPauser.selector);
        circuitBreaker.pause(_controllerA());
    }

    /// @dev A re-arm during the pause cannot extend it: the controller rejects `pauseFor` while paused, and the
    ///      revert rolls back the registration consumption.
    function testRevert_cbPause_rearmedMidPause_cannotExtend() public {
        uint256 resumeSince = _pauseA();
        vm.prank(executor);
        circuitBreaker.registerPauser(_controllerA(), committee);
        vm.warp(resumeSince - 1);

        vm.prank(committee);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        circuitBreaker.pause(_controllerA());

        assertEq(_pausable(_a()).getResumeSinceTimestamp(), resumeSince, "resumeSince unchanged");
        assertEq(circuitBreaker.getPauser(_controllerA()), committee, "registration kept");
    }

    // ── Wiring ──

    /// @dev Registration does not check the controller role. Without it, the pause reverts with the controller's
    ///      access error, and the registration stays for a later fix of the wiring.
    function testRevert_cbPause_withoutControllerRole_keepsRegistration() public {
        Market storage a = _a();
        bytes32 pauserRole = a.controller.PAUSER_ROLE();
        a.controller.revokeRole(pauserRole, address(circuitBreaker));

        vm.prank(committee);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(circuitBreaker), pauserRole
            )
        );
        circuitBreaker.pause(address(a.controller));

        assertEq(circuitBreaker.getPauser(address(a.controller)), committee, "registration kept");
        assertFalse(_pausable(a).isPaused(), "not paused");
    }

    /// @dev A Reseal Manager pause that is already active makes the CircuitBreaker pause revert. The registration
    ///      is not consumed, so the committee can still pause after the Reseal Manager resumes.
    function testRevert_cbPause_duringResealPause_registrationNotConsumed() public {
        Market storage a = _a();
        vm.prank(resealManager);
        a.controller.pauseFor(7 days);

        vm.prank(committee);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        circuitBreaker.pause(address(a.controller));
        assertEq(circuitBreaker.getPauser(address(a.controller)), committee, "registration not consumed");

        vm.prank(resealManager);
        a.controller.resume();
        uint256 resumeSince = _pauseA();
        assertEq(resumeSince, block.timestamp + circuitBreaker.pauseDuration(), "committee pause after the resume");
    }

    // ── Re-arm and liveness ──

    /// @dev Only the admin re-arms. A re-arm after expiry gives the committee one more pause and a fresh heartbeat.
    function test_cbRearm_afterExpiry_adminRegistersPauserAgain() public {
        vm.warp(_pauseA());

        vm.prank(committee);
        vm.expectRevert(ICircuitBreaker.SenderNotAdmin.selector);
        circuitBreaker.registerPauser(_controllerA(), committee);

        vm.prank(executor);
        circuitBreaker.registerPauser(_controllerA(), committee);
        assertEq(
            circuitBreaker.heartbeatExpiry(committee),
            block.timestamp + circuitBreaker.heartbeatInterval(),
            "fresh heartbeat window"
        );

        uint256 resumeSince = _pauseA();
        assertEq(resumeSince, block.timestamp + circuitBreaker.pauseDuration(), "second pause after the re-arm");
    }

    /// @dev Liveness ends at the expiry second. A heartbeat one second earlier extends it by the interval. An
    ///      expired pauser stays registered but cannot pause or heartbeat until the admin registers it again.
    function test_cbHeartbeat_expiresAtDeadline_adminRegistrationRevives() public {
        uint256 interval = profile.initialHeartbeatInterval;
        uint256 expiry = circuitBreaker.heartbeatExpiry(committee);
        assertEq(expiry, block.timestamp + interval, "setup: registration opened the window");

        vm.warp(expiry - 1);
        vm.prank(committee);
        circuitBreaker.heartbeat();
        uint256 extended = circuitBreaker.heartbeatExpiry(committee);
        assertEq(extended, expiry - 1 + interval, "heartbeat extends from now");

        vm.warp(extended);
        assertFalse(circuitBreaker.isPauserLive(committee), "expired at the expiry second");
        vm.prank(committee);
        vm.expectRevert(ICircuitBreaker.HeartbeatExpired.selector);
        circuitBreaker.pause(_controllerA());
        vm.prank(committee);
        vm.expectRevert(ICircuitBreaker.HeartbeatExpired.selector);
        circuitBreaker.heartbeat();
        assertEq(circuitBreaker.getPauser(_controllerA()), committee, "expired pauser stays registered");

        vm.prank(executor);
        circuitBreaker.registerPauser(_controllerA(), committee);
        assertTrue(circuitBreaker.isPauserLive(committee), "admin registration revives");
        _pauseA();
        assertTrue(_pausable(_a()).isPaused(), "paused after the revival");
    }

    // ── Open findings ──

    /// @dev Pins open finding I-M003: through the C-10-OQ-1 re-arm route, the admin chains maximum pauses with no
    ///      gap, one admin action per pause. A fix changes this outcome; update this test with the fix.
    function test_IM003_adminRearmAtResume_chainsBackToBackMaxPauses() public {
        uint256 maxPause = circuitBreaker.MAX_PAUSE_DURATION();
        assertEq(maxPause, profile.maxPauseDuration, "setup: profile bound");
        vm.prank(executor);
        circuitBreaker.setPauseDuration(maxPause);
        uint256 start = block.timestamp;

        vm.warp(_pauseA());
        assertFalse(_pausable(_a()).isPaused(), "first pause lapsed");
        vm.prank(executor);
        circuitBreaker.registerPauser(_controllerA(), committee);
        uint256 resumeSince = _pauseA();

        assertEq(resumeSince, start + 2 * maxPause, "two maximum pauses back to back");
        vm.warp(resumeSince - 1);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        _a().core.accrueInterest(_a().params);
    }

    /// @dev Pins open finding I-M003: the Reseal Manager's controller roles turn a bounded CircuitBreaker pause into
    ///      an indefinite one in one step. A fix changes this outcome; update this test with the fix.
    function test_IM003_resealRoles_turnCbPauseIndefinite() public {
        Market storage a = _a();
        _pauseA();

        vm.startPrank(resealManager);
        a.controller.resume();
        a.controller.pauseFor(type(uint256).max); // PAUSE_INFINITELY
        vm.stopPrank();
        assertEq(_pausable(a).getResumeSinceTimestamp(), type(uint256).max, "indefinite pause");

        vm.warp(block.timestamp + circuitBreaker.MAX_PAUSE_DURATION() + 1);
        assertTrue(_pausable(a).isPaused(), "still paused past the CircuitBreaker bound");

        vm.prank(executor);
        circuitBreaker.registerPauser(address(a.controller), committee);
        vm.prank(committee);
        vm.expectRevert(PausableUntil.ResumedExpected.selector);
        circuitBreaker.pause(address(a.controller));
    }
}
