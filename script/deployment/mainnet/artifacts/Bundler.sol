// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {BundlerAddresses} from "../../DeploymentTypes.sol";

library Bundler {
    function addresses() internal pure returns (BundlerAddresses memory b) {
        b.bundler = 0x0056b888E90a1b783311351B54B782dE5de61e87;
        b.generalAdapter = 0x0C6151F0205A6Edf143b42C4f7B4E97a8f099260;
        b.vaultAdapter = 0xb1A64663B5390Ecf1a582df7e19d0a6753d1B84A;
    }
}
