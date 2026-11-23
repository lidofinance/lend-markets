// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {
    ProtocolAddresses,
    MarketParameters,
    MarketDeploymentResult,
    DeploymentSnapshot,
    RecordedMarket,
    TrailingAnchorPriceFeedSpec
} from "../../script/deployment/DeploymentTypes.sol";
import {TrailingAnchorPriceFeed} from "../../script/deployment/TrailingAnchorPriceFeed.sol";

import {AcceptanceBase} from "../acceptance/AcceptanceBase.t.sol";
import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";
import {TrailingAnchorMarketFixture, TrailingAnchorMarketHarness} from "../setup/TrailingAnchorMarketFixture.sol";

/// @notice The acceptance suite's checks on a market over a trailing anchor oracle, run locally: the market that the
///         recipe deploys and the record that its artifact would hold, in place of a fork and a recorded run.
contract AcceptanceNavOracleTest is AcceptanceBase {
    MockOndoPriceGetter internal getter;
    address internal other = makeAddr("other");

    /// @dev Binds the acceptance context to a market that the recipe deploys over a fresh local protocol. The logs
    ///      are recorded from the start, so the instant-activation scan sees every grant.
    function setUp() public override {
        vm.warp(1_760_000_000);
        vm.recordLogs();
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 usdy = new MockERC20("Ondo US Dollar Yield", "USDY", 18);
        getter = new MockOndoPriceGetter();
        getter.setCurrentPrice(1.1e18);
        TrailingAnchorPriceFeedSpec memory spec =
            TrailingAnchorMarketFixture.usdySpec(address(getter), address(usdc), address(usdy));
        TrailingAnchorMarketHarness harness = new TrailingAnchorMarketHarness(spec);
        ProtocolAddresses memory p = harness.deployProtocol(
            TrailingAnchorMarketFixture.protocolParameters(
                makeAddr("agent"), makeAddr("executor"), makeAddr("resealManager")
            )
        );
        MarketParameters memory parameters =
            TrailingAnchorMarketFixture.marketParameters(address(usdc), address(usdy), makeAddr("guardian"));
        MarketDeploymentResult memory result = harness.deployTrailingAnchorMarket(p, parameters, address(harness));
        parameters.market.oracle = result.params.oracle;
        parameters.market.guardianSignals = result.guardianSignals;

        DeploymentSnapshot memory d;
        d.protocol = p;
        d.markets = new RecordedMarket[](1);
        d.markets[0].parameters = parameters;
        d.markets[0].contracts = result;
        d.markets[0].priceFeedKind = TrailingAnchorPriceFeed.kindName(spec.kind);
        d.markets[0].priceFeed.trailingAnchor = spec;
        _bindTypedDeployment(d, 0, address(0), false, address(0));
    }

    function test_assertOracle_takesTheRecipesOracle() external {
        _assertOracle();
    }

    function test_assertRoleHolderCompleteness_takesTheRecipesMarket() external {
        _assertRoleHolderCompleteness();
    }

    /// @dev A record whose kind names the other adapter is refused.
    function testRevert_assertOracle_kindNameMismatch() external {
        priceFeedKind = "centrifuge-nav";
        vm.expectRevert(bytes("price feed kind: centrifuge-nav != usdy-nav"));
        this.assertOracle();
    }

    /// @dev A record that sets a second kind is refused.
    function testRevert_assertOracle_ambiguousRecord() external {
        expectedPriceFeed.usdySource = address(getter);
        vm.expectRevert(bytes("unknown or ambiguous oracle config: 2 != 1"));
        this.assertOracle();
    }

    /// @dev A record over another source builds another implementation, refused by its codehash.
    function testRevert_assertOracle_recordOverAnotherSource() external {
        MockOndoPriceGetter otherGetter = new MockOndoPriceGetter();
        expectedPriceFeed.trailingAnchor.source = address(otherGetter);
        bytes32 actual = IOssifiableProxy(oracle).proxy__getImplementation().codehash;
        bytes32 expected = address(new UsdyNavOracle(address(otherGetter), loanToken, collateralToken)).codehash;
        vm.expectRevert(
            bytes(
                string.concat(
                    "trailing anchor oracle implementation: ", vm.toString(actual), " != ", vm.toString(expected)
                )
            )
        );
        this.assertOracle();
    }

    /// @dev A record whose spec names another loan token of the same decimals builds the same implementation, so the
    ///      token comparison is what refuses it.
    function testRevert_assertOracle_recordForOtherTokens() external {
        address token = address(new MockERC20("Tether USD", "USDT", 6));
        expectedPriceFeed.trailingAnchor.loanToken = token;
        vm.expectRevert(
            bytes(
                string.concat(
                    "oracle loan token != market loan token: ", vm.toString(token), " != ", vm.toString(loanToken)
                )
            )
        );
        this.assertOracle();
    }

    /// @dev A second manager, granted after the deployment, is refused with the deployment's own error.
    function testRevert_assertOracle_extraManager() external {
        bytes32 managerRole = TrailingAnchorOracleBase(oracle).MANAGER_ROLE();
        vm.prank(agent);
        TrailingAnchorOracleBase(oracle).grantRole(managerRole, other);
        vm.expectRevert(
            abi.encodeWithSelector(TrailingAnchorPriceFeed.RoleHolderCountMismatch.selector, managerRole, 1, 2)
        );
        this.assertOracle();
    }

    /// @dev A market at a higher LLTV than the oracle's floor and ceiling fit is refused.
    function testRevert_assertOracle_corridorTooWideForTheMarketLltv() external {
        lltv = 0.982e18;
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorPriceFeed.CorridorTooWide.selector, 0.01e18, 0.002e18, 0.982e18, 1_199_345_337_514_542
            )
        );
        this.assertOracle();
    }

    /// @dev The role audit counts the oracle's holders too: a second price acceptor is refused.
    function testRevert_assertRoleHolderCompleteness_extraPriceAcceptor() external {
        bytes32 acceptorRole = TrailingAnchorOracleBase(oracle).PRICE_ACCEPTOR_ROLE();
        vm.prank(agent);
        TrailingAnchorOracleBase(oracle).grantRole(acceptorRole, other);
        vm.expectRevert(bytes("unexpected enumerable role-holder count: 2 != 1"));
        this.assertRoleHolderCompleteness();
    }

    function assertOracle() external {
        _assertOracle();
    }

    function assertRoleHolderCompleteness() external {
        _assertRoleHolderCompleteness();
    }
}
