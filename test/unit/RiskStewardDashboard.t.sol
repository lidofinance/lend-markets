// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {ILidoLendMarketConfigurator} from "../../src/interfaces/ILidoLendMarketConfigurator.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";

/// @dev Minimal controller stub: stores the config and lets the dashboard read-modify-write it. Local to this
///      file (no shared configurator mock exists in `test/setup/Mocks.sol`; the scenario suite drives the real
///      controller). The real controller's bound/order validation stays with the controller; here we isolate
///      the dashboard's tighten-only direction guard and the per-market steward gating.
contract MockMarketController is ILidoLendMarketConfigurator {
    CollateralActivationConfig internal _cfg;
    uint256 internal _cap;
    mapping(address => bool) public instantActivation;
    bool public frozen;

    function setForTest(CollateralActivationConfig memory cfg) external {
        _cfg = cfg;
    }

    function collateralActivationConfig() external view returns (CollateralActivationConfig memory) {
        return _cfg;
    }

    function setCollateralActivationConfig(CollateralActivationConfig calldata cfg) external {
        _cfg = cfg;
    }

    function setInstantActivation(address caller, bool enabled) external {
        instantActivation[caller] = enabled;
    }

    function supplyCap() external view returns (uint256) {
        return _cap;
    }

    function setSupplyCap(uint256 cap) external {
        _cap = cap;
    }

    function freeze() external {
        frozen = true;
    }
}

/// @dev Minimal core stub exposing only `marketController`, the one method the dashboard reads to resolve a
///      market id to its controller.
contract MockLidoLendCore {
    mapping(Id => address) internal _controller;

    function setController(Id id, address controller) external {
        _controller[id] = controller;
    }

    function marketController(Id id) external view returns (address) {
        return _controller[id];
    }
}

