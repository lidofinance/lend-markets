// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ConfigToml} from "../../script/lib/ConfigToml.sol";
import {OracleConfigFile, UsdyOracleConfig} from "../../script/lib/OracleConfigFile.sol";

contract OracleConfigFileHarness {
    function parseUsdy(string memory toml) external view returns (UsdyOracleConfig memory) {
        return OracleConfigFile.parseUsdy(toml);
    }

    function readUsdy(string memory name) external view returns (UsdyOracleConfig memory) {
        return OracleConfigFile.readUsdy(name);
    }
}

/// @notice Unit tests for the USDY oracle configuration: the sanity band travels from the TOML into the
///         constructor arguments, and a config missing or zeroing either bound is rejected before broadcast.
contract OracleConfigFileTest is Test {
    OracleConfigFileHarness internal harness;
    string internal toml;

    function setUp() external {
        harness = new OracleConfigFileHarness();
        toml = _validToml();
    }

    /// @dev The bounds are quoted because they exceed int64; parsing keeps their full width.
    function test_parseUsdy_acceptsQuotedWideBounds() external view {
        UsdyOracleConfig memory cfg = harness.parseUsdy(toml);

        assertEq(cfg.usdyOracle, address(0xA1), "usdy_oracle");
        assertEq(cfg.feed, address(0xF1), "feed");
        assertEq(cfg.loanToken, address(0x11), "loan_token");
        assertEq(cfg.collateralToken, address(0xC1), "collateral_token");
        assertEq(cfg.minPrice, 0.5e24, "min_price");
        assertEq(cfg.maxPrice, 10e24, "max_price");
    }

    /// @dev A config with no lower bound cannot be deployed: the oracle rejects a zero `MIN_PRICE`, and
    ///      silently defaulting one would leave the market with no floor at all.
    function testRevert_parseUsdy_missingMinPrice() external {
        string memory invalid = vm.replace(toml, "min_price = \"500000000000000000000000\"\n", "");
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".min_price"));
        harness.parseUsdy(invalid);
    }

    /// @dev Same for the upper bound.
    function testRevert_parseUsdy_missingMaxPrice() external {
        string memory invalid = vm.replace(toml, "max_price = \"10000000000000000000000000\"\n", "");
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".max_price"));
        harness.parseUsdy(invalid);
    }

    /// @dev A zero bound is treated as unset rather than as a band that accepts everything.
    function testRevert_parseUsdy_zeroMinPrice() external {
        string memory invalid = vm.replace(toml, "min_price = \"500000000000000000000000\"", "min_price = \"0\"");
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".min_price"));
        harness.parseUsdy(invalid);
    }

    /// @dev The fork-provisioning config is fully filled in, so it round-trips through `readUsdy` and must
    ///      carry a usable band: `deploy-oracle-usdy` cannot broadcast an instance whose `price()` reverts on
    ///      every call.
    function test_readUsdy_forkConfigCarriesUsableBand() external view {
        UsdyOracleConfig memory cfg = harness.readUsdy("fork-usdy-usdt");
        assertGt(cfg.minPrice, 0, "min_price");
        assertLe(cfg.minPrice, cfg.maxPrice, "min_price <= max_price");
    }

    /// @dev The mainnet config is an addresses-to-be-filled placeholder, so it is checked at the TOML level:
    ///      the band keys must already be there, since a filled-in address list with no band would not deploy.
    function test_mainnetConfig_declaresBand() external view {
        string memory raw = vm.readFile(OracleConfigFile.configPath("usdy-usdt"));
        uint256 minPrice = vm.parseTomlUint(raw, ".min_price");
        uint256 maxPrice = vm.parseTomlUint(raw, ".max_price");
        assertGt(minPrice, 0, "min_price");
        assertLe(minPrice, maxPrice, "min_price <= max_price");
    }

    function _validToml() private pure returns (string memory) {
        return string.concat(
            "kind = \"usdy\"\n",
            "usdy_oracle = \"0x00000000000000000000000000000000000000A1\"\n",
            "feed = \"0x00000000000000000000000000000000000000F1\"\n",
            "loan_token = \"0x0000000000000000000000000000000000000011\"\n",
            "collateral_token = \"0x00000000000000000000000000000000000000C1\"\n",
            "min_price = \"500000000000000000000000\"\n",
            "max_price = \"10000000000000000000000000\"\n"
        );
    }
}
