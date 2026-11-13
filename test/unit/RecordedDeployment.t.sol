// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {RecordedDeployment} from "../../script/deployment/RecordedDeployment.sol";
import {DeploymentSnapshot, RecordedMarket} from "../../script/deployment/DeploymentTypes.sol";
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

    function test_mainnet_loadsRecordedWethWstethMarket() public {
        vm.chainId(1);
        vm.etch(MainnetProtocol.addresses().core, hex"00");
        DeploymentSnapshot memory d = harness.load("mainnet");
        assertEq(d.markets.length, 1);
        RecordedMarket memory market = d.markets[0];
        assertEq(market.role, "weth-wsteth");
        assertEq(market.parameters.name, "weth-wsteth");
        assertEq(market.deployedBlock, 26406479);
        assertEq(Id.unwrap(market.contracts.id), 0xe4af8961b4e5a779b85d8c461be1007e4b78a7933976e0a5f23121682020de29);
        assertEq(Id.unwrap(market.contracts.id), Id.unwrap(market.contracts.params.id()));
        assertEq(market.contracts.params.loanToken, d.weth);
        assertEq(market.contracts.params.collateralToken, d.wstEth);
        assertEq(market.contracts.params.irm, d.protocol.irmRouter);
        assertEq(market.contracts.params.oracle, 0x20a078F9940dC05C46De4153D1bCbd54D2b5b151);
        assertEq(market.contracts.controller, 0xCF1B266d320CA9c0d4e13eF2C46465962F040e88);
        assertEq(market.contracts.vault, 0xd8765FA896be3D30A49B9a7d95453E34E2c7A056);
        assertEq(market.contracts.guardianSignals, 0xc8a8CBBF4c55980F85332fD8470DF0fC52d690aC);
        assertEq(market.contracts.irmConfig, 0x6076f89f5Cd68c526C73eA1F730d9ce8f05301a6);
        assertEq(market.parameters.market.oracle, market.contracts.params.oracle);
        assertEq(market.parameters.market.guardianSignals, market.contracts.guardianSignals);
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
