// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {BundlerAddresses, BundlerParameters, DeployBundlerBase} from "../DeployBundlerBase.s.sol";

contract DeployBundlerMainnet is DeployBundlerBase {
    function getConfig() public pure override returns (BundlerParameters memory c) {
        c.weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH9
        c.wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0; // Lido wstETH
    }

    function getDeployment() internal pure override returns (BundlerAddresses memory d) {
        d.bundler = 0x0056b888E90a1b783311351B54B782dE5de61e87;
        d.generalAdapter = 0x0C6151F0205A6Edf143b42C4f7B4E97a8f099260;
        d.vaultAdapter = 0xb1A64663B5390Ecf1a582df7e19d0a6753d1B84A;
    }
}
