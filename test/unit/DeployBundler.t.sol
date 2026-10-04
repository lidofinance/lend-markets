// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {DeployBundler} from "../../script/DeployBundler.s.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {BundlerConfig, BundlerConfigFile} from "../../script/lib/BundlerConfigFile.sol";
import {ConfigToml} from "../../script/lib/ConfigToml.sol";
import {DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";

contract DeployBundlerHarness is DeployBundler {
    function validateArtifactsFor(string memory run, string memory bundlerName) external view {
        _validateArtifacts(run, bundlerName);
    }
}

contract BundlerConfigHarness {
    function parse(string memory toml) external pure returns (BundlerConfig memory) {
        return BundlerConfigFile.parse(toml);
    }
}

/// @notice RPC-free checks of the bundler deploy script's artifact validation and config reader: a coherent
///         artifact is accepted, an adapter recorded against another core is rejected, and a config missing a
///         key is rejected before anything is deployed.
contract DeployBundlerTest is Test {
    address internal constant AGENT = address(0xA11);
    address internal constant EXECUTOR = address(0xE11);
    address internal constant CORE = address(0xC01);
    /// @dev Stands in for the dispatcher a real run deploys; these checks never deploy one.
    address internal constant BUNDLER3 = address(0xB3);

    DeployBundlerHarness internal harness;
    BundlerConfigHarness internal configHarness;

    function setUp() external {
        harness = new DeployBundlerHarness();
        configHarness = new BundlerConfigHarness();
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

        vm.expectRevert(abi.encodeWithSelector(DeployBundler.RecordedMorphoMismatch.selector, CORE, otherCore));
        harness.validateArtifactsFor(run, "mainnet");
        vm.removeDir(ArtifactMetadataFile.artifactsDir(run), true);
    }

    function testRevert_validateArtifacts_rejectsWrongName() external {
        string memory run = "bundler-artifacts-name-unit";
        _writeArtifacts(run, CORE);

        vm.expectRevert(abi.encodeWithSelector(DeployBundler.RecordedNameMismatch.selector, "other", "mainnet"));
        harness.validateArtifactsFor(run, "other");
        vm.removeDir(ArtifactMetadataFile.artifactsDir(run), true);
    }

    function test_parse_readsTheTokenAddresses() external view {
        BundlerConfig memory cfg = configHarness.parse(
            "weth = \"0x0000000000000000000000000000000000000001\"\nwsteth = \"0x0000000000000000000000000000000000000002\"\n"
        );
        assertEq(cfg.weth, address(1), "weth");
        assertEq(cfg.wsteth, address(2), "wsteth");
    }

    function testRevert_parse_rejectsZeroWeth() external {
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".weth"));
        configHarness.parse(
            "weth = \"0x0000000000000000000000000000000000000000\"\nwsteth = \"0x0000000000000000000000000000000000000002\"\n"
        );
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
                ArtifactMetadataFile.header(metadata, "protocol-deployment"),
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
                ArtifactMetadataFile.header(metadata, "bundler3-adapters"),
                "\n[bundler]\nname = \"mainnet\"\nbundler3 = \"",
                vm.toString(BUNDLER3),
                "\"\nmorpho = \"",
                vm.toString(recordedMorpho),
                "\"\n"
            )
        );
    }
}
