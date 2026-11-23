// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {DeployCoreBase} from "../DeployCoreBase.s.sol";
import {CircuitBreakerParameters, CoreConfig, ProtocolAddresses} from "../../lib/ProtocolDeployer.sol";

contract DeployCoreHoodi is DeployCoreBase {
    function getConfig() public pure override returns (CoreConfig memory c) {
        c.chainId = 560048;
        c.admin = 0x0534aA41907c9631fae990960bCC72d75fA7cfeD; // Lido DAO Agent
        c.manager = 0x79a20FD0FA36453B2F45eAbab19bfef43575Ba9E; // Easy Track EVMScriptExecutor
        c.resealManager = 0x05172CbCDb7307228F781436b327679e4DAE166B; // Dual Governance ResealManager

        // The mainnet profile with short pauses, for testing.
        c.circuitBreaker = CircuitBreakerParameters({
            minPauseDuration: 1 minutes,
            maxPauseDuration: 60 days,
            minHeartbeatInterval: 30 days,
            maxHeartbeatInterval: 1095 days,
            initialPauseDuration: 5 minutes,
            initialHeartbeatInterval: 365 days
        });
    }

    function getDeployment() internal pure override returns (ProtocolAddresses memory d) {
        d.chainId = 560048;
        d.core = 0x78d3262E82A35d290507bCF9B4834735DdA6b854;
        d.factory = 0x1ba98E8Cb00dC00a00E41E10cc17692917aEe896;
        d.ownerFacade = 0x5B2BdE06288a5db7289C028Fd4C8C175B5E3985B;
        d.irmRouter = 0x88b624325385B3db69Db73A65DAdbaa15DE4406d;
        d.adaptiveCurveIrm = 0x781f04920A82504B5AE13E02678dFc696eCca892;
        d.irmConfigFactory = 0xcE80DA265F3b982a0B85192697c87df516c9555f;
        d.dashboard = 0xc249abf58AC31dDEB3C715d7B395119aeeF729d1;
        d.circuitBreaker = 0x3d7f98a7aDa46DB97C100f09746bf3A0Ff4BE192;
        d.resealManager = 0x05172CbCDb7307228F781436b327679e4DAE166B;
        d.agent = 0x0534aA41907c9631fae990960bCC72d75fA7cfeD;
        d.executor = 0x79a20FD0FA36453B2F45eAbab19bfef43575Ba9E;
    }
}
