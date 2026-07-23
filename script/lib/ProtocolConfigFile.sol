// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "./ArtifactMetadata.sol";

struct ProtocolConfig {
    address agent;
    address evmScriptExecutor;
}

struct ProtocolDeployment {
    string deployment;
    string network;
    uint256 chainId;
    bytes32 configHash;
    address core;
    address ownerFacade;
    address irmRouter;
    address adaptiveCurveIrm;
    address factory;
    address builder;
    address riskStewardDashboard;
    address guardianSignalsImpl;
    uint256 deployedBlock;
    address deployer;
    address agent;
    address evmScriptExecutor;
}

struct MarketDeployment {
    string name;
    bytes32 id;
    address controller;
    address vault;
    address oracle;
    address guardianSignals;
    address[] pausers;
    uint256 deployedBlock;
}

struct Deployment {
    ProtocolDeployment protocol;
    bool hasExitBooks;
    address morphoExitBook;
    address erc4626ExitBook;
    uint256 exitBooksDeployedBlock;
    address exitBooksDeployer;
    uint256 exitBookMaxRequestLifetime;
    MarketDeployment[] markets;
}

library ProtocolConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    error MarketAlreadyRecorded(string name);
    error MarketIdAlreadyRecorded(bytes32 id);
    error ExitBooksAlreadyRecorded();
    error ArtifactAlreadyExists(string path);

    function writeDeployment(Deployment memory d) internal returns (string memory path) {
        ArtifactMetadataFile.ensureArtifactsDir();
        string memory s = ArtifactMetadataFile.header(
            ArtifactMetadata({
                deployment: d.protocol.deployment, chainId: d.protocol.chainId, configHash: d.protocol.configHash
            }),
            "protocol-registry"
        );
        s = string.concat(s, "\n[protocol]\n");
        s = string.concat(s, _kv("deployment", d.protocol.deployment));
        s = string.concat(s, _kv("network", d.protocol.network));
        s = string.concat(s, _kv("chain_id", d.protocol.chainId));
        s = string.concat(s, _kv("config_hash", d.protocol.configHash));
        s = string.concat(s, _kv("core", d.protocol.core));
        s = string.concat(s, _kv("owner_facade", d.protocol.ownerFacade));
        s = string.concat(s, _kv("irm_router", d.protocol.irmRouter));
        s = string.concat(s, _kv("adaptive_curve_irm", d.protocol.adaptiveCurveIrm));
        s = string.concat(s, _kv("factory", d.protocol.factory));
        s = string.concat(s, _kv("builder", d.protocol.builder));
        s = string.concat(s, _kv("risk_steward_dashboard", d.protocol.riskStewardDashboard));
        s = string.concat(s, _kv("guardian_signals_impl", d.protocol.guardianSignalsImpl));
        s = string.concat(s, _kv("deployed_block", d.protocol.deployedBlock));
        s = string.concat(s, _kv("deployer", d.protocol.deployer));
        s = string.concat(s, _kv("agent", d.protocol.agent));
        s = string.concat(s, _kv("evm_script_executor", d.protocol.evmScriptExecutor));

        if (d.hasExitBooks) {
            s = string.concat(
                s,
                _exitBooksSection(
                    d.morphoExitBook,
                    d.erc4626ExitBook,
                    d.exitBooksDeployedBlock,
                    d.exitBooksDeployer,
                    d.exitBookMaxRequestLifetime
                )
            );
        }

        for (uint256 i; i < d.markets.length; ++i) {
            s = string.concat(s, _marketSection(d.markets[i]));
        }

        path = deployedPath();
        _requireArtifactAbsent(path);
        vm.writeFile(path, s);
    }

    function requireDeploymentUndeployed() internal view {
        _requireArtifactAbsent(deployedPath());
    }

    function appendMarket(string memory path, MarketDeployment memory m) internal {
        requireMarketAbsent(path, m.name);
        vm.writeFile(path, string.concat(vm.readFile(path), _marketSection(m)));
    }

    function appendExitBooks(
        string memory path,
        address morpho,
        address erc4626,
        uint256 deployedBlock,
        address deployer,
        uint256 maxRequestLifetime
    ) internal {
        requireExitBooksAbsent(path);
        vm.writeFile(
            path,
            string.concat(
                vm.readFile(path), _exitBooksSection(morpho, erc4626, deployedBlock, deployer, maxRequestLifetime)
            )
        );
    }

    function requireExitBooksAbsent(string memory path) internal view {
        string memory registry = vm.readFile(path);
        if (vm.keyExistsToml(registry, ".exit_books.morpho") || vm.keyExistsToml(registry, ".exit_books.erc4626")) {
            revert ExitBooksAlreadyRecorded();
        }
    }

    function requireMarketAbsent(string memory path, string memory name) internal view {
        if (vm.keyExistsToml(vm.readFile(path), string.concat(".markets.", name))) {
            revert MarketAlreadyRecorded(name);
        }
    }

    /// @dev Matches the exact market-id line to avoid other bytes32 fields.
    function requireMarketIdAbsent(string memory path, bytes32 id) internal view {
        if (containsMarketId(vm.readFile(path), id)) revert MarketIdAlreadyRecorded(id);
    }

    function containsMarketId(string memory registry, bytes32 id) internal pure returns (bool) {
        bytes memory haystack = bytes(registry);
        bytes memory needle = bytes(string.concat("id = \"", vm.toString(id), "\""));
        if (needle.length > haystack.length) return false;

        for (uint256 i; i <= haystack.length - needle.length; ++i) {
            bool matches = true;
            for (uint256 j; j < needle.length; ++j) {
                if (haystack[i + j] != needle[j]) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    function writeMarketOnly(MarketDeployment memory m, ArtifactMetadata memory metadata)
        internal
        returns (string memory path)
    {
        ArtifactMetadataFile.ensureArtifactsDir();
        path = string.concat(ArtifactMetadataFile.artifactsDir(), "/market-", m.name, ".toml");
        _requireArtifactAbsent(path);
        vm.writeFile(path, string.concat(ArtifactMetadataFile.header(metadata, "market-deployment"), _marketSection(m)));
    }

    function _marketSection(MarketDeployment memory m) private pure returns (string memory s) {
        s = string.concat("\n[markets.", m.name, "]\n");
        s = string.concat(s, _kv("id", m.id));
        s = string.concat(s, _kv("controller", m.controller));
        s = string.concat(s, _kv("vault", m.vault));
        s = string.concat(s, _kv("oracle", m.oracle));
        s = string.concat(s, _kv("guardian_signals", m.guardianSignals));
        s = string.concat(s, _kvArray("pausers", m.pausers));
        s = string.concat(s, _kv("deployed_block", m.deployedBlock));
    }

    function _exitBooksSection(
        address morpho,
        address erc4626,
        uint256 deployedBlock,
        address deployer,
        uint256 maxRequestLifetime
    ) private pure returns (string memory s) {
        s = "\n[exit_books]\n";
        s = string.concat(s, _kv("morpho", morpho));
        s = string.concat(s, _kv("erc4626", erc4626));
        s = string.concat(s, _kv("deployed_block", deployedBlock));
        s = string.concat(s, _kv("deployer", deployer));
        s = string.concat(s, _kv("max_request_lifetime", maxRequestLifetime));
    }

    function _kv(string memory key, string memory value) private pure returns (string memory) {
        return string.concat(key, " = \"", value, "\"\n");
    }

    function _kv(string memory key, address value) private pure returns (string memory) {
        return string.concat(key, " = \"", vm.toString(value), "\"\n");
    }

    function _kv(string memory key, bytes32 value) private pure returns (string memory) {
        return string.concat(key, " = \"", vm.toString(value), "\"\n");
    }

    function _kv(string memory key, uint256 value) private pure returns (string memory) {
        return string.concat(key, " = ", vm.toString(value), "\n");
    }

    function _kvArray(string memory key, address[] memory values) private pure returns (string memory s) {
        s = string.concat(key, " = [");
        for (uint256 i; i < values.length; ++i) {
            s = string.concat(s, i == 0 ? "\"" : ", \"", vm.toString(values[i]), "\"");
        }
        s = string.concat(s, "]\n");
    }

    function deployedPath() internal view returns (string memory) {
        return string.concat(ArtifactMetadataFile.artifactsDir(), "/registry.toml");
    }

    function _requireArtifactAbsent(string memory path) private view {
        if (vm.exists(path)) revert ArtifactAlreadyExists(path);
    }
}
