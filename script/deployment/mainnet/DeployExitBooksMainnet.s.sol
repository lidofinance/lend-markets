// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {DeployExitBooksBase} from "../DeployExitBooksBase.s.sol";
import {ExitBookAddresses, ExitBooksConfig} from "../../lib/ProtocolDeployer.sol";

contract DeployExitBooksMainnet is DeployExitBooksBase {
    function getConfig() public pure override returns (ExitBooksConfig memory c) {
        c.pauser = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E; // Risk Steward
        c.maxRequestLifetime = 90 days;
    }

    /// @dev The replacements of the pair that was deployed with the core.
    function getDeployment() internal pure override returns (ExitBookAddresses memory d) {
        d.morpho = 0xAd28EFa8f2ef56a68b0Eb6836f4aE1d2D6459Ecd;
        d.erc4626 = 0x0d2580e4c9b20507eDFAeFC7777d760F12Ad55D4;
    }
}
