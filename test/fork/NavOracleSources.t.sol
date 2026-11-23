// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {CentrifugeNavOracle, ICentrifugeSpoke} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {IOndoPriceGetter, UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {TrailingAnchorOracleModel} from "../setup/TrailingAnchorOracleModel.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @notice Each NAV adapter over its live mainnet source. The unit suites use mocks of the sources, so only these
///         tests show that an adapter reads the source that a deployment gives it.
contract NavOracleSourcesTest is ForkStack {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDY = 0x96F6eF951840721AdBF46Ac996b59E0235CB985C;
    address internal constant ONDO_USDY_ORACLE = 0xA0219AA5B31e65Bc920B5b6DFb8EdF0988121De0;

    address internal constant JTRSY = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
    address internal constant CENTRIFUGE_SPOKE = 0xEC3582fcDc34078a4B7a8c75a5a3AE46f48525aB;
    uint64 internal constant JTRSY_POOL_ID = 281474976710662;
    bytes16 internal constant JTRSY_SHARE_CLASS_ID = 0x00010000000000060000000000000001;
    uint256 internal constant MAX_PRICE_AGE = 7 days;

    /// @dev A NAV with 18 decimals is between these values. A source with other decimals is far outside them.
    uint256 internal constant MIN_NAV = 1e18;
    uint256 internal constant MAX_NAV = 2e18;

    address internal admin = makeAddr("admin");

    function setUp() public {
        _selectSourceFork();
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

    /// @dev JTRSY and USDC have 6 decimals, so the price is the Spoke value times 1e18. The seed reverts if the
    ///      Spoke's price is older than `MAX_PRICE_AGE`.
    function test_centrifugeNavOracle_readsTheSpoke() public {
        assertEq(IERC20Metadata(JTRSY).decimals(), 6, "JTRSY decimals");
        ICentrifugeSpoke spoke = ICentrifugeSpoke(CENTRIFUGE_SPOKE);
        assertEq(spoke.shareToken(JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID), JTRSY, "share token of the share class");
        uint256 nav = spoke.pricePoolPerShare(JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID, false);
        assertGe(nav, MIN_NAV, "Spoke value below an 18-decimal NAV");
        assertLe(nav, MAX_NAV, "Spoke value above an 18-decimal NAV");

        _assertSeededFrom(
            address(
                new CentrifugeNavOracle(
                    CENTRIFUGE_SPOKE, JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID, MAX_PRICE_AGE, USDC, JTRSY
                )
            ),
            nav,
            1e18
        );
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
