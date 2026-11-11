// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ExitBookAddresses} from "../DeploymentTypes.sol";

abstract contract ExitBooks {
    function _exitBooks() internal pure returns (ExitBookAddresses memory books) {
        books.chainId = 560048;
        books.morpho = 0xE626f019B04930fd0992A524FbE162695E99644D;
        books.erc4626 = 0xc0DB4417ee3F4510fa60eabFEfC0227e5a1CF127;
    }
}
