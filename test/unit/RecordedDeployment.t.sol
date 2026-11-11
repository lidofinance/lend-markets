// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {RecordedDeployment} from "../../script/deployment/RecordedDeployment.sol";
import {DeploymentSnapshot} from "../../script/deployment/DeploymentTypes.sol";
import {Protocol as MainnetProtocol} from "../../script/deployment/mainnet/artifacts/Protocol.sol";
import {Deployment as HoodiDeployment} from "../../script/deployment/hoodi-testnet/artifacts/Deployment.sol";

contract RecordedDeploymentHarness {
    function load(string memory run) external view returns (DeploymentSnapshot memory) {
        return RecordedDeployment.load(run);
    }
}

contract RecordedDeploymentTest is Test {
    using MarketParamsLib for MarketParams;

    RecordedDeploymentHarness private harness;

    function setUp() public {
        harness = new RecordedDeploymentHarness();
    }

    function testRevert_unknownRun_doesNotFallBackToMainnet() public {
        vm.chainId(1);
        vm.expectRevert("Unknown deployment run");
        harness.load("unknown");
    }

    function testRevert_wrongChain_isRejected() public {
        vm.chainId(560048);
        vm.expectRevert("Deployment chain mismatch");
        harness.load("mainnet");
    }

    function testRevert_missingCore_doesNotDeployReplacement() public {
        vm.chainId(1);
        vm.expectRevert("Deployment core missing code");
        harness.load("mainnet");
        assertEq(MainnetProtocol.addresses().core.code.length, 0);
    }

    function test_mainnet_keepsMarketsAbsentUntilRecorded() public {
        vm.chainId(1);
        vm.etch(MainnetProtocol.addresses().core, hex"00");
        DeploymentSnapshot memory d = harness.load("mainnet");
        assertEq(d.markets.length, 0);
    }

    function test_hoodi_marketIdsMatchRecordedParameters() public {
        vm.chainId(560048);
        vm.etch(HoodiDeployment.snapshot().protocol.core, hex"00");
        DeploymentSnapshot memory d = harness.load("hoodi-testnet");
        assertEq(d.markets.length, 3);
        for (uint256 i; i < d.markets.length; ++i) {
            assertEq(Id.unwrap(d.markets[i].contracts.id), Id.unwrap(d.markets[i].contracts.params.id()));
            assertEq(d.markets[i].contracts.params.irm, d.protocol.irmRouter);
        }
    }
}
