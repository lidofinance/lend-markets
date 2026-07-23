// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {ProtocolConfigFile} from "../../script/lib/ProtocolConfigFile.sol";

contract ProtocolConfigFileHarness {
    function containsMarketId(string memory registry, bytes32 id) external pure returns (bool) {
        return ProtocolConfigFile.containsMarketId(registry, id);
    }
}

contract ProtocolConfigFileTest is Test {
    ProtocolConfigFileHarness internal harness;

    function setUp() external {
        harness = new ProtocolConfigFileHarness();
    }

    function test_containsMarketId_findsRecordedId() external view {
        bytes32 id = bytes32(uint256(0x1234));
        string memory registry = string.concat(
            "[markets.first]\nid = \"",
            vm.toString(id),
            "\"\ncontroller = \"0x0000000000000000000000000000000000000001\"\n"
        );

        assertTrue(harness.containsMarketId(registry, id));
    }

    function test_containsMarketId_ignoresOtherBytes32Values() external view {
        bytes32 id = bytes32(uint256(0x1234));
        string memory registry = string.concat("[artifact]\nconfig_hash = \"", vm.toString(id), "\"\n");

        assertFalse(harness.containsMarketId(registry, id));
    }
}
