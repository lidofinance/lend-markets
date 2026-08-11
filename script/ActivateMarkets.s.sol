// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {Vm} from "forge-std/Vm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "./lib/DeployConfigFile.sol";
import {ProtocolConfigFile} from "./lib/ProtocolConfigFile.sol";

// --- Minimal write surfaces. The IRM submodule's nested `MarketParams` is ABI-identical to the core's, so the
//     core type matches; the CircuitBreaker pins solc 0.8.34 and cannot be imported here. ---

interface IActivationIrm {
    function applyIrmConfig(MarketParams calldata marketParams, address config) external;
    function marketCurveConfig(bytes32 id) external view returns (address);
}

interface IActivationRouter {
    function manager() external view returns (address);
    function marketIrm(bytes32 id) external view returns (address);
    function setMarketIrm(MarketParams calldata marketParams, address irm) external;
}

interface IActivationFacade {
    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement) external;
}

interface IActivationMorphoBook {
    function isMarketAllowed(bytes32 id) external view returns (bool);
    function setMarketAllowed(MarketParams calldata marketParams, bool allowed) external;
}

interface IActivationErc4626Book {
    function isVaultAllowed(address vault) external view returns (bool);
    function setVaultAllowed(address vault, bool allowed) external;
}

interface IActivationCircuitBreaker {
    function getPauser(address pausable) external view returns (address);
    function registerPauser(address pausable, address newPauser) external;
}

interface IActivationCore {
    function isSettlementEnabled(bytes32 id) external view returns (bool);
    function marketController(bytes32 id) external view returns (address);
    function market(bytes32 id)
        external
        view
        returns (
            uint128 tSupplyA,
            uint128 tSupplyS,
            uint128 tBorrowA,
            uint128 tBorrowS,
            uint128 lastUpdate,
            uint128 fee
        );
}

