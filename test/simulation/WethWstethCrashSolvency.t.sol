// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Random} from "./Random.sol";
import {SolvencySimulation} from "./SolvencySimulation.sol";

/// @notice Solvency simulation on an 18/18 market shaped like WETH/wstETH. The price walks up or down by up to 2% a
///         step, and one step in a hundred instead cuts it to 25% to 95%. Once a run, a scheduled crash halves it
///         on a year, or cuts it to 30% on a month, which has far fewer moves. That crash fires once it would sink
///         a leveraged borrower well under water (`_crashReady`), and a keeper must then write the debt off.
contract WethWstethCrashSolvencySimulation is SolvencySimulation {
    using Random for Random.Context;

    function _loanDecimals() internal pure override returns (uint8) {
        return 18;
    }

    /// @dev 1.15 to 1.25 WETH per wstETH.
    function _priceBand() internal pure override returns (uint256, uint256) {
        return (1.15e36, 1.25e36);
    }

    function _stepPrice(uint256 current) internal override returns (uint256) {
        if (random.chance(100)) {
            g.crashes++;
            return current * random.between(25, 95) / 100;
        }
        uint256 delta = random.between(0, 200);
        return random.chance(5000) ? current * (10_000 + delta) / 10_000 : current * (10_000 - delta) / 10_000;
    }

    function _crashFactor() internal view override returns (uint256) {
        return longRun ? 0.5e18 : 0.3e18;
    }

    /// @dev Argues the crash floors: the schedule floor in `_assertCoverage` and the write-off here. Argued miss
    ///      odds: about 4.5e-6 a year, 1.1e-5 a month. A due crash waits for a lever, which a `Borrow` draw makes at
    ///      0.075 an iteration outside about 24 iterations the pause and freeze block (80 slots at 3.3 slots an
    ///      iteration); guardians never ban a leveraged borrower. After a walk crash undoes a lever, the crash comes
    ///      due unready with odds at most 0.027. The draw window ends 26 days before the run (`_scheduleEvents`):
    ///      147 iterations for the wait, 40 for the write-off, which `LiquidateBadDebt` at 0.30 an iteration misses
    ///      with odds 2.7e-6. A month cannot get under 1e-5: on top of the year's odds, both leveraged borrowers
    ///      stay unlevered for its first 178 iterations with odds 6.1e-6. Not argued: free liquidity capping a
    ///      lever, and root settlement cuts or a 19% price rise on a year undoing one.
    function _assertPriceModelConsequences() internal view override {
        assertGt(g.crashes, 0, "weth/wsteth: no crash");
        assertGt(count[Action.LiquidateBadDebt], 0, "weth/wsteth: no write-off");
        if (longRun) assertGt(count[Action.Liquidate], 0, "weth/wsteth: no solvent liquidation in a year");
    }
}
