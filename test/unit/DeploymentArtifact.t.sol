// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeploymentArtifact} from "../../script/deployment/DeploymentArtifact.sol";
import {
    DeploymentSchema,
    DeploymentHeader,
    MarketRecord,
    ProtocolRecord
} from "../../script/deployment/DeploymentRecord.sol";
import {RecordDeployment} from "../../script/deployment/RecordDeployment.s.sol";
import {GenerateProtocol} from "../../script/deployment/GenerateProtocol.s.sol";

contract RecordDeploymentHarness is RecordDeployment {
    function record(string memory runName, string memory report) external returns (string memory) {
        return _record(runName, report);
    }
}

contract DeploymentArtifactTest is Test {
    function test_marketArtifactPreservesLargeValuesAndCommittee() public {
        string memory runName = "artifact-roundtrip-unit";
        string memory dir = DeploymentArtifact.directory(runName);
        require(!vm.exists(dir), "Fixture exists");
        MarketRecord memory r;
        r.header = DeploymentHeader({
            version: 1,
            run: runName,
            kind: "market",
            name: "test-market",
            chainId: 1,
            sender: address(this),
            blockNumber: 100
        });
        r.role = "test-market";
        r.plan.name = "test-market";
        r.plan.wrapper.name = 'Quoted "vault"';
        r.plan.market.supplyCap = type(uint256).max;
        r.plan.market.activationConfig.maxDelayInflow = type(uint128).max;
        r.plan.curve.adjustmentSpeed = -1;
        r.plan.committee.guardians = new address[](1);
        r.plan.committee.guardians[0] = address(0x1234);
        r.addresses.controller = address(0xCAFE);
        vm.createDir(string.concat(dir, "/markets"), true);
        string memory file = DeploymentArtifact.path(r.header);
        vm.writeToml(vm.serializeJsonType(DeploymentSchema.MARKETRECORD, abi.encode(r)), file);
        MarketRecord memory loaded =
            abi.decode(DeploymentArtifact.read(file, runName, "market", DeploymentSchema.MARKETRECORD), (MarketRecord));
        assertEq(loaded.plan.market.supplyCap, type(uint256).max);
        assertEq(loaded.plan.market.activationConfig.maxDelayInflow, type(uint128).max);
        assertEq(loaded.plan.curve.adjustmentSpeed, -1);
        assertEq(loaded.plan.committee.guardians[0], address(0x1234));
        assertEq(loaded.addresses.controller, address(0xCAFE));
        assertEq(loaded.plan.wrapper.name, 'Quoted "vault"');
        vm.removeDir(dir, true);
    }

    function test_protocolResultExportsAddressProviderWithoutConfig() public {
        string memory runName = "artifact-protocol-unit";
        string memory dir = DeploymentArtifact.directory(runName);
        require(!vm.exists(dir), "Fixture exists");
        ProtocolRecord memory r;
        r.header = DeploymentHeader({
            version: 1,
            run: runName,
            kind: "protocol",
            name: "protocol",
            chainId: 560048,
            sender: address(this),
            blockNumber: 100
        });
        r.addresses.chainId = 560048;
        r.addresses.core = address(0x1234);
        vm.createDir(dir, true);
        vm.writeToml(
            vm.serializeJsonType(DeploymentSchema.PROTOCOLRECORD, abi.encode(r)), DeploymentArtifact.path(r.header)
        );
        string memory source = vm.readFile((new GenerateProtocol()).run(runName));
        assertTrue(vm.contains(source, "p.chainId = 560048;"));
        assertTrue(vm.contains(source, vm.toString(address(0x1234))));
        vm.removeDir(dir, true);
        vm.removeDir(string.concat("script/deployment/generated/", runName), true);
    }

    function testRevert_simulationCannotPublishArtifact() public {
        string memory runName = "artifact-rejected-simulation";
        RecordDeploymentHarness recorder = new RecordDeploymentHarness();
        string memory report = _emptyBroadcast(runName);
        vm.expectRevert("Incomplete broadcast");
        recorder.record(runName, report);
        assertFalse(vm.exists(DeploymentArtifact.directory(runName)));
    }

    function testRevert_completedReportCannotBeRelabelledAsAnotherRun() public {
        RecordDeploymentHarness recorder = new RecordDeploymentHarness();
        string memory report = _emptyBroadcast("artifact-original-run");
        vm.expectRevert("Broadcast run mismatch");
        recorder.record("artifact-another-run", report);
        assertFalse(vm.exists("deployed/artifact-another-run"));
    }

    function testRevert_recordingCannotEscapeDeploymentDirectory() public {
        RecordDeploymentHarness recorder = new RecordDeploymentHarness();
        vm.expectRevert("Invalid artifact name");
        recorder.run("../other", "script/deployment/mainnet/DeployProtocol.s.sol");
    }

    function _emptyBroadcast(string memory runName) private returns (string memory) {
        ProtocolRecord memory r;
        r.header = DeploymentHeader({
            version: 1,
            run: runName,
            kind: "protocol",
            name: "protocol",
            chainId: block.chainid,
            sender: address(this),
            blockNumber: block.number
        });
        string memory artifact = vm.serializeJsonType(DeploymentSchema.PROTOCOLRECORD, abi.encode(r));
        // Native Forge reports retain the display string's escaping in returns.<name>.value.
        string memory escaped =
            vm.replace(vm.replace(artifact, string(hex"5c"), string(hex"5c5c")), string(hex"22"), string(hex"5c22"));
        string memory value = vm.serializeString("native-return", "value", escaped);
        return string.concat(
            '{"chain":',
            vm.toString(block.chainid),
            ',"transactions":[],"receipts":[],"pending":[],"returns":{"artifact":',
            value,
            "}}"
        );
    }
}
