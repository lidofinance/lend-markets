// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";

import {
    TrailingAnchorOracleModel,
    TrailingAnchorOracleState,
    TrailingAnchorOracleUpdate
} from "./TrailingAnchorOracleModel.sol";
import {LidoLendSetup} from "./LidoLendSetup.sol";
import {MockERC20} from "./Mocks.sol";
import {MockOndoPriceGetter} from "./NavSourceMocks.sol";
import {Market} from "./Types.sol";

/// @notice A fresh stack with one USDC/USDY-shaped market (6-decimal loan, 18-decimal collateral, 98% LLTV) priced by a
///         real `UsdyNavOracle` over a mock Ondo getter, for the scenarios that need the core around the oracle.
/// @dev `PRICE_SCALE` is 1e6 here: the oracle's current price is the getter's 18-decimal NAV, and `price()` returns it
///      times 1e6.
abstract contract NavOracleMarketSetup is LidoLendSetup {
    using TrailingAnchorOracleModel for TrailingAnchorOracleState;

    /// @dev 2025-09-24 12:00 UTC.
    uint256 internal constant START = 1_758_715_200;
    /// @dev USDY's NAV on that day.
    uint256 internal constant INITIAL_NAV = 1.1069161e18;
    uint256 internal constant PRICE_SCALE = 1e6;
    uint256 internal constant LLTV = 0.98e18;

    MockERC20 internal usdc;
    MockERC20 internal usdy;
    MockOndoPriceGetter internal nav;
    UsdyNavOracle internal navOracle;
    /// @dev Stands in for the DAO Agent: the oracle's price acceptor and manager.
    address internal governance;

    /// @dev Deploys the stack with the oracle initialized from `INITIAL_NAV` on the working defaults.
    function _deployNavMarket() internal returns (Market storage) {
        vm.warp(START);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdy = new MockERC20("Ondo USD Yield", "USDY", 18);
        nav = new MockOndoPriceGetter();
        nav.setCurrentPrice(INITIAL_NAV);
        governance = _actor("governance");
        DeployConfig memory cfg = _defaultConfig(address(usdc), address(usdy), address(nav));
        cfg.lltv = LLTV;
        return _deployProtocol(cfg);
    }

    function _deployOracle(address, address admin) internal override returns (address oracle) {
        address impl = address(new UsdyNavOracle(address(nav), address(usdc), address(usdy)));
        oracle = _behindProxy(impl, admin, TrailingAnchorOracleModel.initializeCall(admin));
        navOracle = UsdyNavOracle(oracle);
        bytes32 priceAcceptorRole = navOracle.PRICE_ACCEPTOR_ROLE();
        bytes32 managerRole = navOracle.MANAGER_ROLE();
        vm.startPrank(admin);
        navOracle.grantRole(priceAcceptorRole, governance);
        navOracle.grantRole(managerRole, governance);
        vm.stopPrank();
    }

    function _state() internal view returns (TrailingAnchorOracleState memory) {
        return TrailingAnchorOracleModel.read(navOracle);
    }

    /// @dev Sets the getter to `currentPrice` and returns the oracle price it gives.
    function _setCurrentPrice(uint256 currentPrice) internal returns (uint256 oraclePrice) {
        nav.setCurrentPrice(currentPrice);
        return currentPrice * PRICE_SCALE;
    }

    /// @dev Puts the current price at `factor` (WAD) of the anchor price and returns the oracle price it gives.
    function _setCurrentPriceAtAnchor(uint256 factor) internal returns (uint256 oraclePrice) {
        return _setCurrentPrice(Math.mulDiv(_state().anchorPrice, factor, TrailingAnchorOracleModel.WAD));
    }

    /// @dev The oracle price the getter gives now.
    function _oraclePrice() internal view returns (uint256) {
        return nav.currentPrice() * PRICE_SCALE;
    }

    /// @dev The keeper's routine: `updateAnchor()`, checked against the model. Returns whether the anchor moved.
    function _keeper() internal returns (bool moved) {
        TrailingAnchorOracleUpdate memory u = _state().update(nav.currentPrice(), nav.isDown(), block.timestamp);
        TrailingAnchorOracleBase.UpdateOutcome outcome = navOracle.updateAnchor();
        assertEq(uint8(outcome), uint8(u.outcome), "the outcome the model predicts");
        assertEq(abi.encode(_state()), abi.encode(u.next), "the model's state after the keeper's update");
        return u.anchorSet;
    }

    /// @dev Runs the keeper at each pending anchor's window until the price sits within the bounds, or until a window
    ///      moves nothing because the anchor sits on the floor or the ceiling. Returns the number of re-anchors.
    function _keeperWalk() internal returns (uint256 reanchors) {
        _keeper();
        while (!_state().withinBounds(nav.currentPrice())) {
            vm.warp(_state().pendingAnchorAt + _state().reanchorDelay);
            if (!_keeper()) break;
            ++reanchors;
        }
    }

    /// @dev The exact revert of a current price outside the bounds at the current state.
    function _boundsError() internal view returns (bytes memory) {
        TrailingAnchorOracleState memory s = _state();
        return abi.encodeWithSelector(
            TrailingAnchorOracleBase.PriceOutOfBounds.selector, nav.currentPrice(), s.lowerBound(), s.upperBound()
        );
    }
}
