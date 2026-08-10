// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {ExitBookBase} from "../src/periphery/ExitBookBase.sol";
import {MorphoExitBook} from "../src/periphery/MorphoExitBook.sol";

import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {ExitBookConfig} from "./lib/ExitBookConfigFile.sol";
import {ProtocolConfigFile, ExitBooksDeployment} from "./lib/ProtocolConfigFile.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";
import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";

/// @notice Deploys and records both exit books for an existing protocol.
contract DeployExitBooks is Script, ProtocolDeployer {
    error CoreNotContract(address core);
    error UnexpectedCore(address expected, address actual);
    error UnexpectedMaxRequestLifetime(address book, uint256 expected, uint256 actual);
    error MissingRole(address book, bytes32 role, address holder);
    error UnexpectedRoleMemberCount(address book, bytes32 role, uint256 expected, uint256 actual);
    error DeployerRetainsAdmin(address book, address deployer);

    function run(string memory config) external returns (address morpho, address erc4626) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        string memory protocolArtifact = vm.readFile(ProtocolConfigFile.protocolPath());
        DeployConfigFile.requireRegistryGovernance(deployConfig, protocolArtifact);
        ProtocolConfigFile.requireExitBooksUndeployed();

        address core = vm.parseTomlAddress(protocolArtifact, ".protocol.core");
        if (core.code.length == 0) revert CoreNotContract(core);
        address agent = vm.parseTomlAddress(protocolArtifact, ".protocol.agent");
        address executor = vm.parseTomlAddress(protocolArtifact, ".protocol.evm_script_executor");
        address pauser = deployConfig.exitBookPauser;
        uint256 maxRequestLifetime = deployConfig.exitBookMaxRequestLifetime;
        uint256 deployedBlock = vm.getBlockNumber();
        address deployer = msg.sender;

        vm.startBroadcast();
        (morpho, erc4626) = _deployExitBooks(
            ExitBookConfig({
                agent: agent,
                evmScriptExecutor: executor,
                pauser: pauser,
                core: core,
                maxRequestLifetime: maxRequestLifetime
            }),
            deployer
        );
        vm.stopBroadcast();

        _validateExitBook(morpho, core, agent, executor, pauser, deployer);
        _validateExitBook(erc4626, address(0), agent, executor, pauser, deployer);
        _requireMaxRequestLifetime(morpho, maxRequestLifetime);
        _requireMaxRequestLifetime(erc4626, maxRequestLifetime);
        string memory artifactPath = ProtocolConfigFile.writeExitBooks(
            ExitBooksDeployment({
                morpho: morpho,
                erc4626: erc4626,
                deployedBlock: deployedBlock,
                deployer: deployer,
                agent: agent,
                evmScriptExecutor: executor,
                pauser: pauser,
                maxRequestLifetime: maxRequestLifetime
            }),
            ArtifactMetadata({
                deployment: ArtifactMetadataFile.deployment(),
                chainId: deployConfig.chainId,
                configHash: deployConfig.configHash
            })
        );

        console2.log("morphoExitBook  :", morpho);
        console2.log("erc4626ExitBook :", erc4626);
        console2.log("recorded        :", artifactPath);
    }

    function _validateExitBook(
        address book,
        address expectedCore,
        address agent,
        address executor,
        address pauser,
        address deployer
    ) private view {
        ExitBookBase b = ExitBookBase(book);
        if (expectedCore != address(0)) {
            address actualCore = address(MorphoExitBook(book).MORPHO());
            if (actualCore != expectedCore) revert UnexpectedCore(expectedCore, actualCore);
        }
        _requireRole(b, b.DEFAULT_ADMIN_ROLE(), agent);
        _requireRole(b, b.ALLOWLIST_MANAGER_ROLE(), agent);
        _requireRole(b, b.ALLOWLIST_MANAGER_ROLE(), executor);
        _requireRole(b, b.FEE_MANAGER_ROLE(), agent);
        _requireRole(b, b.RECOVERER_ROLE(), agent);
        _requireRole(b, b.PAUSER_ROLE(), pauser);
        _requireRoleMemberCount(b, b.PAUSER_ROLE(), 1);
        _requireRoleMemberCount(b, b.RESUMER_ROLE(), 0);
        if (b.hasRole(b.DEFAULT_ADMIN_ROLE(), deployer)) revert DeployerRetainsAdmin(book, deployer);
    }

    function _requireRole(ExitBookBase book, bytes32 role, address holder) private view {
        if (!book.hasRole(role, holder)) revert MissingRole(address(book), role, holder);
    }

    function _requireRoleMemberCount(ExitBookBase book, bytes32 role, uint256 expected) private view {
        uint256 actual = book.getRoleMemberCount(role);
        if (actual != expected) revert UnexpectedRoleMemberCount(address(book), role, expected, actual);
    }

    function _requireMaxRequestLifetime(address book, uint256 expected) private view {
        uint256 actual = ExitBookBase(book).MAX_REQUEST_LIFETIME();
        if (actual != expected) revert UnexpectedMaxRequestLifetime(book, expected, actual);
    }
}
