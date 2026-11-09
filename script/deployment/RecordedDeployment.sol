// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {LegacyDeployment} from "../legacy/LegacyDeployment.sol";
import {ArtifactMetadataFile} from "../legacy/lib/ArtifactMetadata.sol";
import {DeploymentArtifact} from "./DeploymentArtifact.sol";
import {DeploymentSnapshot, RecordedMarket} from "./DeploymentSnapshot.sol";
import {
    DeploymentSchema,
    ProtocolRecord,
    MarketRecord,
    ExitBooksRecord,
    BundlerRecord,
    VaultV2Record
} from "./DeploymentRecord.sol";

library RecordedDeployment {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function load(string memory runName) internal view returns (DeploymentSnapshot memory d) {
        string memory dir = DeploymentArtifact.directory(runName);
        bool historical = !vm.keyExistsToml(vm.readFile(string.concat(dir, "/protocol.toml")), ".header.version");
        if (historical) {
            d = LegacyDeployment.loadProtocol(runName);
        } else {
            ProtocolRecord memory p = abi.decode(
                DeploymentArtifact.read(
                    string.concat(dir, "/protocol.toml"), runName, "protocol", DeploymentSchema.PROTOCOLRECORD
                ),
                (ProtocolRecord)
            );
            d.protocol = p.addresses;
            require(
                p.header.chainId == block.chainid && d.protocol.chainId == block.chainid,
                "Recorded protocol chain mismatch"
            );
            d.circuitBreakerPlan = p.plan.circuitBreakerPlan;
        }
        require(d.protocol.core.code.length != 0, "Recorded protocol missing code");
        string memory file = string.concat(dir, "/exit-books.toml");
        if (vm.exists(file) && !vm.keyExistsToml(vm.readFile(file), ".header.version")) {
            string memory a = ArtifactMetadataFile.requireCompatible(file, LegacyDeployment.metadata(runName));
            d.books.chainId = block.chainid;
            d.books.morpho = vm.parseTomlAddress(a, ".exit_books.morpho");
            d.books.erc4626 = vm.parseTomlAddress(a, ".exit_books.erc4626");
            d.bookPauser = vm.parseTomlAddress(a, ".exit_books.pauser");
            d.bookLifetime = vm.parseTomlUint(a, ".exit_books.max_request_lifetime");
        } else if (vm.exists(file)) {
            ExitBooksRecord memory r = abi.decode(
                DeploymentArtifact.read(file, runName, "exit-books", DeploymentSchema.EXITBOOKSRECORD),
                (ExitBooksRecord)
            );
            require(
                r.header.chainId == block.chainid && r.addresses.chainId == block.chainid
                    && r.plan.core == d.protocol.core,
                "Exit books protocol mismatch"
            );
            d.books = r.addresses;
            d.bookPauser = r.plan.pauser;
            d.bookLifetime = r.plan.maxRequestLifetime;
        }
        file = string.concat(dir, "/bundler.toml");
        if (vm.exists(file) && !vm.keyExistsToml(vm.readFile(file), ".header.version")) {
            string memory a = ArtifactMetadataFile.requireCompatible(file, LegacyDeployment.metadata(runName));
            require(vm.parseTomlAddress(a, ".bundler.morpho") == d.protocol.core, "Historical bundler core mismatch");
            d.bundler = vm.parseTomlAddress(a, ".bundler.bundler3");
            d.generalAdapter = vm.parseTomlAddress(a, ".bundler.general_adapter");
            d.vaultAdapter = vm.parseTomlAddress(a, ".bundler.vault_adapter");
            d.weth = vm.parseTomlAddress(a, ".bundler.weth");
            d.wstEth = vm.parseTomlAddress(a, ".bundler.wsteth");
        } else if (vm.exists(file)) {
            BundlerRecord memory r = abi.decode(
                DeploymentArtifact.read(file, runName, "bundler", DeploymentSchema.BUNDLERRECORD), (BundlerRecord)
            );
            require(r.header.chainId == block.chainid && r.core == d.protocol.core, "Bundler protocol mismatch");
            d.bundler = r.addresses.bundler;
            d.generalAdapter = r.addresses.generalAdapter;
            d.vaultAdapter = r.addresses.vaultAdapter;
            d.weth = r.plan.weth;
            d.wstEth = r.plan.wstEth;
        }
        string memory marketsDir = string.concat(dir, "/markets");
        Vm.DirEntry[] memory files;
        if (vm.exists(marketsDir)) files = vm.readDir(marketsDir);
        uint256 count;
        for (uint256 i; i < files.length; ++i) {
            if (!files[i].isDir && !files[i].isSymlink && DeploymentArtifact.isToml(files[i].path)) ++count;
        }
        d.markets = new RecordedMarket[](count);
        uint256 next;
        for (uint256 i; i < files.length; ++i) {
            if (files[i].isDir || files[i].isSymlink || !DeploymentArtifact.isToml(files[i].path)) continue;
            // readDir returns absolute paths; the artifact itself owns and validates the relative name.
            string memory contents = vm.readFile(files[i].path);
            string memory name = vm.parseTomlString(
                contents, vm.keyExistsToml(contents, ".header.version") ? ".header.name" : ".market.name"
            );
            RecordedMarket memory market = loadMarket(runName, name, d.protocol.core);
            for (uint256 j; j < next; ++j) {
                require(
                    keccak256(bytes(d.markets[j].role)) != keccak256(bytes(market.role)),
                    "Duplicate recorded market role"
                );
            }
            d.markets[next++] = market;
        }
        if (block.chainid == 1) {
            if (d.weth == address(0)) d.weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
            if (d.wstEth == address(0)) d.wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
            d.stEth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        }
    }

    function loadMarket(string memory runName, string memory name, address core)
        internal
        view
        returns (RecordedMarket memory market)
    {
        string memory dir = DeploymentArtifact.directory(runName);
        DeploymentArtifact.requireName(name);
        string memory file = string.concat(dir, "/markets/", name, ".toml");
        if (!vm.keyExistsToml(vm.readFile(file), ".header.version")) {
            market = LegacyDeployment.loadMarket(runName, name, core);
        } else {
            MarketRecord memory r = abi.decode(
                DeploymentArtifact.read(
                    string.concat(dir, "/markets/", name, ".toml"), runName, "market", DeploymentSchema.MARKETRECORD
                ),
                (MarketRecord)
            );
            require(r.header.chainId == block.chainid && r.core == core, "Market protocol mismatch");
            require(
                bytes(r.role).length != 0 && keccak256(bytes(r.plan.name)) == keccak256(bytes(name)),
                "Market identity mismatch"
            );
            market.deployedBlock = r.header.blockNumber;
            market.priceFeedKind = "wsteth-rate";
            market.priceFeed.wstEth = r.plan.market.collateralToken;
            market.role = r.role;
            market.plan = r.plan;
            market.contracts = r.addresses;
        }
        string memory vaultPath = string.concat(dir, "/vaults/", name, ".toml");
        if (vm.exists(vaultPath) && vm.keyExistsToml(vm.readFile(vaultPath), ".header.version")) {
            VaultV2Record memory v = abi.decode(
                DeploymentArtifact.read(vaultPath, runName, "vault", DeploymentSchema.VAULTV2RECORD), (VaultV2Record)
            );
            require(
                v.header.chainId == block.chainid && v.core == core && v.irmRouter == market.contracts.params.irm,
                "Vault protocol mismatch"
            );
            market.vaultV2 = v.addresses.vault;
            market.adapter = v.addresses.adapter;
        }
    }
}
