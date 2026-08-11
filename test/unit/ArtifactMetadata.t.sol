// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ArtifactMetadata, ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";

contract ArtifactMetadataHarness {
    function artifactsDir(string memory name) external pure returns (string memory) {
        return ArtifactMetadataFile.artifactsDir(name);
    }

    function requireCompatible(string memory path, ArtifactMetadata memory expected)
        external
        view
        returns (string memory)
    {
        return ArtifactMetadataFile.requireCompatible(path, expected);
    }

    function requireExact(string memory path, ArtifactMetadata memory expected) external view returns (string memory) {
        return ArtifactMetadataFile.requireExact(path, expected);
    }

    function requireRunResourcesCompatible(ArtifactMetadata memory expected) external view {
        ArtifactMetadataFile.requireRunResourcesCompatible(expected);
    }
}

contract ArtifactMetadataTest is Test {
    ArtifactMetadataHarness internal harness;

    function setUp() external {
        harness = new ArtifactMetadataHarness();
    }

    function test_requireCompatible_acceptsMatchingMetadata() external {
        ArtifactMetadata memory metadata = _metadata("artifact-metadata-match", 1, 0xCAFE, 0xBEEF);
        string memory path = _write("match", metadata);

        string memory artifact = harness.requireCompatible(path, metadata);

        assertEq(vm.parseTomlString(artifact, ".artifact.kind"), "dependency");
        _cleanup("match");
    }

    function test_requireCompatible_acceptsDifferentExactConfig() external {
        ArtifactMetadata memory actual = _metadata("run", 1, 0xCAFE, 0xBEEF);
        ArtifactMetadata memory expected = _metadata("run", 1, 0xBAD, 0xBEEF);
        string memory path = _write("compatible-config", actual);

        harness.requireCompatible(path, expected);

        _cleanup("compatible-config");
    }

    function testRevert_requireCompatible_deploymentMismatch() external {
        ArtifactMetadata memory actual = _metadata("actual", 1, 0xCAFE, 0xBEEF);
        ArtifactMetadata memory expected = _metadata("expected", 1, 0xCAFE, 0xBEEF);
        string memory path = _write("deployment", actual);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactDeploymentMismatch.selector, path, expected.deployment, actual.deployment
            )
        );
        harness.requireCompatible(path, expected);
        _cleanup("deployment");
    }

    function testRevert_requireCompatible_chainIdMismatch() external {
        ArtifactMetadata memory actual = _metadata("run", 2, 0xCAFE, 0xBEEF);
        ArtifactMetadata memory expected = _metadata("run", 1, 0xCAFE, 0xBEEF);
        string memory path = _write("chain", actual);

        vm.expectRevert(
            abi.encodeWithSelector(ArtifactMetadataFile.ArtifactChainIdMismatch.selector, path, uint256(1), uint256(2))
        );
        harness.requireCompatible(path, expected);
        _cleanup("chain");
    }

    function testRevert_requireCompatible_compatibilityHashMismatch() external {
        ArtifactMetadata memory actual = _metadata("run", 1, 0xCAFE, 0xBAD);
        ArtifactMetadata memory expected = _metadata("run", 1, 0xCAFE, 0xBEEF);
        string memory path = _write("compatibility", actual);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactCompatibilityHashMismatch.selector,
                path,
                expected.compatibilityHash,
                actual.compatibilityHash
            )
        );
        harness.requireCompatible(path, expected);
        _cleanup("compatibility");
    }

    function testRevert_requireCompatible_missingExactConfigProvenance() external {
        ArtifactMetadata memory expected = _metadata("run", 1, 0xCAFE, 0xBEEF);
        string memory path = _writeRaw(
            "missing-config",
            string.concat(
                "[artifact]\nkind = \"dependency\"\ndeployment = \"run\"\nchain_id = 1\ncompatibility_hash = \"",
                vm.toString(expected.compatibilityHash),
                "\"\n"
            )
        );

        vm.expectRevert(abi.encodeWithSelector(ArtifactMetadataFile.ArtifactConfigHashMissing.selector, path));
        harness.requireCompatible(path, expected);
        _cleanup("missing-config");
    }

    function testRevert_requireRunResourcesCompatible_rejectsPoisonedPreProtocolOracle() external {
        string memory run = "artifact-metadata-incompatible-resource-unit";
        string memory dir = string.concat("deployed/", run, "/oracles");
        if (vm.exists(string.concat("deployed/", run))) vm.removeDir(string.concat("deployed/", run), true);
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/oracle.toml");
        ArtifactMetadata memory recorded = _metadata(run, 1, 0xCAFE, 0xBEEF);
        vm.writeFile(path, ArtifactMetadataFile.header(recorded, "oracle"));
        ArtifactMetadata memory expected = _metadata(run, 1, 0xBAD, 0xBAD);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactCompatibilityHashMismatch.selector,
                string.concat(vm.projectRoot(), "/", path),
                expected.compatibilityHash,
                recorded.compatibilityHash
            )
        );
        harness.requireRunResourcesCompatible(expected);
        vm.removeDir(string.concat("deployed/", run), true);
    }

    function testRevert_requireRunResourcesCompatible_rejectsPoisonedCircuitBreaker() external {
        string memory run = "artifact-metadata-incompatible-circuit-breaker-unit";
        string memory runDir = string.concat("deployed/", run);
        string memory dir = string.concat(runDir, "/circuit-breakers");
        if (vm.exists(runDir)) vm.removeDir(runDir, true);
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/lido-lend.toml");
        ArtifactMetadata memory recorded = _metadata(run, 1, 0xCAFE, 0xBEEF);
        vm.writeFile(path, ArtifactMetadataFile.header(recorded, "circuit-breaker"));
        ArtifactMetadata memory expected = _metadata(run, 1, 0xBAD, 0xBAD);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactCompatibilityHashMismatch.selector,
                string.concat(vm.projectRoot(), "/", path),
                expected.compatibilityHash,
                recorded.compatibilityHash
            )
        );
        harness.requireRunResourcesCompatible(expected);
        vm.removeDir(runDir, true);
    }

    function test_artifactsDir_acceptsWhitelistedRunName() external view {
        assertEq(harness.artifactsDir("Run_1.2-test"), "deployed/Run_1.2-test");
    }

    function testRevert_artifactsDir_rejectsEmptyName() external {
        _expectInvalidArtifactsDir("");
    }

    function testRevert_artifactsDir_rejectsSlash() external {
        _expectInvalidArtifactsDir("a/b");
    }

    function testRevert_artifactsDir_rejectsBackslash() external {
        _expectInvalidArtifactsDir("a\\b");
    }

    function testRevert_artifactsDir_rejectsDot() external {
        _expectInvalidArtifactsDir(".");
    }

    function testRevert_artifactsDir_rejectsDotDot() external {
        _expectInvalidArtifactsDir("..");
    }

    function testRevert_artifactsDir_rejectsQuote() external {
        _expectInvalidArtifactsDir('a"b');
    }

    function testRevert_artifactsDir_rejectsNewline() external {
        _expectInvalidArtifactsDir("a\nb");
    }

    function test_requireExact_acceptsMatchingMetadata() external {
        ArtifactMetadata memory metadata = _metadata("run", 1, 0xCAFE, 0xBEEF);
        string memory path = _write("exact", metadata);

        harness.requireExact(path, metadata);

        _cleanup("exact");
    }

    function testRevert_requireExact_configHashMismatch() external {
        ArtifactMetadata memory actual = _metadata("run", 1, 0xBAD, 0xBEEF);
        ArtifactMetadata memory expected = _metadata("run", 1, 0xCAFE, 0xBEEF);
        string memory path = _write("exact-config", actual);

        vm.expectRevert(
            abi.encodeWithSelector(
                ArtifactMetadataFile.ArtifactConfigHashMismatch.selector, path, expected.configHash, actual.configHash
            )
        );
        harness.requireExact(path, expected);
        _cleanup("exact-config");
    }

    function _write(string memory tag, ArtifactMetadata memory metadata) private returns (string memory path) {
        return _writeRaw(tag, ArtifactMetadataFile.header(metadata, "dependency"));
    }

    function _writeRaw(string memory tag, string memory artifact) private returns (string memory path) {
        string memory dir = _dir(tag);
        if (vm.exists(dir)) vm.removeDir(dir, true);
        vm.createDir(dir, true);
        path = string.concat(dir, "/dependency.toml");
        vm.writeFile(path, artifact);
    }

    function _metadata(string memory deployment, uint256 chainId, uint256 configHash, uint256 compatibilityHash)
        private
        pure
        returns (ArtifactMetadata memory)
    {
        return ArtifactMetadata({
            deployment: deployment,
            chainId: chainId,
            configHash: bytes32(configHash),
            compatibilityHash: bytes32(compatibilityHash)
        });
    }

    function _dir(string memory tag) private pure returns (string memory) {
        return string.concat("deployed/artifact-metadata-unit-", tag);
    }

    function _cleanup(string memory tag) private {
        vm.removeDir(_dir(tag), true);
    }

    function _expectInvalidArtifactsDir(string memory name) private {
        vm.expectRevert(abi.encodeWithSelector(ArtifactMetadataFile.InvalidArtifactsDir.selector, name));
        harness.artifactsDir(name);
    }
}
