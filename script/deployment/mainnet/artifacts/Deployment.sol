// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ExitBooks} from "./ExitBooks.sol";
import {Bundler} from "./Bundler.sol";
import {Protocol} from "./Protocol.sol";
import {DeploymentSnapshot, RecordedMarket, BundlerAddresses} from "../../DeploymentTypes.sol";

library Deployment {
    function snapshot() internal pure returns (DeploymentSnapshot memory d) {
        d.protocol = Protocol.addresses();
        d.circuitBreakerParameters = Protocol.circuitBreakerParameters();
        d.books = ExitBooks.addresses();
        d.bookPauser = ExitBooks.PAUSER;
        d.bookLifetime = ExitBooks.MAX_REQUEST_LIFETIME;
        BundlerAddresses memory bundler = Bundler.addresses();
        d.bundler = bundler.bundler;
        d.generalAdapter = bundler.generalAdapter;
        d.vaultAdapter = bundler.vaultAdapter;
        d.weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        d.wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        d.stEth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        d.markets = new RecordedMarket[](0);
    }
}
