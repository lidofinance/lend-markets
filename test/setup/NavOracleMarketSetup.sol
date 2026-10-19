// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {NavOracleBase} from "../../src/oracle/NavOracleBase.sol";
import {UsdyOracle} from "../../src/oracle/UsdyOracle.sol";
import {NavOracleCheckParams} from "../../src/types/NavOracleTypes.sol";

import {LidoLendSetup} from "./LidoLendSetup.sol";
import {MockERC20, MockNavOracle, MockUsdFeed} from "./Mocks.sol";
import {NavOracleModel, NavOracleState} from "./NavOracleModel.sol";
import {Market} from "./Types.sol";

/// @notice A fresh stack with one USDC/USDY-shaped market (6-decimal loan, 18-decimal collateral, 98% LLTV) priced by a
///         real `UsdyOracle` over a mock NAV getter and a mock USD feed, for the scenarios that need the core around
///         the oracle.
/// @dev `PRICE_SCALE` is 1e6 here, so a source price is a NAV times 1e6 and moves in steps of 1e6.
abstract contract NavOracleMarketSetup is LidoLendSetup {
    using NavOracleModel for NavOracleState;

    /// @dev 2025-09-24 12:00 UTC, the first day of the recorded series.
    uint256 internal constant START = 1_758_715_200;
    /// @dev USDY's NAV on that day.
    uint256 internal constant INITIAL_NAV = 1.1069161e18;
    uint256 internal constant PRICE_SCALE = 1e6;
    uint256 internal constant LLTV = 0.98e18;

    MockERC20 internal usdc;
    MockERC20 internal usdy;
    MockNavOracle internal nav;
    MockUsdFeed internal feed;
    UsdyOracle internal navOracle;
    address internal configurator;

    NavOracleCheckParams internal navParams;

    /// @dev Deploys the stack with the oracle initialized from `INITIAL_NAV` under `params`.
    function _deployNavMarket(NavOracleCheckParams memory params) internal returns (Market storage) {
        vm.warp(START);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdy = new MockERC20("Ondo USD Yield", "USDY", 18);
        nav = new MockNavOracle();
        feed = new MockUsdFeed();
        nav.setPrice(INITIAL_NAV);
        navParams = params;
        configurator = _actor("configurator");
        DeployConfig memory cfg = _defaultConfig(address(usdc), address(usdy), address(nav));
        cfg.lltv = LLTV;
        return _deployProtocol(cfg);
    }

    function _deployOracle(address, address admin) internal override returns (address oracle) {
        address impl = address(new UsdyOracle(address(nav), address(usdc), address(usdy), address(feed)));
        oracle = _behindProxy(impl, admin, abi.encodeCall(NavOracleBase.initialize, (admin, navParams)));
        navOracle = UsdyOracle(oracle);
        bytes32 configRole = navOracle.CONFIG_ROLE();
        vm.prank(admin);
        navOracle.grantRole(configRole, configurator);
    }

    function _state() internal view returns (NavOracleState memory) {
        return NavOracleModel.read(navOracle);
    }

    /// @dev Sets the source to the NAV that prices at `sourcePrice`, rounded up to the price scale, and returns the
    ///      source price that results.
    function _setSource(uint256 sourcePrice) internal returns (uint256) {
        uint256 navValue = Math.ceilDiv(sourcePrice, PRICE_SCALE);
        nav.setPrice(navValue);
        return navValue * PRICE_SCALE;
    }

    /// @dev Puts the source `factor` (WAD) of the current expected price.
    function _setSourceAtPath(uint256 factor) internal returns (uint256) {
        return _setSource(Math.mulDiv(_state().expectedPrice(block.timestamp), factor, NavOracleModel.WAD));
    }

    function _source() internal view returns (uint256) {
        return nav.navPrice() * PRICE_SCALE;
    }

    /// @dev The keeper's routine: `moveReferencePrice()` when the specification allows it, then `checkpoint()` when it
    ///      allows it. Returns what ran.
    function _keeper() internal returns (bool moved, bool checkpointed) {
        if (_moveAllowed()) {
            navOracle.moveReferencePrice();
            moved = true;
        }
        if (_checkpointAllowed()) {
            navOracle.checkpoint();
            checkpointed = true;
        }
    }

    function _moveAllowed() internal view returns (bool) {
        NavOracleState memory s = _state();
        uint256 source = _source();
        uint256 expected = s.expectedPrice(block.timestamp);
        return block.timestamp - s.referencePriceSetAt >= s.params.referenceInterval
            && s.inBand(source, block.timestamp)
            && source >= Math.mulDiv(expected, NavOracleModel.WAD - s.params.growthTolerance, NavOracleModel.WAD)
            && source >= s.floor(block.timestamp) && source <= s.upperBound(block.timestamp);
    }

    function _checkpointAllowed() internal view returns (bool) {
        NavOracleState memory s = _state();
        uint256 source = _source();
        return block.timestamp - s.checkpointAt >= s.params.fallInterval && s.inBand(source, block.timestamp)
            && source >= s.floor(block.timestamp);
    }

    /// @dev The exact revert of a band breach at the current source and time.
    function _bandError() internal view returns (bytes memory) {
        NavOracleState memory s = _state();
        return abi.encodeWithSelector(
            NavOracleBase.PriceOutOfBounds.selector, _source(), s.bandLow(block.timestamp), s.bandHigh(block.timestamp)
        );
    }
}
