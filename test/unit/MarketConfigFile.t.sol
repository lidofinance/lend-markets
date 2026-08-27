// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {MarketConfigFile} from "../../script/lib/MarketConfigFile.sol";

contract MarketConfigFileHarness {
    function parse(string memory toml)
        external
        pure
        returns (
            LidoLendMarketFactory.MarketSpec memory market,
            LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec,
            AdaptiveCurveParams memory curve
        )
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
        (
            LidoLendMarketFactory.MarketSpec memory market,
            LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec,
            AdaptiveCurveParams memory curve
        ) = harness.parse(toml);

        assertEq(market.lltv, 0.8e18, "lltv");
        assertEq(erc4626WrapperSpec.name, "Test Vault", "ERC-4626 wrapper name");
        assertEq(erc4626WrapperSpec.symbol, "TEST", "ERC-4626 wrapper symbol");
        assertEq(curve.curveSteepness, 4e18, "curve steepness");
        assertEq(curve.targetUtilization, 0.9e18, "target utilization");
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
            "[activation]\n",
            "min_activation_delay = 600\n",
            "max_activation_delay = 7200\n",
            "max_delay_inflow = \"10000000000000000000000\"\n",
            "activating_lock_duration = 0\n",
            "min_activation_amount = \"10000000000000000000\"\n",
            "min_deposit_amount = \"0\"\n",
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
