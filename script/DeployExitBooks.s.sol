// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {ExitBookBase} from "../src/periphery/ExitBookBase.sol";
import {MorphoExitBook} from "../src/periphery/MorphoExitBook.sol";

import {ProtocolDeployer} from "./lib/ProtocolDeployer.sol";
import {ExitBookConfig} from "./lib/ExitBookConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";
import {DeployConfigFile, DeployConfig} from "./lib/DeployConfigFile.sol";

/// @notice Deploys both exit books for an existing protocol and appends them to its run registry.
contract DeployExitBooks is Script, ProtocolDeployer {
    error CoreNotContract(address core);
    error UnexpectedCore(address expected, address actual);
    error UnexpectedMaxRequestLifetime(address book, uint256 expected, uint256 actual);
    error MissingRole(address book, bytes32 role, address holder);
    error DeployerRetainsAdmin(address book, address deployer);

    function run(string memory config) external returns (address morpho, address erc4626) {
        DeployConfig memory deployConfig = DeployConfigFile.read(config);
        DeployConfigFile.requireChainId(deployConfig);
        DeployConfigFile.requireActorSeparation(deployConfig, msg.sender);
        string memory registryPath = ProtocolConfigFile.deployedPath();
        string memory registry = vm.readFile(registryPath);
        DeployConfigFile.requireRegistryGovernance(deployConfig, registry);
        ProtocolConfigFile.requireExitBooksAbsent(registryPath);

        address core = vm.parseTomlAddress(registry, ".protocol.core");
        if (core.code.length == 0) revert CoreNotContract(core);
        address agent = vm.parseTomlAddress(registry, ".protocol.agent");
        address executor = vm.parseTomlAddress(registry, ".protocol.evm_script_executor");
        uint256 maxRequestLifetime = deployConfig.exitBookMaxRequestLifetime;
        uint256 deployedBlock = vm.getBlockNumber();
        address deployer = msg.sender;

        vm.startBroadcast();
        (morpho, erc4626) = _deployExitBooks(
            ExitBookConfig({
                agent: agent, evmScriptExecutor: executor, core: core, maxRequestLifetime: maxRequestLifetime
            }),
            deployer
        );
        vm.stopBroadcast();

        _validateExitBook(morpho, core, agent, executor, deployer);
        _validateExitBook(erc4626, address(0), agent, executor, deployer);
        _requireMaxRequestLifetime(morpho, maxRequestLifetime);
        _requireMaxRequestLifetime(erc4626, maxRequestLifetime);
        ProtocolConfigFile.appendExitBooks(registryPath, morpho, erc4626, deployedBlock, deployer, maxRequestLifetime);

        console2.log("morphoExitBook  :", morpho);
        console2.log("erc4626ExitBook :", erc4626);
        console2.log("registry        :", registryPath);
    }

    function _validateExitBook(address book, address expectedCore, address agent, address executor, address deployer)
        private
        view
    {
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
        if (b.hasRole(b.DEFAULT_ADMIN_ROLE(), deployer)) revert DeployerRetainsAdmin(book, deployer);
    }

    function _requireRole(ExitBookBase book, bytes32 role, address holder) private view {
        if (!book.hasRole(role, holder)) revert MissingRole(address(book), role, holder);
    }

    function _requireMaxRequestLifetime(address book, uint256 expected) private view {
        uint256 actual = ExitBookBase(book).MAX_REQUEST_LIFETIME();
        if (actual != expected) revert UnexpectedMaxRequestLifetime(book, expected, actual);
    }
}
