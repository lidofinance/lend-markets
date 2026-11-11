// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {DeploymentArtifact} from "../../script/deployment/DeploymentArtifact.sol";
import {DeploymentSchema, DeploymentHeader, MarketRecord} from "../../script/deployment/DeploymentRecord.sol";

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
}
