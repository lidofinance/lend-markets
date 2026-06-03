// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {LidoMarketController} from "../../src/controllers/LidoMarketController.sol";
import {LidoMarketControllerTestBase} from "../shared/LidoMarketControllerTestBase.sol";

/// @dev `_validateConfig` rules: a positive delay range (no zero delay, which would disable the
///      activation gate), and load-scaling knobs that are coherent (decay rate and reference set
///      together; cap at least the reference).
contract LidoMarketControllerConfigValidationTest is LidoMarketControllerTestBase {
    function _enabledLoadCfg() internal view returns (IMarketController.MarketConfig memory cfg) {
        cfg = _config();
        cfg.maxDelayMaturationLoad = REF;
        cfg.maturationLoadCap = REF;
        cfg.maturationLoadDecayPerSecond = uint128(REF / MAX_DELAY);
    }

    function test_AcceptsDefaultDisabledConfig() public {
        harness.setMarketConfig(MARKET, _config()); // disabled, min delay 10m — valid
    }

    function test_AcceptsEnabledConfig() public {
        harness.setMarketConfig(MARKET, _enabledLoadCfg()); // valid enabled config
    }

    // Zero min delay would let collateral mature instantly, disabling the gate.
    function test_RejectsZeroMinDelay() public {
        IMarketController.MarketConfig memory cfg = _config();
        cfg.minMaturationDelay = 0;
        cfg.maxMaturationDelay = 0;
        vm.expectRevert(LidoMarketController.ConfigOutOfBounds.selector);
        harness.setMarketConfig(MARKET, cfg);
    }

    function test_RejectsZeroMinDelayEvenWithPositiveMax() public {
        IMarketController.MarketConfig memory cfg = _config();
        cfg.minMaturationDelay = 0; // maxMaturationDelay stays at the default 2h
        vm.expectRevert(LidoMarketController.ConfigOutOfBounds.selector);
        harness.setMarketConfig(MARKET, cfg);
    }

    function test_RejectsMinDelayAboveMax() public {
        IMarketController.MarketConfig memory cfg = _config();
        cfg.minMaturationDelay = MAX_DELAY + 1;
        vm.expectRevert(LidoMarketController.ConfigOutOfBounds.selector);
        harness.setMarketConfig(MARKET, cfg);
    }

    // Load-scaling knobs must be set together: reference without a decay rate is incoherent.
    function test_RejectsReferenceWithoutDecay() public {
        IMarketController.MarketConfig memory cfg = _config();
        cfg.maxDelayMaturationLoad = REF;
        cfg.maturationLoadDecayPerSecond = 0;
        vm.expectRevert(LidoMarketController.ConfigOutOfBounds.selector);
        harness.setMarketConfig(MARKET, cfg);
    }

    function test_RejectsDecayWithoutReference() public {
        IMarketController.MarketConfig memory cfg = _config();
        cfg.maxDelayMaturationLoad = 0;
        cfg.maturationLoadDecayPerSecond = 1;
        vm.expectRevert(LidoMarketController.ConfigOutOfBounds.selector);
        harness.setMarketConfig(MARKET, cfg);
    }

    // When enabled, the cap must be at least the reference so the load can saturate the delay.
    function test_RejectsCapBelowReference() public {
        IMarketController.MarketConfig memory cfg = _enabledLoadCfg();
        cfg.maturationLoadCap = REF - 1;
        vm.expectRevert(LidoMarketController.ConfigOutOfBounds.selector);
        harness.setMarketConfig(MARKET, cfg);
    }
}
