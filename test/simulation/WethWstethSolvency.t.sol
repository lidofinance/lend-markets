// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {WAD} from "@lido-lend/src/libraries/MathLib.sol";

import {Random} from "./Random.sol";
import {SolvencySimulation} from "./SolvencySimulation.sol";

/// @notice Solvency simulation on an 18/18 market priced like the WETH/wstETH oracle, which reports Lido's accounting
///         rate. The price grows with the staking yield, about 3% a year, and one step in a hundred instead falls by up
///         to 0.1%, as a negative rebase would. No position goes underwater, so the run must see no bad debt. It covers
///         a healthy market with an 18-decimal loan token at the prices the real market sees.
contract WethWstethSolvencySimulation is SolvencySimulation {
    using Random for Random.Context;

    function _loanDecimals() internal pure override returns (uint8) {
        return 18;
    }

    /// @dev 1.15 to 1.25 WETH per wstETH.
    function _priceBand() internal pure override returns (uint256, uint256) {
        return (1.15e36, 1.25e36);
    }

    /// @dev A rise of up to 100 parts per million, 50 on average, which compounds to about 3% over a year's 600 steps.
    function _stepPrice(uint256 current) internal override returns (uint256) {
        if (random.chance(100)) return current * (1e6 - random.between(1, 1000)) / 1e6;
        return current * (1e6 + random.between(0, 100)) / 1e6;
    }

    function _crashFactor() internal pure override returns (uint256) {
        return WAD;
    }

    function _assertPriceModelConsequences() internal view override {
        assertEq(count[Action.LiquidateBadDebt], 0, "weth/wsteth: a write-off on a steady price");
        assertEq(g.badDebt, 0, "weth/wsteth: bad debt on a steady price");
        assertEq(g.badDebtGate, 0, "weth/wsteth: the bad-debt gate fired on a steady price");
    }
}
