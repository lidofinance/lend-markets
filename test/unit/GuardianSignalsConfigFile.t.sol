// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {GuardianSignalsConfig, GuardianSignalsConfigFile} from "../../script/lib/GuardianSignalsConfigFile.sol";

contract GuardianSignalsConfigFileHarness {
    function parse(string memory toml) external view returns (GuardianSignalsConfig memory) {
        return GuardianSignalsConfigFile.parse(toml);
    }
}

contract GuardianSignalsConfigFileTest is Test {
    GuardianSignalsConfigFileHarness internal harness;

    function setUp() external {
        harness = new GuardianSignalsConfigFileHarness();
    }

    function test_parse_acceptsValidCommittee() external view {
        GuardianSignalsConfig memory cfg = harness.parse(
            'quorum = 1\nsuspect_window = 3600\nguardians = ["0x0000000000000000000000000000000000000001"]\n'
        );

        assertEq(cfg.quorum, 1);
        assertEq(cfg.suspectWindow, 3600);
        assertEq(cfg.guardians.length, 1);
        assertEq(cfg.guardians[0], address(1));
    }

    function testRevert_parse_rejectsQuorumAboveCommitteeSize() external {
        vm.expectRevert(abi.encodeWithSelector(GuardianSignalsConfigFile.InvalidQuorum.selector, 1, 0));
        harness.parse("quorum = 1\nsuspect_window = 0\nguardians = []\n");
    }
}
