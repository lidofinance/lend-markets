// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {ArtifactMetadata} from "../../script/lib/ArtifactMetadata.sol";
import {CircuitBreakerConfig, CircuitBreakerConfigFile} from "../../script/lib/CircuitBreakerConfigFile.sol";
import {DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";

contract CircuitBreakerConfigFileHarness {
    function writeDeployed(
        string memory name,
        address circuitBreaker,
        address admin,
        uint256 deployedBlock,
        CircuitBreakerConfig memory cfg,
        ArtifactMetadata memory metadata
    ) external returns (string memory) {
        return CircuitBreakerConfigFile.writeDeployed(name, circuitBreaker, admin, deployedBlock, cfg, metadata);
    }

    function readDeployed(string memory name, ArtifactMetadata memory metadata) external view returns (address) {
        return CircuitBreakerConfigFile.readDeployed(name, metadata);
    }

    function profileFor(string memory deployConfig) external view returns (CircuitBreakerConfig memory) {
        return CircuitBreakerConfigFile.read(DeployConfigFile.read(deployConfig).circuitBreakerArtifact);
    }

    function profileName(string memory deployConfig) external view returns (string memory) {
        return DeployConfigFile.read(deployConfig).circuitBreakerArtifact;
    }
}

contract CircuitBreakerConfigFileTest is Test {
    CircuitBreakerConfigFileHarness internal harness;

    function setUp() external {
        harness = new CircuitBreakerConfigFileHarness();
    }

    function test_writeDeployed_recordsResolvedConfig() external {
        string memory run = "circuit-breaker-config-file-unit";
        string memory dir = string.concat("deployed/", run);
        if (vm.exists(dir)) vm.removeDir(dir, true);

        CircuitBreakerConfig memory cfg = CircuitBreakerConfig({
            minPauseDuration: 5 days,
            maxPauseDuration: 60 days,
            minHeartbeatInterval: 30 days,
            maxHeartbeatInterval: 1095 days,
            initialPauseDuration: 21 days,
            initialHeartbeatInterval: 365 days
        });
        ArtifactMetadata memory metadata = ArtifactMetadata({
            deployment: run,
            chainId: 1,
            configHash: bytes32(uint256(0xCAFE)),
            compatibilityHash: bytes32(uint256(0xBEEF))
        });
        address circuitBreaker = address(0xCB);
        address admin = address(0xA11);
        string memory name = "lido-lend";

        string memory path = harness.writeDeployed(name, circuitBreaker, admin, 123, cfg, metadata);
        string memory artifact = vm.readFile(path);

        assertEq(path, string.concat(dir, "/circuit-breakers/lido-lend.toml"));
        assertEq(vm.parseTomlString(artifact, ".artifact.kind"), "circuit-breaker");
        assertEq(vm.parseTomlString(artifact, ".circuit_breaker.name"), name);
        assertEq(vm.parseTomlAddress(artifact, ".circuit_breaker.address"), circuitBreaker);
        assertEq(vm.parseTomlAddress(artifact, ".circuit_breaker.admin"), admin);
        assertFalse(vm.keyExistsToml(artifact, ".circuit_breaker.deployer"));
        assertEq(vm.parseTomlUint(artifact, ".circuit_breaker.initial_pause_duration"), 21 days);
        assertEq(harness.readDeployed(name, metadata), circuitBreaker);

        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerConfigFile.ArtifactAlreadyExists.selector, path));
        harness.writeDeployed(name, circuitBreaker, admin, 123, cfg, metadata);
        vm.removeDir(dir, true);
    }

    /// @dev Config pin: the `mainnet` deploy config selects the "lido-lend" circuit-breaker profile. The profile
    ///      starts the pause duration at five minutes and sets its lower limit to 60 seconds.
    ///      `script/config/circuit-breakers/lido-lend.toml` sets `initial_pause_duration = 300` and
    ///      `min_pause_duration = 60`. `DeployCircuitBreaker` passes these values to the `CircuitBreaker` constructor.
    ///      This test reads the config files only. `test_cbPause_pausesOnlyRegisteredController_forExactDuration`
    ///      shows the expiry on a deployed breaker.
    function test_mainnetDeployConfig_selectsLidoLendProfile_fiveMinutePause() external view {
        _assertLidoLendProfile("mainnet");
    }

    /// @dev Same pin as `test_mainnetDeployConfig_selectsLidoLendProfile_fiveMinutePause`; this test shows that
    ///      the Hoodi deploy config selects the same "lido-lend" profile.
    function test_hoodiDeployConfig_selectsLidoLendProfile_fiveMinutePause() external view {
        _assertLidoLendProfile("hoodi");
    }

    /// @dev Same pin as `test_mainnetDeployConfig_selectsLidoLendProfile_fiveMinutePause`; this test shows that
    ///      the fork deploy config selects the same "lido-lend" profile.
    function test_forkMainnetDeployConfig_selectsLidoLendProfile_fiveMinutePause() external view {
        _assertLidoLendProfile("fork-mainnet");
    }

    function _assertLidoLendProfile(string memory deployConfig) private view {
        assertEq(harness.profileName(deployConfig), "lido-lend", "circuit-breaker profile");
        CircuitBreakerConfig memory cfg = harness.profileFor(deployConfig);
        assertEq(cfg.minPauseDuration, 60, "min pause duration");
        assertEq(cfg.initialPauseDuration, 5 minutes, "initial pause duration");
    }
}
