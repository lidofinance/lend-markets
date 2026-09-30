// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IrmKind} from "../setup/Types.sol";
import {UsdcUsdySolvencySimulation} from "./UsdcUsdySolvency.t.sol";

/// @notice The USDC/USDY solvency simulation on the adaptive-curve IRM, so the books are also checked under a rate
///         that follows utilization.
contract UsdcUsdyAdaptiveSolvencySimulation is UsdcUsdySolvencySimulation {
    function _irmKind() internal pure override returns (IrmKind) {
        return IrmKind.Adaptive;
    }
}
