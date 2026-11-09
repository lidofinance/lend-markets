// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {HistoricalArtifacts} from "../setup/HistoricalArtifacts.sol";

import {Test} from "forge-std/Test.sol";

import {VerifyVaultV2Artifacts} from "../../script/legacy/VerifyVaultV2Artifacts.s.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/legacy/lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "../../script/legacy/lib/DeployConfigFile.sol";

contract VerifyVaultV2ArtifactsHarness is VerifyVaultV2Artifacts {
    function validateArtifactsFor(string memory run, string memory vaultName, string memory adapterName) external view {
        _validateArtifacts(run, vaultName, adapterName);
    }
}

contract VerifyVaultV2ArtifactsTest is Test {
    address internal constant AGENT = address(0xA11);
    address internal constant EXECUTOR = address(0xE11);
    address internal constant CORE = address(0xC01);
    address internal constant IRM_ROUTER = address(0x1A1);
    address internal constant VAULT = address(0xA017);

    VerifyVaultV2ArtifactsHarness internal harness;

    function setUp() external {
        harness = new VerifyVaultV2ArtifactsHarness();
    }

    function test_validateArtifacts_acceptsCoherentPair() external {
        string memory run = "vault-artifacts-valid-unit";
        _writeArtifacts(run, CORE);

        harness.validateArtifactsFor(run, "vault", "adapter");
        vm.removeDir(ArtifactMetadataFile.artifactsDir(run), true);
    }

    function testRevert_validateArtifacts_rejectsAdapterFromAnotherCore() external {
        string memory run = "vault-artifacts-core-unit";
        address otherCore = address(0xBAD);
        _writeArtifacts(run, otherCore);

        vm.expectRevert(abi.encodeWithSelector(VerifyVaultV2Artifacts.AdapterCoreMismatch.selector, CORE, otherCore));
        harness.validateArtifactsFor(run, "vault", "adapter");
        vm.removeDir(ArtifactMetadataFile.artifactsDir(run), true);
    }

    function _writeArtifacts(string memory run, address adapterCore) private {
        string memory dir = ArtifactMetadataFile.artifactsDir(run);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(string.concat(dir, "/vaults"), true);
        vm.createDir(string.concat(dir, "/adapters"), true);

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
                "\"\nirm_router = \"",
                vm.toString(IRM_ROUTER),
                "\"\n"
            )
        );
        vm.writeFile(
            string.concat(dir, "/vaults/vault.toml"),
            string.concat(
                HistoricalArtifacts.header(metadata, "vault-v2"),
                "\n[vault]\nname = \"vault\"\naddress = \"",
                vm.toString(VAULT),
                "\"\n"
            )
        );
        vm.writeFile(
            string.concat(dir, "/adapters/adapter.toml"),
            string.concat(
                HistoricalArtifacts.header(metadata, "vault-v2-adapter"),
                "\n[adapter]\nname = \"adapter\"\nvault_artifact = \"vault\"\nvault = \"",
                vm.toString(VAULT),
                "\"\nmorpho = \"",
                vm.toString(adapterCore),
                "\"\nadaptive_curve_irm = \"",
                vm.toString(IRM_ROUTER),
                "\"\n"
            )
        );
    }
}
