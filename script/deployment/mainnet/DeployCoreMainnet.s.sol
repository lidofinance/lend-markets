// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {DeployCoreBase} from "../DeployCoreBase.s.sol";
import {CircuitBreakerParameters, CoreConfig, ProtocolAddresses} from "../../lib/ProtocolDeployer.sol";

contract DeployCoreMainnet is DeployCoreBase {
    function getConfig() public pure override returns (CoreConfig memory c) {
        c.chainId = 1;
        c.admin = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c; // Lido DAO Agent
        c.manager = 0xFE5986E06210aC1eCC1aDCafc0cc7f8D63B3F977; // Easy Track EVMScriptExecutor
        c.resealManager = 0x7914b5a1539b97Bd0bbd155757F25FD79A522d24; // Dual Governance ResealManager

        // The upstream CircuitBreaker 1.0.0 mainnet profile.
        c.circuitBreaker = CircuitBreakerParameters({
            minPauseDuration: 5 days,
            maxPauseDuration: 60 days,
            minHeartbeatInterval: 30 days,
            maxHeartbeatInterval: 1095 days,
            initialPauseDuration: 21 days,
            initialHeartbeatInterval: 365 days
        });
    }

    function getDeployment() internal pure override returns (ProtocolAddresses memory d) {
        d.chainId = 1;
        d.core = 0x026a770badc7126c7252Ef8d407E5b9C56147491;
        d.factory = 0xBe1C1eaBda3eD8a93D3CE3246cf4EeF8111c76C7;
        d.ownerFacade = 0x85378a1073E8f338e11A97E090E47e2F0FdD3D5a;
        d.irmRouter = 0x81B7cC9523B30429110282d90db2fa90ff443d91;
        d.adaptiveCurveIrm = 0xf6f1565F4fD3d29E6bDAb86764A50BCde381422f;
        d.irmConfigFactory = 0xE7ce129Eb67970C4d71e1456ad50f84B43C35496;
        d.dashboard = 0xC3C241bC213EF3ba16234A7c689999209cE515D7;
        d.circuitBreaker = 0xd0A81A130a303237d338A0b5835edcB011Ab3afd;
        d.resealManager = 0x7914b5a1539b97Bd0bbd155757F25FD79A522d24;
        d.agent = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;
        d.executor = 0xFE5986E06210aC1eCC1aDCafc0cc7f8D63B3F977;
    }
}
