// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

import {LidoLendMarketBuilder, MarketRoles} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {ArtifactMetadata} from "../../script/lib/ArtifactMetadata.sol";
import {ProtocolConfigFile, MarketDeployment} from "../../script/lib/ProtocolConfigFile.sol";

contract ProtocolConfigFileHarness {
    function containsMarketId(string memory artifact, bytes32 id) external pure returns (bool) {
        return ProtocolConfigFile.containsMarketId(artifact, id);
    }

    function writeMarket(MarketDeployment memory market, ArtifactMetadata memory metadata)
        external
        returns (string memory)
    {
        return ProtocolConfigFile.writeMarket(market, metadata);
    }

    function requireMarketIdUndeployed(bytes32 id) external view {
        ProtocolConfigFile.requireMarketIdUndeployed(id);
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

    function test_writeMarket_recordsCompleteSeparateImmutableArtifacts() external {
        string memory run = _prepareRun("protocol-config-file-unit");
        MarketDeployment memory market = _market("first", bytes32(uint256(0x1234)), address(0xCB));
        string memory path = harness.writeMarket(market, _metadata(run));
        string memory artifact = vm.readFile(path);

        assertEq(vm.parseTomlString(artifact, ".artifact.kind"), "market-deployment");
        assertEq(vm.parseTomlAddress(artifact, ".market.oracle"), market.market.oracle);
        assertEq(vm.parseTomlAddress(artifact, ".market.controller"), market.controller);
        assertEq(vm.parseTomlAddress(artifact, ".market.circuit_breaker"), address(0xCB));
        assertEq(vm.parseTomlAddressArray(artifact, ".roles.pausers")[0], address(0xCB));
        address[] memory managers = vm.parseTomlAddressArray(artifact, ".roles.managers");
        assertEq(managers.length, 2);
        assertEq(managers[0], market.ownerFacade);
        assertEq(managers[1], market.riskStewardDashboard);
        address[] memory unfreezers = vm.parseTomlAddressArray(artifact, ".roles.unfreezers");
        assertEq(unfreezers.length, 1);
        assertEq(unfreezers[0], market.ownerFacade);
        assertEq(
            vm.parseTomlUint(artifact, ".activation.min_activation_delay"),
            market.market.activationConfig.minActivationDelay
        );
        assertEq(
            vm.parseTomlUint(artifact, ".settlement.full_cut_below_collateral"),
            market.market.settlementConfig.fullCutBelowCollateral
        );
        assertEq(vm.parseTomlInt(artifact, ".curve.curve_steepness"), market.curveParams.curveSteepness);
        string memory second =
            harness.writeMarket(_market("second", bytes32(uint256(2)), address(0xCB)), _metadata(run));

        assertNotEq(path, second);
        assertTrue(vm.exists(path));
        assertTrue(vm.exists(second));

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolConfigFile.MarketIdAlreadyRecorded.selector, bytes32(uint256(0x1234)))
        );
        harness.requireMarketIdUndeployed(bytes32(uint256(0x1234)));
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function _prepareRun(string memory run) private returns (string memory) {
        vm.setEnv("ARTIFACTS_DIR", run);
        string memory dir = string.concat("deployed/", run);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        return run;
    }

    function _metadata(string memory run) private pure returns (ArtifactMetadata memory) {
        return ArtifactMetadata({deployment: run, chainId: 1, configHash: bytes32(uint256(0xCAFE))});
    }

    function _market(string memory name, bytes32 id, address circuitBreaker)
        private
        pure
        returns (MarketDeployment memory d)
    {
        address[] memory pausers = new address[](1);
        pausers[0] = circuitBreaker;
        d = MarketDeployment({
            name: name,
            oracleArtifact: "wsteth",
            guardianGroup: "main",
            id: id,
            builder: address(0xB0),
            controller: address(0xC0),
            vault: address(0xA0),
            irm: address(0x1),
            ownerFacade: address(0xFA),
            riskStewardDashboard: address(0xDA),
            market: LidoLendMarketBuilder.MarketSpec({
                loanToken: address(0x10),
                collateralToken: address(0x20),
                oracle: address(0x30),
                lltv: 0.8 ether,
                guardianSignals: address(0x40),
                activationConfig: CollateralActivationConfig({
                    minActivationDelay: 1,
                    maxActivationDelay: 2,
                    maxDelayInflow: 3,
                    activatingLockAmount: 4,
                    activatingLockDuration: 5,
                    minActivationAmount: 6,
                    maxGuardiansQuorumDelay: 7,
                    delayPerStrike: 8,
                    delayPerSuspect: 9
                }),
                settlementConfig: SettlementConfig({
                    sliceFloorBps: 10, sliceFloorAssets: 11, fullCutBelowCollateral: 12, ltvStepBps: 13
                }),
                vaultName: "Vault",
                vaultSymbol: "VLT"
            }),
            roles: MarketRoles({
                admin: address(0x50),
                proxyAdmin: address(0x50),
                managers: new address[](0),
                pausers: pausers,
                freezers: new address[](0),
                unfreezers: new address[](0),
                resumers: new address[](0)
            }),
            curveParams: AdaptiveCurveParams({
                curveSteepness: 4 ether,
                adjustmentSpeed: 1,
                targetUtilization: 0.9 ether,
                initialRateAtTarget: 2,
                minRateAtTarget: 1,
                maxRateAtTarget: 3,
                maxBorrowRate: 4
            }),
            deployedBlock: 100
        });
    }
}
