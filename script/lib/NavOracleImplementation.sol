// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";

import {NavOracleConfig, OracleConfigFile} from "./OracleConfigFile.sol";

/// @notice Builds the NAV oracle implementation a config describes. The deployment and the preflight both build through
///         here, so the preflight's codehash comparison compares the same constructor call.
library NavOracleImplementation {
    function deploy(NavOracleConfig memory cfg) internal returns (address) {
        if (OracleConfigFile.isKind(cfg.kind, OracleConfigFile.KIND_NAV_USDY)) {
            return address(new UsdyNavOracle(cfg.source, cfg.loanToken, cfg.collateralToken));
        }
        if (OracleConfigFile.isKind(cfg.kind, OracleConfigFile.KIND_NAV_CENTRIFUGE)) {
            return address(
                new CentrifugeNavOracle(cfg.source, cfg.poolId, cfg.shareClassId, cfg.loanToken, cfg.collateralToken)
            );
        }
        revert OracleConfigFile.UnknownOracleKind(cfg.kind);
    }
}
