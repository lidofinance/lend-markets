// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {UsdyStableOracle} from "../../src/oracle/UsdyStableOracle.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {OraclePreflight} from "../../script/lib/OraclePreflight.sol";
import {WstEthOracleConfig, UsdyOracleConfig} from "../../script/lib/OracleConfigFile.sol";

contract OraclePreflightHarness {
    function validate(string memory name, address oracle, address loanToken, address collateralToken, address admin)
        external
    {
        OraclePreflight.validate(name, oracle, loanToken, collateralToken, admin);
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
}
