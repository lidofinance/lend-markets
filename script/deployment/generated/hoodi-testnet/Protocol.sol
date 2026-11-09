// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ProtocolAddresses} from "../../DeploymentTypes.sol";

// Generated from deployed/hoodi-testnet; regenerate instead of editing addresses.
abstract contract Protocol {
    function _protocolAddresses() internal pure returns (ProtocolAddresses memory p) {
        p.chainId = 560048;
        p.core = 0x78d3262E82A35d290507bCF9B4834735DdA6b854;
        p.factory = 0x1ba98E8Cb00dC00a00E41E10cc17692917aEe896;
        p.ownerFacade = 0x5B2BdE06288a5db7289C028Fd4C8C175B5E3985B;
        p.irmRouter = 0x88b624325385B3db69Db73A65DAdbaa15DE4406d;
        p.adaptiveCurveIrm = 0x781f04920A82504B5AE13E02678dFc696eCca892;
        p.irmConfigFactory = 0xcE80DA265F3b982a0B85192697c87df516c9555f;
        p.dashboard = 0xc249abf58AC31dDEB3C715d7B395119aeeF729d1;
        p.circuitBreaker = 0x3d7f98a7aDa46DB97C100f09746bf3A0Ff4BE192;
        p.resealManager = 0x05172CbCDb7307228F781436b327679e4DAE166B;
        p.agent = 0x0534aA41907c9631fae990960bCC72d75fA7cfeD;
        p.executor = 0x79a20FD0FA36453B2F45eAbab19bfef43575Ba9E;
    }
}
