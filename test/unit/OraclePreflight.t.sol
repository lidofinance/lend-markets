// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {OraclePreflight} from "../../script/lib/OraclePreflight.sol";
import {NavOracleImplementation} from "../../script/lib/NavOracleImplementation.sol";
import {NavOracleConfig, WstEthOracleConfig, UsdyOracleConfig} from "../../script/lib/OracleConfigFile.sol";

import {MockNavOracle} from "../setup/Mocks.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

contract OraclePreflightHarness {
    function validate(
        string memory name,
        address oracle,
        address loanToken,
        address collateralToken,
        uint256 lltv,
        address admin
    ) external {
        OraclePreflight.validate(name, oracle, loanToken, collateralToken, lltv, admin);
    }

    function validateWstEth(WstEthOracleConfig memory cfg, address oracle, address collateralToken) external {
        OraclePreflight.validateWstEth(
            cfg, oracle, OssifiableProxy(payable(oracle)).proxy__getImplementation(), collateralToken
        );
        if (IOracleForTest(oracle).price() == 0) revert OraclePreflight.OraclePriceIsZero();
    }

    function validateProxy(address oracle, address admin) external returns (address) {
        return OraclePreflight.validateProxy(oracle, admin);
    }

    function validateUsdy(UsdyOracleConfig memory cfg, address oracle, address loanToken, address collateralToken)
        external
    {
        OraclePreflight.validateUsdy(
            cfg, oracle, OssifiableProxy(payable(oracle)).proxy__getImplementation(), loanToken, collateralToken
        );
        if (IOracleForTest(oracle).price() == 0) revert OraclePreflight.OraclePriceIsZero();
    }

    function validateNav(
        NavOracleConfig memory cfg,
        address oracle,
        address loanToken,
        address collateralToken,
        uint256 lltv
    ) external {
        OraclePreflight.validateNav(
            cfg, oracle, OssifiableProxy(payable(oracle)).proxy__getImplementation(), loanToken, collateralToken, lltv
        );
        if (IOracleForTest(oracle).price() == 0) revert OraclePreflight.OraclePriceIsZero();
    }

    function requireNavSizing(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv) external pure {
        OraclePreflight.requireNavSizing(p, lltv);
    }
}

interface IOracleForTest {
    function price() external view returns (uint256);
}

contract FakeOracleProxy {
    address internal immutable _admin;
    address internal immutable _implementation;

    constructor(address admin, address implementation) {
        _admin = admin;
        _implementation = implementation;
    }

    function proxy__getAdmin() external view returns (address) {
        return _admin;
    }

    function proxy__getImplementation() external view returns (address) {
        return _implementation;
    }
}

contract WstEthRateMock {
    uint256 internal rate = 1.1 ether;

    function setRate(uint256 value) external {
        rate = value;
    }

    function getStETHByWstETH(uint256 amount) external view returns (uint256) {
        return amount * rate / 1 ether;
    }
}

contract DecimalsMock {
    uint8 public immutable decimals;

    constructor(uint8 value) {
        decimals = value;
    }
}

contract NavOracleMock {
    function getPrice() external pure returns (uint256) {
        return 1 ether;
    }
}

contract FeedMock {
    uint8 public immutable decimals = 8;

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (0, 1e8, 0, 0, 0);
    }
}

