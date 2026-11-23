// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {BundlerAddresses, BundlerParameters, DeployBundlerBase} from "../DeployBundlerBase.s.sol";

contract DeployBundlerHoodi is DeployBundlerBase {
    function getConfig() public pure override returns (BundlerParameters memory c) {
        c.weth = 0xE69a5c6dd88cA798b93c3C92fc50c51Fd5305eB4; // Hoodi WETH
        c.wstEth = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4; // Hoodi wstETH
    }

    /// @dev The Bundler3 is shared with an earlier deployment; the adapters are the ones over this protocol's core.
    function getDeployment() internal pure override returns (BundlerAddresses memory d) {
        d.bundler = 0x4bF26080218F3F6B369Def91754c85ef7bb48e41;
        d.generalAdapter = 0xc38648Cb6488C444809354Fa3ce4f1B66F015C5B;
        d.vaultAdapter = 0x57b125DB2A901A1031D52a1C8Be8Eb9c2EC79a0C;
    }
}
