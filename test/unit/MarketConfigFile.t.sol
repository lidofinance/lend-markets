// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";

import {LidoLendMarketBuilder, MarketRoles} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {MarketConfigFile, IrmSelection} from "../../script/lib/MarketConfigFile.sol";
import {IrmConfigFile} from "../../script/lib/IrmConfigFile.sol";

contract MarketConfigFileHarness {
    function parse(string memory toml)
        external
        view
        returns (LidoLendMarketBuilder.MarketSpec memory market, MarketRoles memory roles, IrmSelection memory irm)
    {
        return MarketConfigFile.parse(toml);
    }
}

contract MarketConfigFileTest is Test {
    MarketConfigFileHarness internal harness;
    string internal toml;

    function setUp() external {
        harness = new MarketConfigFileHarness();
        toml = _validToml();
    }

    function test_parse_acceptsQuotedWideValues() external view {
        (LidoLendMarketBuilder.MarketSpec memory market,, IrmSelection memory irm) = harness.parse(toml);

        assertEq(market.lltv, 0.8e18, "lltv");
        assertEq(irm.curve.curveSteepness, 4e18, "curve steepness");
        assertEq(irm.curve.targetUtilization, 0.9e18, "target utilization");
    }

    /// @dev A config with no `irm_artifact` key is an adaptive-curve market: the overwhelmingly common case
    ///      keeps working without the new key.
    function test_parse_defaultsToTheBackboneAdaptiveCurveIrm() external view {
        (,, IrmSelection memory irm) = harness.parse(toml);

        assertEq(irm.artifact, IrmConfigFile.ADAPTIVE_CURVE, "irm artifact defaults to adaptive-curve");
        assertFalse(irm.kinked, "not kinked");
    }

    function test_parse_kinkedMarketReadsKinkParams() external view {
        (,, IrmSelection memory irm) = harness.parse(_kinkedToml());

        assertEq(irm.artifact, "linear-kink", "irm artifact");
        assertTrue(irm.kinked, "kinked");
        assertEq(uint256(irm.kink.optimalUtilization), 0.9e18, "optimal utilization");
        assertEq(uint256(irm.kink.baseRate), 158548959, "base rate");
        assertEq(uint256(irm.kink.slope1), 634195839, "slope1");
        assertEq(uint256(irm.kink.slope2), 443937087, "slope2");
    }

    /// @dev The model and its params travel together: naming the kinked IRM while carrying `[curve]` is a
    ///      config error, not a market that silently activates with the wrong params.
    function testRevert_parse_kinkedMarketCarryingCurveParams() external {
        string memory invalid = vm.replace(_kinkedToml(), "[kink]", "[curve]");

        vm.expectRevert(abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".kink"));
        harness.parse(invalid);
    }

    function testRevert_parse_adaptiveMarketCarryingKinkParams() external {
        string memory invalid = vm.replace(toml, "[curve]", "[kink]");

        vm.expectRevert(abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".curve"));
        harness.parse(invalid);
    }

    function testRevert_parse_kinkOptimalUtilizationAtFullUtilization() external {
        string memory invalid = vm.replace(
            _kinkedToml(),
            "optimal_utilization = \"900000000000000000\"",
            "optimal_utilization = \"1000000000000000000\""
        );

        vm.expectRevert(
            abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".kink.optimal_utilization")
        );
        harness.parse(invalid);
    }

    /// @dev `LinearKinkIrm.MAX_BORROW_RATE` is 800%/yr on `baseRate + slope1 + slope2`.
    function testRevert_parse_kinkPeakRateOverModelCap() external {
        string memory invalid = vm.replace(_kinkedToml(), "slope2 = \"443937087\"", "slope2 = \"253678335870\"");

        vm.expectRevert(abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".kink.peak_rate"));
        harness.parse(invalid);
    }

    function testRevert_parse_sliceFloorBpsOverLimit() external {
        string memory invalid = vm.replace(toml, "slice_floor_bps = 100", "slice_floor_bps = 10001");

        vm.expectRevert(
            abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".settlement.slice_floor_bps")
        );
        harness.parse(invalid);
    }

    function testRevert_parse_ltvStepBpsOverLimit() external {
        string memory invalid = vm.replace(toml, "ltv_step_bps = 100", "ltv_step_bps = 10001");

        vm.expectRevert(
            abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".settlement.ltv_step_bps")
        );
        harness.parse(invalid);
    }

    function testRevert_parse_invalidCurve() external {
        string memory invalid = vm.replace(
            toml, "target_utilization = \"900000000000000000\"", "target_utilization = \"1000000000000000000\""
        );

        vm.expectRevert(
            abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".curve.target_utilization")
        );
        harness.parse(invalid);
    }

    function testRevert_parse_activationDelayOverUint40() external {
        string memory invalid = vm.replace(toml, "min_activation_delay = 600", "min_activation_delay = 1099511627776");

        vm.expectRevert(
            abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".activation.min_activation_delay")
        );
        harness.parse(invalid);
    }

    function testRevert_parse_sliceFloorAssetsOverUint96() external {
        string memory invalid =
            vm.replace(toml, "slice_floor_assets = \"0\"", "slice_floor_assets = \"79228162514264337593543950336\"");

        vm.expectRevert(
            abi.encodeWithSelector(MarketConfigFile.InvalidConfigValue.selector, ".settlement.slice_floor_assets")
        );
        harness.parse(invalid);
    }

    /// @dev The same market, opted into the deployed `linear-kink` IRM: `[kink]` replaces `[curve]`. Rates are
    ///      per-second WAD — 0.5%/yr base, 2%/yr slope1, 1.4%/yr slope2.
    function _kinkedToml() private view returns (string memory) {
        string memory withRef = vm.replace(
            toml, "lltv = \"800000000000000000\"", "lltv = \"800000000000000000\"\nirm_artifact = \"linear-kink\""
        );
        return string.concat(
            vm.replace(
                withRef,
                string.concat(
                    "[curve]\n",
                    "curve_steepness = \"4000000000000000000\"\n",
                    "adjustment_speed = \"1585489599188\"\n",
                    "target_utilization = \"900000000000000000\"\n",
                    "initial_rate_at_target = \"1268391679\"\n",
                    "min_rate_at_target = \"31709791\"\n",
                    "max_rate_at_target = \"63419583967\"\n",
                    "max_borrow_rate = \"0\"\n"
                ),
                ""
            ),
            "[kink]\n",
            "optimal_utilization = \"900000000000000000\"\n",
            "base_rate = \"158548959\"\n",
            "slope1 = \"634195839\"\n",
            "slope2 = \"443937087\"\n"
        );
    }

    function _validToml() private pure returns (string memory) {
        return string.concat(
            "[market]\n",
            "loan_token = \"0x0000000000000000000000000000000000000001\"\n",
            "collateral_token = \"0x0000000000000000000000000000000000000002\"\n",
            "oracle = \"0x0000000000000000000000000000000000000003\"\n",
            "lltv = \"800000000000000000\"\n",
            "guardian_signals = \"0x0000000000000000000000000000000000000004\"\n",
            "vault_name = \"Test Vault\"\n",
            "vault_symbol = \"TEST\"\n",
            "[roles]\n",
            "admin = \"0x0000000000000000000000000000000000000005\"\n",
            "proxy_admin = \"0x0000000000000000000000000000000000000006\"\n",
            "managers = []\n",
            "pausers = []\n",
            "freezers = []\n",
            "unfreezers = []\n",
            "resumers = []\n",
            "[activation]\n",
            "min_activation_delay = 600\n",
            "max_activation_delay = 7200\n",
            "max_delay_inflow = \"10000000000000000000000\"\n",
            "activating_lock_amount = \"0\"\n",
            "activating_lock_duration = 0\n",
            "min_activation_amount = \"10000000000000000000\"\n",
            "max_guardians_quorum_delay = 0\n",
            "delay_per_strike = 7200\n",
            "delay_per_suspect = 0\n",
            "[settlement]\n",
            "slice_floor_bps = 100\n",
            "slice_floor_assets = \"0\"\n",
            "full_cut_below_collateral = \"10000000000000000000\"\n",
            "ltv_step_bps = 100\n",
            "[curve]\n",
            "curve_steepness = \"4000000000000000000\"\n",
            "adjustment_speed = \"1585489599188\"\n",
            "target_utilization = \"900000000000000000\"\n",
            "initial_rate_at_target = \"1268391679\"\n",
            "min_rate_at_target = \"31709791\"\n",
            "max_rate_at_target = \"63419583967\"\n",
            "max_borrow_rate = \"0\"\n"
        );
    }
}
