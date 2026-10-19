// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IrmKind} from "../setup/Types.sol";
import {WethWstethSolvencySimulation} from "./WethWstethSolvency.t.sol";

/// @notice The WETH/wstETH solvency simulation on the adaptive-curve IRM, so the books are also checked under a rate
///         that follows utilization.
contract WethWstethAdaptiveSolvencySimulation is WethWstethSolvencySimulation {
    function _irmKind() internal pure override returns (IrmKind) {
        return IrmKind.Adaptive;
    }
}
