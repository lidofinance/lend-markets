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
        address admin,
        address evmScriptExecutor
    ) external {
        OraclePreflight.validate(name, oracle, loanToken, collateralToken, lltv, admin, evmScriptExecutor);
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
        uint256 lltv,
        address admin,
        address evmScriptExecutor
    ) external {
        OraclePreflight.validateNav(
            cfg,
            oracle,
            OssifiableProxy(payable(oracle)).proxy__getImplementation(),
            loanToken,
            collateralToken,
            lltv,
            admin,
            evmScriptExecutor
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
    /// @dev The LLTV the NAV fixture's market runs at.
    uint256 internal constant NAV_LLTV = 0.98e18;

    OraclePreflightHarness internal harness;
    WstEthRateMock internal wstEth;
    address internal admin;
    address internal evmScriptExecutor = makeAddr("evmScriptExecutor");
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
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV, admin, evmScriptExecutor);
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
        harness.validateNav(cfg, navOracle, cfg.loanToken, wrongCollateral, NAV_LLTV, admin, evmScriptExecutor);
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
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV, admin, evmScriptExecutor);
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
        p.maxAnchorContinuousRiseRate = 0.07e18;
        _expectNavParameterMismatch(
            cfg,
            navOracle,
            p,
            "max_anchor_continuous_rise_rate",
            0.07e18,
            TrailingAnchorOracleModel.MAX_ANCHOR_CONTINUOUS_RISE_RATE
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorContinuousFallRate = 0.02e18;
        _expectNavParameterMismatch(
            cfg,
            navOracle,
            p,
            "max_anchor_continuous_fall_rate",
            0.02e18,
            TrailingAnchorOracleModel.MAX_ANCHOR_CONTINUOUS_FALL_RATE
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorBelowBase = 0.005e18;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "max_anchor_below_base", 0.005e18, TrailingAnchorOracleModel.MAX_ANCHOR_BELOW_BASE
        );
        p = TrailingAnchorOracleModel.defaultParameters();
        p.maxAnchorAboveBase = 0.001e18;
        _expectNavParameterMismatch(
            cfg, navOracle, p, "max_anchor_above_base", 0.001e18, TrailingAnchorOracleModel.MAX_ANCHOR_ABOVE_BASE
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

    /// @dev The working 1% floor and 0.2% ceiling fit a 98% LLTV and not 98.2%. There LIF = 1 / (1 − 0.3 × 0.018)
    ///      and LLTV × LIF × 1.0005 = 0.987825…, which leaves a ceiling of 0.1199% over the 0.99 × 0.999 of the
    ///      floor.
    function testRevert_validate_rejectsNavCorridorTooWideForTheLltv() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.NavCorridorTooWide.selector, 0.01e18, 0.002e18, 0.982e18, 1_199_345_337_514_542
            )
        );
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, 0.982e18, admin, evmScriptExecutor);
    }

    /// @dev A market at a lower LLTV passes: the corridor that fits 98% also fits 92%.
    function test_validate_acceptsNavMarketAtALowerLltv() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, 0.92e18, admin, evmScriptExecutor);
    }

    /// @dev An extra holder of any role is refused: a deployer left as admin, a third manager, a second price
    ///      acceptor.
    function testRevert_validate_rejectsNavExtraRoleHolder() external {
        address deployer = makeAddr("deployer");
        bytes32[3] memory roles;
        uint256[3] memory expectedCounts = [uint256(1), 2, 1];
        for (uint256 i; i < 3; ++i) {
            (NavOracleConfig memory cfg, address navOracle) = _navFixture();
            TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(navOracle);
            roles = [nav.DEFAULT_ADMIN_ROLE(), nav.MANAGER_ROLE(), nav.PRICE_ACCEPTOR_ROLE()];
            vm.prank(admin);
            nav.grantRole(roles[i], deployer);
            vm.expectRevert(
                abi.encodeWithSelector(
                    OraclePreflight.NavRoleHolderCountMismatch.selector,
                    roles[i],
                    expectedCounts[i],
                    expectedCounts[i] + 1
                )
            );
            harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV, admin, evmScriptExecutor);
        }
    }

    /// @dev A role with the right number of holders but a wrong one is refused, with the wrong holder named: the
    ///      deployer in place of the EasyTrack executor or of the Agent as a manager, in place of the Agent as the
    ///      price acceptor, and in place of the Agent as the admin.
    function testRevert_validate_rejectsNavWrongRoleHolder() external {
        address deployer = makeAddr("deployer");
        for (uint256 i; i < 4; ++i) {
            (NavOracleConfig memory cfg, address navOracle) = _navFixture();
            TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(navOracle);
            bytes32[4] memory roles =
                [nav.MANAGER_ROLE(), nav.MANAGER_ROLE(), nav.PRICE_ACCEPTOR_ROLE(), nav.DEFAULT_ADMIN_ROLE()];
            address replaced = i == 0 ? evmScriptExecutor : admin;
            vm.startPrank(admin);
            nav.grantRole(roles[i], deployer);
            nav.revokeRole(roles[i], replaced);
            vm.stopPrank();
            vm.expectRevert(
                abi.encodeWithSelector(OraclePreflight.NavRoleHolderUnexpected.selector, roles[i], deployer)
            );
            harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV, admin, evmScriptExecutor);
        }
    }

    /// @dev The holder check is on the oracle's own members, so an expected list that names one address twice does
    ///      not let a second manager through.
    function testRevert_validate_rejectsNavHolderBesideARepeatedExpectedOne() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        bytes32 managerRole = TrailingAnchorOracleBase(navOracle).MANAGER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(OraclePreflight.NavRoleHolderUnexpected.selector, managerRole, evmScriptExecutor)
        );
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV, admin, admin);
    }

    /// @dev A source already outside the bounds fails the preflight with the oracle's own revert, on the 18-decimal
    ///      prices it compares: $0.98 against a $1.00 anchor, 0.1% down and 0.05% up.
    function testRevert_validate_rejectsTrippedNavOracle() external {
        (NavOracleConfig memory cfg, address navOracle) = _navFixture();
        MockNavOracle(cfg.source).setPrice(0.98 ether);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.PriceOutOfBounds.selector, 0.98e18, 0.999e18, 1.0005e18)
        );
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV, admin, evmScriptExecutor);
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
        harness.validateNav(cfg, navOracle, cfg.loanToken, cfg.collateralToken, NAV_LLTV, admin, evmScriptExecutor);
    }

    function _expectNavUintMismatch(string memory key, uint256 expected, uint256 actual) private {
        vm.expectRevert(abi.encodeWithSelector(OraclePreflight.OracleUintMismatch.selector, key, expected, actual));
    }

    function _navFixture() private returns (NavOracleConfig memory cfg, address navOracle) {
        cfg = NavOracleConfig({
            kind: "nav-usdy",
            source: _navSource(),
            poolId: 0,
            shareClassId: bytes16(0),
            maxPriceAge: 0,
            loanToken: address(new DecimalsMock(6)),
            collateralToken: address(new DecimalsMock(18)),
            parameters: TrailingAnchorOracleModel.defaultParameters(),
            seedMinPrice: 0.99e18,
            seedMaxPrice: 1.01e18
        });
        navOracle = address(
            new OssifiableProxy(
                NavOracleImplementation.deploy(cfg),
                admin,
                TrailingAnchorOracleModel.initializeCall(admin, cfg.parameters, cfg.seedMinPrice, cfg.seedMaxPrice)
            )
        );
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(navOracle);
        bytes32 managerRole = nav.MANAGER_ROLE();
        bytes32 priceAcceptorRole = nav.PRICE_ACCEPTOR_ROLE();
        vm.startPrank(admin);
        nav.grantRole(managerRole, admin);
        nav.grantRole(managerRole, evmScriptExecutor);
        nav.grantRole(priceAcceptorRole, admin);
        vm.stopPrank();
    }

    /// @dev An Ondo-style NAV getter at $1.00.
    function _navSource() private returns (address source) {
        MockNavOracle nav = new MockNavOracle();
        nav.setPrice(1 ether);
        return address(nav);
    }
}

