// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {GuardiansOpinion} from "../../src/types/GuardianSignalsTypes.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {GuardianSignalsHandler} from "./handlers/GuardianSignalsHandler.sol";

/// @notice Stateful invariants for the guardian-signal registry. The suite deploys the registry alone and uses
///         two market ids. The registry does not call the core and does not move tokens. A market therefore
///         gives no additional states.
/// @dev The handler holds a shadow model of the registry state. The model comes from the specification. A model
///      that reads its values from the registry agrees with each defect in the registry.
///
///      The handler asserts further properties. Each one compares the state before a call with the state after
///      the call, so each one is adjacent to its call.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 128
contract GuardianSignalsInvariant is Test {
    GuardianSignals internal gs;
    GuardianSignalsHandler internal handler;

    /// @dev The initial committee. The address pool of the handler starts with these three addresses.
    address internal constant GUARDIAN_1 = address(0x6001);
    address internal constant GUARDIAN_2 = address(0x6002);
    address internal constant GUARDIAN_3 = address(0x6003);

    uint256 internal constant INITIAL_QUORUM = 2;
    uint40 internal constant INITIAL_SUSPECT_WINDOW = 1 hours;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_000_000);

        address[] memory guardians = new address[](3);
        guardians[0] = GUARDIAN_1;
        guardians[1] = GUARDIAN_2;
        guardians[2] = GUARDIAN_3;

        address impl = address(new GuardianSignals());
        gs = GuardianSignals(
            address(
                new OssifiableProxy(
                    impl,
                    address(this),
                    abi.encodeWithSignature(
                        "initialize(address,address[],uint256)", address(this), guardians, INITIAL_QUORUM
                    )
                )
            )
        );

        // `initialize` sets the suspect window to zero. A non-zero window keeps a report active after its block.
        gs.grantRole(gs.MANAGER_ROLE(), address(this));
        gs.setSuspectWindow(INITIAL_SUSPECT_WINDOW);

        handler = new GuardianSignalsHandler(gs);
        gs.grantRole(gs.MANAGER_ROLE(), address(handler));
        gs.grantRole(gs.ACCESS_LIMITER_ROLE(), address(handler));
        gs.grantRole(gs.ACCESS_RESTORER_ROLE(), address(handler));

        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = GuardianSignalsHandler.doFlag.selector;
        selectors[1] = GuardianSignalsHandler.doUnflag.selector;
        selectors[2] = GuardianSignalsHandler.doSuspect.selector;
        selectors[3] = GuardianSignalsHandler.doUnsuspect.selector;
        selectors[4] = GuardianSignalsHandler.doPrune.selector;
        selectors[5] = GuardianSignalsHandler.doSyncFrontier.selector;
        selectors[6] = GuardianSignalsHandler.doBan.selector;
        selectors[7] = GuardianSignalsHandler.doUnban.selector;
        selectors[8] = GuardianSignalsHandler.doSetQuorum.selector;
        selectors[9] = GuardianSignalsHandler.doSetSuspectWindow.selector;
        selectors[10] = GuardianSignalsHandler.doAddGuardian.selector;
        selectors[11] = GuardianSignalsHandler.doRemoveGuardian.selector;
        selectors[12] = GuardianSignalsHandler.doReplaceGuardian.selector;
        selectors[13] = GuardianSignalsHandler.doHeartbeat.selector;
        // These two actions are necessary. Without a change of time, no suspect window expires. Without a
        // delegate, each signal uses the guardian route only.
        selectors[14] = GuardianSignalsHandler.doWarp.selector;
        selectors[15] = GuardianSignalsHandler.doSetDelegate.selector;
        // Without this action the committee stays near its initial size and never reaches the 32-seat limit.
        selectors[16] = GuardianSignalsHandler.doResizeCommittee.selector;
        selectors[17] = GuardianSignalsHandler.doStaleSignal.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev The result of `isBanned` is equal to `latch OR strikeCount >= quorum`. The test asserts both
    ///      directions. The registry has no getter for the latch, and this equality is the only way to read it.
    ///      If the quorum becomes larger than the flag count, the second term is false and only the latch
    ///      remains.
    function invariant_banEqualsLatchOrQuorum() public view {
        for (uint256 pair; pair < handler.pairCount(); ++pair) {
            Id market = handler.pairMarket(pair);
            address account = handler.pairAccount(pair);
            bool expected = handler.modelLatched(pair) || handler.modelStrikes(pair) >= gs.getQuorum();

            assertEq(gs.isBanned(market, account), expected, "isBanned != latch || strikes >= quorum");
            assertEq(gs.getOpinion(market, account).banned, expected, "getOpinion.banned != isBanned");
        }
    }

    /// @dev The registry state of each pair is equal to the model: each field of `getOpinion`, the flag set, and
    ///      the report set with its timestamps. A lost, extra or mis-timestamped signal therefore fails here.
    function invariant_registryMatchesModel() public view {
        for (uint256 pair; pair < handler.pairCount(); ++pair) {
            _assertOpinionMatchesModel(pair);
            _assertFlagSetMatchesModel(pair);
            _assertReportSetMatchesModel(pair);
        }
    }

    /// @dev The stored frontier and the stored heartbeats are equal to the model. The model applies the
    ///      specification. A heartbeat that moves its guardian from at or below `F` to above `F` sets
    ///      `max(F, candidate)`, a sync sets `max(F, candidate)`, and each other action keeps `F`. The model
    ///      never decreases, so this equality also asserts that the frontier never moves back. It also finds a
    ///      missed advance.
    function invariant_frontierMatchesModel() public view {
        assertEq(gs.getQuorumFrontier(), handler.modelFrontier(), "frontier != the model frontier");
        (address[] memory guardians, uint40[] memory timestamps) = gs.getHeartbeats();
        for (uint256 i; i < guardians.length; ++i) {
            assertEq(timestamps[i], handler.modelHeartbeat(guardians[i]), "heartbeat != the model heartbeat");
        }
    }

    /// @dev These counts show an empty campaign. The counts for each pair show the isolation property. If the
    ///      campaign used one market id only, it did not test the independence of the two ids.
    function afterInvariant() public {
        emit log_named_uint("flags", handler.flags());
        emit log_named_uint("unflags", handler.unflags());
        emit log_named_uint("suspects", handler.suspects());
        emit log_named_uint("unsuspects", handler.unsuspects());
        emit log_named_uint("prunes", handler.prunes());
        emit log_named_uint("pruneCountChecks", handler.pruneCountChecks());
        emit log_named_uint("rotations", handler.rotations());
        emit log_named_uint("delegatePromotions", handler.delegatePromotions());
        emit log_named_uint("maxCommitteeSize", handler.maxCommitteeSize());
        emit log_named_uint("capRejections", handler.capRejections());
        emit log_named_uint("quorumChanges", handler.quorumChanges());
        emit log_named_uint("windowChanges", handler.windowChanges());
        emit log_named_uint("frontierAdvances", handler.advances());
        emit log_named_uint("staleGuardianCalls", handler.staleGuardianCalls());
        emit log_named_uint("staleDelegateCalls", handler.staleDelegateCalls());
        emit log_named_uint("reassignedDelegateCalls", handler.reassignedDelegateCalls());
        for (uint256 pair; pair < handler.pairCount(); ++pair) {
            emit log_named_uint("pairTouches", handler.pairTouches(pair));
        }
    }

    function _assertOpinionMatchesModel(uint256 pair) internal view {
        GuardiansOpinion memory opinion = gs.getOpinion(handler.pairMarket(pair), handler.pairAccount(pair));
        assertEq(opinion.strikeCount, handler.modelStrikes(pair), "strikeCount != the model flags");
        assertEq(
            opinion.suspectCount, handler.modelSuspectCount(pair), "suspectCount != reports active at the last rebuild"
        );
        // The expiry uses the current window and not the window of the last rebuild.
        assertEq(
            opinion.suspectExpiryTimestamp,
            uint256(handler.modelSuspectReportedAt(pair)) + gs.getSuspectWindow(),
            "suspectExpiryTimestamp != the latest counted report + the current window"
        );
        assertEq(opinion.quorumFrontierTimestamp, handler.modelFrontier(), "opinion frontier != the model frontier");
    }

    /// @dev The registry set holds no duplicates. An equal size and the model membership of each entry
    ///      therefore give set equality.
    function _assertFlagSetMatchesModel(uint256 pair) internal view {
        address[] memory flaggedBy = gs.getFlaggedBy(handler.pairMarket(pair), handler.pairAccount(pair));
        assertEq(flaggedBy.length, handler.modelStrikes(pair), "flag set size != the model");
        for (uint256 i; i < flaggedBy.length; ++i) {
            assertTrue(handler.modelIsFlagged(pair, flaggedBy[i]), "the registry holds a flag that the model does not");
        }
    }

    function _assertReportSetMatchesModel(uint256 pair) internal view {
        (address[] memory reporters, uint40[] memory reportedAt) =
            gs.getSuspectedBy(handler.pairMarket(pair), handler.pairAccount(pair));
        assertEq(reporters.length, handler.modelReportCount(pair), "report set size != the model");
        for (uint256 i; i < reporters.length; ++i) {
            assertEq(reportedAt[i], handler.modelReportedAt(pair, reporters[i]), "report timestamp != the model");
        }
    }

    /// @dev The specification gives a warning. The 32-seat limit does not limit the stored signal sets of an
    ///      account, because a removal keeps the flag of the departed guardian. This test moves 40 identities
    ///      through one seat, and the account then holds 40 flags. One prune call must return the set to the
    ///      size of the current committee.
    function test_prune_restoresTheBoundAfterRotationExceedsTheCap() public {
        Id market = Id.wrap(bytes32(uint256(0xC0DE)));
        address account = address(0x8004);

        // A quorum of 1 permits each removal. The committee keeps two seats and one seat for rotation.
        gs.setQuorum(1);

        uint256 rotations = 40;
        for (uint256 i; i < rotations; ++i) {
            address rotating = address(uint160(0x7000_0000 + i));
            gs.addGuardian(rotating);

            address[] memory one = new address[](1);
            one[0] = account;
            vm.prank(rotating);
            gs.flag(market, rotating, one);

            gs.removeGuardian(rotating);
        }

        assertEq(
            gs.getFlaggedBy(market, account).length, rotations, "the registry keeps the flag of each departed guardian"
        );
        assertGt(
            gs.getFlaggedBy(market, account).length, gs.MAX_GUARDIANS_COUNT(), "the stored set is larger than the limit"
        );

        gs.prune(market, account);

        assertLe(
            gs.getFlaggedBy(market, account).length,
            gs.getGuardianCount(),
            "prune must return the set to the committee size"
        );
        assertTrue(gs.isBanned(market, account), "the prune call does not clear a latched ban");
    }
}
