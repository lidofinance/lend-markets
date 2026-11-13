// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {DeployNavOracle} from "../../script/DeployNavOracle.s.sol";
import {NavOracleConfig, OracleConfigFile} from "../../script/lib/OracleConfigFile.sol";
import {OraclePreflight} from "../../script/lib/OraclePreflight.sol";

import {MockERC20} from "../setup/Mocks.sol";
import {MockCentrifugeSpoke, MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

contract DeployNavOracleHarness is DeployNavOracle {
    function deployNavOracle(NavOracleConfig memory cfg, address agent, address evmScriptExecutor)
        external
        returns (address)
    {
        return _deployNavOracle(cfg, agent, evmScriptExecutor, address(this));
    }
}

/// @notice The NAV oracle deployment: what the script's deploy step leaves on chain is what the market preflight
///         requires, and a source price outside the config's seed range deploys nothing.
contract DeployNavOracleTest is Test {
    uint256 internal constant LLTV = 0.98e18;

    DeployNavOracleHarness internal harness;
    MockOndoPriceGetter internal getter;
    address internal agent = makeAddr("agent");
    address internal evmScriptExecutor = makeAddr("evmScriptExecutor");
    NavOracleConfig internal cfg;

    function setUp() external {
        vm.warp(1_760_000_000);
        harness = new DeployNavOracleHarness();
        getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(1.1e18);
        cfg.kind = OracleConfigFile.KIND_NAV_USDY;
        cfg.source = address(getter);
        cfg.loanToken = address(new MockERC20("USD Coin", "USDC", 6));
        cfg.collateralToken = address(new MockERC20("Ondo US Dollar Yield", "USDY", 18));
        cfg.maxLltv = LLTV;
        cfg.parameters = TrailingAnchorOracleModel.defaultParameters();
        cfg.seedMinPrice = 1.09e18;
        cfg.seedMaxPrice = 1.11e18;
    }

    /// @dev The Agent is the proxy admin, the only admin and the only price acceptor, the Agent and the EasyTrack
    ///      executor are the managers, and the deployer keeps nothing: the market preflight, which checks each role's
    ///      whole member list, takes the oracle as deployed. The anchor is the source's price.
    function test_deployNavOracle_leavesWhatThePreflightRequires() external {
        address oracle = harness.deployNavOracle(cfg, agent, evmScriptExecutor);
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(oracle);
        assertEq(nav.anchorPrice(), 1.1e18, "anchor");
        assertEq(nav.MAX_LLTV(), LLTV, "MAX_LLTV");
        assertEq(nav.getRoleMemberCount(nav.DEFAULT_ADMIN_ROLE()), 1, "one admin");
        assertTrue(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), agent), "the Agent is the admin");
        assertFalse(nav.hasRole(nav.DEFAULT_ADMIN_ROLE(), address(harness)), "the deployer renounced");
        address implementation = OraclePreflight.validateProxy(oracle, agent);
        OraclePreflight.validateNav(
            cfg, oracle, implementation, cfg.loanToken, cfg.collateralToken, LLTV, agent, evmScriptExecutor
        );
    }

    /// @dev A `nav-centrifuge` config deploys the Centrifuge adapter with each of its own arguments in its place: the
    ///      price age and the LLTV are both plain numbers, so each is read back from its own getter.
    function test_deployNavOracle_centrifugeConfigLandsInItsImmutables() external {
        uint64 poolId = 281474976710662;
        bytes16 shareClassId = 0x00010000000000060000000000000001;
        MockERC20 share = new MockERC20("JTRSY", "JTRSY", 6);
        MockCentrifugeSpoke spoke = new MockCentrifugeSpoke(poolId, shareClassId, address(share));
        spoke.setCurrentPrice(1.1e18);
        cfg.kind = OracleConfigFile.KIND_NAV_CENTRIFUGE;
        cfg.source = address(spoke);
        cfg.poolId = poolId;
        cfg.shareClassId = shareClassId;
        cfg.maxPriceAge = 3 days;
        cfg.collateralToken = address(share);

        CentrifugeNavOracle oracle = CentrifugeNavOracle(harness.deployNavOracle(cfg, agent, evmScriptExecutor));
        assertEq(address(oracle.SPOKE()), address(spoke), "SPOKE");
        assertEq(oracle.POOL_ID(), poolId, "POOL_ID");
        assertEq(oracle.SHARE_CLASS_ID(), shareClassId, "SHARE_CLASS_ID");
        assertEq(oracle.MAX_PRICE_AGE(), 3 days, "MAX_PRICE_AGE");
        assertEq(oracle.MAX_LLTV(), LLTV, "MAX_LLTV");
        assertEq(oracle.PRICE_SCALE(), 1e18, "PRICE_SCALE");
    }

    /// @dev A source one wei outside the seed range, on either side, is refused: an oracle seeded from an unreviewed
    ///      price would set its floor and ceiling around it.
    function testRevert_deployNavOracle_seedOutsideRange() external {
        getter.setCurrentPrice(1.09e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.UnexpectedPrice.selector, 1.09e18 - 1, 1.09e18, 1.11e18)
        );
        harness.deployNavOracle(cfg, agent, evmScriptExecutor);
        getter.setCurrentPrice(1.11e18 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.UnexpectedPrice.selector, 1.11e18 + 1, 1.09e18, 1.11e18)
        );
        harness.deployNavOracle(cfg, agent, evmScriptExecutor);
    }
}
