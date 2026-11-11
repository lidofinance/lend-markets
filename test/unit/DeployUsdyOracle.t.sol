// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {DeployUsdyOracle} from "../../script/DeployUsdyOracle.s.sol";
import {ArtifactMetadataFile} from "../../script/lib/ArtifactMetadata.sol";
import {DeployConfigFile} from "../../script/lib/DeployConfigFile.sol";
import {OracleConfigFile, UsdyOracleConfig} from "../../script/lib/OracleConfigFile.sol";

import {MockChainlinkFeed, MockLoanToken} from "./UsdyStableOracle.t.sol";

contract DeployUsdyOracleTest is Test {
    string internal constant DEPLOY_CONFIG = "fork-mainnet";
    string internal constant ORACLE_CONFIG = "fork-usdy-usdt";
    /// @dev Temporary run directory below `deployed/`. The test removes it.
    string internal constant RUN = "usdy-oracle-deploy-unit";

    /// @dev A stranger cannot call `initialize` on a deployed `UsdyStableOracle` proxy and bind another feed or
    ///      another loan token. `DeployUsdyOracle.run` passes the init data to `_behindProxy`, so the proxy is
    ///      initialized in the call that creates it. A later `initialize` reverts with `InvalidInitialization`.
    ///      `initialize` itself has no caller check. The other initializable proxies from
    ///      `LidoLendPrimitives._behindProxy` and `LidoLendMarketFactory` also get their init data at creation. The
    ///      `WstEthRateOracle` proxy gets empty data, and it has no initializer.
    ///      This test calls the script entry point with the checked-in fork configs. It sets `ARTIFACTS_DIR`, which
    ///      is a process-wide variable that the fork suites read. The test skips when the variable is already set.
    function testRevert_strangerInitializeAfterDeploy_invalidInitialization() external {
        vm.skip(bytes(vm.envOr("ARTIFACTS_DIR", string(""))).length != 0);

        UsdyOracleConfig memory config = OracleConfigFile.readUsdy(ORACLE_CONFIG);
        vm.etch(config.feed, address(new MockChainlinkFeed()).code);
        vm.etch(config.loanToken, address(new MockLoanToken()).code);
        vm.chainId(DeployConfigFile.read(DEPLOY_CONFIG).chainId);
        string memory runDir = ArtifactMetadataFile.artifactsDir(RUN);
        if (vm.exists(runDir)) vm.removeDir(runDir, true);

        vm.setEnv("ARTIFACTS_DIR", RUN);
        UsdyStableOracle oracle = UsdyStableOracle(new DeployUsdyOracle().run(DEPLOY_CONFIG, ORACLE_CONFIG));
        vm.setEnv("ARTIFACTS_DIR", "");
        vm.removeDir(runDir, true);
        assertEq(address(oracle.stableUsdFeed()), config.feed, "setup: configured feed bound at deploy");

        address strangerFeed = address(new MockChainlinkFeed());
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(strangerFeed, config.loanToken);

        assertEq(address(oracle.stableUsdFeed()), config.feed, "configured feed kept");
        // 10^(36 + 6 loan + 8 feed - 18 USDY - 18 NAV) = 1e14.
        assertEq(oracle.scale(), 1e14, "configured scale kept");
    }
}
