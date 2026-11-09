// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeployConfigFile} from "../../script/legacy/lib/DeployConfigFile.sol";

contract HistoricalProtocolIdentityHarness {
    function validate(string memory artifact) external view {
        DeployConfigFile.requireProtocolArtifactCompatibility(artifact);
    }
}

contract HistoricalProtocolIdentityTest is Test {
    HistoricalProtocolIdentityHarness internal harness = new HistoricalProtocolIdentityHarness();

    function test_acceptsCanonicalHeader() public view {
        harness.validate(_artifact(_expectedHash()));
    }

    function testRevert_forgedHeader() public {
        bytes32 forged = bytes32(uint256(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(DeployConfigFile.RegistryCompatibilityHashMismatch.selector, _expectedHash(), forged)
        );
        harness.validate(_artifact(forged));
    }

    function _expectedHash() private pure returns (bytes32) {
        return keccak256(abi.encode("unit", uint256(1), address(1), address(2), address(3), "shared"));
    }

    function _artifact(bytes32 hash) private pure returns (string memory) {
        return string.concat(
            '[artifact]\ncompatibility_hash = "',
            vm.toString(hash),
            '"\n[protocol]\nnetwork = "unit"\nchain_id = 1\n',
            'agent = "0x0000000000000000000000000000000000000001"\n',
            'evm_script_executor = "0x0000000000000000000000000000000000000002"\n',
            'reseal_manager = "0x0000000000000000000000000000000000000003"\n',
            'circuit_breaker_artifact = "shared"\n'
        );
    }
}
