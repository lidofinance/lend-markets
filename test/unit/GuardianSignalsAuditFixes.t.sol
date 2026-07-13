// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {BlockInfoWithHash} from "../../src/types/GuardianSignalsTypes.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

/// @notice Regression for guardian audit finding W1: heartbeat rejects non-canonical zero-hash proofs.
contract GuardianSignalsAuditFixesTest is Test {
    GuardianSignals internal gs;

    address internal constant G1 = address(0x4001);
    address internal constant G2 = address(0x4002);
    address internal constant G3 = address(0x4003);
    address internal constant M1 = address(0x4101);
    address internal constant M2 = address(0x4102);
    address internal constant M3 = address(0x4103);
    address internal constant BOB = address(0x5001);

    Id internal constant MARKET = Id.wrap(bytes32(uint256(0xA11CE)));

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_000_000);
        address impl = address(new GuardianSignals());
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],address[],uint256)", address(this), _guardians(), _managers(), uint256(2)
        );
        gs = GuardianSignals(address(new OssifiableProxy(impl, address(this), initData)));
        gs.grantRole(gs.MANAGER_ROLE(), address(this));
    }

    function _guardians() internal pure returns (address[] memory g) {
        g = new address[](3);
        (g[0], g[1], g[2]) = (G1, G2, G3);
    }

    function _managers() internal pure returns (address[] memory m) {
        m = new address[](3);
        (m[0], m[1], m[2]) = (M1, M2, M3);
    }

    function _validBlock() internal view returns (BlockInfoWithHash memory) {
        uint40 n = uint40(block.number - 1);
        return BlockInfoWithHash({hash: blockhash(n), number: n, timestamp: uint40(block.timestamp)});
    }

    /// W1: a zero-hash proof for the current block (where `blockhash` is zero) is rejected.
    function test_W1_heartbeatRejectsZeroHashCurrentBlock() public {
        BlockInfoWithHash memory forged =
            BlockInfoWithHash({hash: bytes32(0), number: uint40(block.number), timestamp: uint40(block.timestamp)});
        vm.prank(M1);
        vm.expectRevert(IGuardianSignals.InvalidBlockHash.selector);
        gs.heartbeat(forged);
    }

    /// W1: a zero-hash proof for a block outside the 256-block window (also `blockhash` zero) is rejected.
    function test_W1_heartbeatRejectsZeroHashStaleBlock() public {
        vm.roll(block.number + 300);
        uint40 stale = uint40(block.number - 300); // outside the blockhash lookback window
        BlockInfoWithHash memory forged =
            BlockInfoWithHash({hash: bytes32(0), number: stale, timestamp: uint40(block.timestamp)});
        vm.prank(M1);
        vm.expectRevert(IGuardianSignals.InvalidBlockHash.selector);
        gs.heartbeat(forged);
    }

    /// W1: a canonical in-window past block still records the heartbeat.
    function test_W1_heartbeatAcceptsCanonicalBlock() public {
        vm.prank(M1);
        gs.heartbeat(_validBlock());
        assertEq(gs.getHeartbeat(G1), uint40(block.timestamp), "canonical heartbeat recorded");
    }
}
