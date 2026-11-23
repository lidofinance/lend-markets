// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {CentrifugeNavOracle, ICentrifugeSpoke} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {IOndoPriceGetter, UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {
    DeployMarketBase,
    MarketDeployConfig,
    MarketDeploymentResult
} from "../../script/deployment/DeployMarketBase.s.sol";
import {DeployUsdcDejaaaMainnet} from "../../script/deployment/mainnet/markets/DeployUsdcDejaaaMainnet.s.sol";
import {DeployUsdcDejtrsyMainnet} from "../../script/deployment/mainnet/markets/DeployUsdcDejtrsyMainnet.s.sol";
import {DeployUsdcJaaaMainnet} from "../../script/deployment/mainnet/markets/DeployUsdcJaaaMainnet.s.sol";
import {DeployUsdcJtrsyMainnet} from "../../script/deployment/mainnet/markets/DeployUsdcJtrsyMainnet.s.sol";
import {DeployUsdcUsdyMainnet} from "../../script/deployment/mainnet/markets/DeployUsdcUsdyMainnet.s.sol";

import {ForkStack} from "../fork/helpers/ForkStack.sol";
import {IOssifiableProxy} from "../setup/IOssifiableProxy.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {MockOndoPriceGetter} from "../setup/NavSourceMocks.sol";
import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";

