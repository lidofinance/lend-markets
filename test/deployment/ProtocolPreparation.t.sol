// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {ForkFixture} from "../setup/ForkFixture.sol";
import {DeploymentSnapshot, RecordedMarket} from "../../script/deployment/DeploymentSnapshot.sol";

contract TwoRequiredMarketsFixture is ForkFixture {
    function _requiredMarkets() internal pure override returns (RecordedMarket[] memory markets) {
        RecordedMarket[] memory base = super._requiredMarkets();
        markets = new RecordedMarket[](2);
        markets[0] = base[0];
        markets[1].role = "additional-weth-wsteth";
        markets[1].plan = _wethWstethPlan(base[0].plan.committee.guardians);
        markets[1].plan.name = "additional-weth-wsteth";
        markets[1].plan.market.lltv = 0.93e18;
    }
}

contract ProtocolPreparationTest is Test {
    ForkFixture internal fixture;
    bytes internal encodedDeployment;

    function setUp() public {
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(vm.envString("RPC_URL"));
        else vm.createSelectFork(vm.envString("RPC_URL"), pin);
        fixture = new ForkFixture();
        encodedDeployment = abi.encode(fixture.prepareInert());
    }

    function test_mixedMarkets_prepareInertAndPreserveActiveState() public {
        DeploymentSnapshot memory d = abi.decode(encodedDeployment, (DeploymentSnapshot));
        RecordedMarket[] memory first = new RecordedMarket[](1);
        first[0] = d.markets[0];
        fixture.prepareExisting(d.protocol, d.books, first);
        ILidoLend core = ILidoLend(d.protocol.core);
        assertGt(core.market(first[0].contracts.id).lastUpdate, 0);
        assertEq(core.market(d.markets[1].contracts.id).lastUpdate, 0);
        bytes32 beforeState = keccak256(abi.encode(core.market(first[0].contracts.id)));
        RecordedMarket[] memory result = fixture.prepareExisting(d.protocol, d.books, d.markets);
        assertEq(result.length, 2);
        assertEq(keccak256(abi.encode(core.market(first[0].contracts.id))), beforeState);
        for (uint256 i; i < result.length; ++i) {
            assertEq(result[i].contracts.controller, d.markets[i].contracts.controller);
            assertEq(result[i].contracts.vault, d.markets[i].contracts.vault);
            assertGt(core.market(result[i].contracts.id).lastUpdate, 0);
        }
        uint256 nonce = vm.getNonce(address(fixture));
        fixture.prepareExisting(d.protocol, d.books, result);
        assertEq(vm.getNonce(address(fixture)), nonce, "active reuse must not deploy replacements");
    }

    function test_missingMarket_deploysOverExistingProtocol() public {
        DeploymentSnapshot memory d = abi.decode(encodedDeployment, (DeploymentSnapshot));
        RecordedMarket[] memory none = new RecordedMarket[](0);
        RecordedMarket[] memory result = fixture.prepareExisting(d.protocol, d.books, none);
        assertEq(result.length, 1);
        assertEq(result[0].role, "weth-wsteth");
        assertGt(ILidoLend(d.protocol.core).market(result[0].contracts.id).lastUpdate, 0);
        assertEq(address(LidoLendMarketController(result[0].contracts.controller).LIDO_LEND()), d.protocol.core);
    }

    function test_multipleMissingMarkets_useSamePreparationAndSharedResources() public {
        DeploymentSnapshot memory d = abi.decode(encodedDeployment, (DeploymentSnapshot));
        RecordedMarket[] memory none = new RecordedMarket[](0);
        TwoRequiredMarketsFixture multiple = new TwoRequiredMarketsFixture();
        RecordedMarket[] memory result = multiple.prepareExisting(d.protocol, d.books, none);
        assertEq(result.length, 2);
        assertEq(result[0].contracts.guardianSignals, result[1].contracts.guardianSignals);
        assertEq(result[0].contracts.params.oracle, result[1].contracts.params.oracle);
        assertNotEq(result[0].contracts.controller, result[1].contracts.controller);
        assertGt(ILidoLend(d.protocol.core).market(result[0].contracts.id).lastUpdate, 0);
        assertGt(ILidoLend(d.protocol.core).market(result[1].contracts.id).lastUpdate, 0);
    }

    function testRevert_recordedMissingCodeDoesNotDeployReplacement() public {
        DeploymentSnapshot memory d = abi.decode(encodedDeployment, (DeploymentSnapshot));
        address missing = makeAddr("missing.controller");
        d.markets[0].contracts.controller = missing;
        vm.expectRevert(abi.encodeWithSignature("MissingCode(address)", missing));
        fixture.prepareExisting(d.protocol, d.books, d.markets);
    }
}
