// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {NavOracleConfig, OracleConfigFile} from "../../script/lib/OracleConfigFile.sol";
import {OraclePreflight} from "../../script/lib/OraclePreflight.sol";

import {AcceptanceMarketAssertions} from "../acceptance/AcceptanceBase.t.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

import {DeployNavOracleHarness} from "./DeployNavOracle.t.sol";

/// @notice The acceptance suite's oracle check on a NAV oracle, run locally: the oracle the deploy step leaves and
///         the `[oracle]` table its artifact records, in place of a fork and a run's files.
contract AcceptanceNavOracleTest is AcceptanceMarketAssertions {
    NavOracleConfig internal cfg;

    /// @dev Binds the context the acceptance suite reads from a run's artifacts to a locally deployed oracle.
    function setUp() public override {
        vm.warp(1_760_000_000);
        agent = makeAddr("agent");
        executor = makeAddr("evmScriptExecutor");
        lltv = 0.98e18;
        loanToken = address(new MockERC20("USD Coin", "USDC", 6));
        collateralToken = address(new MockERC20("Ondo US Dollar Yield", "USDY", 18));
        MockOndoPriceGetter getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(1.1e18);

        cfg.kind = OracleConfigFile.KIND_NAV_USDY;
        cfg.source = address(getter);
        cfg.loanToken = loanToken;
        cfg.collateralToken = collateralToken;
        cfg.maxLltv = lltv;
        cfg.parameters = TrailingAnchorOracleModel.defaultParameters();
        cfg.seedMinPrice = 1.09e18;
        cfg.seedMaxPrice = 1.11e18;
        oracle = new DeployNavOracleHarness().deployNavOracle(cfg, agent, executor);
        _recordArtifact();
    }

    function test_assertOracle_takesTheDeployedNavOracle() external {
        _assertOracle();
    }

    /// @dev A third manager, granted after the deployment, is refused.
    function testRevert_assertOracle_extraManager() external {
        bytes32 managerRole = TrailingAnchorOracleBase(oracle).MANAGER_ROLE();
        vm.prank(agent);
        TrailingAnchorOracleBase(oracle).grantRole(managerRole, makeAddr("third"));
        vm.expectRevert(abi.encodeWithSelector(OraclePreflight.NavRoleHolderCountMismatch.selector, managerRole, 2, 3));
        this.assertOracle();
    }

    /// @dev A price acceptor that is not the Agent is refused.
    function testRevert_assertOracle_otherPriceAcceptor() external {
        bytes32 acceptorRole = TrailingAnchorOracleBase(oracle).PRICE_ACCEPTOR_ROLE();
        address other = makeAddr("other");
        vm.startPrank(agent);
        TrailingAnchorOracleBase(oracle).grantRole(acceptorRole, other);
        TrailingAnchorOracleBase(oracle).revokeRole(acceptorRole, agent);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(OraclePreflight.NavRoleHolderUnexpected.selector, acceptorRole, other));
        this.assertOracle();
    }

    /// @dev A market at a higher LLTV than the oracle is sized for is refused.
    function testRevert_assertOracle_marketLltvAboveMax() external {
        lltv = 0.982e18;
        vm.expectRevert(abi.encodeWithSelector(OraclePreflight.NavLltvAboveMax.selector, 0.982e18, 0.98e18));
        this.assertOracle();
    }

    /// @dev An artifact that records another `max_lltv` than the deployed implementation was built with is refused:
    ///      the implementation it describes has another codehash.
    function testRevert_assertOracle_artifactRecordsAnotherMaxLltv() external {
        cfg.maxLltv = 0.99e18;
        _recordArtifact();
        vm.expectPartialRevert(OraclePreflight.OracleImplementationMismatch.selector);
        this.assertOracle();
    }

    function assertOracle() external {
        _assertOracle();
    }

    /// @dev The `[oracle]` table of the run's oracle artifact, as the deploy script writes it.
    function _recordArtifact() internal {
        oracleCfg =
            string.concat("[oracle]\naddress = \"", vm.toString(oracle), "\"\n", OracleConfigFile.navArtifact(cfg));
    }
}
