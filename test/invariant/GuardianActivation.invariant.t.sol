// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";

import {GuardianActivationHandler} from "./handlers/GuardianActivationHandler.sol";

/// @notice Stateful invariants that connect the guardian registry to the policy that reads it. The market in
///         this suite has a non-zero frontier fallback and a non-zero per-suspect delay.
/// @dev This configuration is necessary. `ActivationInflowHandler` sets the fallback to zero, and
///      `MarketSolvency` gives instant activation to each actor. No other suite tests the surcharge arithmetic
///      or the frontier gate.
///
///      The suite computes the unlock time from the start and the base delay of the lot. It does not read the
///      unlock time from the controller, because that value is the value under test. The handler asserts the
///      maturation decision.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 128
contract GuardianActivationInvariant is LidoLendSetup {
    GuardianActivationHandler internal handler;

    address internal constant GUARDIAN_1 = address(0x6001);
    address internal constant GUARDIAN_2 = address(0x6002);
    address internal constant GUARDIAN_3 = address(0x6003);

    /// @dev These values match the hoodi markets, where the fallback is active. The fallback is 36 hours. The
    ///      maximum base delay is two hours. Each strike and each suspect report adds two hours.
    uint40 internal constant QUORUM_FALLBACK = 36 hours;
    uint40 internal constant DELAY_PER_SIGNAL = 2 hours;

    uint256 internal constant LENDER_DEPOSIT = 1_000_000 ether;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_000_000);

        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);

        DeployConfig memory cfg = _defaultConfig(address(loan), address(collateral), address(collateral));
        // The configuration under test. The frontier gate and the suspect surcharge are both active.
        cfg.activation.maxGuardiansQuorumDelay = QUORUM_FALLBACK;
        cfg.activation.delayPerStrike = DELAY_PER_SIGNAL;
        cfg.activation.delayPerSuspect = DELAY_PER_SIGNAL;
        cfg.guardians = new address[](3);
        cfg.guardians[0] = GUARDIAN_1;
        cfg.guardians[1] = GUARDIAN_2;
        cfg.guardians[2] = GUARDIAN_3;
        cfg.quorum = 2;
        cfg.suspectWindow = 1 hours;

        Market storage m = _deployProtocol(cfg);

        // One lender supplies the loan tokens that the borrow calls use.
        _fund(m.loanToken, address(this), LENDER_DEPOSIT);
        m.loanToken.approve(address(m.vault), type(uint256).max);
        m.vault.deposit(LENDER_DEPOSIT, address(this));

        address[3] memory borrowers = [_actor("alice"), _actor("bob"), _actor("carol")];
        handler = new GuardianActivationHandler(
            m.core, m.controller, m.guardianSignals, m.oracle, m.loanToken, m.collateralToken, m.params, m.id, borrowers
        );

        // The handler sends the governance overrides and the committee changes, and it therefore needs the two
        // override roles and `MANAGER_ROLE`. `initialize` grants none of them, and the deploy base grants
        // `MANAGER_ROLE` to the admin only.
        GuardianSignals gs = GuardianSignals(address(m.guardianSignals));
        gs.grantRole(gs.ACCESS_LIMITER_ROLE(), address(handler));
        gs.grantRole(gs.ACCESS_RESTORER_ROLE(), address(handler));
        gs.grantRole(gs.MANAGER_ROLE(), address(handler));

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = GuardianActivationHandler.doSupplyCollateral.selector;
        selectors[1] = GuardianActivationHandler.doBorrow.selector;
        selectors[2] = GuardianActivationHandler.doRepay.selector;
        selectors[3] = GuardianActivationHandler.doFlag.selector;
        selectors[4] = GuardianActivationHandler.doUnflag.selector;
        selectors[5] = GuardianActivationHandler.doSuspect.selector;
        selectors[6] = GuardianActivationHandler.doUnsuspect.selector;
        selectors[7] = GuardianActivationHandler.doBan.selector;
        selectors[8] = GuardianActivationHandler.doHeartbeatQuorum.selector;
        selectors[9] = GuardianActivationHandler.doWarp.selector;
        // Without `doUnban` a ban lasts until the end of the run, and no banned lot matures.
        selectors[10] = GuardianActivationHandler.doUnban.selector;
        selectors[11] = GuardianActivationHandler.doSetQuorum.selector;
        selectors[12] = GuardianActivationHandler.doReplaceGuardian.selector;
        selectors[13] = GuardianActivationHandler.doSetSuspectWindow.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The formula of `docs/specs/market-controller.md` "Collateral activation":
    ///
    ///          unlockTime = activatingStart + storedBaseDelay
    ///                     + strikeCount * delayPerStrike
    ///                     + suspectCount * delayPerSuspect   when activatingStart < suspectExpiryTimestamp
    ///
    ///      This is an equality and not a limit. One more strike, or one more counted report, must move the
    ///      unlock time by one delay unit. A banned borrower has no finite unlock time.
    function invariant_unlockEqualsStartPlusBaseDelayPlusSignalSurcharge() public view {
        Market storage m = protocol.markets[0];
        for (uint256 i; i < handler.borrowerCount(); ++i) {
            address borrower = handler.borrowerAt(i);
            if (m.controller.positionOf(borrower).activating == 0) continue;

            assertEq(
                m.controller.positionOf(borrower).unlockTime,
                handler.modelUnlockTime(borrower),
                "unlockTime != the value from the specification"
            );
        }
    }

    /// @dev These counts show how the campaign matured the lots. A non-zero `maturedOnFallback` count shows
    ///      that lots matured without scan evidence.
    function afterInvariant() public {
        emit log_named_uint("supplies", handler.supplies());
        emit log_named_uint("borrows", handler.borrows());
        emit log_named_uint("signals", handler.signals());
        emit log_named_uint("configChanges", handler.configChanges());
        emit log_named_uint("maturations", handler.maturations());
        emit log_named_uint("maturedOnFrontier", handler.maturedOnFrontier());
        emit log_named_uint("maturedOnFallback", handler.maturedOnFallback());
    }

    /// @dev The deadline starts at the lot start. The surcharge increases the unlock time only. If the base
    ///      delay and the surcharge together reach the fallback window, the deadline is always earlier than the
    ///      unlock time. The lot then matures without scan evidence.
    ///
    ///      The specification permits this result, and the test therefore asserts it as the expected value. If
    ///      a later change measures the deadline from the unlock time, this test fails. The campaign above
    ///      cannot reach this state. Three guardians at two hours for each signal stay inside the 36-hour
    ///      window.
    function test_largeSurchargeDischargesTheFrontierRequirement() public {
        Market storage m = protocol.markets[0];
        address borrower = _actor("dave");

        // Three reports at twelve hours each reach the 36-hour window. The base delay moves the unlock time
        // past the window, and the deadline is therefore earlier than the unlock time.
        CollateralActivationConfig memory cfg = m.controller.collateralActivationConfig();
        cfg.delayPerSuspect = 12 hours;
        m.controller.setCollateralActivationConfig(cfg);

        _fund(m.collateralToken, borrower, 1000 ether);
        vm.startPrank(borrower);
        m.collateralToken.approve(address(m.core), type(uint256).max);
        m.core.supplyCollateral(m.params, 100 ether, borrower, "");
        vm.stopPrank();

        uint256 lotStart = block.timestamp;
        for (uint256 i; i < 3; ++i) {
            address guardian = i == 0 ? GUARDIAN_1 : (i == 1 ? GUARDIAN_2 : GUARDIAN_3);
            vm.prank(guardian);
            m.guardianSignals.suspect(m.id, guardian, _one(borrower));
        }

        uint256 unlock = m.controller.positionOf(borrower).unlockTime;
        uint256 deadline = lotStart + QUORUM_FALLBACK;
        assertGt(unlock, deadline, "the unlock time must be later than the fallback deadline");

        // The time is past the unlock time. The committee sent no heartbeat, so the frontier is still zero.
        vm.warp(unlock);
        assertEq(m.guardianSignals.getQuorumFrontier(), 0, "no guardian sent a heartbeat");
        assertLt(m.guardianSignals.getQuorumFrontier(), unlock, "the frontier is earlier than the unlock time");

        // The second deposit starts a sync. The first lot matures, so the bucket holds the new deposit only.
        vm.startPrank(borrower);
        m.core.supplyCollateral(m.params, 10 ether, borrower, "");
        vm.stopPrank();

        assertEq(
            m.controller.positionOf(borrower).activating,
            10 ether,
            "the lot matured on the fallback without scan evidence"
        );
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
