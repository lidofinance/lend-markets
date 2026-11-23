// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ProtocolAddresses} from "./ProtocolDeployer.sol";
import {DeployCoreMainnet} from "../deployment/mainnet/DeployCoreMainnet.s.sol";
import {EasyTrackMainnet} from "../deployment/mainnet/EasyTrackMainnet.sol";
import {DeployCoreHoodi} from "../deployment/hoodi/DeployCoreHoodi.s.sol";
import {EasyTrackHoodi} from "../deployment/hoodi/EasyTrackHoodi.sol";

/// @notice The records of the network in use: its protocol, as its core script gives it, and Easy Track's activation
///         factory over it.
library RecordedProtocol {
    error UnsupportedChain(uint256 chainId);

    /// @notice The protocol of the chain in use; a script outside a test refuses a chain without one.
    function current() internal returns (ProtocolAddresses memory) {
        if (block.chainid == 1) return new DeployCoreMainnet().getOrDeploy();
        if (block.chainid == 560048) return new DeployCoreHoodi().getOrDeploy();
        revert UnsupportedChain(block.chainid);
    }

    /// @notice Easy Track's `LidoLendActivateMarket` on the chain in use; zero until it is deployed. Easy Track runs
    ///         its motions only once a vote registers it.
    function activateMarketFactory() internal view returns (address) {
        if (block.chainid == 1) return EasyTrackMainnet.ACTIVATE_MARKET_FACTORY;
        if (block.chainid == 560048) return EasyTrackHoodi.ACTIVATE_MARKET_FACTORY;
        revert UnsupportedChain(block.chainid);
    }
}
