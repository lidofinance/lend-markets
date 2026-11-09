// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {GenerateProtocol} from "../../script/deployment/GenerateProtocol.s.sol";
import {ArtifactMetadataFile} from "../../script/legacy/lib/ArtifactMetadata.sol";
import {GenerateExitBooks} from "../../script/deployment/GenerateExitBooks.s.sol";

contract ProtocolExportTest is Test {
    GenerateProtocol internal exporter;

    function setUp() public {
        exporter = new GenerateProtocol();
    }

    function test_exportDifferentNetworks_keepsSeparateAddressProviders() public {
        string memory first = _runName("mainnet");
        string memory second = _runName("hoodi");
        _writeProtocol(first, 1);
        _writeProtocol(second, 560048);
        // Protocol export must not read or validate the independently managed exit-book artifact.
        vm.writeFile(string.concat("deployed/", first, "/exit-books.toml"), "not a protocol artifact");
        string memory firstPath = exporter.run(first);
        bytes32 firstContent = keccak256(bytes(vm.readFile(firstPath)));
        string memory secondPath = exporter.run(second);
        assertEq(firstPath, string.concat("script/deployment/generated/", first, "/Protocol.sol"));
        assertEq(secondPath, string.concat("script/deployment/generated/", second, "/Protocol.sol"));
        assertEq(keccak256(bytes(vm.readFile(firstPath))), firstContent);
        assertTrue(vm.contains(vm.readFile(firstPath), "p.chainId = 1;"));
        assertTrue(vm.contains(vm.readFile(secondPath), "p.chainId = 560048;"));
        // Exit books never appear in the protocol address provider.
        assertFalse(vm.contains(vm.readFile(firstPath), "p.morphoBook ="));
        _clean(first);
        _clean(second);
    }

    function testRevert_exportRejectsMismatchedProtocolChain() public {
        string memory name = _runName("mismatch");
        _writeProtocol(name, 1);
        string memory path = string.concat("deployed/", name, "/protocol.toml");
        string memory source = vm.readFile(path);
        source = vm.replace(source, "[artifact]\nchain_id = 1", "[artifact]\nchain_id = 560048");
        vm.writeFile(path, source);
        vm.expectRevert("Protocol identity differs from selected run");
        exporter.run(name);
        assertFalse(vm.exists(string.concat("script/deployment/generated/", name)));
        vm.removeDir(string.concat("deployed/", name), true);
    }

    function testRevert_exportCannotEscapeRunDirectory() public {
        vm.expectRevert(abi.encodeWithSelector(ArtifactMetadataFile.InvalidArtifactsDir.selector, "../mainnet"));
        exporter.run("../mainnet");
    }

    function test_exitBooksExportDoesNotRequireProtocol() public {
        string memory name = _runName("books");
        string memory directory = string.concat("deployed/", name);
        require(!vm.exists(directory), "Export fixture already exists");
        vm.createDir(directory, true);
        vm.writeFile(
            string.concat(directory, "/exit-books.toml"),
            string.concat(
                "[artifact]\ndeployment = \"",
                name,
                "\"\nchain_id = 560048\n",
                "[exit_books]\nmorpho = \"0x1111111111111111111111111111111111111111\"\n",
                "erc4626 = \"0x2222222222222222222222222222222222222222\"\n"
            )
        );
        string memory output = (new GenerateExitBooks()).run(name);
        assertEq(output, string.concat("script/deployment/generated/", name, "/ExitBooks.sol"));
        assertTrue(vm.contains(vm.readFile(output), "books.chainId = 560048;"));
        assertFalse(vm.exists(string.concat(directory, "/protocol.toml")));
        _clean(name);
    }

    function _writeProtocol(string memory name, uint256 chainId) private {
        string memory directory = string.concat("deployed/", name);
        require(!vm.exists(directory), "Export fixture already exists");
        vm.createDir(directory, true);
        string memory header = string.concat("deployment = \"", name, "\"\nchain_id = ", vm.toString(chainId), "\n");
        string memory contents = string.concat(
            "[artifact]\nchain_id = ",
            vm.toString(chainId),
            "\ndeployment = \"",
            name,
            "\"\n",
            "[protocol]\n",
            header,
            "core = \"0x1111111111111111111111111111111111111111\"\n",
            "factory = \"0x2222222222222222222222222222222222222222\"\n",
            "owner_facade = \"0x3333333333333333333333333333333333333333\"\n",
            "irm_router = \"0x4444444444444444444444444444444444444444\"\n",
            "adaptive_curve_irm = \"0x5555555555555555555555555555555555555555\"\n",
            "irm_config_factory = \"0x6666666666666666666666666666666666666666\"\n",
            "risk_steward_dashboard = \"0x7777777777777777777777777777777777777777\"\n",
            "circuit_breaker = \"0x8888888888888888888888888888888888888888\"\n",
            "reseal_manager = \"0x9999999999999999999999999999999999999999\"\n",
            "agent = \"0x1111111111111111111111111111111111111111\"\n",
            "evm_script_executor = \"0x2222222222222222222222222222222222222222\"\n"
        );
        vm.writeFile(string.concat(directory, "/protocol.toml"), contents);
    }

    function _runName(string memory suffix) private view returns (string memory) {
        return string.concat("export-test-", vm.toString(address(this)), "-", suffix);
    }

    function _clean(string memory name) private {
        vm.removeDir(string.concat("deployed/", name), true);
        vm.removeDir(string.concat("script/deployment/generated/", name), true);
    }
}
