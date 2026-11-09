// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ForkFixture} from "../setup/ForkFixture.sol";
import {DeploymentSnapshot} from "../../script/deployment/DeploymentSnapshot.sol";
import {MarketMotionReadinessAcceptance} from "../acceptance/MarketMotionReadiness.t.sol";
import {MarketActivatedAcceptance} from "../acceptance/MarketActivated.t.sol";

contract FreshMarketReadinessAcceptance is MarketMotionReadinessAcceptance {
    bytes private fixtureRecord;

    function setUp() public override {
        if (bytes(vm.envOr("ARTIFACTS_DIR", string(""))).length != 0) {
            vm.skip(true, "use acceptance-run for a recorded deployment");
        }
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), pin);
        vm.recordLogs();
        DeploymentSnapshot memory d = (new ForkFixture()).prepareInert();
        fixtureRecord = abi.encode(d);
        _bindTypedDeployment(d, 0, d.protocol.agent, true, address(0));
    }

    function test_secondMarketIsReadyIndependently() public {
        DeploymentSnapshot memory d = abi.decode(fixtureRecord, (DeploymentSnapshot));
        _bindTypedDeployment(d, 1, d.protocol.agent, true, address(0));
        this.test_deployedInertAndReadyForMotion();
    }
}

contract FreshMarketActivatedAcceptance is MarketActivatedAcceptance {
    bytes private fixtureRecord;

    function setUp() public override {
        if (bytes(vm.envOr("ARTIFACTS_DIR", string(""))).length != 0) {
            vm.skip(true, "use acceptance-run for a recorded deployment");
        }
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), pin);
        vm.recordLogs();
        DeploymentSnapshot memory d = (new ForkFixture()).prepare();
        fixtureRecord = abi.encode(d);
        _bindTypedDeployment(d, 0, d.protocol.agent, true, d.protocol.agent);
    }

    function test_secondMarketIsActivatedIndependently() public {
        DeploymentSnapshot memory d = abi.decode(fixtureRecord, (DeploymentSnapshot));
        _bindTypedDeployment(d, 1, d.protocol.agent, true, d.protocol.agent);
        this.test_fullyConnectedConfiguredAndLive();
    }
}
