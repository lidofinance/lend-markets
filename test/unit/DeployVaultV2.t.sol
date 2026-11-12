// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {IVaultV2} from "@vault-v2/src/interfaces/IVaultV2.sol";
import {IMorphoMarketV1AdapterV2} from "@vault-v2/src/adapters/interfaces/IMorphoMarketV1AdapterV2.sol";

import {DeployVaultV2} from "../../script/DeployVaultV2.s.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";
import {MockERC20} from "../setup/Mocks.sol";

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

    /// @dev A new vault of the pinned upstream vault-v2 has every timelock at zero. A named curator can then submit
    ///      and execute each curator action in one transaction. `script/DeployVaultV2.s.sol` sets no timelock, so a
    ///      deployed vault starts with this default. This test does not run the script.
    function test_pinnedVaultV2_newVaultHasZeroTimelocks() external {
        IVaultV2 vault = _deployVault();
        bytes4[18] memory timelocked = [
            IVaultV2.setIsAllocator.selector,
            IVaultV2.setReceiveSharesGate.selector,
            IVaultV2.setSendSharesGate.selector,
            IVaultV2.setReceiveAssetsGate.selector,
            IVaultV2.setSendAssetsGate.selector,
            IVaultV2.setAdapterRegistry.selector,
            IVaultV2.addAdapter.selector,
            IVaultV2.removeAdapter.selector,
            IVaultV2.increaseTimelock.selector,
            IVaultV2.decreaseTimelock.selector,
            IVaultV2.abdicate.selector,
            IVaultV2.setPerformanceFee.selector,
            IVaultV2.setManagementFee.selector,
            IVaultV2.setPerformanceFeeRecipient.selector,
            IVaultV2.setManagementFeeRecipient.selector,
            IVaultV2.increaseAbsoluteCap.selector,
            IVaultV2.increaseRelativeCap.selector,
            IVaultV2.setForceDeallocatePenalty.selector
        ];
        for (uint256 i; i < timelocked.length; ++i) {
            assertEq(vault.timelock(timelocked[i]), 0, vm.toString(abi.encodePacked(timelocked[i])));
        }
    }

    /// @dev A new vault of the pinned upstream vault-v2 has no gate, so anyone can deposit and hold shares.
    ///      `script/DeployVaultV2.s.sol` sets no gate, so a deployed vault starts with this default. This test does
    ///      not run the script.
    function test_pinnedVaultV2_newVaultHasNoGates() external {
        IVaultV2 vault = _deployVault();
        assertEq(vault.receiveSharesGate(), address(0), "receiveSharesGate");
        assertEq(vault.sendSharesGate(), address(0), "sendSharesGate");
        assertEq(vault.receiveAssetsGate(), address(0), "receiveAssetsGate");
        assertEq(vault.sendAssetsGate(), address(0), "sendAssetsGate");
    }

    /// @dev A new adapter of the pinned upstream vault-v2 has every timelock at zero. A named curator can then burn
    ///      the adapter's market shares in one transaction. `script/DeployVaultV2.s.sol` sets no timelock, so a
    ///      deployed adapter starts with this default. This test does not run the script.
    function test_pinnedVaultV2_newAdapterHasZeroTimelocks() external {
        IVaultV2 vault = _deployVault();
        IMorphoMarketV1AdapterV2 adapter = IMorphoMarketV1AdapterV2(
            vm.deployCode(
                "MorphoMarketV1AdapterV2.sol:MorphoMarketV1AdapterV2", abi.encode(address(vault), CORE, IRM_ROUTER)
            )
        );
        bytes4[5] memory timelocked = [
            IMorphoMarketV1AdapterV2.increaseTimelock.selector,
            IMorphoMarketV1AdapterV2.decreaseTimelock.selector,
            IMorphoMarketV1AdapterV2.abdicate.selector,
            IMorphoMarketV1AdapterV2.setSkimRecipient.selector,
            IMorphoMarketV1AdapterV2.burnShares.selector
        ];
        for (uint256 i; i < timelocked.length; ++i) {
            assertEq(adapter.timelock(timelocked[i]), 0, vm.toString(abi.encodePacked(timelocked[i])));
        }
    }

    /// @dev Deploys the pinned upstream `VaultV2` from its `out/` artifact. `DeployVaultV2.run` reads `ARTIFACTS_DIR`
    ///      from the environment and needs a live protocol, so a unit test cannot drive it.
    function _deployVault() private returns (IVaultV2) {
        MockERC20 asset = new MockERC20("Asset", "AST", 18);
        return IVaultV2(vm.deployCode("VaultV2.sol:VaultV2", abi.encode(AGENT, address(asset))));
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
