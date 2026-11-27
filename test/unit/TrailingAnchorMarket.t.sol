// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {
    ProtocolAddresses,
    MarketParameters,
    MarketDeploymentResult,
    TrailingAnchorKind,
    TrailingAnchorPriceFeedSpec
} from "../../script/deployment/DeploymentTypes.sol";
import {MarketDeployment} from "../../script/deployment/MarketDeployment.sol";
import {TrailingAnchorMarket} from "../../script/deployment/TrailingAnchorMarket.sol";
import {TrailingAnchorPriceFeed} from "../../script/deployment/TrailingAnchorPriceFeed.sol";

import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {MockCentrifugeVault, MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";
import {TrailingAnchorMarketFixture, TrailingAnchorMarketHarness} from "../setup/TrailingAnchorMarketFixture.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

/// @notice A market over a trailing anchor oracle, deployed by the recipe over a protocol that the protocol recipe
///         deploys on the local EVM: the handoff of a new oracle, the refusals before anything is deployed, and the
///         checks on a reused oracle.
contract TrailingAnchorMarketTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant SEED_PRICE = 1.1e18;

    address internal agent = makeAddr("agent");
    address internal other = makeAddr("other");
    MockERC20 internal usdc;
    MockERC20 internal usdy;
    MockOndoPriceGetter internal getter;
    TrailingAnchorPriceFeedSpec internal spec;
    TrailingAnchorMarketHarness internal harness;
    ProtocolAddresses internal protocol;

    function setUp() external {
        vm.warp(1_760_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdy = new MockERC20("Ondo US Dollar Yield", "USDY", 18);
        getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(SEED_PRICE);
        spec = TrailingAnchorMarketFixture.usdySpec(address(getter), address(usdc), address(usdy));
        harness = new TrailingAnchorMarketHarness(spec);
        protocol = harness.deployProtocol(
            TrailingAnchorMarketFixture.protocolParameters(agent, makeAddr("executor"), makeAddr("resealManager"))
        );
    }

    /// @dev The new oracle is the spec's adapter behind an Agent-administered proxy, seeded at the source's price
    ///      with the spec's parameters. The Agent holds each role alone and the deployer holds none. The market's
    ///      components read that oracle.
    function test_deployTrailingAnchorMarket_handsTheOracleToTheAgent() external {
        MarketDeploymentResult memory d = _deploy(_parameters());
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(d.params.oracle);

        assertEq(IOssifiableProxy(address(nav)).proxy__getAdmin(), agent, "proxy admin");
        assertEq(address(nav).codehash, keccak256(type(OssifiableProxy).runtimeCode), "proxy code");
        address implementation = IOssifiableProxy(address(nav)).proxy__getImplementation();
        assertEq(
            implementation.codehash,
            address(new UsdyNavOracle(address(getter), address(usdc), address(usdy))).codehash,
            "implementation"
        );
        bytes32[3] memory roles = [nav.DEFAULT_ADMIN_ROLE(), nav.MANAGER_ROLE(), nav.PRICE_ACCEPTOR_ROLE()];
        for (uint256 i; i < roles.length; ++i) {
            assertEq(nav.getRoleMemberCount(roles[i]), 1, "one holder");
            assertEq(nav.getRoleMember(roles[i], 0), agent, "the Agent holds the role");
            assertFalse(nav.hasRole(roles[i], address(harness)), "the deployer holds no role");
        }
        assertEq(nav.anchorPrice(), SEED_PRICE, "anchor");
        assertEq(nav.basePrice(), SEED_PRICE, "base price");
        assertEq(nav.pendingAnchorAt(), 0, "no pending anchor");
        _assertParameters(nav, spec.parameters);
        assertEq(nav.price(), SEED_PRICE * 1e6, "price at the 6/18-decimal scale");

        assertEq(d.params.loanToken, address(usdc), "market loan token");
        assertEq(d.params.collateralToken, address(usdy), "market collateral token");
        assertEq(d.params.irm, protocol.irmRouter, "market IRM");
        assertEq(d.params.lltv, TrailingAnchorMarketFixture.LLTV, "market LLTV");
        assertEq(address(ILidoLendERC4626(d.vault).controller()), d.controller, "vault controller");
        harness.reportTrailingAnchor(address(nav));
    }

    /// @dev A Centrifuge spec deploys the Centrifuge adapter, each of its fields in its own immutable.
    function test_deployTrailingAnchorMarket_deploysTheCentrifugeAdapter() external {
        MockERC20 share = new MockERC20("JTRSY", "JTRSY", 6);
        MockCentrifugeVault vault = new MockCentrifugeVault(address(share), spec.loanToken);
        vault.setCurrentPrice(SEED_PRICE);
        TrailingAnchorPriceFeedSpec memory s = spec;
        s.kind = TrailingAnchorKind.Centrifuge;
        s.source = address(vault);
        s.maxPriceAge = 3 days;
        s.collateralToken = address(share);
        TrailingAnchorMarketHarness centrifuge = new TrailingAnchorMarketHarness(s);
        MarketParameters memory parameters = _parameters();
        parameters.market.collateralToken = address(share);

        MarketDeploymentResult memory d =
            centrifuge.deployTrailingAnchorMarket(protocol, parameters, address(centrifuge));
        CentrifugeNavOracle nav = CentrifugeNavOracle(d.params.oracle);
        assertEq(address(nav.VAULT()), address(vault), "VAULT");
        assertEq(nav.MAX_PRICE_AGE(), 3 days, "MAX_PRICE_AGE");
        assertEq(nav.PRICE_SCALE(), 1e18, "PRICE_SCALE");
        assertEq(nav.anchorPrice(), SEED_PRICE, "anchor");
        assertEq(nav.getRoleMember(nav.MANAGER_ROLE(), 0), agent, "the Agent is the manager");
    }

    /// @dev A source one wei outside the seed range, on either side, deploys nothing: an oracle seeded from an
    ///      unreviewed price would set its floor and ceiling around it.
    function testRevert_deployTrailingAnchorMarket_seedOutsideRange() external {
        MarketParameters memory parameters = _parameters();
        getter.setCurrentPrice(1.09e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.UnexpectedPrice.selector, 1.09e18 - 1, 1.09e18, 1.11e18)
        );
        _deploy(parameters);
        getter.setCurrentPrice(1.11e18 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.UnexpectedPrice.selector, 1.11e18 + 1, 1.09e18, 1.11e18)
        );
        _deploy(parameters);
    }

    /// @dev A zero in any of the eight parameters or in the seed range refuses the recipe at construction: a field
    ///      that a market script leaves out reads as zero.
    function testRevert_constructor_zeroSpecValue() external {
        bytes32[10] memory fields = [
            bytes32("maxPriceAboveAnchor"),
            "maxPriceBelowAnchor",
            "maxAnchorContinuousRiseRate",
            "maxAnchorContinuousFallRate",
            "maxAnchorBelowBase",
            "maxAnchorAboveBase",
            "reanchorDelay",
            "reanchorWindow",
            "seedMinPrice",
            "seedMaxPrice"
        ];
        for (uint256 i; i < fields.length; ++i) {
            TrailingAnchorPriceFeedSpec memory s = spec;
            if (i == 0) s.parameters.maxPriceAboveAnchor = 0;
            else if (i == 1) s.parameters.maxPriceBelowAnchor = 0;
            else if (i == 2) s.parameters.maxAnchorContinuousRiseRate = 0;
            else if (i == 3) s.parameters.maxAnchorContinuousFallRate = 0;
            else if (i == 4) s.parameters.maxAnchorBelowBase = 0;
            else if (i == 5) s.parameters.maxAnchorAboveBase = 0;
            else if (i == 6) s.parameters.reanchorDelay = 0;
            else if (i == 7) s.parameters.reanchorWindow = 0;
            else if (i == 8) s.seedMinPrice = 0;
            else s.seedMaxPrice = 0;
            vm.expectRevert(abi.encodeWithSelector(TrailingAnchorMarket.ZeroSpecValue.selector, fields[i]));
            new TrailingAnchorMarketHarness(s);
        }
    }

    /// @dev The deployer renounces its admin role after the handoff, so a deployer that is the Agent is refused.
    function testRevert_deployTrailingAnchorMarket_deployerIsAgent() external {
        vm.expectRevert(TrailingAnchorMarket.DeployerIsAgent.selector);
        harness.deployTrailingAnchorMarket(protocol, _parameters(), agent);
    }

    /// @dev A market whose tokens are not the spec's is refused before an oracle is deployed.
    function testRevert_deployTrailingAnchorMarket_marketTokensAreNotTheSpecs() external {
        address token = address(new MockERC20("Tether USD", "USDT", 6));
        MarketParameters memory parameters = _parameters();
        parameters.market.loanToken = token;
        vm.expectRevert(
            abi.encodeWithSelector(MarketDeployment.IncompatibleDependency.selector, bytes32("loanToken"), usdc, token)
        );
        _deploy(parameters);
        parameters = _parameters();
        parameters.market.collateralToken = token;
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketDeployment.IncompatibleDependency.selector, bytes32("collateralToken"), usdy, token
            )
        );
        _deploy(parameters);
    }

    /// @dev The base deployment would put the oracle behind a proxy with no `initialize`, which anyone could then
    ///      call first. The recipe refuses it.
    function testRevert_deployMarket_refusesAnUninitializedOracle() external {
        vm.expectRevert(TrailingAnchorMarket.PriceFeedNotDeployed.selector);
        harness.deployMarket(protocol, _parameters());
    }

    /// @dev The working corridor does not fit a 98.2% market: the oracle is checked at the market's LLTV before the
    ///      factory deploys anything.
    function testRevert_deployTrailingAnchorMarket_corridorTooWideForTheMarketLltv() external {
        MarketParameters memory parameters = _parameters();
        parameters.market.lltv = 0.982e18;
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorPriceFeed.CorridorTooWide.selector, 0.01e18, 0.002e18, 0.982e18, 1_199_345_337_514_542
            )
        );
        _deploy(parameters);
    }

    /// @dev A second market reuses the first market's oracle when it still has the spec's parameters and roles.
    function test_deployTrailingAnchorMarket_reusesAMatchingOracle() external {
        MarketDeploymentResult memory first = _deploy(_parameters());
        MarketDeploymentResult memory second = _deploy(_secondMarket(first));
        assertEq(second.params.oracle, first.params.oracle, "same oracle");
        assertNotEq(second.controller, first.controller, "own controller");
    }

    /// @dev After `setParameters`, a reuse with the old spec is refused with the changed parameter named.
    function testRevert_deployTrailingAnchorMarket_reusedOracleHasOtherParameters() external {
        MarketDeploymentResult memory first = _deploy(_parameters());
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
        p.reanchorDelay = 7 hours;
        vm.prank(agent);
        TrailingAnchorOracleBase(first.params.oracle).setParameters(p);
        MarketParameters memory parameters = _secondMarket(first);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorPriceFeed.ParameterMismatch.selector, bytes32("reanchorDelay"), 6 hours, 7 hours
            )
        );
        _deploy(parameters);
    }

    /// @dev A second manager on the reused oracle is refused.
    function testRevert_deployTrailingAnchorMarket_reusedOracleHasAnExtraManager() external {
        MarketDeploymentResult memory first = _deploy(_parameters());
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(first.params.oracle);
        bytes32 managerRole = nav.MANAGER_ROLE();
        vm.prank(agent);
        nav.grantRole(managerRole, other);
        MarketParameters memory parameters = _secondMarket(first);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorPriceFeed.RoleHolderCountMismatch.selector, managerRole, 1, 2)
        );
        _deploy(parameters);
    }

    /// @dev A market over the reused oracle with another loan token of the same decimals is refused. The codehash does
    ///      not bind the tokens, so on the base deployment path the token check is the only guard.
    function testRevert_deployMarket_reusedOracleForOtherTokens() external {
        MarketDeploymentResult memory first = _deploy(_parameters());
        address token = address(new MockERC20("Tether USD", "USDT", 6));
        MarketParameters memory parameters = _secondMarket(first);
        parameters.market.loanToken = token;
        vm.expectRevert(
            abi.encodeWithSelector(MarketDeployment.IncompatibleDependency.selector, bytes32("loanToken"), usdc, token)
        );
        harness.deployMarket(protocol, parameters);
    }

    /// @dev A reused oracle whose proxy admin is not the Agent is refused.
    function testRevert_deployTrailingAnchorMarket_reusedOracleHasAnotherProxyAdmin() external {
        MarketDeploymentResult memory first = _deploy(_parameters());
        vm.prank(agent);
        IOssifiableProxy(first.params.oracle).proxy__changeAdmin(other);
        MarketParameters memory parameters = _secondMarket(first);
        vm.expectRevert(
            abi.encodeWithSelector(
                MarketDeployment.IncompatibleDependency.selector, bytes32("priceFeed.admin"), agent, other
            )
        );
        _deploy(parameters);
    }

    /// @dev An oracle over another source has another implementation, refused by its codehash.
    function testRevert_deployTrailingAnchorMarket_reusedOracleReadsAnotherSource() external {
        MockOndoPriceGetter otherGetter = new MockOndoPriceGetter();
        otherGetter.setCurrentPrice(SEED_PRICE);
        address implementation = address(new UsdyNavOracle(address(otherGetter), address(usdc), address(usdy)));
        address oracle = address(
            new OssifiableProxy(
                implementation,
                agent,
                TrailingAnchorOracleModel.initializeCall(agent, spec.parameters, spec.seedMinPrice, spec.seedMaxPrice)
            )
        );
        MarketParameters memory parameters = _parameters();
        parameters.market.oracle = oracle;
        vm.expectRevert(abi.encodeWithSelector(MarketDeployment.PriceFeedCodeMismatch.selector, implementation));
        _deploy(parameters);
    }

    /// @dev A source outside the bounds of the reused oracle fails the run with the oracle's own revert.
    function testRevert_deployTrailingAnchorMarket_reusedOracleIsOutsideItsBounds() external {
        MarketDeploymentResult memory first = _deploy(_parameters());
        getter.setCurrentPrice(1.2e18);
        MarketParameters memory parameters = _secondMarket(first);
        uint256 lowerBound = Math.mulDiv(SEED_PRICE, WAD - TrailingAnchorOracleModel.MAX_PRICE_BELOW_ANCHOR, WAD);
        uint256 upperBound = Math.mulDiv(SEED_PRICE, WAD + TrailingAnchorOracleModel.MAX_PRICE_ABOVE_ANCHOR, WAD);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorOracleBase.PriceOutOfBounds.selector, 1.2e18, lowerBound, upperBound)
        );
        _deploy(parameters);
    }

    /// @dev A reused oracle whose pricing is suspended is refused.
    function testRevert_deployTrailingAnchorMarket_reusedOracleIsSuspended() external {
        MarketDeploymentResult memory first = _deploy(_parameters());
        uint40 resumesAt = uint40(block.timestamp + 3 days);
        vm.prank(agent);
        TrailingAnchorOracleBase(first.params.oracle).setPricingResumesAt(resumesAt);
        MarketParameters memory parameters = _secondMarket(first);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.PricingSuspended.selector, resumesAt));
        _deploy(parameters);
    }

    // ---
    // HELPERS
    // ---

    function _deploy(MarketParameters memory parameters) internal returns (MarketDeploymentResult memory) {
        return harness.deployTrailingAnchorMarket(protocol, parameters, address(harness));
    }

    function _parameters() internal returns (MarketParameters memory) {
        return TrailingAnchorMarketFixture.marketParameters(address(usdc), address(usdy), makeAddr("guardian"));
    }

    /// @dev A market at another LLTV over the first market's oracle and guardian registry.
    function _secondMarket(MarketDeploymentResult memory first) internal returns (MarketParameters memory parameters) {
        parameters = _parameters();
        parameters.name = "usdc-usdy-2";
        parameters.market.lltv = 0.96e18;
        parameters.market.oracle = first.params.oracle;
        parameters.market.guardianSignals = first.guardianSignals;
        parameters.wrapper.symbol = "lendUSDCUSDY2";
    }

    function _assertParameters(TrailingAnchorOracleBase nav, TrailingAnchorOracleBase.Parameters memory p)
        internal
        view
    {
        assertEq(nav.maxPriceAboveAnchor(), p.maxPriceAboveAnchor, "maxPriceAboveAnchor");
        assertEq(nav.maxPriceBelowAnchor(), p.maxPriceBelowAnchor, "maxPriceBelowAnchor");
        assertEq(nav.maxAnchorContinuousRiseRate(), p.maxAnchorContinuousRiseRate, "maxAnchorContinuousRiseRate");
        assertEq(nav.maxAnchorContinuousFallRate(), p.maxAnchorContinuousFallRate, "maxAnchorContinuousFallRate");
        assertEq(nav.maxAnchorBelowBase(), p.maxAnchorBelowBase, "maxAnchorBelowBase");
        assertEq(nav.maxAnchorAboveBase(), p.maxAnchorAboveBase, "maxAnchorAboveBase");
        assertEq(nav.reanchorDelay(), p.reanchorDelay, "reanchorDelay");
        assertEq(nav.reanchorWindow(), p.reanchorWindow, "reanchorWindow");
    }
}
