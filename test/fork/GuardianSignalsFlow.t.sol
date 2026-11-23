// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice The guardian committee the deployment wired into one market, driven as its real members: a quorum of
///         flags bans a borrower, a retraction never lifts the latch, only the owner facade does, and heartbeats
///         move the quorum frontier.
contract GuardianSignalsFlowForkTest is ForkStack {
    using MarketActions for Market;

    ILidoLendOwner internal facade;
    address internal executor;
    address[] internal guardians;

    function setUp() public {
        _onlyOnOneMarketPerKind();
        _setUpTarget();
        facade = _facade();
        executor = _executor();
        guardians = _quorumGuardians();

        LENDER = _freshActor(market, "guardians.lender");
        BORROWER = _freshActor(market, "guardians.borrower");
        uint256 deposit = _maxBorrow(market, lot, market.oracle.price()) + _oneLoanToken();
        _requireSupplyHeadroom(market, deposit);
        deal(address(market.loanToken), LENDER, deposit);
        market.vaultDeposit(LENDER, deposit);

        collateralIssuer.dealCollateral(BORROWER, lot);
        market.supplyCollateral(BORROWER, lot);
    }

    // ---
    // BAN, RETRACT, UNBAN
    // ---

    function test_flag_atQuorum_bansAndBlocksBorrow() public {
        market.banVia(guardians, BORROWER);

        ILidoLendMarketController.BorrowerPosition memory position = market.controller.positionOf(BORROWER);
        assertTrue(position.banned, "controller sees the ban");
        assertEq(position.unlockTime, type(uint256).max, "a banned lot never matures");

        market.activateCollateral();
        vm.prank(BORROWER);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        market.core.borrow(market.params, 1, 0, BORROWER, BORROWER);
    }

    function test_unflag_afterBan_dropsStrikeKeepsLatch() public {
        market.banVia(guardians, BORROWER);
        market.unflagAs(guardians[0], BORROWER);
        assertTrue(market.guardianSignals.isBanned(market.id, BORROWER), "retraction never lifts a latched ban");
    }

    function test_unbanViaFacade_clearsLatchAndStrikes_thenLotMaturesAndBorrows() public {
        market.banVia(guardians, BORROWER);

        Id[] memory ids = new Id[](1);
        ids[0] = market.id;
        vm.prank(executor);
        facade.unbanGuardianSignals(ids, BORROWER);

        ILidoLendMarketController.BorrowerPosition memory position = market.controller.positionOf(BORROWER);
        assertFalse(position.banned, "ban lifted");
        assertEq(position.flagCount, 0, "strikes cleared with the ban");
        assertLt(position.unlockTime, type(uint256).max, "the timer is finite again");

        market.activateCollateral();
        market.borrow(BORROWER, _maxBorrow(market, lot, market.oracle.price()) / 2);
    }

    /// @dev The facade is the only route: the Agent holds no restorer role on the registry itself.
    function testRevert_unban_byAgentDirectly() public {
        market.banVia(guardians, BORROWER);
        address agent = _admin();
        bytes32 role = market.guardianSignals.ACCESS_RESTORER_ROLE();
        vm.prank(agent);
        vm.expectRevert(_missingRoleError(agent, role));
        market.guardianSignals.unban(market.id, BORROWER);
    }

    // ---
    // HEARTBEATS
    // ---

    function test_heartbeat_storesTimestamp_andMovesFrontier() public {
        vm.roll(block.number + 1);
        uint256 scanned = block.timestamp;
        for (uint256 i; i < guardians.length; ++i) {
            market.heartbeatAt(guardians[i], scanned);
        }
        assertEq(market.syncFrontier(), scanned, "a quorum of heartbeats at `scanned` moves the frontier there");
    }
    using MarketActions for Market;

    /// @dev Below quorum a strike is a delay, not a ban: with a second guardian and quorum two (set through the
    ///      facade), one flag pushes the unlock time out by exactly `delayPerStrike`, and the retraction pulls it
    ///      back. This market is the one whose live config carries a non-zero surcharge.
    function test_flag_belowQuorum_addsDelayPerStrike_unflagRemovesIt() public {
        uint256 surcharge = _activationConfig(market).delayPerStrike;
        require(surcharge != 0, "GuardianSignalsFlow: this market's live config must carry a per-strike delay");

        address second = makeAddr("guardians.second");
        vm.startPrank(executor);
        facade.addGuardian(market.id, second);
        facade.setGuardiansQuorum(market.id, 2);
        vm.stopPrank();
        assertEq(market.guardianSignals.getQuorum(), 2, "quorum raised through the facade");

        uint256 unlockBefore = market.controller.positionOf(BORROWER).unlockTime;
        market.flagAs(guardians[0], BORROWER);
        assertFalse(market.guardianSignals.isBanned(market.id, BORROWER), "one strike below quorum two is no ban");
        assertEq(market.controller.positionOf(BORROWER).unlockTime, unlockBefore + surcharge, "strike delays the lot");

        market.unflagAs(guardians[0], BORROWER);
        assertEq(market.controller.positionOf(BORROWER).unlockTime, unlockBefore, "retraction removes the surcharge");
    }
}