/// @notice The mainnet market scripts over a trailing anchor oracle, on a mainnet fork over the deployed protocol and
///         the live tokens and sources. Each script deploys its market over a new oracle that the Agent holds alone,
///         seeded at the source's price; a market over a reused oracle requires the script's tokens, parameters and
///         roles.
contract TrailingAnchorMarketScriptsTest is ForkStack {
    uint256 internal constant WAD = 1e18;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDY = 0x96F6eF951840721AdBF46Ac996b59E0235CB985C;
    address internal constant DEJTRSY = 0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72;
    address internal constant JTRSY = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
    address internal constant JAAA = 0x5a0F93D040De44e78F251b03c43be9CF317Dcf64;
    address internal constant DEJAAA = 0xAAA0008C8CF3A7Dca931adaF04336A5D808C82Cc;
    address internal constant ONDO_USDY_ORACLE = 0xA0219AA5B31e65Bc920B5b6DFb8EdF0988121De0;
    address internal constant SPOKE = 0xEC3582fcDc34078a4B7a8c75a5a3AE46f48525aB;

    /// @dev The USDC/USDY script's seed range.
    uint256 internal constant USDY_SEED_MIN = 1.142e18;
    uint256 internal constant USDY_SEED_MAX = 1.166e18;

    address internal other = makeAddr("other");
    DeployMarketBase internal usdy;

    function setUp() public {
        _forkNetwork("mainnet");
        protocol = network.core.getOrDeploy();
        usdy = new DeployUsdcUsdyMainnet();
    }

    /// @dev USDC/USDY: the oracle is the USDY adapter on Ondo's getter behind an Agent-administered proxy, seeded at
    ///      the source's price with the working parameters, and the Agent holds each role alone. The market's
    ///      components read that oracle.
    function test_usdcUsdy_deploysTheUsdyNavOracleForTheAgent() external {
        uint256 source = IOndoPriceGetter(ONDO_USDY_ORACLE).getPrice();
        MarketDeploymentResult memory d = _deploy(usdy);
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(d.params.oracle);

        assertEq(IOssifiableProxy(address(nav)).proxy__getAdmin(), protocol.agent, "proxy admin");
        assertEq(address(nav).codehash, keccak256(type(OssifiableProxy).runtimeCode), "proxy code");
        assertEq(
            IOssifiableProxy(address(nav)).proxy__getImplementation().codehash,
            address(new UsdyNavOracle(ONDO_USDY_ORACLE, USDC, USDY)).codehash,
            "implementation"
        );
        _assertHandedToTheAgent(nav, address(usdy));
        assertEq(nav.anchorPrice(), source, "anchor");
        assertEq(nav.basePrice(), source, "base price");
        assertEq(nav.pendingAnchorAt(), 0, "no pending anchor");
        _assertParameters(nav);
        assertEq(nav.price(), source * 1e6, "price at the 6/18-decimal scale");

        assertEq(d.params.loanToken, USDC, "market loan token");
        assertEq(d.params.collateralToken, USDY, "market collateral token");
        assertEq(d.params.irm, protocol.irmRouter, "market IRM");
        assertEq(d.params.lltv, 0.98e18, "market LLTV");
        assertEq(address(ILidoLendERC4626(d.vault).controller()), d.controller, "vault controller");
    }

    /// @dev USDC/deJTRSY: the Centrifuge adapter on the Spoke, for the deJTRSY pool and share class.
    function test_usdcDejtrsy_deploysTheCentrifugeNavOracle() external {
        _assertCentrifuge(
            new DeployUsdcDejtrsyMainnet(), DEJTRSY, 281474976710660, 0x00010000000000040000000000000001, 1e6
        );
    }

    /// @dev USDC/JTRSY: the Centrifuge adapter on the Spoke, for the JTRSY pool and share class, at the 6/6-decimal
    ///      scale.
    function test_usdcJtrsy_deploysTheCentrifugeNavOracle() external {
        _assertCentrifuge(
            new DeployUsdcJtrsyMainnet(), JTRSY, 281474976710662, 0x00010000000000060000000000000001, 1e18
        );
    }

    /// @dev USDC/JAAA: the Centrifuge adapter on the Spoke, for the JAAA pool and share class, at the 6/6-decimal
    ///      scale.
    function test_usdcJaaa_deploysTheCentrifugeNavOracle() external {
        _assertCentrifuge(new DeployUsdcJaaaMainnet(), JAAA, 281474976710663, 0x00010000000000070000000000000001, 1e18);
    }

    /// @dev USDC/deJAAA: the Centrifuge adapter on the Spoke, for the deJAAA pool and share class.
    function test_usdcDejaaa_deploysTheCentrifugeNavOracle() external {
        _assertCentrifuge(
            new DeployUsdcDejaaaMainnet(), DEJAAA, 281474976710659, 0x00010000000000030000000000000001, 1e6
        );
    }

    /// @dev A source one wei outside the script's seed range, on either side, deploys nothing: an oracle seeded from
    ///      an unreviewed price would set its floor and ceiling around it.
    function testRevert_sourceOutsideTheSeedRange() external {
        MarketDeployConfig memory parameters = usdy.getDeployConfig();
        _setUsdyPrice(USDY_SEED_MIN - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.UnexpectedPrice.selector, USDY_SEED_MIN - 1, USDY_SEED_MIN, USDY_SEED_MAX
            )
        );
        usdy.deploy(protocol, parameters);
        _setUsdyPrice(USDY_SEED_MAX + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.UnexpectedPrice.selector, USDY_SEED_MAX + 1, USDY_SEED_MIN, USDY_SEED_MAX
            )
        );
        usdy.deploy(protocol, parameters);
    }

    /// @dev A market whose tokens are not the script's is refused before an oracle is deployed, and so is one over a
    ///      reused oracle: the codehash does not bind the tokens.
    function testRevert_marketTokensOtherThanTheScripts() external {
        address token = address(new MockERC20("Tether USD", "USDT", 6));
        MarketDeployConfig memory parameters = usdy.getDeployConfig();
        parameters.market.loanToken = token;
        vm.expectRevert(
            abi.encodeWithSelector(DeployMarketBase.IncompatibleDependency.selector, bytes32("loanToken"), USDC, token)
        );
        usdy.deploy(protocol, parameters);

        parameters = usdy.getDeployConfig();
        parameters.market.collateralToken = token;
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployMarketBase.IncompatibleDependency.selector, bytes32("collateralToken"), USDY, token
            )
        );
        usdy.deploy(protocol, parameters);

        parameters = _secondMarket(_deploy(usdy));
        parameters.market.loanToken = token;
        vm.expectRevert(
            abi.encodeWithSelector(DeployMarketBase.IncompatibleDependency.selector, bytes32("loanToken"), USDC, token)
        );
        usdy.deploy(protocol, parameters);
    }

    /// @dev A second market reuses the first market's oracle when it still has the script's parameters and roles.
    function test_secondMarket_reusesAMatchingOracle() external {
        MarketDeploymentResult memory first = _deploy(usdy);
        MarketDeploymentResult memory second = usdy.deploy(protocol, _secondMarket(first));
        assertEq(second.params.oracle, first.params.oracle, "same oracle");
        assertNotEq(second.controller, first.controller, "own controller");
    }

    /// @dev A reused oracle whose proxy admin is not the Agent is refused.
    function testRevert_reusedOracle_otherProxyAdmin() external {
        MarketDeploymentResult memory first = _deploy(usdy);
        vm.prank(protocol.agent);
        IOssifiableProxy(first.params.oracle).proxy__changeAdmin(other);
        MarketDeployConfig memory parameters = _secondMarket(first);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployMarketBase.IncompatibleDependency.selector, bytes32("priceFeed.admin"), protocol.agent, other
            )
        );
        usdy.deploy(protocol, parameters);
    }

    /// @dev An oracle over another source has another implementation, refused by its codehash.
    function testRevert_reusedOracle_otherSource() external {
        MockOndoPriceGetter otherGetter = new MockOndoPriceGetter();
        otherGetter.setCurrentPrice(IOndoPriceGetter(ONDO_USDY_ORACLE).getPrice());
        address implementation = address(new UsdyNavOracle(address(otherGetter), USDC, USDY));
        address oracle = address(
            new OssifiableProxy(
                implementation,
                protocol.agent,
                TrailingAnchorOracleModel.initializeCall(
                    protocol.agent, TrailingAnchorOracleModel.defaultParameters(), USDY_SEED_MIN, USDY_SEED_MAX
                )
            )
        );
        MarketDeployConfig memory parameters = usdy.getDeployConfig();
        parameters.market.oracle = oracle;
        vm.expectRevert(abi.encodeWithSelector(DeployMarketBase.PriceFeedCodeMismatch.selector, implementation));
        usdy.deploy(protocol, parameters);
    }

    /// @dev A source one wei above the reused oracle's upper bound fails the run with the oracle's own revert.
    function testRevert_reusedOracle_outsideItsBounds() external {
        uint256 anchor = IOndoPriceGetter(ONDO_USDY_ORACLE).getPrice();
        MarketDeploymentResult memory first = _deploy(usdy);
        uint256 lowerBound = Math.mulDiv(anchor, WAD - TrailingAnchorOracleModel.MAX_PRICE_BELOW_ANCHOR, WAD);
        uint256 upperBound = Math.mulDiv(anchor, WAD + TrailingAnchorOracleModel.MAX_PRICE_ABOVE_ANCHOR, WAD);
        _setUsdyPrice(upperBound + 1);
        MarketDeployConfig memory parameters = _secondMarket(first);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrailingAnchorOracleBase.PriceOutOfBounds.selector, upperBound + 1, lowerBound, upperBound
            )
        );
        usdy.deploy(protocol, parameters);
    }

    /// @dev A reused oracle whose pricing is suspended is refused.
    function testRevert_reusedOracle_suspended() external {
        MarketDeploymentResult memory first = _deploy(usdy);
        uint40 resumesAt = uint40(block.timestamp + 3 days);
        vm.prank(protocol.agent);
        TrailingAnchorOracleBase(first.params.oracle).setPricingResumesAt(resumesAt);
        MarketDeployConfig memory parameters = _secondMarket(first);
        vm.expectRevert(abi.encodeWithSelector(TrailingAnchorOracleBase.PricingSuspended.selector, resumesAt));
        usdy.deploy(protocol, parameters);
    }

    // ---
    // HELPERS
    // ---

    /// @dev The market of `script` with the script's own config.
    function _deploy(DeployMarketBase script) internal returns (MarketDeploymentResult memory) {
        return script.deploy(protocol, script.getDeployConfig());
    }

    /// @dev A USDC/USDY market at another LLTV over the first market's oracle and guardian registry.
    function _secondMarket(MarketDeploymentResult memory first) internal view returns (MarketDeployConfig memory p) {
        p = usdy.getDeployConfig();
        p.market.lltv = 0.96e18;
        p.market.oracle = first.params.oracle;
        p.market.guardianSignals = first.guardianSignals;
        p.wrapper.symbol = "lendUSDCUSDY2";
    }

    /// @dev Ondo's getter returns `price` from now on.
    function _setUsdyPrice(uint256 price) internal {
        vm.mockCall(ONDO_USDY_ORACLE, abi.encodeCall(IOndoPriceGetter.getPrice, ()), abi.encode(price));
    }

    function _assertCentrifuge(
        DeployMarketBase script,
        address share,
        uint64 poolId,
        bytes16 shareClassId,
        uint256 priceScale
    ) internal {
        uint256 source = ICentrifugeSpoke(SPOKE).pricePoolPerShare(poolId, shareClassId, false);
        MarketDeploymentResult memory d = _deploy(script);
        CentrifugeNavOracle nav = CentrifugeNavOracle(d.params.oracle);
        assertEq(address(nav.SPOKE()), SPOKE, "SPOKE");
        assertEq(nav.POOL_ID(), poolId, "POOL_ID");
        assertEq(nav.SHARE_CLASS_ID(), shareClassId, "SHARE_CLASS_ID");
        assertEq(nav.MAX_PRICE_AGE(), 7 days, "MAX_PRICE_AGE");
        assertEq(nav.PRICE_SCALE(), priceScale, "PRICE_SCALE");
        assertEq(nav.anchorPrice(), source, "anchor");
        _assertHandedToTheAgent(TrailingAnchorOracleBase(address(nav)), address(script));
        _assertParameters(TrailingAnchorOracleBase(address(nav)));
        assertEq(d.params.collateralToken, share, "market collateral token");
    }

    function _assertHandedToTheAgent(TrailingAnchorOracleBase nav, address deployer) internal view {
        bytes32[3] memory roles = [nav.DEFAULT_ADMIN_ROLE(), nav.MANAGER_ROLE(), nav.PRICE_ACCEPTOR_ROLE()];
        for (uint256 i; i < roles.length; ++i) {
            assertEq(nav.getRoleMemberCount(roles[i]), 1, "one holder");
            assertEq(nav.getRoleMember(roles[i], 0), protocol.agent, "the Agent holds the role");
            assertFalse(nav.hasRole(roles[i], deployer), "the deployer holds no role");
        }
    }

    /// @dev The working parameters.
    function _assertParameters(TrailingAnchorOracleBase nav) internal view {
        TrailingAnchorOracleBase.Parameters memory p = TrailingAnchorOracleModel.defaultParameters();
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
