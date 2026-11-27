// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CentrifugeNavOracle, ICentrifugeVault} from "../../src/oracle/CentrifugeNavOracle.sol";
import {ChainlinkOracle, IChainlinkFeed} from "../../src/oracle/ChainlinkOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {IOndoPriceGetter, UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @dev The kind of a Centrifuge vault; 0 is an asynchronous vault.
interface ICentrifugeVaultKind {
    function vaultKind() external view returns (uint8);
}

/// @dev The whitelist of a Chronicle router, which its admins edit.
interface IChronicleToll {
    function kiss(address who) external;
}

/// @notice Each NAV adapter over its live mainnet source. The unit suites use mocks of the sources, so only these
///         tests show that an adapter reads the source that a deployment gives it. They skip off mainnet. On a fork
///         whose clock runs ahead of the host's, every stamp is older by the lead, and the age limits grow by it.
contract NavOracleSourcesTest is ForkStack {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDY = 0x96F6eF951840721AdBF46Ac996b59E0235CB985C;
    address internal constant ONDO_USDY_ORACLE = 0xA0219AA5B31e65Bc920B5b6DFb8EdF0988121De0;

    address internal constant JTRSY = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
    address internal constant JAAA = 0x5a0F93D040De44e78F251b03c43be9CF317Dcf64;
    address internal constant DEJTRSY = 0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72;
    address internal constant DEJAAA = 0xAAA0008C8CF3A7Dca931adaF04336A5D808C82Cc;
    address internal constant JTRSY_USDC_VAULT = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;
    address internal constant JAAA_USDC_VAULT = 0x4880799eE5200fC58DA299e965df644fBf46780B;
    address internal constant DEJTRSY_USDC_VAULT = 0x18Ab9fC0B2e4Fef9e0e03c8EC63BA287a3238257;
    address internal constant DEJAAA_USDC_VAULT = 0x4865BC9701fBD1207A7B50e2aF442C7DAf154c9c;
    uint256 internal constant MAX_PRICE_AGE = 7 days;

    /// @dev Chainlink's NAVLink feeds, open to any caller.
    address internal constant CHAINLINK_JTRSY_NAV = 0x0C2e4Df738e99e8db80012f5bb2a303f3f48Ca74;
    address internal constant CHAINLINK_JAAA_NAV = 0x3BbccB2301759D2e4A5692bA72DAb4b75dC43B1a;
    /// @dev Chronicle's Chainlink-format adapters, each over its router, which answers only callers on its whitelist.
    address internal constant CHRONICLE_JTRSY = 0x22d9527ad4489D3C760A6380a3c4dD06114B09aE;
    address internal constant CHRONICLE_JAAA = 0x5A4BEEB8854442D69267C9a0a3A17BE60fDded04;
    address internal constant CHRONICLE_DEJTRSY = 0xb71e0Da4C6853718C04dAf58CA2ec22eB0fC4517;
    address internal constant CHRONICLE_DEJAAA = 0xEC41d6BA0fCdae0E41A521F510907BF7E4a87694;
    address internal constant CHRONICLE_JTRSY_ROUTER = 0xE980a33EFA3EDDaa689eCbdCE4B2278D4DB94471;
    address internal constant CHRONICLE_JAAA_ROUTER = 0x5D44916E0Db13EcD661b20Df4D645904E57589C8;
    address internal constant CHRONICLE_DEJTRSY_ROUTER = 0x2EdD943484f104760591E18184CaBD53cdfBfC21;
    address internal constant CHRONICLE_DEJAAA_ROUTER = 0x25563a9F085975CC6B86F66F3c010c24c12B3Ffa;
    /// @dev `Kisser_1`, an admin of each router, through which Chronicle whitelists a reader.
    address internal constant CHRONICLE_KISSER = 0x371A53bB4203Ad5D7e60e220BaC1876FF3Ddda5B;
    /// @dev Above both providers' heartbeats: 27 hours for Chainlink's NAV feeds, a day for Chronicle's.
    uint256 internal constant MAX_FEED_AGE = 2 days;
    /// @dev How far a feed may be from the vault's price: a feed may trail a new NAV for up to a day.
    uint256 internal constant MAX_FEED_DEVIATION = 0.005e18;

    /// @dev A NAV with 18 decimals is between these values. A source with other decimals is far outside them.
    uint256 internal constant MIN_NAV = 1e18;
    uint256 internal constant MAX_NAV = 2e18;

    address internal admin = makeAddr("admin");

    function setUp() public {
        _selectSourceFork();
        if (block.chainid != 1) vm.skip(true, "NavOracleSources: the sources are on mainnet");
    }

    /// @dev USDY has 18 decimals and USDC has 6, so the price is the Ondo value times 1e6.
    function test_usdyNavOracle_readsTheOndoOracle() public {
        assertEq(IERC20Metadata(USDY).decimals(), 18, "USDY decimals");
        assertEq(IERC20Metadata(USDC).decimals(), 6, "USDC decimals");
        uint256 nav = IOndoPriceGetter(ONDO_USDY_ORACLE).getPrice();
        assertGe(nav, MIN_NAV, "Ondo value below an 18-decimal NAV");
        assertLe(nav, MAX_NAV, "Ondo value above an 18-decimal NAV");

        _assertSeededFrom(address(new UsdyNavOracle(ONDO_USDY_ORACLE, USDC, USDY)), nav, 1e6);
    }

    /// @dev JTRSY and USDC have 6 decimals: the adapter converts 10^18 JTRSY units, and the price is that value times
    ///      1e18. The seed reverts if the vault's price stamp is older than `MAX_PRICE_AGE` plus the fork's clock lead.
    function test_centrifugeNavOracle_readsTheJtrsyVault() public {
        _assertVaultSeeds(JTRSY_USDC_VAULT, JTRSY, 6);
    }

    function test_centrifugeNavOracle_readsTheJaaaVault() public {
        _assertVaultSeeds(JAAA_USDC_VAULT, JAAA, 6);
    }

    /// @dev deJTRSY has 18 decimals: the adapter converts 10^30 deJTRSY units, and the price is that value times 1e6.
    function test_centrifugeNavOracle_readsTheDejtrsyVault() public {
        _assertVaultSeeds(DEJTRSY_USDC_VAULT, DEJTRSY, 18);
    }

    function test_centrifugeNavOracle_readsTheDejaaaVault() public {
        _assertVaultSeeds(DEJAAA_USDC_VAULT, DEJAAA, 18);
    }

    /// @dev The vault is the asynchronous USDC vault of `share`, its value of `10^(shareDecimals + 12)` share units is
    ///      an 18-decimal NAV, and an oracle over it seeds from that value.
    function _assertVaultSeeds(address vault, address share, uint8 shareDecimals) internal {
        assertEq(IERC20Metadata(share).decimals(), shareDecimals, "share decimals");
        assertEq(ICentrifugeVault(vault).share(), share, "share token of the vault");
        assertEq(ICentrifugeVault(vault).asset(), USDC, "asset of the vault");
        assertEq(ICentrifugeVaultKind(vault).vaultKind(), 0, "asynchronous vault");
        uint256 nav = ICentrifugeVault(vault).convertToAssets(10 ** (uint256(shareDecimals) + 12));
        assertGe(nav, MIN_NAV, "vault value below an 18-decimal NAV");
        assertLe(nav, MAX_NAV, "vault value above an 18-decimal NAV");

        _assertSeededFrom(
            address(new CentrifugeNavOracle(vault, MAX_PRICE_AGE + _forkClockLead(), USDC, share)),
            nav,
            10 ** (24 - uint256(shareDecimals))
        );
    }

    /// @dev Chainlink's 6-decimal NAV feeds of JTRSY and JAAA, which any caller reads: the anchor is the answer times
    ///      1e12, and the price of these 6-decimal shares in USDC scales by 1e18 more.
    function test_chainlinkOracle_readsTheChainlinkFeeds() public {
        _assertFeedSeeds(CHAINLINK_JTRSY_NAV, JTRSY, JTRSY_USDC_VAULT, address(this));
        _assertFeedSeeds(CHAINLINK_JAAA_NAV, JAAA, JAAA_USDC_VAULT, address(this));
    }

    /// @dev Chronicle's 18-decimal adapters of the four tokens. A deploy reverts with the router's `NotTolled` for the
    ///      proxy until Chronicle whitelists the proxy's address; the address is predicted before the deploy.
    function test_chainlinkOracle_readsTheChronicleAdapters() public {
        _assertChronicleSeeds(CHRONICLE_JTRSY, CHRONICLE_JTRSY_ROUTER, JTRSY, JTRSY_USDC_VAULT);
        _assertChronicleSeeds(CHRONICLE_JAAA, CHRONICLE_JAAA_ROUTER, JAAA, JAAA_USDC_VAULT);
        _assertChronicleSeeds(CHRONICLE_DEJTRSY, CHRONICLE_DEJTRSY_ROUTER, DEJTRSY, DEJTRSY_USDC_VAULT);
        _assertChronicleSeeds(CHRONICLE_DEJAAA, CHRONICLE_DEJAAA_ROUTER, DEJAAA, DEJAAA_USDC_VAULT);
    }

    function _assertChronicleSeeds(address feed, address router, address share, address vault) internal {
        ChainlinkOracle impl = new ChainlinkOracle(feed, MAX_FEED_AGE + _forkClockLead(), USDC, share);
        address proxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        try this.deployOracle(address(impl)) {
            revert("the proxy deployed before the whitelist");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSignature("NotTolled(address)", proxy), "NotTolled for the proxy");
        }

        proxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.prank(CHRONICLE_KISSER);
        IChronicleToll(router).kiss(proxy);
        _assertSeedsFromFeed(impl, share, vault, proxy);
    }

    /// @dev The oracle's proxy over `implementation`, deployed in a call of its own, so that a test can catch the
    ///      revert and go on: a revert expected of the deploy itself would end the test.
    function deployOracle(address implementation) external returns (address) {
        return address(new OssifiableProxy(implementation, admin, TrailingAnchorOracleModel.initializeCall(admin)));
    }

    /// @dev `reader` reads the feed for the expected value: a caller the feed answers.
    function _assertFeedSeeds(address feed, address share, address vault, address reader) internal {
        _assertSeedsFromFeed(
            new ChainlinkOracle(feed, MAX_FEED_AGE + _forkClockLead(), USDC, share), share, vault, reader
        );
    }

    /// @dev The oracle over `impl` seeds from the feed's answer at 18 decimals, and that price is within
    ///      `MAX_FEED_DEVIATION` of the share's Centrifuge vault, so the feed prices this token.
    function _assertSeedsFromFeed(ChainlinkOracle impl, address share, address vault, address reader) internal {
        uint8 shareDecimals = IERC20Metadata(share).decimals();
        assertEq(ICentrifugeVault(vault).share(), share, "the vault's share token");
        IChainlinkFeed feed = impl.FEED();
        vm.prank(reader);
        (, int256 answer,,,) = feed.latestRoundData();
        uint256 nav = uint256(answer) * impl.ANSWER_SCALE();
        assertGe(nav, MIN_NAV, "feed value below an 18-decimal NAV");
        assertLe(nav, MAX_NAV, "feed value above an 18-decimal NAV");
        uint256 vaultNav = ICentrifugeVault(vault).convertToAssets(10 ** shareDecimals) * 1e12;
        assertApproxEqRel(nav, vaultNav, MAX_FEED_DEVIATION, "feed value against the vault's price");

        _assertSeededFrom(address(impl), nav, TrailingAnchorOracleModel.priceScale(6, shareDecimals));
    }

    /// @dev An oracle that is initialized over `implementation` has the source value `nav` as its anchor, returns it
    ///      times `priceScale`, and an update finds the price inside the bounds.
    function _assertSeededFrom(address implementation, uint256 nav, uint256 priceScale) internal {
        TrailingAnchorOracleBase oracle = TrailingAnchorOracleBase(
            address(new OssifiableProxy(implementation, admin, TrailingAnchorOracleModel.initializeCall(admin)))
        );
        assertEq(oracle.anchorPrice(), nav, "anchor is the source value");
        assertEq(oracle.price(), nav * priceScale, "price is the source value at the market scale");
        assertEq(
            uint8(oracle.updateAnchor()), uint8(TrailingAnchorOracleBase.UpdateOutcome.WithinBounds), "update outcome"
        );
    }
}
