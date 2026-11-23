// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {DeployExitBooksBase} from "../DeployExitBooksBase.s.sol";
import {ExitBookAddresses, ExitBooksConfig} from "../../lib/ProtocolDeployer.sol";

contract DeployExitBooksHoodi is DeployExitBooksBase {
    function getConfig() public pure override returns (ExitBooksConfig memory c) {
        c.pauser = 0xe65b86bB03Bd1B11BF39C6d87060c7A52236988D; // Risk Steward Committee Safe
        c.maxRequestLifetime = 90 days;
    }

    function getDeployment() internal pure override returns (ExitBookAddresses memory d) {
        d.morpho = 0xE626f019B04930fd0992A524FbE162695E99644D;
        d.erc4626 = 0xc0DB4417ee3F4510fa60eabFEfC0227e5a1CF127;
    }
}
