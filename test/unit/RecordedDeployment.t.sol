// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import {DeployConfigFile} from "../../script/legacy/lib/DeployConfigFile.sol";
import {ExportDeployment} from "../../script/deployment/ExportDeployment.s.sol";
import {RecordedDeployment} from "../../script/deployment/RecordedDeployment.sol";
import {DeploymentSnapshot} from "../../script/deployment/DeploymentSnapshot.sol";
import {DeploymentArtifact} from "../../script/deployment/DeploymentArtifact.sol";
import {
    DeploymentHeader,
    DeploymentSchema,
    ProtocolRecord,
    MarketRecord
} from "../../script/deployment/DeploymentRecord.sol";
import {ForkStack} from "../fork/helpers/ForkStack.sol";

contract RecordedDeploymentHarness is ForkStack {
    function load(string memory runName) external returns (DeploymentSnapshot memory d) {
        d = RecordedDeployment.load(runName);
        _useDeployment(d);
    }

    function marketForRole(string memory role) external returns (string memory) {
        return _marketForRole(role);
    }
}

contract RecordedDeploymentTest is Test {
    RecordedDeploymentHarness internal harness;

    function setUp() public {
        harness = new RecordedDeploymentHarness();
        vm.setEnv("ARTIFACTS_CONFIG", "");
    }

    function test_twoMarkets_resolveRolesThroughSharedContext() public {
        string memory runName = "reader-roles-unit";
        _protocol(runName);
        _market(runName, "first", "primary");
        _market(runName, "second", "secondary");
        DeploymentSnapshot memory d = harness.load(runName);
        assertEq(d.markets.length, 2);
        assertEq(harness.marketForRole("primary"), "first");
        assertEq(harness.marketForRole("secondary"), "second");
        vm.removeDir(DeploymentArtifact.directory(runName), true);
    }

    function testRevert_duplicateRolesFailDuringLoading() public {
        string memory runName = "reader-duplicate-unit";
        _protocol(runName);
        _market(runName, "first", "primary");
        _market(runName, "second", "primary");
        vm.expectRevert("Duplicate recorded market role");
        harness.load(runName);
        vm.removeDir(DeploymentArtifact.directory(runName), true);
    }

    function testRevert_emptyRoleFailsDuringLoading() public {
        string memory runName = "reader-empty-role-unit";
        _protocol(runName);
        _market(runName, "first", "");
        vm.expectRevert("Market identity mismatch");
        harness.load(runName);
        vm.removeDir(DeploymentArtifact.directory(runName), true);
    }

    function testRevert_marketFromAnotherCoreFailsDuringLoading() public {
        string memory runName = "reader-core-unit";
        _protocol(runName);
        MarketRecord memory r = _market(runName, "first", "primary");
        r.core = address(0xBAD);
        vm.writeToml(
            vm.serializeJsonType(DeploymentSchema.MARKETRECORD, abi.encode(r)), DeploymentArtifact.path(r.header)
        );
        vm.expectRevert("Market protocol mismatch");
        harness.load(runName);
        vm.removeDir(DeploymentArtifact.directory(runName), true);
    }

    function test_historicalHoodi_preservesMarketsAndPriceFeedKinds() public {
        vm.chainId(560048);
        string memory protocol = vm.readFile("deployed/hoodi-testnet/protocol.toml");
        address core = vm.parseTomlAddress(protocol, ".protocol.core");
        vm.etch(core, hex"00");
        DeploymentSnapshot memory d = harness.load("hoodi-testnet");
        assertEq(d.protocol.core, core);
        assertEq(d.protocol.chainId, 560048);
        assertEq(d.markets.length, 3);
        assertEq(harness.marketForRole("weth-wsteth"), "weth-wsteth");
        assertEq(harness.marketForRole("usdy-usdt"), "usdt-usdy");
        uint256 treasuryMarkets;
        for (uint256 i; i < d.markets.length; ++i) {
            if (keccak256(bytes(d.markets[i].priceFeedKind)) == keccak256("usdy-stable")) ++treasuryMarkets;
        }
        assertEq(treasuryMarkets, 2);
        assertEq(d.wstEth, 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4);
        assertEq(d.usdy, 0xE22a71d42632aBAC08F44FCbd41221A8D8C56972);
        assertEq(d.usdyBlocklist, address(0));
    }

    function test_historicalMainnet_protocolWithoutMarketsLoads() public {
        vm.chainId(1);
        string memory protocol = vm.readFile("deployed/mainnet/protocol.toml");
        address core = vm.parseTomlAddress(protocol, ".protocol.core");
        vm.etch(core, hex"00");
        DeploymentSnapshot memory d = harness.load("mainnet");
        assertEq(d.protocol.core, core);
        assertEq(d.markets.length, 0);
        assertTrue(d.books.morpho != address(0));
        assertTrue(d.bundler != address(0));
    }

    function testRevert_invalidRunNames() public {
        vm.expectRevert("Invalid artifact name");
        harness.load("");
        vm.expectRevert("Invalid artifact name");
        harness.load("../mainnet");
    }

    function testRevert_missingProtocol() public {
        vm.expectRevert();
        harness.load("reader-missing-protocol-unit");
    }

    function testRevert_historicalWrongChain() public {
        vm.chainId(1);
        vm.expectRevert("Historical protocol chain mismatch");
        harness.load("hoodi-testnet");
    }

    function test_historicalIdentityMismatch() public {
        for (uint8 field; field < 6; ++field) {
            string memory run = "reader-identity-unit";
            _historical(run);
            harness.load(run);
            string[6] memory keys = [
                ".artifact.deployment",
                ".protocol.deployment",
                ".artifact.chain_id",
                ".artifact.config_hash",
                ".artifact.compatibility_hash",
                ".protocol.core"
            ];
            string[6] memory values = [
                '"another-run"',
                '"another-run"',
                "1",
                '"0x0000000000000000000000000000000000000000000000000000000000000001"',
                '"0x0000000000000000000000000000000000000000000000000000000000000001"',
                '"0x0000000000000000000000000000000000000001"'
            ];
            uint256 i = field;
            vm.writeToml(values[i], string.concat(DeploymentArtifact.directory(run), "/protocol.toml"), keys[i]);
            vm.expectRevert();
            harness.load(run);
            vm.removeDir(DeploymentArtifact.directory(run), true);
        }
    }

    function test_historicalMarketMismatch() public {
        for (uint8 field; field < 7; ++field) {
            string memory run = "reader-market-identity-unit";
            _historical(run);
            harness.load(run);
            string[7] memory keys = [
                ".market.name",
                ".market.factory",
                ".market.irm",
                ".market.guardian_signals",
                ".market.oracle",
                ".artifact.deployment",
                ".artifact.compatibility_hash"
            ];
            uint256 i = field;
            string memory value = i == 0 || i == 5
                ? '"another-market"'
                : i == 6
                    ? '"0x0000000000000000000000000000000000000000000000000000000000000001"'
                    : '"0x0000000000000000000000000000000000000001"';
            vm.writeToml(value, string.concat(DeploymentArtifact.directory(run), "/markets/weth-wsteth.toml"), keys[i]);
            vm.expectRevert();
            harness.load(run);
            vm.removeDir(DeploymentArtifact.directory(run), true);
        }
    }

    function test_historicalVaultPair_loads() public {
        string memory run = "reader-vault-unit";
        _historical(run);
        _vaultPair(run);
        DeploymentSnapshot memory d = harness.load(run);
        for (uint256 i; i < d.markets.length; ++i) {
            if (keccak256(bytes(d.markets[i].plan.name)) == keccak256("weth-wsteth")) {
                assertEq(d.markets[i].vaultV2, address(0xA017));
                assertEq(d.markets[i].adapter, address(0xADA));
            }
        }
        vm.removeDir(DeploymentArtifact.directory(run), true);
    }

    function test_historicalVaultPair_rejectsBrokenRelationship() public {
        for (uint8 field; field < 6; ++field) {
            string memory run = "reader-vault-invalid-unit";
            _historical(run);
            _vaultPair(run);
            harness.load(run);
            string[6] memory keys = [
                ".vault.name",
                ".adapter.name",
                ".adapter.vault_artifact",
                ".adapter.vault",
                ".adapter.morpho",
                ".adapter.adaptive_curve_irm"
            ];
            uint256 i = field;
            string memory path = string.concat(
                DeploymentArtifact.directory(run), i == 0 ? "/vaults/weth-wsteth.toml" : "/adapters/weth-wsteth.toml"
            );
            vm.writeToml(i < 3 ? '"wrong"' : '"0x0000000000000000000000000000000000000001"', path, keys[i]);
            vm.expectRevert();
            harness.load(run);
            vm.removeDir(DeploymentArtifact.directory(run), true);
        }
    }

    function test_historicalPriceFeeds_preserveIndependentParameters() public {
        string memory run = "reader-feeds-unit";
        _historical(run);
        DeploymentSnapshot memory d = harness.load(run);
        for (uint256 i; i < d.markets.length; ++i) {
            string memory a =
                vm.readFile(string.concat("deployed/hoodi-testnet/oracles/", d.markets[i].plan.name, ".toml"));
            if (keccak256(bytes(d.markets[i].priceFeedKind)) == keccak256("usdy-stable")) {
                assertEq(d.markets[i].priceFeed.wstEth, address(0));
                assertEq(d.markets[i].priceFeed.usdySource, vm.parseTomlAddress(a, ".oracle.usdy_oracle"));
                assertEq(d.markets[i].priceFeed.feed, vm.parseTomlAddress(a, ".oracle.feed"));
                assertEq(d.markets[i].priceFeed.minPrice, vm.parseTomlUint(a, ".oracle.min_price"));
                assertEq(d.markets[i].priceFeed.maxPrice, vm.parseTomlUint(a, ".oracle.max_price"));
            } else {
                assertEq(d.markets[i].priceFeed.wstEth, vm.parseTomlAddress(a, ".oracle.wsteth"));
            }
            assertGt(d.markets[i].deployedBlock, 0);
        }
        vm.removeDir(DeploymentArtifact.directory(run), true);
    }

    function testRevert_historicalBundlerFromAnotherCore() public {
        string memory run = "reader-bundler-unit";
        _historicalFrom(run, "mainnet", 1);
        harness.load(run);
        vm.writeToml(
            '"0x0000000000000000000000000000000000000001"',
            string.concat(DeploymentArtifact.directory(run), "/bundler.toml"),
            ".bundler.morpho"
        );
        vm.expectRevert("Historical bundler core mismatch");
        harness.load(run);
        vm.removeDir(DeploymentArtifact.directory(run), true);
    }

    function testRevert_missingExternalConfig() public {
        string memory run = "reader-config-missing-unit";
        _historical(run);
        string memory path = string.concat(DeploymentArtifact.directory(run), "/protocol.toml");
        string memory p = vm.readFile(path);
        vm.writeToml('"no-such-config"', path, ".protocol.network");
        vm.writeToml(
            string.concat('"', vm.toString(_compatibility(p, "no-such-config")), '"'),
            path,
            ".artifact.compatibility_hash"
        );
        vm.expectRevert();
        harness.load(run);
        vm.removeDir(DeploymentArtifact.directory(run), true);
    }

    function testRevert_historicalVaultWithoutAdapter() public {
        string memory run = "reader-vault-incomplete-unit";
        _historical(run);
        _vaultPair(run);
        vm.removeFile(string.concat(DeploymentArtifact.directory(run), "/adapters/weth-wsteth.toml"));
        vm.expectRevert();
        harness.load(run);
        vm.removeDir(DeploymentArtifact.directory(run), true);
    }

    function _historical(string memory run) private {
        _historicalFrom(run, "hoodi-testnet", 560048);
    }

    function _historicalFrom(string memory run, string memory source, uint256 chainId) private {
        string memory dir = DeploymentArtifact.directory(run);
        require(!vm.exists(dir), "Fixture exists");
        vm.chainId(chainId);
        string memory protocol = vm.readFile(string.concat("deployed/", source, "/protocol.toml"));
        Vm.DirEntry[] memory files = vm.readDir(string.concat("deployed/", source), 2);
        for (uint256 i; i < files.length; ++i) {
            if (files[i].isSymlink || files[i].isDir || !DeploymentArtifact.isToml(files[i].path)) continue;
            _copyHistoricalArtifact(files[i].path, source, run, protocol);
        }
        address core = vm.parseTomlAddress(vm.readFile(string.concat(dir, "/protocol.toml")), ".protocol.core");
        vm.etch(core, hex"00");
    }

    function _copyHistoricalArtifact(
        string memory file,
        string memory source,
        string memory run,
        string memory protocol
    ) private {
        string memory path = vm.replace(
            file, string.concat("deployed/", source, "/"), string.concat("deployed/", run, "/")
        );
        string[] memory parts = vm.split(path, "/");
        vm.createDir(vm.replace(path, string.concat("/", parts[parts.length - 1]), ""), true);
        string memory contents = vm.replace(
            vm.readFile(file),
            vm.toString(vm.parseTomlBytes32(protocol, ".artifact.compatibility_hash")),
            vm.toString(_compatibility(protocol, source))
        );
        contents = vm.replace(
            contents,
            string.concat('network = "', vm.parseTomlString(protocol, ".protocol.network"), '"'),
            string.concat('network = "', source, '"')
        );
        contents = vm.replace(
            contents, string.concat('deployment = "', source, '"'), string.concat('deployment = "', run, '"')
        );
        vm.writeFile(path, contents);
    }

    function _compatibility(string memory p, string memory network) private pure returns (bytes32) {
        return DeployConfigFile.canonicalCompatibilityHash(
            network,
            vm.parseTomlUint(p, ".protocol.chain_id"),
            vm.parseTomlAddress(p, ".protocol.agent"),
            vm.parseTomlAddress(p, ".protocol.evm_script_executor"),
            vm.parseTomlAddress(p, ".protocol.reseal_manager"),
            vm.parseTomlString(p, ".protocol.circuit_breaker_artifact")
        );
    }

    function _vaultPair(string memory run) private {
        string memory dir = DeploymentArtifact.directory(run);
        string memory protocol = vm.readFile(string.concat(dir, "/protocol.toml"));
        string[] memory sections = vm.split(protocol, "[protocol]");
        vm.createDir(string.concat(dir, "/vaults"), true);
        vm.createDir(string.concat(dir, "/adapters"), true);
        vm.writeFile(
            string.concat(dir, "/vaults/weth-wsteth.toml"),
            string.concat(
                sections[0], '[vault]\nname = "weth-wsteth"\naddress = "', vm.toString(address(0xA017)), '"\n'
            )
        );
        vm.writeFile(
            string.concat(dir, "/adapters/weth-wsteth.toml"),
            string.concat(
                sections[0],
                '[adapter]\nname = "weth-wsteth"\nvault_artifact = "weth-wsteth"\nvault = "',
                vm.toString(address(0xA017)),
                '"\naddress = "',
                vm.toString(address(0xADA)),
                '"\nmorpho = "',
                vm.toString(vm.parseTomlAddress(protocol, ".protocol.core")),
                '"\nadaptive_curve_irm = "',
                vm.toString(vm.parseTomlAddress(protocol, ".protocol.irm_router")),
                '"\n'
            )
        );
    }

    function test_export_preservesNestedHistoricalMarketParameters() public {
        vm.chainId(560048);
        vm.etch(vm.parseTomlAddress(vm.readFile("deployed/hoodi-testnet/protocol.toml"), ".protocol.core"), hex"00");
        string memory json = (new ExportDeployment()).run("hoodi-testnet");
        assertEq(vm.parseJsonUint(json, ".protocol.chainId"), 560048);
        uint256 stableFeeds;
        for (uint256 i; i < 3; ++i) {
            string memory key = string.concat(".markets[", vm.toString(i), "]");
            if (
                keccak256(bytes(vm.parseJsonString(json, string.concat(key, ".priceFeedKind"))))
                    == keccak256("usdy-stable")
            ) {
                assertGt(vm.parseJsonUint(json, string.concat(key, ".priceFeed.minPrice")), 0);
                ++stableFeeds;
            }
        }
        assertEq(stableFeeds, 2);
    }

    function test_export_preservesTypedMarketParameters() public {
        string memory run = "reader-export-unit";
        _protocol(run);
        MarketRecord memory r = _market(run, "first", "primary");
        r.plan.market.activationConfig.maxActivationDelay = 8 hours;
        r.plan.market.collateralToken = address(0x1234);
        vm.writeToml(
            vm.serializeJsonType(DeploymentSchema.MARKETRECORD, abi.encode(r)), DeploymentArtifact.path(r.header)
        );
        string memory json = (new ExportDeployment()).run(run);
        assertEq(vm.parseJsonUint(json, ".markets[0].plan.market.activationConfig.maxActivationDelay"), 8 hours);
        assertEq(vm.parseJsonAddress(json, ".markets[0].priceFeed.wstEth"), address(0x1234));
        vm.removeDir(DeploymentArtifact.directory(run), true);
    }

    function _protocol(string memory runName) private {
        require(!vm.exists(DeploymentArtifact.directory(runName)), "Fixture exists");
        vm.createDir(string.concat(DeploymentArtifact.directory(runName), "/markets"), true);
        ProtocolRecord memory r;
        r.header = _header(runName, "protocol", "protocol");
        r.addresses.core = address(this);
        r.addresses.chainId = block.chainid;
        vm.writeToml(
            vm.serializeJsonType(DeploymentSchema.PROTOCOLRECORD, abi.encode(r)), DeploymentArtifact.path(r.header)
        );
    }

    function _market(string memory runName, string memory name, string memory role)
        private
        returns (MarketRecord memory r)
    {
        r.header = _header(runName, "market", name);
        r.core = address(this);
        r.role = role;
        r.plan.name = name;
        vm.writeToml(
            vm.serializeJsonType(DeploymentSchema.MARKETRECORD, abi.encode(r)), DeploymentArtifact.path(r.header)
        );
    }

    function _header(string memory runName, string memory kind, string memory name)
        private
        view
        returns (DeploymentHeader memory)
    {
        return DeploymentHeader({
            version: 1,
            run: runName,
            kind: kind,
            name: name,
            chainId: block.chainid,
            sender: address(this),
            blockNumber: block.number
        });
    }
}
