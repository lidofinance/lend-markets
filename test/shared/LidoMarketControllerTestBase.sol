// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {MarketAccessRegistry} from "../../src/controllers/MarketAccessRegistry.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {LidoMarketControllerHarness} from "./LidoMarketControllerHarness.sol";

/// @dev Shared fixture for harness-based LidoMarketController unit tests. Deploys the controller
///      behind an OssifiableProxy, wires the access registry and roles, and exposes common probes.
///      The lending-market address only needs non-empty code so `initialize` passes its NoCode
///      check; these unit tests drive the controller through internal hook handlers that do not
///      call back into the core.
abstract contract LidoMarketControllerTestBase is Test {
    LidoMarketControllerHarness internal harness;
    MarketAccessRegistry internal registry;

    Id internal constant MARKET = Id.wrap(bytes32(uint256(1)));
    address internal constant LENDING_MARKET = address(0xBEEF);

    uint64 internal constant MIN_DELAY = 10 minutes;
    uint64 internal constant MAX_DELAY = 2 hours;
    uint128 internal constant MIN_MATURATION_AMOUNT = 10e18;
    uint128 internal constant REF = 100e18;

    function setUp() public virtual {
        // Non-empty code so the controller's NoCode check passes during initialize. The body is a
        // bare revert.
        vm.etch(LENDING_MARKET, hex"60006000fd");
        // Hook handlers (supplyCollateral, borrow, ...) call back into the core via
        // `_currentPosition` / `_totalBorrowTotals` to sync the deleverage heap. Mock the two
        // surfaces with zeros — unit tests don't exercise heap state.
        vm.mockCall(
            LENDING_MARKET,
            abi.encodeWithSignature("position(bytes32,address)"),
            abi.encode(uint256(0), uint128(0), uint128(0))
        );
        vm.mockCall(
            LENDING_MARKET,
            abi.encodeWithSignature("market(bytes32)"),
            abi.encode(uint128(0), uint128(0), uint128(0), uint128(0), uint128(0), uint128(0))
        );

        registry = new MarketAccessRegistry(address(this));
        registry.grantRole(registry.OPERATOR_ROLE(), address(this));

        LidoMarketControllerHarness impl = new LidoMarketControllerHarness();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)",
            LENDING_MARKET,
            Id.unwrap(MARKET),
            address(registry),
            address(this)
        );
        OssifiableProxy proxy = new OssifiableProxy(address(impl), address(this), initData);
        harness = LidoMarketControllerHarness(payable(address(proxy)));

        harness.grantRole(harness.CONFIGURATOR_ROLE(), address(this));
        harness.grantRole(harness.RISK_STEWARD_ROLE(), address(this));
        harness.grantRole(harness.PAUSER_ROLE(), address(this));
        harness.grantRole(harness.UNPAUSER_ROLE(), address(this));

        vm.warp(1_700_000_000);
    }

    function _config() internal view returns (IMarketController.MarketConfig memory) {
        return harness.defaultMarketConfig();
    }

    /// @dev Enable the leaky-bucket delay: load REF maps to maxDelay, accumulator drains fully over
    ///      the maxDelay window (decay = cap / MAX_DELAY).
    function _enableLeakyBucket() internal {
        IMarketController.MarketConfig memory cfg = _config();
        cfg.minMaturationAmount = MIN_MATURATION_AMOUNT;
        cfg.maxDelayMaturationLoad = REF;
        cfg.maturationLoadCap = REF; // minimal cap (== reference): shortest tail
        cfg.maturationLoadDecayPerSecond = uint128(REF / MAX_DELAY);
        harness.setMarketConfig(MARKET, cfg);
    }

    function _supplyCollateral(address user, uint256 amount) internal {
        harness.exposed_handleSupplyCollateral(MARKET, user, user, amount);
    }

    function _maturedOf(address user) internal view returns (uint256) {
        return uint256(harness.collateralState(MARKET, user).maturedCollateral);
    }

    function _maturingOf(address user) internal view returns (uint256) {
        return uint256(harness.collateralState(MARKET, user).maturingCollateral);
    }
}
