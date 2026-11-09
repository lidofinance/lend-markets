// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {DeploymentArtifact} from "./DeploymentArtifact.sol";
import {ProtocolRecord, DeploymentSchema} from "./DeploymentRecord.sol";
import {ProtocolAddresses} from "./DeploymentTypes.sol";
import {ArtifactMetadataFile} from "../legacy/lib/ArtifactMetadata.sol";

/// @notice Exports protocol addresses as an inheritable Solidity contract.
contract GenerateProtocol is Script {
    function run(string memory runName) external returns (string memory output) {
        string memory runDir = ArtifactMetadataFile.artifactsDir(runName);
        string memory protocol = vm.readFile(string.concat(runDir, "/protocol.toml"));
        ProtocolAddresses memory p;
        bool current = vm.keyExistsToml(protocol, ".header.version");
        if (current) {
            ProtocolRecord memory record = abi.decode(
                DeploymentArtifact.read(
                    string.concat(runDir, "/protocol.toml"), runName, "protocol", DeploymentSchema.PROTOCOLRECORD
                ),
                (ProtocolRecord)
            );
            p = record.addresses;
            require(p.chainId == record.header.chainId, "Protocol identity differs from selected run");
        } else {
            require(
                keccak256(bytes(vm.parseTomlString(protocol, ".protocol.deployment"))) == keccak256(bytes(runName))
                    && keccak256(bytes(vm.parseTomlString(protocol, ".artifact.deployment")))
                        == keccak256(bytes(runName))
                    && vm.parseTomlUint(protocol, ".protocol.chain_id")
                        == vm.parseTomlUint(protocol, ".artifact.chain_id"),
                "Protocol identity differs from selected run"
            );
            p.chainId = vm.parseTomlUint(protocol, ".protocol.chain_id");
        }
        string memory source = string.concat(
            "// SPDX-License-Identifier: GPL-2.0-or-later\npragma solidity 0.8.36;\n\n",
            'import {ProtocolAddresses} from "../../DeploymentTypes.sol";\n\n',
            "// Generated from ",
            runDir,
            "; regenerate instead of editing addresses.\n",
            "abstract contract Protocol {\n",
            "    function _protocolAddresses() internal pure returns (ProtocolAddresses memory p) {\n",
            "        p.chainId = ",
            vm.toString(p.chainId),
            ";\n"
        );
        string[11] memory fields = [
            "core",
            "factory",
            "ownerFacade",
            "irmRouter",
            "adaptiveCurveIrm",
            "irmConfigFactory",
            "dashboard",
            "circuitBreaker",
            "resealManager",
            "agent",
            "executor"
        ];
        string[11] memory keys = [
            "core",
            "factory",
            "owner_facade",
            "irm_router",
            "adaptive_curve_irm",
            "irm_config_factory",
            "risk_steward_dashboard",
            "circuit_breaker",
            "reseal_manager",
            "agent",
            "evm_script_executor"
        ];
        address[11] memory addresses = [
            p.core,
            p.factory,
            p.ownerFacade,
            p.irmRouter,
            p.adaptiveCurveIrm,
            p.irmConfigFactory,
            p.dashboard,
            p.circuitBreaker,
            p.resealManager,
            p.agent,
            p.executor
        ];
        for (uint256 i; i < 11; ++i) {
            source = string.concat(
                source,
                _assignment(
                    fields[i],
                    current ? addresses[i] : vm.parseTomlAddress(protocol, string.concat(".protocol.", keys[i]))
                )
            );
        }
        string memory directory = string.concat("script/deployment/generated/", runName);
        vm.createDir(directory, true);
        output = string.concat(directory, "/Protocol.sol");
        vm.writeFile(output, string.concat(source, "    }\n}\n"));
    }

    function _assignment(string memory field, address value) private pure returns (string memory) {
        return string.concat("        p.", field, " = ", vm.toString(value), ";\n");
    }
}
