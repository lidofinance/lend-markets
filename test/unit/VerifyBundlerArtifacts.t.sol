// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {HistoricalArtifacts} from "../setup/HistoricalArtifacts.sol";

import {Test} from "forge-std/Test.sol";

import {VerifyBundlerArtifacts} from "../../script/legacy/VerifyBundlerArtifacts.s.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/legacy/lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "../../script/legacy/lib/DeployConfigFile.sol";

contract VerifyBundlerArtifactsHarness is VerifyBundlerArtifacts {
    function validateArtifactsFor(string memory run, string memory bundlerName) external view {
        _validateArtifacts(run, bundlerName);
    }
}

/// @notice Historical bundler artifacts must identify the intended deployment and core.
contract VerifyBundlerArtifactsTest is Test {
    address internal constant AGENT = address(0xA11);
    address internal constant EXECUTOR = address(0xE11);
    address internal constant CORE = address(0xC01);
    /// @dev Stands in for the dispatcher a real run deploys; these checks never deploy one.
    address internal constant BUNDLER3 = address(0xB3);

    VerifyBundlerArtifactsHarness internal harness;

    function setUp() external {
        harness = new VerifyBundlerArtifactsHarness();
    }

    function test_validateArtifacts_acceptsCoherentArtifact() external {
        string memory run = "bundler-artifacts-valid-unit";
        _writeArtifacts(run, CORE);

        harness.validateArtifactsFor(run, "mainnet");
        vm.removeDir(ArtifactMetadataFile.artifactsDir(run), true);
    }

    function testRevert_validateArtifacts_rejectsAdapterFromAnotherCore() external {
        string memory run = "bundler-artifacts-core-unit";
        address otherCore = address(0xBAD);
        _writeArtifacts(run, otherCore);

        vm.expectRevert(abi.encodeWithSelector(VerifyBundlerArtifacts.RecordedMorphoMismatch.selector, CORE, otherCore));
        harness.validateArtifactsFor(run, "mainnet");
        vm.removeDir(ArtifactMetadataFile.artifactsDir(run), true);
    }

    function testRevert_validateArtifacts_rejectsWrongName() external {
        string memory run = "bundler-artifacts-name-unit";
        _writeArtifacts(run, CORE);

        vm.expectRevert(
            abi.encodeWithSelector(VerifyBundlerArtifacts.RecordedNameMismatch.selector, "other", "mainnet")
        );
        harness.validateArtifactsFor(run, "other");
        vm.removeDir(ArtifactMetadataFile.artifactsDir(run), true);
    }

    function _writeArtifacts(string memory run, address recordedMorpho) private {
        string memory dir = ArtifactMetadataFile.artifactsDir(run);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);

        bytes32 configHash = bytes32(uint256(0xCAFE));
        address resealManager = address(0x5EA1);
        bytes32 compatibilityHash =
            DeployConfigFile.canonicalCompatibilityHash("unit", 1, AGENT, EXECUTOR, resealManager, "lido-lend");
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: run, chainId: 1, configHash: configHash, compatibilityHash: compatibilityHash
        });

        vm.writeFile(
            string.concat(dir, "/protocol.toml"),
            string.concat(
                HistoricalArtifacts.header(metadata, "protocol-deployment"),
                "\n[protocol]\ndeployment = \"",
                run,
                "\"\nnetwork = \"unit\"\nchain_id = 1\nconfig_hash = \"",
                vm.toString(configHash),
                "\"\nagent = \"",
                vm.toString(AGENT),
                "\"\nevm_script_executor = \"",
                vm.toString(EXECUTOR),
                "\"\nreseal_manager = \"",
                vm.toString(resealManager),
                "\"\ncircuit_breaker_artifact = \"lido-lend\"\ncore = \"",
                vm.toString(CORE),
                "\"\n"
            )
        );
        vm.writeFile(
            string.concat(dir, "/bundler.toml"),
            string.concat(
                HistoricalArtifacts.header(metadata, "bundler3-adapters"),
                "\n[bundler]\nname = \"mainnet\"\nbundler3 = \"",
                vm.toString(BUNDLER3),
                "\"\nmorpho = \"",
                vm.toString(recordedMorpho),
                "\"\n"
            )
        );
    }
}
