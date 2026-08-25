// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {
    ProtocolConfigFile,
    ProtocolDeployment,
    MarketDeployment,
    ExitBooksDeployment
} from "../../script/lib/ProtocolConfigFile.sol";

contract ProtocolConfigFileHarness {
    function containsMarketId(string memory artifact, bytes32 id) external pure returns (bool) {
        return ProtocolConfigFile.containsMarketId(artifact, id);
    }

    function writeMarket(MarketDeployment memory market, ArtifactMetadata memory metadata, string memory deployment)
        external
        returns (string memory)
    {
        return ProtocolConfigFile.writeMarket(market, metadata, deployment);
    }

    function writeProtocol(ProtocolDeployment memory protocol, ArtifactMetadata memory metadata)
        external
        returns (string memory)
    {
        return ProtocolConfigFile.writeProtocol(protocol, metadata);
    }

    function writeExitBooks(ExitBooksDeployment memory exitBooks, ArtifactMetadata memory metadata)
        external
        returns (string memory)
    {
        return ProtocolConfigFile.writeExitBooks(exitBooks, metadata);
    }

    function requireMarketIdUndeployed(bytes32 id, string memory deployment) external view {
        ProtocolConfigFile.requireMarketIdUndeployed(id, deployment);
    }

    function requireMarketRoleUndeployed(string memory role, string memory deployment) external view {
        ProtocolConfigFile.requireMarketRoleUndeployed(role, deployment);
    }

    function requireMarketsCompatible(ArtifactMetadata memory expected) external view {
        ProtocolConfigFile.requireMarketsCompatible(expected);
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
        MarketDeployment memory market = _market("first", bytes32(uint256(0x1234)));
        string memory path = harness.writeMarket(market, _metadata(run), run);
        string memory artifact = vm.readFile(path);

        assertEq(vm.parseTomlString(artifact, ".artifact.kind"), "market-deployment");
        assertEq(vm.parseTomlAddress(artifact, ".market.oracle"), market.market.oracle);
        assertEq(vm.parseTomlAddress(artifact, ".market.controller"), market.controller);
        assertEq(vm.parseTomlAddress(artifact, ".market.factory"), market.factory);
        assertEq(vm.parseTomlUint(artifact, ".market.supply_cap"), market.market.supplyCap);
        assertFalse(vm.keyExistsToml(artifact, ".roles"), "derived roles are not deployment inputs");
        assertFalse(vm.keyExistsToml(artifact, ".market.circuit_breaker"), "CircuitBreaker is protocol-wide");
        assertEq(
            vm.parseTomlUint(artifact, ".activation.min_activation_delay"),
            market.market.activationConfig.minActivationDelay
        );
        assertEq(
            vm.parseTomlUint(artifact, ".settlement.full_cut_below_collateral"),
            market.market.settlementConfig.fullCutBelowCollateral
        );
        assertEq(vm.parseTomlString(artifact, ".market.role"), "wsteth-weth");
        assertEq(vm.parseTomlAddress(artifact, ".market.irm_config"), market.irmConfig);
        assertEq(vm.parseTomlInt(artifact, ".curve.curve_steepness"), market.curveParams.curveSteepness);
        string memory second = harness.writeMarket(_market("second", bytes32(uint256(2))), _metadata(run), run);

        assertNotEq(path, second);
        assertTrue(vm.exists(path));
        assertTrue(vm.exists(second));

        vm.expectRevert(
            abi.encodeWithSelector(ProtocolConfigFile.MarketIdAlreadyRecorded.selector, bytes32(uint256(0x1234)))
        );
        harness.requireMarketIdUndeployed(bytes32(uint256(0x1234)), run);
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function testRevert_requireMarketRoleUndeployed_duplicateRole() external {
        string memory run = _prepareRun("protocol-config-role-unit");
        harness.writeMarket(_market("first", bytes32(uint256(1))), _metadata(run), run);

        vm.expectRevert(abi.encodeWithSelector(ProtocolConfigFile.MarketRoleAlreadyRecorded.selector, "wsteth-weth"));
        harness.requireMarketRoleUndeployed("wsteth-weth", run);
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function test_requireMarketRoleUndeployed_acceptsUnrecordedRole() external {
        string memory run = _prepareRun("protocol-config-new-role-unit");
        harness.writeMarket(_market("first", bytes32(uint256(1))), _metadata(run), run);

        harness.requireMarketRoleUndeployed("usdy-usdt", run);
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function test_requireMarketsCompatible_acceptsDifferentExactConfig() external {
        string memory run = _prepareRun("protocol-config-compatible-markets-unit");
        harness.writeMarket(_market("first", bytes32(uint256(1))), _metadata(run), run);
        ArtifactMetadata memory expected = _metadata(run);
        expected.configHash = bytes32(uint256(0xBAD));

        harness.requireMarketsCompatible(expected);
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function testRevert_requireMarketsCompatible_rejectsDifferentCompatibilityHash() external {
        string memory run = _prepareRun("protocol-config-incompatible-markets-unit");
        string memory path = harness.writeMarket(_market("first", bytes32(uint256(1))), _metadata(run), run);
        ArtifactMetadata memory expected = _metadata(run);
        expected.compatibilityHash = bytes32(uint256(0xBAD));

        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactCompatibilityHashMismatch.selector,
                string.concat(vm.projectRoot(), "/", path),
                expected.compatibilityHash,
                bytes32(uint256(0xBEEF))
            )
        );
        harness.requireMarketsCompatible(expected);
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function testRevert_requireMarketRoleUndeployed_missingRole() external {
        string memory run = _prepareRun("protocol-config-missing-role-unit");
        string memory markets = string.concat("deployed/", run, "/markets");
        vm.createDir(markets, true);
        string memory path = string.concat(markets, "/legacy.toml");
        vm.writeFile(path, "[market]\nname = \"legacy\"\n");

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolConfigFile.MarketRoleMissing.selector, string.concat(vm.projectRoot(), "/", path)
            )
        );
        harness.requireMarketRoleUndeployed("wsteth-weth", run);
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function test_writeProtocolAndExitBooks_recordsGovernanceConfiguration() external {
        string memory run = _prepareRun("protocol-config-factory-unit");
        vm.setEnv("ARTIFACTS_DIR", run);
        ProtocolDeployment memory protocol = ProtocolDeployment({
            deployment: run,
            network: "unit",
            chainId: 1,
            configHash: bytes32(uint256(0xCAFE)),
            circuitBreakerArtifact: "lido-lend",
            core: address(0x10),
            ownerFacade: address(0x11),
            irmRouter: address(0x12),
            adaptiveCurveIrm: address(0x13),
            irmConfigFactory: address(0x14),
            factory: address(0x15),
            riskStewardDashboard: address(0x17),
            circuitBreaker: address(0xCB),
            guardianSignalsImpl: address(0x18),
            deployedBlock: 100,
            deployer: address(0x19),
            agent: address(0x1A),
            evmScriptExecutor: address(0x1B)
        });

        string memory protocolArtifact = vm.readFile(harness.writeProtocol(protocol, _metadata(run)));

        assertEq(
            vm.parseTomlAddress(protocolArtifact, ".protocol.irm_config_factory"),
            protocol.irmConfigFactory,
            "IRM config factory"
        );
        assertEq(vm.parseTomlAddress(protocolArtifact, ".protocol.circuit_breaker"), protocol.circuitBreaker);
        assertEq(
            vm.parseTomlString(protocolArtifact, ".protocol.circuit_breaker_artifact"), protocol.circuitBreakerArtifact
        );
        assertFalse(vm.keyExistsToml(protocolArtifact, ".roles"), "derived roles are not deployment inputs");
        address pauser = makeAddr("exitBookPauser");
        ExitBooksDeployment memory exitBooks = ExitBooksDeployment({
            morpho: address(0x10),
            erc4626: address(0x11),
            deployedBlock: 100,
            pauser: pauser,
            maxRequestLifetime: 365 days
        });

        string memory exitBooksArtifact = vm.readFile(harness.writeExitBooks(exitBooks, _metadata(run)));

        assertEq(vm.parseTomlAddress(exitBooksArtifact, ".exit_books.pauser"), pauser);
        assertFalse(vm.keyExistsToml(exitBooksArtifact, ".roles"), "derived roles are not deployment inputs");
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function _prepareRun(string memory run) private returns (string memory) {
        string memory dir = string.concat("deployed/", run);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        return run;
    }

    function _metadata(string memory run) private pure returns (ArtifactMetadata memory) {
        return ArtifactMetadata({
            deployment: run,
            chainId: 1,
            configHash: bytes32(uint256(0xCAFE)),
            compatibilityHash: bytes32(uint256(0xBEEF))
        });
    }

    function _market(string memory name, bytes32 id) private pure returns (MarketDeployment memory d) {
        d = MarketDeployment({
            name: name,
            role: "wsteth-weth",
            oracleArtifact: "wsteth",
            guardianGroup: "main",
            id: id,
            factory: address(0xB0),
            controller: address(0xC0),
            vault: address(0xA0),
            irm: address(0x1),
            market: LidoLendMarketFactory.MarketSpec({
                loanToken: address(0x10),
                collateralToken: address(0x20),
                oracle: address(0x30),
                lltv: 0.8 ether,
                guardianSignals: address(0x40),
                supplyCap: 1_000 ether,
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
                })
            }),
            erc4626WrapperSpec: LidoLendMarketFactory.ERC4626WrapperSpec({name: "Vault", symbol: "VLT"}),
            curveParams: AdaptiveCurveParams({
                    curveSteepness: 4 ether,
                    adjustmentSpeed: 1,
                    targetUtilization: 0.9 ether,
                    initialRateAtTarget: 2,
                    minRateAtTarget: 1,
                    maxRateAtTarget: 3,
                    maxBorrowRate: 4
                }),
            irmConfig: address(0x1CF6),
            deployedBlock: 100
        });
    }
}
