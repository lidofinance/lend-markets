// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {DeployMarketBase} from "./DeployMarketBase.s.sol";

/// @notice The base of a market script over a trailing anchor oracle: its adapter behind a proxy that the Agent
///         administers, seeded by the proxy's initializer and then held by the Agent alone.
abstract contract DeployTrailingAnchorMarketBase is DeployMarketBase {
    /// @notice A new oracle over the adapter `implementation`, with the launch `parameters` and a seed price that the
    ///         source must give within [`seedMinPrice`, `seedMaxPrice`]. The deployer, its first admin, grants each
    ///         role to the Agent and renounces its own.
    function _deployTrailingAnchorOracle(
        address implementation,
        TrailingAnchorOracleBase.Parameters memory parameters,
        uint256 seedMinPrice,
        uint256 seedMaxPrice
    ) internal returns (address oracle) {
        oracle = _deployProxy(
            implementation,
            abi.encodeCall(TrailingAnchorOracleBase.initialize, (deployer, parameters, seedMinPrice, seedMaxPrice))
        );
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(oracle);
        nav.grantRole(nav.MANAGER_ROLE(), protocol.agent);
        nav.grantRole(nav.PRICE_ACCEPTOR_ROLE(), protocol.agent);
        nav.grantRole(nav.DEFAULT_ADMIN_ROLE(), protocol.agent);
        nav.renounceRole(nav.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
