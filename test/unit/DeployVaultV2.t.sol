// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {DeployVaultV2} from "../../script/DeployVaultV2.s.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";

contract DeployVaultV2Harness is DeployVaultV2 {
    function requireAdapterTargets(string memory protocol) external view returns (address core, address irmRouter) {
        return _requireAdapterTargets(protocol);
    }

    function validateArtifactsFor(string memory run, string memory vaultName, string memory adapterName) external view {
        _validateArtifacts(run, vaultName, adapterName);
    }
}

contract DeployVaultV2Test is Test {
    address internal constant AGENT = address(0xA11);
    address internal constant EXECUTOR = address(0xE11);
    address internal constant CORE = address(0xC01);
    address internal constant IRM_ROUTER = address(0x1A1);
    address internal constant VAULT = address(0xA017);

    DeployVaultV2Harness internal harness;

    function setUp() external {
        harness = new DeployVaultV2Harness();
    }

    function testRevert_requireAdapterTargets_irmRouterNotContract() external {
        address irmRouter = makeAddr("missingIrmRouter");

        vm.expectRevert(abi.encodeWithSelector(DeployVaultV2.ProtocolIrmRouterNotContract.selector, irmRouter));
        harness.requireAdapterTargets(_protocol(address(harness), irmRouter));
    }

    function test_requireAdapterTargets_acceptsContracts() external view {
        (address core, address irmRouter) = harness.requireAdapterTargets(_protocol(address(harness), address(harness)));

        assertEq(core, address(harness));
        assertEq(irmRouter, address(harness));
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

        vm.expectRevert(abi.encodeWithSelector(DeployVaultV2.AdapterCoreMismatch.selector, CORE, otherCore));
        harness.validateArtifactsFor(run, "vault", "adapter");
        vm.removeDir(ArtifactMetadataFile.artifactsDir(run), true);
    }

    function _protocol(address core, address irmRouter) private view returns (string memory) {
        return string.concat(
            "[protocol]\ncore = \"", vm.toString(core), "\"\nirm_router = \"", vm.toString(irmRouter), "\"\n"
        );
    }

    function _writeArtifacts(string memory run, address adapterCore) private {
        string memory dir = ArtifactMetadataFile.artifactsDir(run);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(string.concat(dir, "/vaults"), true);
        vm.createDir(string.concat(dir, "/adapters"), true);

        bytes32 configHash = bytes32(uint256(0xCAFE));
        bytes32 compatibilityHash = DeployConfigFile.canonicalCompatibilityHash("unit", 1, AGENT, EXECUTOR, "lido-lend");
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
                ArtifactMetadataFile.header(metadata, "vault-v2"),
                "\n[vault]\nname = \"vault\"\naddress = \"",
                vm.toString(VAULT),
                "\"\n"
            )
        );
        vm.writeFile(
            string.concat(dir, "/adapters/adapter.toml"),
            string.concat(
                ArtifactMetadataFile.header(metadata, "vault-v2-adapter"),
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
