// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ProtocolAddresses} from "../../DeploymentTypes.sol";

// Generated from deployed/mainnet; regenerate instead of editing addresses.
abstract contract Protocol {
    function _protocolAddresses() internal pure returns (ProtocolAddresses memory p) {
        p.chainId = 1;
        p.core = 0x026a770badc7126c7252Ef8d407E5b9C56147491;
        p.factory = 0xBe1C1eaBda3eD8a93D3CE3246cf4EeF8111c76C7;
        p.ownerFacade = 0x85378a1073E8f338e11A97E090E47e2F0FdD3D5a;
        p.irmRouter = 0x81B7cC9523B30429110282d90db2fa90ff443d91;
        p.adaptiveCurveIrm = 0xf6f1565F4fD3d29E6bDAb86764A50BCde381422f;
        p.irmConfigFactory = 0xE7ce129Eb67970C4d71e1456ad50f84B43C35496;
        p.dashboard = 0xC3C241bC213EF3ba16234A7c689999209cE515D7;
        p.circuitBreaker = 0xd0A81A130a303237d338A0b5835edcB011Ab3afd;
        p.resealManager = 0x7914b5a1539b97Bd0bbd155757F25FD79A522d24;
        p.agent = 0x3e40D73EB977Dc6a537aF587D48316feE66E9C8c;
        p.executor = 0xFE5986E06210aC1eCC1aDCafc0cc7f8D63B3F977;
    }
}