/// @notice Binds every market recorded in the run, broadcasting as the `EVMScriptExecutor`. Stands in for the
///         `LidoLendActivateMarket` motion on fork and devnet runs, where governance is not available.
/// @dev Call order is fixed: the adaptive model's per-market config precedes `createMarket`, whose first
///      `borrowRate` ping reverts on an unset model. Inputs come from each market's recorded artifact rather
///      than its config. Every completed step is checked independently, so a run interrupted between broadcast
///      transactions resumes at its first missing step.
contract ActivateMarkets is Script {
    using MarketParamsLib for MarketParams;

    error WrongSender(address expected, address actual);
    error MarketIdMismatch(string name, bytes32 fromParams, bytes32 fromArtifact);
    error UnexpectedController(string name, address expected, address actual);
    error UnexpectedIrmConfig(string name, address expected, address actual);
    error UnexpectedIrmRoute(string name, address expected, address actual);
    error UnexpectedPauser(string name, address expected, address actual);
    error UnexpectedSettlementFlag(string name);
    error ProtocolChainIdMismatch(uint256 expected, uint256 actual);
    error ProtocolDeploymentMismatch(string expected, string actual);

    /// @dev Backbone addresses and activation inputs, resolved once in `run`.
    struct Backbone {
        address router;
        address adaptiveCurveIrm;
        address facade;
        address core;
        address circuitBreaker;
        address pauserCommittee;
        bool hasExitBooks;
        address morphoBook;
        address erc4626Book;
    }

    struct ActivationInput {
        string name;
        address controller;
        address vault;
        MarketParams market;
        address irmConfig;
    }

    Backbone internal bb;

    function run() external {
        string memory protocolPath = ProtocolConfigFile.protocolPath();
        string memory protocol = vm.readFile(protocolPath);
        string memory deployment = ArtifactMetadataFile.deployment();
        string memory recordedDeployment = vm.parseTomlString(protocol, ".protocol.deployment");
        if (keccak256(bytes(recordedDeployment)) != keccak256(bytes(deployment))) {
            revert ProtocolDeploymentMismatch(deployment, recordedDeployment);
        }

        uint256 protocolChainId = vm.parseTomlUint(protocol, ".protocol.chain_id");
        if (protocolChainId != block.chainid) revert ProtocolChainIdMismatch(protocolChainId, block.chainid);
        DeployConfigFile.requireProtocolArtifactCompatibility(protocol);

        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: deployment,
            chainId: block.chainid,
            configHash: vm.parseTomlBytes32(protocol, ".protocol.config_hash"),
            compatibilityHash: vm.parseTomlBytes32(protocol, ".artifact.compatibility_hash")
        });
        protocol = ArtifactMetadataFile.requireExact(protocolPath, metadata);

        bb.router = vm.parseTomlAddress(protocol, ".protocol.irm_router");
        bb.adaptiveCurveIrm = vm.parseTomlAddress(protocol, ".protocol.adaptive_curve_irm");
        bb.facade = vm.parseTomlAddress(protocol, ".protocol.owner_facade");
        bb.core = vm.parseTomlAddress(protocol, ".protocol.core");
        bb.circuitBreaker = vm.parseTomlAddress(protocol, ".protocol.circuit_breaker");
        // Motion input: governance routes an emergency committee. The Agent stands in for it.
        bb.pauserCommittee = vm.parseTomlAddress(protocol, ".protocol.agent");

        string memory exitBooksPath = ProtocolConfigFile.exitBooksPath();
        if (vm.exists(exitBooksPath)) {
            string memory exitBooks = ArtifactMetadataFile.requireCompatible(exitBooksPath, metadata);
            bb.hasExitBooks = true;
            bb.morphoBook = vm.parseTomlAddress(exitBooks, ".exit_books.morpho");
            bb.erc4626Book = vm.parseTomlAddress(exitBooks, ".exit_books.erc4626");
        }

        // Validate the complete input set before the first broadcast. Otherwise a bad later artifact could leave
        // an earlier market partially activated.
        Vm.DirEntry[] memory entries = vm.readDir(ProtocolConfigFile.marketsDir());
        ActivationInput[] memory markets = new ActivationInput[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || entries[i].isSymlink) continue;
            string memory artifact = ArtifactMetadataFile.requireCompatible(entries[i].path, metadata);
            markets[i] = _loadActivationInput(artifact);
        }

        // The broadcaster must be the router's manager, i.e. the executor the deployment wired.
        address executor = IActivationRouter(bb.router).manager();
        if (msg.sender != executor) revert WrongSender(executor, msg.sender);

        // Check every already-completed step before sending the first transaction. A conflicting later market
        // must not leave an earlier one newly activated.
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || entries[i].isSymlink) continue;
            _requireResumable(markets[i]);
        }

        // The run directory is the authoritative market set: a market added after the backbone deploy is
        // recorded here but appears in no config.
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || entries[i].isSymlink) continue;
            _activateOne(markets[i]);
        }
    }

    function _loadActivationInput(string memory artifact) internal view returns (ActivationInput memory input) {
        input.name = vm.parseTomlString(artifact, ".market.name");
        input.controller = vm.parseTomlAddress(artifact, ".market.controller");
        input.vault = vm.parseTomlAddress(artifact, ".market.vault");
        bytes32 artifactId = vm.parseTomlBytes32(artifact, ".market.id");

        input.market = MarketParams({
            loanToken: vm.parseTomlAddress(artifact, ".market.loan_token"),
            collateralToken: vm.parseTomlAddress(artifact, ".market.collateral_token"),
            oracle: vm.parseTomlAddress(artifact, ".market.oracle"),
            irm: bb.router,
            lltv: vm.parseTomlUint(artifact, ".market.lltv")
        });

        bytes32 id = Id.unwrap(input.market.id());
        if (id != artifactId) revert MarketIdMismatch(input.name, id, artifactId);
        input.irmConfig = vm.parseTomlAddress(artifact, ".market.irm_config");
    }

    function _activateOne(ActivationInput memory input) internal {
        vm.startBroadcast();
        _resumeActivation(input.name, input.market, input.controller, input.vault, input.irmConfig);
        vm.stopBroadcast();

        console2.log("activation complete:", input.name);
        console2.log("  routed irm:", bb.adaptiveCurveIrm);
    }

    function _requireResumable(ActivationInput memory input) internal view {
        bytes32 id = Id.unwrap(input.market.id());
        address currentIrmConfig = IActivationIrm(bb.adaptiveCurveIrm).marketCurveConfig(id);
        if (currentIrmConfig != address(0) && currentIrmConfig != input.irmConfig) {
            revert UnexpectedIrmConfig(input.name, input.irmConfig, currentIrmConfig);
        }

        address currentIrm = IActivationRouter(bb.router).marketIrm(id);
        if (currentIrm != address(0) && currentIrm != bb.adaptiveCurveIrm) {
            revert UnexpectedIrmRoute(input.name, bb.adaptiveCurveIrm, currentIrm);
        }

        (,,,, uint128 lastUpdate,) = IActivationCore(bb.core).market(id);
        if (lastUpdate != 0) {
            address currentController = IActivationCore(bb.core).marketController(id);
            if (currentController != input.controller) {
                revert UnexpectedController(input.name, input.controller, currentController);
            }
            if (!IActivationCore(bb.core).isSettlementEnabled(id)) revert UnexpectedSettlementFlag(input.name);
        }

        if (bb.circuitBreaker != address(0)) {
            address currentPauser = IActivationCircuitBreaker(bb.circuitBreaker).getPauser(input.controller);
            if (currentPauser != address(0) && currentPauser != bb.pauserCommittee) {
                revert UnexpectedPauser(input.name, bb.pauserCommittee, currentPauser);
            }
        }
    }

    function _resumeActivation(
        string memory name,
        MarketParams memory p,
        address controller,
        address vault,
        address irmConfig
    ) internal {
        bytes32 id = Id.unwrap(p.id());
        address currentIrmConfig = IActivationIrm(bb.adaptiveCurveIrm).marketCurveConfig(id);
        if (currentIrmConfig == address(0)) IActivationIrm(bb.adaptiveCurveIrm).applyIrmConfig(p, irmConfig);
        else if (currentIrmConfig != irmConfig) revert UnexpectedIrmConfig(name, irmConfig, currentIrmConfig);

        address currentIrm = IActivationRouter(bb.router).marketIrm(id);
        if (currentIrm == address(0)) IActivationRouter(bb.router).setMarketIrm(p, bb.adaptiveCurveIrm);
        else if (currentIrm != bb.adaptiveCurveIrm) revert UnexpectedIrmRoute(name, bb.adaptiveCurveIrm, currentIrm);

        (,,,, uint128 lastUpdate,) = IActivationCore(bb.core).market(id);
        if (lastUpdate == 0) {
            IActivationFacade(bb.facade).createMarket(p, controller, true);
        } else {
            address currentController = IActivationCore(bb.core).marketController(id);
            if (currentController != controller) revert UnexpectedController(name, controller, currentController);
            if (!IActivationCore(bb.core).isSettlementEnabled(id)) revert UnexpectedSettlementFlag(name);
        }

        if (bb.circuitBreaker != address(0)) {
            address currentPauser = IActivationCircuitBreaker(bb.circuitBreaker).getPauser(controller);
            if (currentPauser == address(0)) {
                IActivationCircuitBreaker(bb.circuitBreaker).registerPauser(controller, bb.pauserCommittee);
            } else if (currentPauser != bb.pauserCommittee) {
                revert UnexpectedPauser(name, bb.pauserCommittee, currentPauser);
            }
        }
        if (bb.hasExitBooks) {
            if (!IActivationMorphoBook(bb.morphoBook).isMarketAllowed(id)) {
                IActivationMorphoBook(bb.morphoBook).setMarketAllowed(p, true);
            }
            if (!IActivationErc4626Book(bb.erc4626Book).isVaultAllowed(vault)) {
                IActivationErc4626Book(bb.erc4626Book).setVaultAllowed(vault, true);
            }
        }
    }
}
