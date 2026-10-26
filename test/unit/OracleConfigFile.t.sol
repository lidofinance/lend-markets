// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {ConfigToml} from "../../script/lib/ConfigToml.sol";
import {NavOracleConfig, OracleConfigFile, UsdyOracleConfig} from "../../script/lib/OracleConfigFile.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

contract OracleConfigFileHarness {
    function parseUsdy(string memory toml) external view returns (UsdyOracleConfig memory) {
        return OracleConfigFile.parseUsdy(toml);
    }

    function readUsdy(string memory name) external view returns (UsdyOracleConfig memory) {
        return OracleConfigFile.readUsdy(name);
    }

    function parseNav(string memory toml, string memory prefix) external view returns (NavOracleConfig memory) {
        return OracleConfigFile.parseNav(toml, prefix);
    }

    function navArtifact(NavOracleConfig memory cfg) external pure returns (string memory) {
        return OracleConfigFile.navArtifact(cfg);
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

    // ---
    // NAV ORACLE CONFIG
    // ---

    /// @dev Every adapter kind's constructor arguments, both bounds, the lifetime and both speeds travel from the TOML
    ///      into the deployment.
    function test_parseNav_readsCentrifugeConfig() external view {
        NavOracleConfig memory cfg = harness.parseNav(_navCentrifugeToml(), "");
        assertEq(cfg.kind, "nav-centrifuge", "kind");
        assertEq(cfg.source, address(0x5B), "source");
        assertEq(cfg.poolId, 281474976710662, "pool_id");
        assertEq(cfg.shareClassId, bytes16(0x00010000000000060000000000000001), "share_class_id");
        assertEq(cfg.loanToken, address(0x11), "loan_token");
        assertEq(cfg.collateralToken, address(0xC1), "collateral_token");
        assertEq(cfg.maxPriceIncrease, TrailingAnchorOracleModel.MAX_PRICE_INCREASE, "max_price_increase");
        assertEq(cfg.maxPriceDecrease, TrailingAnchorOracleModel.MAX_PRICE_DECREASE, "max_price_decrease");
        assertEq(cfg.anchorLifetime, TrailingAnchorOracleModel.ANCHOR_LIFETIME, "anchor_lifetime");
        assertEq(cfg.maxAnchorRise, TrailingAnchorOracleModel.MAX_ANCHOR_RISE, "max_anchor_rise");
        assertEq(cfg.maxAnchorFall, TrailingAnchorOracleModel.MAX_ANCHOR_FALL, "max_anchor_fall");
    }

    function testRevert_parseNav_unknownKind() external {
        string memory invalid = vm.replace(_navUsdyToml(), "kind = \"nav-usdy\"", "kind = \"usdy\"");
        vm.expectRevert(abi.encodeWithSelector(OracleConfigFile.UnknownOracleKind.selector, "usdy"));
        harness.parseNav(invalid, "");
    }

    function testRevert_parseNav_missingMaxAnchorRise() external {
        string memory invalid = vm.replace(_navUsdyToml(), "max_anchor_rise = \"60000000000000000\"\n", "");
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".max_anchor_rise"));
        harness.parseNav(invalid, "");
    }

    /// @dev The validator needs both bounds and the lifetime, and a zero speed would leave the anchor unable to follow
    ///      the source, so a zero one is refused as unset before broadcast.
    function testRevert_parseNav_zeroRequiredParam() external {
        string memory invalid =
            vm.replace(_navUsdyToml(), "max_price_increase = \"500000000000000\"", "max_price_increase = \"0\"");
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".max_price_increase"));
        harness.parseNav(invalid, "");
        invalid = vm.replace(_navUsdyToml(), "anchor_lifetime = 864000", "anchor_lifetime = 0");
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".anchor_lifetime"));
        harness.parseNav(invalid, "");
        invalid = vm.replace(_navUsdyToml(), "max_anchor_fall = \"10000000000000000\"", "max_anchor_fall = \"0\"");
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".max_anchor_fall"));
        harness.parseNav(invalid, "");
    }

    function testRevert_parseNav_zeroLoanToken() external {
        string memory invalid = vm.replace(
            _navUsdyToml(), "0x0000000000000000000000000000000000000011", "0x0000000000000000000000000000000000000000"
        );
        vm.expectRevert(abi.encodeWithSelector(ConfigToml.MissingConfigValue.selector, ".loan_token"));
        harness.parseNav(invalid, "");
    }

    function testRevert_parseNav_shareClassIdLength() external {
        string memory invalid =
            vm.replace(_navCentrifugeToml(), "0x00010000000000060000000000000001", "0x000100000000000600000000000001");
        vm.expectRevert(abi.encodeWithSelector(OracleConfigFile.ShareClassIdNot16Bytes.selector, 15));
        harness.parseNav(invalid, "");
    }

    /// @dev What deployment records under `[oracle]` reads back to the config it came from.
    function test_navArtifact_roundTrips() external view {
        NavOracleConfig memory cfg = harness.parseNav(_navCentrifugeToml(), "");
        string memory artifact = string.concat("[oracle]\n", harness.navArtifact(cfg));
        NavOracleConfig memory back = harness.parseNav(artifact, ".oracle");
        assertEq(keccak256(abi.encode(back)), keccak256(abi.encode(cfg)), "round trip");
    }

    function _navUsdyToml() private pure returns (string memory) {
        return string.concat(
            "kind = \"nav-usdy\"\n",
            "source = \"0x000000000000000000000000000000000000005B\"\n",
            "loan_token = \"0x0000000000000000000000000000000000000011\"\n",
            "collateral_token = \"0x00000000000000000000000000000000000000C1\"\n",
            "max_price_increase = \"500000000000000\"\n",
            "max_price_decrease = \"1000000000000000\"\n",
            "anchor_lifetime = 864000\n",
            "max_anchor_rise = \"60000000000000000\"\n",
            "max_anchor_fall = \"10000000000000000\"\n"
        );
    }

    function _navCentrifugeToml() private pure returns (string memory) {
        return string.concat(
            "kind = \"nav-centrifuge\"\n",
            "source = \"0x000000000000000000000000000000000000005B\"\n",
            "pool_id = 281474976710662\n",
            "share_class_id = \"0x00010000000000060000000000000001\"\n",
            "loan_token = \"0x0000000000000000000000000000000000000011\"\n",
            "collateral_token = \"0x00000000000000000000000000000000000000C1\"\n",
            "max_price_increase = \"500000000000000\"\n",
            "max_price_decrease = \"1000000000000000\"\n",
            "anchor_lifetime = 864000\n",
            "max_anchor_rise = \"60000000000000000\"\n",
            "max_anchor_fall = \"10000000000000000\"\n"
        );
    }
}
