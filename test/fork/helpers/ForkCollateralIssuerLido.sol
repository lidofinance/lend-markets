// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {IWstETH, WstEthRateOracle} from "../../../src/oracle/WstEthRateOracle.sol";
import {ForkCollateralIssuer} from "./ForkCollateralIssuer.sol";

/// @notice Lido: wstETH, priced by its stETH rate.
contract ForkCollateralIssuerLido is ForkCollateralIssuer {
    constructor(address oracle, address collateral)
        ForkCollateralIssuer(
            oracle,
            collateral,
            address(WstEthRateOracle(oracle).WSTETH()),
            abi.encodeCall(IWstETH.getStETHByWstETH, (ORACLE_PRICE_SCALE))
        )
    {}
}
