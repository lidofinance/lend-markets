// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ExitBookAddresses} from "../../DeploymentTypes.sol";

// Generated from deployed/mainnet; regenerate instead of editing addresses.
abstract contract ExitBooks {
    function _exitBooks() internal pure returns (ExitBookAddresses memory books) {
        books.chainId = 1;
        books.morpho = 0xAd28EFa8f2ef56a68b0Eb6836f4aE1d2D6459Ecd;
        books.erc4626 = 0x0d2580e4c9b20507eDFAeFC7777d760F12Ad55D4;
    }
}