/// @notice The sizing rule the preflight checks at the market's LLTV. The expected edges come from the spec's sizing
///         formula, written out here, not from the preflight.
contract OraclePreflightNavSizingTest is Test {
    uint256 internal constant WAD = 1e18;
    /// @dev The preflight rounds the needed side up and the room side down, so it may refuse a line up to this many wei
    ///      inside the edge of the rule. In wei of a whole price, the two ceilings on the needed side add less than
    ///      (1 + above)(1 + ceiling) + (1 + ceiling). The floor on the room and the last ceiling add less than 1
    ///      together, since an integer is below ceil(y) only if it is below y. A ceiling k wei inside the edge leaves
    ///      k × LLTV × LIF × (1 + above) of room, so a refusal needs that sum to be more. The edge stays
    ///      under a whole price, so LLTV × LIF × (1 + above) is at least half the room, and k is at most 10. The
    ///      floor needs only 3.
    uint256 internal constant MAX_ROUNDING_GAP = 10;

    OraclePreflightHarness internal harness;

    function setUp() public {
        harness = new OraclePreflightHarness();
    }

    /// @dev The largest `maxAnchorAboveBase` the sizing rule leaves over each class's floor, by the spec's
    ///      formula: 0.26% at a 98% LLTV with bounds of +0.05% and −0.1% and a 1% floor, 0.31% at ±0.05%, 0.21% at
    ///      ±0.1%, and 1.23% at 92% with ±0.3% and 4%. Each edge passes, and one wei more is refused.
    function test_requireNavSizing_largestAboveBaseIsTheEdge() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        _assertAboveBaseEdge(p, 0.98e18, 0.0026e18, "0.26% at 98%");
        p.maxPriceBelowAnchor = 0.0005e18;
        _assertAboveBaseEdge(p, 0.98e18, 0.0031e18, "0.31% at 98% with 0.05% bounds");
        p.maxPriceAboveAnchor = 0.001e18;
        p.maxPriceBelowAnchor = 0.001e18;
        _assertAboveBaseEdge(p, 0.98e18, 0.0021e18, "0.21% at 98% with 0.1% bounds");
        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorBelowBase = 0.04e18;
        _assertAboveBaseEdge(p, 0.92e18, 0.0123e18, "1.23% at 92% with 0.3% bounds and 4%");
    }

    /// @dev Under an LLTV of about 56.5% the core holds the liquidation incentive at 1.15. At 50% the rule needs
    ///      0.5 × 1.15 × 1.0005 = 0.5752875 of the 0.99 × 0.999 the floor leaves, so the ceiling may sit 71.92% over
    ///      the base price. With the incentive not held, 1 / 0.85, it would stop at 68.05%.
    function test_requireNavSizing_edgeWhereTheIncentiveIsHeld() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        _assertAboveBaseEdge(p, 0.5e18, 0.71916e18, "71.92% at 50%");
    }

    /// @dev The other way round: with the working 0.2% ceiling the rule allows a floor about 1.06% under the base
    ///      price at 98%, and with a 1% ceiling at 92% and ±0.3% bounds about 4.22%. Each edge passes, and one wei
    ///      deeper is refused.
    function test_requireNavSizing_largestBelowBaseIsTheEdge() public {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        uint256 largest = _largestBelowBase(p, 0.98e18);
        assertApproxEqAbs(largest, 0.0106e18, 0.00005e18, "1.06% at 98%");
        p.maxAnchorBelowBase = uint64(largest);
        harness.requireNavSizing(p, 0.98e18);
        p.maxAnchorBelowBase = uint64(largest + 1);
        _expectRefused(p, 0.98e18);

        p.maxPriceAboveAnchor = 0.003e18;
        p.maxPriceBelowAnchor = 0.003e18;
        p.maxAnchorAboveBase = 0.01e18;
        largest = _largestBelowBase(p, 0.92e18);
        assertApproxEqAbs(largest, 0.0422e18, 0.00005e18, "4.22% at 92% with 0.3% bounds and 1%");
        p.maxAnchorBelowBase = uint64(largest);
        harness.requireNavSizing(p, 0.92e18);
        p.maxAnchorBelowBase = uint64(largest + 1);
        _expectRefused(p, 0.92e18);
    }

    /// @dev Any LLTV and any corridor: the preflight takes the parameters only if the lowest price the oracle can
    ///      return covers a debt borrowed at the LLTV against the highest, with the core's incentive on top, and
    ///      refuses them only if it does not. The inequality is checked in whole numbers with no division, so it shares
    ///      no rounding with the preflight; the two may differ by the few wei the preflight rounds against the
    ///      corridor. Its rounding refuses a set up to 4.1 wei over the rule and takes one up to 3.7 wei under it.
    function testFuzz_requireNavSizing_takesACorridorOnlyIfItCoversTheLiquidation(
        uint256 lltv,
        uint64 above,
        uint64 below,
        uint64 belowBase,
        uint64 aboveBase
    ) public {
        lltv = bound(lltv, 0.3e18, 0.99e18);
        TrailingAnchorOracleBase.Parameters memory p;
        p.maxPriceAboveAnchor = uint64(bound(above, 1, 0.05e18));
        p.maxPriceBelowAnchor = uint64(bound(below, 1, 0.05e18));
        p.maxAnchorBelowBase = uint64(bound(belowBase, 0, 0.5e18));
        p.maxAnchorAboveBase = uint64(bound(aboveBase, 0, 0.5e18));

        try harness.requireNavSizing(p, lltv) {
            assertTrue(_covers(p, lltv, 0, 4), "taken, so the corridor covers the liquidation");
        } catch (bytes memory revertData) {
            assertEq(bytes4(revertData), OraclePreflight.NavCorridorTooWide.selector, "refused by the rule");
            assertFalse(_covers(p, lltv, 5, 0), "refused, so the corridor does not cover the liquidation");
        }
    }

    /// @dev At the edge of the sizing rule: the fuzzer picks the LLTV, the bounds and one line, and the other line
    ///      sits near the widest value the spec's rule allows for them. The preflight refuses every set the rule
    ///      refuses, and refuses a set the rule takes only within `MAX_ROUNDING_GAP` of the edge.
    function testFuzz_requireNavSizing_edgeOfTheSizingRule(
        uint256 lltv,
        uint64 above,
        uint64 below,
        uint64 otherLine,
        bool solveCeiling,
        int256 offset
    ) public {
        lltv = bound(lltv, 0.3e18, 0.99e18);
        TrailingAnchorOracleBase.Parameters memory p;
        p.maxPriceAboveAnchor = uint64(bound(above, 1, 0.01e18));
        p.maxPriceBelowAnchor = uint64(bound(below, 1, 0.01e18));
        _setLine(p, !solveCeiling, bound(otherLine, 0, 0.05e18));
        uint256 edge = _widestLine(p, lltv, solveCeiling);
        vm.assume(edge >= 2 * MAX_ROUNDING_GAP && edge <= WAD - 10);
        offset = bound(offset, -2 * int256(MAX_ROUNDING_GAP), int256(MAX_ROUNDING_GAP));
        _setLine(p, solveCeiling, uint256(int256(edge) + offset));
        bool holds = TrailingAnchorOracleModel.sized(p, lltv);
        assertEq(holds, offset <= 0, "the rule holds up to the edge");

        try harness.requireNavSizing(p, lltv) {
            assertTrue(holds, "taken where the rule fails");
        } catch (bytes memory revertData) {
            assertEq(bytes4(revertData), OraclePreflight.NavCorridorTooWide.selector, "refused by the rule");
            if (holds) {
                assertLe(uint256(-offset), MAX_ROUNDING_GAP, "refused further inside the edge than the rounding");
            }
        }
    }

    /// @dev A ceiling 9 wei inside the edge of the rule at a 43.16% LLTV: the rule takes it, and the preflight's
    ///      rounding refuses it.
    function test_requireNavSizing_ceilingNineWeiInsideTheEdgeIsWithinTheRounding() public {
        testFuzz_requireNavSizing_edgeOfTheSizingRule(
            431558710300315627, 1881934947331682, 7062787411673335, 24141113695334605, true, -9
        );
    }

    // ---
    // HELPERS
    // ---

    /// @dev `NavCorridorTooWide` for `p` at `lltv`.
    function _expectRefused(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv) internal {
        vm.expectPartialRevert(OraclePreflight.NavCorridorTooWide.selector);
        harness.requireNavSizing(p, lltv);
    }

    /// @dev Checks that `p`'s largest `maxAnchorAboveBase` at `lltv` is about `expected`, that the preflight
    ///      takes it, and that it refuses one wei more and names the largest.
    function _assertAboveBaseEdge(
        TrailingAnchorOracleBase.Parameters memory p,
        uint256 lltv,
        uint256 expected,
        string memory label
    ) internal {
        uint256 largest = _largestAboveBase(p, lltv);
        assertApproxEqAbs(largest, expected, 0.00005e18, label);
        p.maxAnchorAboveBase = uint64(largest);
        harness.requireNavSizing(p, lltv);
        p.maxAnchorAboveBase = uint64(largest + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                OraclePreflight.NavCorridorTooWide.selector, p.maxAnchorBelowBase, largest + 1, lltv, largest
            )
        );
        harness.requireNavSizing(p, lltv);
    }

    /// @dev The widest `maxAnchorAboveBase` the sizing rule allows, from the spec's formula: the highest price the
    ///      oracle returns, the ceiling × (1 + maxPriceAboveAnchor), times LLTV × LIF must stay under the lowest, the
    ///      floor × (1 − maxPriceBelowAnchor), with LIF rounded down as the core rounds it, and every other step
    ///      rounded against the corridor.
    function _largestAboveBase(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 room = (WAD - p.maxAnchorBelowBase) * (WAD - p.maxPriceBelowAnchor) / WAD;
        uint256 needed = _neededAtTheBasePrice(p, lltv);
        return room < needed ? 0 : room * WAD / needed - WAD;
    }

    /// @dev The widest `maxAnchorBelowBase` the sizing rule allows for `p`'s `maxAnchorAboveBase`, from the
    ///      same formula.
    function _largestBelowBase(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 needed = _ceilDiv(_neededAtTheBasePrice(p, lltv) * (WAD + p.maxAnchorAboveBase), WAD);
        return WAD - _ceilDiv(needed * WAD, WAD - p.maxPriceBelowAnchor);
    }

    /// @dev What the rule needs with the ceiling on the base price: LLTV × LIF × (1 + maxPriceAboveAnchor),
    ///      with LIF rounded down as the core rounds it, and each other step rounded up.
    function _neededAtTheBasePrice(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 lif = TrailingAnchorOracleModel.liquidationIncentive(lltv);
        return _ceilDiv(_ceilDiv(lltv * lif, WAD) * (WAD + p.maxPriceAboveAnchor), WAD);
    }

    /// @dev The sizing rule in whole numbers: (1 − below base)(1 − below anchor) ≥ LLTV × LIF × (1 + above
    ///      base)(1 + above anchor), with LIF = 10 / (7 + 3 × LLTV), or 1.15 where that is higher, and both sides
    ///      multiplied through. `slackFor` wei of a whole price are added to the left side and `slackAgainst` taken
    ///      from it.
    function _covers(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv, uint256 slackAgainst, uint256 slackFor)
        internal
        pure
        returns (bool)
    {
        uint256 room = (WAD - p.maxAnchorBelowBase) * (WAD - p.maxPriceBelowAnchor);
        uint256 reach = (WAD + p.maxAnchorAboveBase) * (WAD + p.maxPriceAboveAnchor);
        room = room + slackFor * WAD - slackAgainst * WAD;
        if (10 * WAD * 100 > 115 * (7 * WAD + 3 * lltv)) return room * 100 * WAD >= 115 * lltv * reach;
        return room * (7 * WAD + 3 * lltv) >= 10 * lltv * reach;
    }

    /// @dev The widest value of the ceiling, or of the floor, under a whole price for which the spec's rule holds with
    ///      the rest of `p`, by bisection on the model. Zero when the rule fails even with that line at zero.
    function _widestLine(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv, bool ceiling)
        internal
        pure
        returns (uint256 widest)
    {
        uint256 refused = WAD;
        while (refused - widest > 1) {
            uint256 middle = (widest + refused) / 2;
            _setLine(p, ceiling, middle);
            if (TrailingAnchorOracleModel.sized(p, lltv)) widest = middle;
            else refused = middle;
        }
    }

    function _setLine(TrailingAnchorOracleBase.Parameters memory p, bool ceiling, uint256 value) internal pure {
        if (ceiling) p.maxAnchorAboveBase = uint64(value);
        else p.maxAnchorBelowBase = uint64(value);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
