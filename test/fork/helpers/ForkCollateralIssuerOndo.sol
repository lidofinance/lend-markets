// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IOndoPriceGetter, UsdyNavOracle} from "../../../src/oracle/UsdyNavOracle.sol";
import {IRWADynamicOracle, UsdyStableOracle} from "../../../src/oracle/UsdyStableOracle.sol";
import {ForkCollateralIssuer} from "./ForkCollateralIssuer.sol";

/// @notice Ondo: USDY, priced by its NAV, which both USDY oracles read.
contract ForkCollateralIssuerOndo is ForkCollateralIssuer {
    constructor(address oracle, address collateral)
        ForkCollateralIssuer(oracle, collateral, _usdyNav(oracle), abi.encodeCall(IOndoPriceGetter.getPrice, ()))
    {}

    /// @dev Ondo's USDY NAV getter behind `oracle`, either USDY oracle.
    function _usdyNav(address oracle) private view returns (address) {
        try UsdyStableOracle(oracle).USDY_ORACLE() returns (IRWADynamicOracle nav) {
            return address(nav);
        } catch {}
        return address(UsdyNavOracle(oracle).SOURCE());
    }
}
