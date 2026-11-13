// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ExitBookAddresses} from "../../DeploymentTypes.sol";

library ExitBooks {
    address internal constant PAUSER = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E;
    uint256 internal constant MAX_REQUEST_LIFETIME = 90 days;

    function addresses() internal pure returns (ExitBookAddresses memory books) {
        books.chainId = 1;
        books.morpho = 0xAd28EFa8f2ef56a68b0Eb6836f4aE1d2D6459Ecd;
        books.erc4626 = 0x0d2580e4c9b20507eDFAeFC7777d760F12Ad55D4;
    }
}
