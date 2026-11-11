// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Protocol as MainnetProtocol} from "./Protocol.sol";
import {ProtocolAddresses} from "../DeploymentTypes.sol";
import {ExitBookConfig} from "../ExitBookPlan.sol";

library ExitBookPlan {
    function get() internal pure returns (uint256 chainId, ExitBookConfig memory plan) {
        ProtocolAddresses memory p = MainnetProtocol.addresses();
        chainId = p.chainId;
        plan = ExitBookConfig({
            agent: p.agent,
            evmScriptExecutor: p.executor,
            pauser: 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E,
            core: p.core,
            maxRequestLifetime: 90 days
        });
    }
}
