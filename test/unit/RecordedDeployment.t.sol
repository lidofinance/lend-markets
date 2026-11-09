// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
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
