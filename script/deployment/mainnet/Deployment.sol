// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Protocol} from "./Protocol.sol";
import {ExitBookPlan} from "./ExitBookPlan.sol";
import {ExitBookConfig} from "../ExitBookPlan.sol";
import {DeploymentSnapshot, RecordedMarket} from "../DeploymentSnapshot.sol";

library Deployment {
    function snapshot() internal pure returns (DeploymentSnapshot memory d) {
        d.protocol = Protocol.addresses();
        d.circuitBreakerPlan = Protocol.plan().circuitBreakerPlan;
        (, ExitBookConfig memory books) = ExitBookPlan.get();
        d.books.chainId = d.protocol.chainId;
        d.books.morpho = 0xAd28EFa8f2ef56a68b0Eb6836f4aE1d2D6459Ecd;
        d.books.erc4626 = 0x0d2580e4c9b20507eDFAeFC7777d760F12Ad55D4;
        d.bookPauser = books.pauser;
        d.bookLifetime = books.maxRequestLifetime;
        d.bundler = 0x0056b888E90a1b783311351B54B782dE5de61e87;
        d.generalAdapter = 0x0C6151F0205A6Edf143b42C4f7B4E97a8f099260;
        d.vaultAdapter = 0xb1A64663B5390Ecf1a582df7e19d0a6753d1B84A;
        d.weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        d.wstEth = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        d.stEth = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
        d.usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        d.usdy = 0x96F6eF951840721AdBF46Ac996b59E0235CB985C;
        d.ondoOracle = 0xA0219AA5B31e65Bc920B5b6DFb8EdF0988121De0;
        d.usdyBlocklist = 0xd8c8174691d936E2C80114EC449037b13421B0a8;
        d.markets = new RecordedMarket[](0);
    }
}