contract OraclePreflightTest is Test {
    /// @dev Band for the USDY fixtures below, in the returned domain: the mocks price 1 USDY at 1e24 (a $1.00
    ///      NAV over a $1.00 feed, 6-dec loan), which sits strictly inside [0.5e24, 10e24].
    uint256 internal constant USDY_MIN_PRICE = 0.5e24;
    uint256 internal constant USDY_MAX_PRICE = 10e24;
    uint256 internal constant WAD = 1e18;
    /// @dev The LLTV the NAV fixture's market runs at: its 1% floor and 0.2% ceiling pass the sizing rule up to about
    ///      98.1%.
    uint256 internal constant NAV_LLTV = 0.98e18;

    OraclePreflightHarness internal harness;
    WstEthRateMock internal wstEth;
    address internal admin;
    address internal oracle;

    function setUp() external {
        harness = new OraclePreflightHarness();
        wstEth = new WstEthRateMock();
        admin = makeAddr("admin");
        oracle = address(new OssifiableProxy(address(new WstEthRateOracle(address(wstEth))), admin, bytes("")));
    }

    function test_validate_acceptsMatchingWstEthOracle() external {
        harness.validateWstEth(_config(), oracle, address(wstEth));
    }

    function testRevert_validate_rejectsWrongCollateral() external {
        address wrongCollateral = makeAddr("wrongCollateral");
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.OracleAddressMismatch.selector, "collateral_token", wrongCollateral, address(wstEth)
            )
        );
        harness.validateWstEth(_config(), oracle, wrongCollateral);
    }

    function testRevert_validate_rejectsWrongImplementation() external {
        address wrongOracle = address(new OssifiableProxy(address(new GuardianSignals()), admin, bytes("")));
        address expectedImplementation = address(new WstEthRateOracle(address(wstEth)));
        address actualImplementation = OssifiableProxy(payable(wrongOracle)).proxy__getImplementation();
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.OracleImplementationMismatch.selector,
                expectedImplementation.codehash,
                actualImplementation.codehash
            )
        );
        harness.validateWstEth(_config(), wrongOracle, address(wstEth));
    }

    function testRevert_validate_rejectsWrongProxyAdmin() external {
        address wrongAdmin = makeAddr("wrongAdmin");
        vm.expectRevert(abi.encodeWithSelector(OraclePreflight.OracleProxyAdminMismatch.selector, wrongAdmin, admin));
        harness.validateProxy(oracle, wrongAdmin);
    }

    function testRevert_validate_rejectsWrongProxyShell() external {
        address implementation = OssifiableProxy(payable(oracle)).proxy__getImplementation();
        address fake = address(new FakeOracleProxy(admin, implementation));
        address expectedProxy = address(new OssifiableProxy(implementation, admin, ""));

        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.OracleProxyCodehashMismatch.selector, expectedProxy.codehash, fake.codehash
            )
        );
        harness.validateProxy(fake, admin);
    }

    function testRevert_validate_rejectsZeroPrice() external {
        wstEth.setRate(0);
        vm.expectRevert(OraclePreflight.OraclePriceIsZero.selector);
        harness.validateWstEth(_config(), oracle, address(wstEth));
    }

    function _config() private view returns (WstEthOracleConfig memory) {
        return WstEthOracleConfig({wstETH: address(wstEth)});
    }

    function test_validate_acceptsMatchingUsdyOracle() external {
        DecimalsMock loan = new DecimalsMock(6);
        DecimalsMock collateral = new DecimalsMock(18);
        NavOracleMock nav = new NavOracleMock();
        FeedMock feed = new FeedMock();
        address usdyOracle = _deployUsdy(address(nav), address(feed), address(loan), USDY_MIN_PRICE, USDY_MAX_PRICE);
        UsdyOracleConfig memory cfg = _usdyConfig(address(nav), address(feed), address(loan), address(collateral));

        harness.validateUsdy(cfg, usdyOracle, address(loan), address(collateral));
    }

    function testRevert_validate_rejectsUsdyCollateralMismatch() external {
        DecimalsMock loan = new DecimalsMock(6);
        DecimalsMock collateral = new DecimalsMock(18);
        NavOracleMock nav = new NavOracleMock();
        FeedMock feed = new FeedMock();
        address usdyOracle = _deployUsdy(address(nav), address(feed), address(loan), USDY_MIN_PRICE, USDY_MAX_PRICE);
        UsdyOracleConfig memory cfg = _usdyConfig(address(nav), address(feed), address(loan), address(collateral));
        address wrongCollateral = makeAddr("wrongUsdyCollateral");

        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.OracleAddressMismatch.selector, "collateral_token", wrongCollateral, address(collateral)
            )
        );
        harness.validateUsdy(cfg, usdyOracle, address(loan), wrongCollateral);
    }

    /// @dev An instance whose immutable band does not match the config it is validated against is rejected,
    ///      which is how a band edited after deployment is caught. The mismatch is staged by widening the
    ///      config's floor below the deployed one.
    function testRevert_validate_rejectsUsdyPriceBoundMismatch() external {
        DecimalsMock loan = new DecimalsMock(6);
        DecimalsMock collateral = new DecimalsMock(18);
        NavOracleMock nav = new NavOracleMock();
        FeedMock feed = new FeedMock();
        address usdyOracle = _deployUsdy(address(nav), address(feed), address(loan), USDY_MIN_PRICE, USDY_MAX_PRICE);
        UsdyOracleConfig memory cfg = _usdyConfig(address(nav), address(feed), address(loan), address(collateral));
        cfg.minPrice = 0.25e24; // config says a wider floor than the deployed immutable

        // The codehash of an impl built from the config's bounds differs from the deployed one, so the
        // implementation check fires first — the band is part of the verified bytecode.
        address expectedImplementation = address(new UsdyStableOracle(address(nav), cfg.minPrice, cfg.maxPrice));
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.OracleImplementationMismatch.selector,
                expectedImplementation.codehash,
                OssifiableProxy(payable(usdyOracle)).proxy__getImplementation().codehash
            )
        );
        harness.validateUsdy(cfg, usdyOracle, address(loan), address(collateral));
    }

    /// @dev A live price on the band edge is rejected before the market is wired: the next NAV move would
    ///      make `price()` revert.
    function testRevert_validate_rejectsUsdyPriceOnBandEdge() external {
        DecimalsMock loan = new DecimalsMock(6);
        DecimalsMock collateral = new DecimalsMock(18);
        NavOracleMock nav = new NavOracleMock();
        FeedMock feed = new FeedMock();
        // Band floor exactly at the live price: 1e18 NAV over a 1e8 feed at scale 1e14 -> 1e24.
        address usdyOracle = _deployUsdy(address(nav), address(feed), address(loan), 1e24, USDY_MAX_PRICE);
        UsdyOracleConfig memory cfg = _usdyConfig(address(nav), address(feed), address(loan), address(collateral));
        cfg.minPrice = 1e24;

        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.OraclePriceOutOfConfiguredBounds.selector, 1e24, 1e24, USDY_MAX_PRICE
            )
        );
        harness.validateUsdy(cfg, usdyOracle, address(loan), address(collateral));
    }

    function _deployUsdy(address nav, address feed, address loan, uint256 minPrice, uint256 maxPrice)
        private
        returns (address)
    {
        return address(
            new OssifiableProxy(
                address(new UsdyStableOracle(nav, minPrice, maxPrice)),
                admin,
                abi.encodeCall(UsdyStableOracle.initialize, (feed, loan))
            )
        );
    }

    function _usdyConfig(address nav, address feed, address loan, address collateral)
        private
        pure
        returns (UsdyOracleConfig memory)
    {
        return UsdyOracleConfig({
            usdyOracle: nav,
            feed: feed,
            loanToken: loan,
            collateralToken: collateral,
            minPrice: USDY_MIN_PRICE,
            maxPrice: USDY_MAX_PRICE
        });
    }

    /// @dev A NAV oracle built from its config over the market's tokens passes, and prices its $1.00 NAV at 1e24 for
    ///      a 6-decimal loan token and an 18-decimal collateral.
    function test_validate_acceptsMatchingNavOracle() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV);
        assertEq(IOracleForTest(navOracle).price(), 1e24, "price");
    }

    function testRevert_validate_rejectsNavCollateralMismatch() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        address wrongCollateral = makeAddr("wrongCollateral");
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.OracleAddressMismatch.selector, "collateral_token", wrongCollateral, cfg.collateralToken
            )
        );
        harness.validateNav(cfg, navOracle, cfg.loanToken, wrongCollateral, NAV_LLTV);
    }

    /// @dev An oracle over another source is another implementation, refused by codehash.
    function testRevert_validate_rejectsNavImplementationMismatch() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        address deployed = OssifiableProxy(payable(navOracle)).proxy__getImplementation();
        cfg.source = _navSource();
        address expected = NavOracleImplementation.deploy(cfg);
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.OracleImplementationMismatch.selector, expected.codehash, deployed.codehash
            )
        );
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV);
    }

    /// @dev Each of the eight parameters is compared with the oracle's own value, under the config's key.
    function testRevert_validate_rejectsNavParameterMismatch() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.maxPriceAboveAnchor = 0.0004e18;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "max_price_above_anchor", 0.0004e18, TrailingAnchorOracleModel.MAX_PRICE_ABOVE_ANCHOR
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxPriceBelowAnchor = 0.002e18;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "max_price_below_anchor", 0.002e18, TrailingAnchorOracleModel.MAX_PRICE_BELOW_ANCHOR
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorRisePerYear = 0.07e18;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "max_anchor_rise_per_year", 0.07e18, TrailingAnchorOracleModel.MAX_ANCHOR_RISE_PER_YEAR
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorFallPerYear = 0.02e18;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "max_anchor_fall_per_year", 0.02e18, TrailingAnchorOracleModel.MAX_ANCHOR_FALL_PER_YEAR
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorBelowMark = 0.005e18;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "max_anchor_below_mark", 0.005e18, TrailingAnchorOracleModel.MAX_ANCHOR_BELOW_MARK
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveMark = 0.001e18;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "max_anchor_above_mark", 0.001e18, TrailingAnchorOracleModel.MAX_ANCHOR_ABOVE_MARK
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.reanchorDelay = 7 hours;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "reanchor_delay", 7 hours, TrailingAnchorOracleModel.REANCHOR_DELAY
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.reanchorWindow = 2 days;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "reanchor_window", 2 days, TrailingAnchorOracleModel.REANCHOR_WINDOW
        );
    }

    /// @dev The largest `maxAnchorAboveMark` the corridor rule leaves over each class's floor, as the spec gives it:
    ///      0.26% at a 98% LLTV with bounds of +0.05% and −0.1% and a 1% floor, 0.31% at ±0.05%, 0.21% at ±0.1%,
    ///      and 1.23% at 92% with ±0.3% and 4%. The rule passes on each.
    function test_requireNavSizing_largestAboveMarkIsTheEdge() external view {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        _assertLargestAboveMark(p, 0.98e18, 0.0026e18, "0.26% at 98%");
        p.maxPriceBelowAnchor = 0.0005e18;
        _assertLargestAboveMark(p, 0.98e18, 0.0031e18, "0.31% at 98% with 0.05% bounds");
        p.maxPriceAboveAnchor = 0.001e18;
        p.maxPriceBelowAnchor = 0.001e18;
        _assertLargestAboveMark(p, 0.98e18, 0.0021e18, "0.21% at 98% with 0.1% bounds");
        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorBelowMark = 0.04e18;
        _assertLargestAboveMark(p, 0.92e18, 0.0123e18, "1.23% at 92% with 0.3% bounds and 4%");
    }

    function testRevert_requireNavSizing_aboveMarkOneWeiTooWide() external {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        uint256 largest = _largestAboveMark(p, 0.98e18);
        p.maxAnchorAboveMark = uint64(largest + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.NavCorridorTooWide.selector, p.maxAnchorBelowMark, largest + 1, 0.98e18, largest
            )
        );
        harness.requireNavSizing(p, 0.98e18);
    }

    /// @dev The other way round: with the working 0.2% ceiling the rule allows a floor about 1.06% under the mark at
    ///      98%, and with a 1% ceiling at 92% and ±0.3% bounds about 4.22%. It passes on the edge and fails one wei
    ///      deeper, where no ceiling wider than about 0.2% fits.
    function test_requireNavSizing_largestBelowMarkIsTheEdge() external {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        uint256 largest = _largestBelowMark(p, 0.98e18);
        assertApproxEqAbs(largest, 0.0106e18, 0.00005e18, "1.06% at 98%");
        p.maxAnchorBelowMark = uint64(largest);
        harness.requireNavSizing(p, 0.98e18);
        p.maxAnchorBelowMark = uint64(largest + 1);
        uint256 largestAboveMark = _largestAboveMark(p, 0.98e18);
        assertLt(largestAboveMark, p.maxAnchorAboveMark, "the ceiling no longer fits");
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.NavCorridorTooWide.selector,
                largest + 1,
                p.maxAnchorAboveMark,
                0.98e18,
                largestAboveMark
            )
        );
        harness.requireNavSizing(p, 0.98e18);

        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorAboveMark = 0.01e18;
        largest = _largestBelowMark(p, 0.92e18);
        assertApproxEqAbs(largest, 0.0422e18, 0.00005e18, "4.22% at 92% with 0.3% bounds and 1%");
        p.maxAnchorBelowMark = uint64(largest);
        harness.requireNavSizing(p, 0.92e18);
    }

    /// @dev The preflight refuses a market whose LLTV is too high for the oracle's corridor: the fixture's 1% floor and
    ///      0.2% ceiling pass at 98% and fail at 98.2%, where the rule allows a ceiling of only about 0.12%.
    function testRevert_validate_rejectsNavCorridorTooWideForTheLltv() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        uint256 largest = _largestAboveMark(cfg.parameters, 0.982e18);
        assertApproxEqAbs(largest, 0.0012e18, 0.00005e18, "about 0.12% at 98.2%");
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.NavCorridorTooWide.selector,
                cfg.parameters.maxAnchorBelowMark,
                cfg.parameters.maxAnchorAboveMark,
                0.982e18,
                largest
            )
        );
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, 0.982e18);
    }

    /// @dev The fall side of the delay rule: with a 0.1% lower bound and a 48-hour delay a source may fall at most
    ///      0.1% × 365 days / 48 hours = 18.25% a year and stay within the bound over one delay. The edge passes, and
    ///      a 20% fall speed is refused.
    function testRevert_requireNavSizing_fallOutrunsTheDelay() external {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.reanchorDelay = 48 hours;
        p.maxAnchorFallPerYear = 0.1825e18;
        harness.requireNavSizing(p, NAV_LLTV);

        p.maxAnchorFallPerYear = 0.2e18;
        vm.expectRevert(
            abi.encodeWithSelector(OraclePreflight.NavFallOutrunsDelay.selector, 0.2e18, 48 hours, 0.1825e18)
        );
        harness.requireNavSizing(p, NAV_LLTV);
    }

    /// @dev A source already outside the bounds fails the preflight with the oracle's own revert, on the 18-decimal
    ///      prices it compares: $0.98 against a $1.00 anchor, 0.1% down and 0.05% up.
    function testRevert_validate_rejectsTrippedNavOracle() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        MockNavOracle(cfg.source).setPrice(0.98 ether);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.PriceOutOfBounds.selector, 0.98e18, 0.999e18, 1.0005e18)
        );
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV);
    }

    /// @dev Validates the fixture's oracle against the config with `p` in place of its parameters.
    function _expectNavParameterMismatch(
        NavOracleConfig memory cfg,
        address navOracle,
        TrailingAnchorOracleBase.Parameters memory p,
        string memory key,
        uint256 expected,
        uint256 actual
    ) private {
        cfg.parameters = p;
        _expectNavUintMismatch(key, expected, actual);
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV);
    }

    function _expectNavUintMismatch(string memory key, uint256 expected, uint256 actual) private {
        vm.expectRevert(abi.encodeWithSelector(OraclePreflight.OracleUintMismatch.selector, key, expected, actual));
    }

    /// @dev Checks that `p`'s largest `maxAnchorAboveMark` at `lltv` is about `expected` and that the rule passes on
    ///      it.
    function _assertLargestAboveMark(
        TrailingAnchorOracleBase.Parameters memory p,
        uint256 lltv,
        uint256 expected,
        string memory label
    ) private view {
        uint256 largest = _largestAboveMark(p, lltv);
        assertApproxEqAbs(largest, expected, 0.00005e18, label);
        p.maxAnchorAboveMark = uint64(largest);
        harness.requireNavSizing(p, lltv);
    }

    /// @dev The widest `maxAnchorAboveMark` the corridor rule allows, from the spec's formula: the highest price the
    ///      oracle returns, the ceiling × (1 + maxPriceAboveAnchor), times LLTV × LIF must stay under the lowest, the
    ///      floor × (1 − maxPriceBelowAnchor), with LIF = min(1.15, 1 / (1 − 0.3 × (1 − LLTV))) and every step
    ///      rounded against the corridor.
    function _largestAboveMark(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        private
        pure
        returns (uint256)
    {
        uint256 room = (WAD - p.maxAnchorBelowMark) * (WAD - p.maxPriceBelowAnchor) / WAD;
        uint256 needed = _neededAtTheMark(p, lltv);
        return room < needed ? 0 : room * WAD / needed - WAD;
    }

    /// @dev The widest `maxAnchorBelowMark` the corridor rule allows for `p`'s `maxAnchorAboveMark`, from the same
    ///      formula.
    function _largestBelowMark(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        private
        pure
        returns (uint256)
    {
        uint256 needed = _ceilDiv(_neededAtTheMark(p, lltv) * (WAD + p.maxAnchorAboveMark), WAD);
        return WAD - _ceilDiv(needed * WAD, WAD - p.maxPriceBelowAnchor);
    }

    /// @dev What the rule needs with the ceiling on the mark: LLTV × LIF × (1 + maxPriceAboveAnchor), each step
    ///      rounded up.
    function _neededAtTheMark(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        private
        pure
        returns (uint256)
    {
        uint256 lif = WAD * WAD / (WAD - 0.3e18 * (WAD - lltv) / WAD);
        if (lif > 1.15e18) lif = 1.15e18;
        return _ceilDiv(_ceilDiv(lltv * lif, WAD) * (WAD + p.maxPriceAboveAnchor), WAD);
    }

    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function _navFixture() private returns (NavOracleConfig memory cfg, address navOracle) {
        cfg = NavOracleConfig({
            kind: "nav-usdy",
            source: _navSource(),
            poolId: 0,
            shareClassId: bytes16(0),
            loanToken: address(new DecimalsMock(6)),
            collateralToken: address(new DecimalsMock(18)),
            parameters: TrailingAnchorOracleModel.defaultParameters()
        });
        navOracle = address(
            new OssifiableProxy(
                NavOracleImplementation.deploy(cfg),
                admin,
                TrailingAnchorOracleModel.initializeCall(admin, cfg.parameters)
            )
        );
    }

    /// @dev An Ondo-style NAV getter at $1.00.
    function _navSource() private returns (address source) {
        MockNavOracle nav = new MockNavOracle();
        nav.setPrice(1 ether);
        return address(nav);
    }
}