/// @dev Dashboard in isolation over mock core/controller: the tighten-only direction guard, per-market steward
///      gating, and the market-id -> controller resolution. The end-to-end run against a real controller lives
///      in `RiskStewardDashboardScenario.t.sol` (mainnet fork).
contract RiskStewardDashboardTest is Test {
    RiskStewardDashboard internal dashboard;
    MockLidoLendCore internal core;
    MockMarketController internal controller;
    MockMarketController internal otherController;
    address internal steward = address(0x57E);

    Id internal marketId = Id.wrap(bytes32(uint256(1)));
    Id internal otherMarketId = Id.wrap(bytes32(uint256(2)));
    Id internal unknownMarketId = Id.wrap(bytes32(uint256(0xDEAD)));

    function _baseConfig() internal pure returns (CollateralActivationConfig memory) {
        return CollateralActivationConfig({
            minActivationDelay: 1 minutes,
            maxActivationDelay: 1 hours,
            maxDelayInflow: 10_000 ether,
            activatingLockAmount: 5 ether,
            activatingLockDuration: 1 hours,
            minActivationAmount: 1,
            maxGuardiansQuorumDelay: 1 days,
            delayPerStrike: 1 hours,
            delayPerSuspect: 30 minutes
        });
    }

    function setUp() public {
        core = new MockLidoLendCore();
        dashboard = new RiskStewardDashboard(address(this), ILidoLend(address(core)));
        dashboard.grantRole(dashboard.STEWARD_ADMIN_ROLE(), address(this));

        controller = new MockMarketController();
        controller.setForTest(_baseConfig());
        otherController = new MockMarketController();
        otherController.setForTest(_baseConfig());

        core.setController(marketId, address(controller));
        core.setController(otherMarketId, address(otherController));

        dashboard.addMarketSteward(marketId, steward);
    }

    // ---
    // Stewards
    // ---

    /// @dev Appointment is additive and enumerable — and it GRANTS the levers: before it the candidate's lever
    ///      call reverts, after it the same call goes through.
    function test_addMarketSteward_appointsAndEnumerates() public {
        address second = address(0x5EC0);

        // Not a steward yet: the lever is gated.
        vm.prank(second);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.increaseActivationDelays(marketId, 5 minutes, 2 hours);

        vm.expectEmit(true, true, false, true);
        emit IRiskStewardDashboard.MarketStewardSet(marketId, second, true);
        dashboard.addMarketSteward(marketId, second);

        assertTrue(dashboard.isMarketSteward(marketId, steward), "first steward set");
        assertTrue(dashboard.isMarketSteward(marketId, second), "second steward set");

        address[] memory all = dashboard.marketStewards(marketId);
        assertEq(all.length, 2, "both stewards enumerated");
        assertEq(all[0], steward, "first enumerated");
        assertEq(all[1], second, "second enumerated");

        // Appointed: the same lever call now works.
        vm.prank(second);
        dashboard.increaseActivationDelays(marketId, 5 minutes, 2 hours);
        assertEq(controller.collateralActivationConfig().minActivationDelay, 5 minutes, "new steward's tighten landed");
    }

    /// @dev Removal drops the steward from the set, emits with `enabled = false` — and REVOKES the levers: the
    ///      ex-steward's lever call reverts where it succeeded before.
    function test_removeMarketSteward_dropsFromSet() public {
        // Sanity: the steward can pull a lever while appointed.
        vm.prank(steward);
        dashboard.increaseActivationDelays(marketId, 2 minutes, 1 hours);

        vm.expectEmit(true, true, false, true);
        emit IRiskStewardDashboard.MarketStewardSet(marketId, steward, false);
        dashboard.removeMarketSteward(marketId, steward);

        assertFalse(dashboard.isMarketSteward(marketId, steward), "steward removed");
        assertEq(dashboard.marketStewards(marketId).length, 0, "set empty after removal");

        // Removed: the same lever call is gated again.
        vm.prank(steward);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.increaseActivationDelays(marketId, 5 minutes, 2 hours);
        assertEq(controller.collateralActivationConfig().minActivationDelay, 2 minutes, "config untouched after revoke");
    }

    /// @dev Stewardship is per market id: an appointment on one market grants nothing on another.
    function test_marketStewards_isolatedPerMarket() public view {
        assertEq(dashboard.marketStewards(marketId).length, 1, "appointed market has the steward");
        assertEq(dashboard.marketStewards(otherMarketId).length, 0, "other market has none");
    }

    /// @dev Appointing is `STEWARD_ADMIN_ROLE`-gated: a steward cannot grow the roster itself.
    function testRevert_addMarketSteward_notAdmin() public {
        bytes32 role = dashboard.STEWARD_ADMIN_ROLE();
        vm.prank(steward); // a steward is not a STEWARD_ADMIN
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, steward, role));
        dashboard.addMarketSteward(marketId, address(0x1));
    }

    /// @dev Removal is `STEWARD_ADMIN_ROLE`-gated too: a steward cannot evict other stewards.
    function testRevert_removeMarketSteward_notAdmin() public {
        bytes32 role = dashboard.STEWARD_ADMIN_ROLE();
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, steward, role));
        dashboard.removeMarketSteward(marketId, steward);
    }

    // ---
    // increaseActivationDelays
    // ---

    /// @dev The happy tighten: both delays rise, the event fires, and the read-modify-write preserves every
    ///      unrelated config field.
    function test_increaseActivationDelays_raisesBoth() public {
        vm.expectEmit(true, false, false, true);
        emit IRiskStewardDashboard.ActivationDelaysIncreased(marketId, 5 minutes, 2 hours);
        vm.prank(steward);
        dashboard.increaseActivationDelays(marketId, 5 minutes, 2 hours);

        CollateralActivationConfig memory cfg = controller.collateralActivationConfig();
        assertEq(cfg.minActivationDelay, 5 minutes, "floor raised");
        assertEq(cfg.maxActivationDelay, 2 hours, "cap raised");
        assertEq(cfg.activatingLockAmount, 5 ether, "unrelated fields preserved by the read-modify-write");
    }

    /// @dev Boundary: equal values hold rather than loosen, so the `<` guard admits them.
    function test_increaseActivationDelays_holdIsAllowed() public {
        vm.prank(steward);
        dashboard.increaseActivationDelays(marketId, 1 minutes, 1 hours);

        CollateralActivationConfig memory cfg = controller.collateralActivationConfig();
        assertEq(cfg.minActivationDelay, 1 minutes, "floor held");
        assertEq(cfg.maxActivationDelay, 1 hours, "cap held");
    }

    /// @dev Lowering the floor is a loosening move: the direction guard rejects it.
    function testRevert_increaseActivationDelays_loweringFloor() public {
        vm.prank(steward);
        vm.expectRevert(IRiskStewardDashboard.NotTightened.selector);
        dashboard.increaseActivationDelays(marketId, 30 seconds, 2 hours);
    }

    /// @dev The other side of the `newMin < min || newMax < max` guard: a raised floor cannot smuggle a lowered cap.
    function testRevert_increaseActivationDelays_loweringCap() public {
        vm.prank(steward);
        vm.expectRevert(IRiskStewardDashboard.NotTightened.selector);
        dashboard.increaseActivationDelays(marketId, 5 minutes, 30 minutes);
    }

    /// @dev The lever is steward-gated: an unappointed caller is rejected before any controller call.
    function testRevert_increaseActivationDelays_notSteward() public {
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.increaseActivationDelays(marketId, 5 minutes, 2 hours);
    }

    /// @dev Stewardship does not travel across markets: an appointment on `marketId` grants no lever on
    ///      `otherMarketId`.
    function testRevert_steward_cannotActOnUnassignedMarket() public {
        // steward is appointed for `marketId`, not `otherMarketId`
        vm.prank(steward);
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.increaseActivationDelays(otherMarketId, 5 minutes, 2 hours);
    }

    /// @dev A market the core has no controller for resolves to zero and reverts `UnknownMarket`, even for an
    ///      appointed steward.
    function testRevert_unknownMarket_hasNoController() public {
        dashboard.addMarketSteward(unknownMarketId, steward); // appointed, but the core has no controller
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IRiskStewardDashboard.UnknownMarket.selector, unknownMarketId));
        dashboard.increaseActivationDelays(unknownMarketId, 5 minutes, 2 hours);
    }

    // ---
    // increaseActivatingLock
    // ---

    /// @dev The lock lever mirrors the delay lever: both fields rise, the event fires, unrelated fields survive.
    function test_increaseActivatingLock_raisesBoth() public {
        vm.expectEmit(true, false, false, true);
        emit IRiskStewardDashboard.ActivatingLockIncreased(marketId, 10 ether, 2 hours);
        vm.prank(steward);
        dashboard.increaseActivatingLock(marketId, 10 ether, 2 hours);

        CollateralActivationConfig memory cfg = controller.collateralActivationConfig();
        assertEq(cfg.activatingLockAmount, 10 ether, "lock amount raised");
        assertEq(cfg.activatingLockDuration, 2 hours, "lock duration raised");
        assertEq(cfg.minActivationDelay, 1 minutes, "unrelated fields preserved");
    }

    /// @dev Lowering the lock amount loosens the Sybil defense: rejected.
    function testRevert_increaseActivatingLock_loweringAmount() public {
        vm.prank(steward);
        vm.expectRevert(IRiskStewardDashboard.NotTightened.selector);
        dashboard.increaseActivatingLock(marketId, 1 ether, 2 hours);
    }

    /// @dev The other side of the lock's tighten guard: a raised amount cannot smuggle a shortened duration.
    function testRevert_increaseActivatingLock_loweringDuration() public {
        vm.prank(steward);
        vm.expectRevert(IRiskStewardDashboard.NotTightened.selector);
        dashboard.increaseActivatingLock(marketId, 10 ether, 30 minutes);
    }

    // ---
    // revokeInstantActivation
    // ---

    /// @dev Revocation is risk-reducing, so it has no direction guard: the dashboard just forwards the target
    ///      to the market's controller.
    function test_revokeInstantActivation_forwards() public {
        controller.setInstantActivation(address(0xBEEF), true);
        vm.prank(steward);
        dashboard.revokeInstantActivation(marketId, address(0xBEEF));
        assertFalse(controller.instantActivation(address(0xBEEF)), "revoke forwarded to controller");
    }

    /// @dev Still steward-gated: revocation is a lever like the others.
    function testRevert_revokeInstantActivation_notSteward() public {
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.revokeInstantActivation(marketId, address(0xBEEF));
    }

    function test_addMarketSteward_zeroReverts() public {
        vm.expectRevert(IRiskStewardDashboard.ZeroSteward.selector);
        dashboard.addMarketSteward(marketId, address(0));
    }

    function test_addMarketSteward_reAddEmitsNothing() public {
        vm.recordLogs();
        dashboard.addMarketSteward(marketId, steward);
        assertEq(vm.getRecordedLogs().length, 0, "no event on a no-op re-add");
    }

    function test_removeMarketSteward_nonStewardEmitsNothing() public {
        vm.recordLogs();
        dashboard.removeMarketSteward(marketId, address(0xBEEF));
        assertEq(vm.getRecordedLogs().length, 0, "no event when removing a non-steward");
    }

    function test_removeMarketSteward_actualRemoveEmits() public {
        vm.expectEmit(true, true, false, true);
        emit IRiskStewardDashboard.MarketStewardSet(marketId, steward, false);
        dashboard.removeMarketSteward(marketId, steward);
        assertFalse(dashboard.isMarketSteward(marketId, steward), "steward removed");
    }

    function test_revokeInstantActivation_emitsEvent() public {
        address caller = address(0xCA11E7);
        vm.expectEmit(true, true, false, true);
        emit IRiskStewardDashboard.InstantActivationRevoked(marketId, caller);
        vm.prank(steward);
        dashboard.revokeInstantActivation(marketId, caller);
        assertFalse(controller.instantActivation(caller), "controller revoke called");
    }

    function test_constructor_zeroAdminReverts() public {
        vm.expectRevert(IRiskStewardDashboard.ZeroAddress.selector);
        new RiskStewardDashboard(address(0), ILidoLend(address(core)));
    }

    function test_constructor_zeroCoreReverts() public {
        vm.expectRevert(IRiskStewardDashboard.ZeroAddress.selector);
        new RiskStewardDashboard(address(this), ILidoLend(address(0)));
    }

    // ---
    // freezeMarket
    // ---

    function test_freezeMarket_forwards() public {
        vm.prank(steward);
        dashboard.freezeMarket(marketId);
        assertTrue(controller.frozen(), "freeze forwarded to controller");
    }

    function testRevert_freezeMarket_notSteward() public {
        vm.expectRevert(IRiskStewardDashboard.NotMarketSteward.selector);
        dashboard.freezeMarket(marketId);
    }

    function testRevert_freezeMarket_unknownMarket() public {
        dashboard.addMarketSteward(unknownMarketId, steward);
        vm.prank(steward);
        vm.expectRevert(abi.encodeWithSelector(IRiskStewardDashboard.UnknownMarket.selector, unknownMarketId));
        dashboard.freezeMarket(unknownMarketId);
    }
}
