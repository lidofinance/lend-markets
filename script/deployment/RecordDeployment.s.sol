// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {DeploymentArtifact} from "./DeploymentArtifact.sol";
import {
    DeploymentHeader,
    DeploymentSchema,
    ProtocolRecord,
    MarketRecord,
    ExitBooksRecord,
    BundlerRecord,
    VaultV2Record
} from "./DeploymentRecord.sol";

/// @notice Publishes results only from successful Forge receipts whose blocks are canonical on the source RPC.
contract RecordDeployment is Script {
    function run(string memory runName, string memory script) external returns (string memory output) {
        DeploymentArtifact.requireName(runName);
        string[] memory parts = vm.split(script, "/");
        string[] memory contractName = vm.split(parts[parts.length - 1], ":");
        string memory broadcastPath =
            string.concat("broadcast/", contractName[0], "/", vm.toString(block.chainid), "/run-latest.json");
        return _record(runName, vm.readFile(broadcastPath));
    }

    function _record(string memory runName, string memory broadcast) internal returns (string memory output) {
        require(vm.parseJsonUint(broadcast, ".chain") == block.chainid, "Broadcast chain mismatch");
        // Forge's display value retains string escapes inside the broadcast JSON value.
        string memory escaped = vm.parseJsonString(broadcast, ".returns.artifact.value");
        string memory artifact = vm.parseJsonString(string.concat('{"artifact":"', escaped, '"}'), ".artifact");
        DeploymentHeader memory h =
            abi.decode(vm.parseJsonType(artifact, ".header", DeploymentSchema.DEPLOYMENTHEADER), (DeploymentHeader));
        require(h.version == 1 && h.chainId == block.chainid, "Artifact chain or version mismatch");
        require(keccak256(bytes(h.run)) == keccak256(bytes(runName)), "Broadcast run mismatch");
        output = DeploymentArtifact.path(h);
        require(!vm.exists(output), "Deployment artifact already exists");
        _checkReceipts(broadcast, h.sender);
        _checkCode(artifact, h.kind);
        string memory dir = DeploymentArtifact.directory(runName);
        string memory archive = string.concat(dir, "/transactions/", h.kind, "-", h.name, ".json");
        require(
            !vm.exists(archive) || keccak256(bytes(vm.readFile(archive))) == keccak256(bytes(broadcast)),
            "Different broadcast archive already exists"
        );
        vm.createDir(string.concat(dir, "/transactions"), true);
        if (keccak256(bytes(h.kind)) == keccak256("market")) vm.createDir(string.concat(dir, "/markets"), true);
        if (keccak256(bytes(h.kind)) == keccak256("vault")) vm.createDir(string.concat(dir, "/vaults"), true);
        vm.writeFile(archive, broadcast);
        vm.writeToml(artifact, output);
    }

    function _checkReceipts(string memory broadcast, address sender) private {
        bytes32[] memory txs = abi.decode(
            vm.parseJsonTypeArray(broadcast, ".transactions", "DeploymentTransactionHash(bytes32 hash)"), (bytes32[])
        );
        bytes32[] memory receipts = abi.decode(
            vm.parseJsonTypeArray(broadcast, ".receipts", "DeploymentReceiptHash(bytes32 transactionHash)"), (bytes32[])
        );
        require(txs.length != 0 && txs.length == receipts.length, "Incomplete broadcast");
        require(vm.parseJsonStringArray(broadcast, ".pending").length == 0, "Pending broadcast transactions");
        bool[] memory matched = new bool[](receipts.length);
        for (uint256 i; i < txs.length; ++i) {
            uint256 receiptIndex = receipts.length;
            for (uint256 j; j < receipts.length; ++j) {
                if (!matched[j] && receipts[j] == txs[i]) {
                    receiptIndex = j;
                    break;
                }
            }
            require(receiptIndex != receipts.length, "Broadcast receipt mismatch");
            matched[receiptIndex] = true;
            _checkReceipt(broadcast, receiptIndex, sender);
        }
    }

    function _checkReceipt(string memory broadcast, uint256 index, address sender) private {
        string memory key = string.concat(".receipts[", vm.toString(index), "]");
        require(vm.parseJsonUint(broadcast, string.concat(key, ".status")) == 1, "Broadcast transaction failed");
        require(vm.parseJsonAddress(broadcast, string.concat(key, ".from")) == sender, "Broadcast sender mismatch");
        uint256 receiptBlock = vm.parseJsonUint(broadcast, string.concat(key, ".blockNumber"));
        require(receiptBlock <= block.number, "Receipt is ahead of the RPC head");
        uint256 currentBlock = block.number;
        // The fork backend resolves blockhash from the source RPC. Move the local view so even old
        // receipts and the latest mined block are inside the EVM's 256-block lookup window.
        vm.roll(receiptBlock + 1);
        bytes32 canonicalHash = blockhash(receiptBlock);
        vm.roll(currentBlock);
        require(
            canonicalHash != bytes32(0)
                && canonicalHash == vm.parseJsonBytes32(broadcast, string.concat(key, ".blockHash")),
            "Broadcast receipt block is not canonical"
        );
    }

    function _checkCode(string memory artifact, string memory kind) private view {
        bytes32 k = keccak256(bytes(kind));
        if (k == keccak256("protocol")) {
            ProtocolRecord memory r =
                abi.decode(vm.parseJsonType(artifact, DeploymentSchema.PROTOCOLRECORD), (ProtocolRecord));
            require(r.addresses.chainId == block.chainid, "Protocol chain mismatch");
            _code(r.addresses.core);
            _code(r.addresses.factory);
            _code(r.addresses.ownerFacade);
            _code(r.addresses.irmRouter);
            _code(r.addresses.adaptiveCurveIrm);
            _code(r.addresses.irmConfigFactory);
            _code(r.addresses.dashboard);
            _code(r.addresses.circuitBreaker);
        } else if (k == keccak256("market")) {
            MarketRecord memory r =
                abi.decode(vm.parseJsonType(artifact, DeploymentSchema.MARKETRECORD), (MarketRecord));
            _code(r.core);
            _code(r.addresses.controller);
            _code(r.addresses.vault);
            _code(r.addresses.guardianSignals);
            _code(r.addresses.irmConfig);
            _code(r.addresses.params.oracle);
        } else if (k == keccak256("exit-books")) {
            ExitBooksRecord memory r =
                abi.decode(vm.parseJsonType(artifact, DeploymentSchema.EXITBOOKSRECORD), (ExitBooksRecord));
            _code(r.plan.core);
            _code(r.addresses.morpho);
            _code(r.addresses.erc4626);
        } else if (k == keccak256("bundler")) {
            BundlerRecord memory r =
                abi.decode(vm.parseJsonType(artifact, DeploymentSchema.BUNDLERRECORD), (BundlerRecord));
            _code(r.core);
            _code(r.addresses.bundler);
            _code(r.addresses.generalAdapter);
            _code(r.addresses.vaultAdapter);
        } else {
            require(k == keccak256("vault"), "Unknown deployment kind");
            VaultV2Record memory r =
                abi.decode(vm.parseJsonType(artifact, DeploymentSchema.VAULTV2RECORD), (VaultV2Record));
            _code(r.core);
            _code(r.irmRouter);
            _code(r.addresses.vault);
            _code(r.addresses.adapter);
        }
    }

    function _code(address account) private view {
        require(account.code.length != 0, "Recorded contract has no code");
    }
}
