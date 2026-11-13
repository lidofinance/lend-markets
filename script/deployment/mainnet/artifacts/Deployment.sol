// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ExitBooks} from "./ExitBooks.sol";
import {Bundler} from "./Bundler.sol";
import {Protocol} from "./Protocol.sol";
import {DeploymentSnapshot, RecordedMarket, BundlerAddresses, MarketParams, Id} from "../../DeploymentTypes.sol";

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
        d.markets = new RecordedMarket[](1);
        d.markets[0] = _wethWsteth();
    }

    function _wethWsteth() private pure returns (RecordedMarket memory m) {
        m.deployedBlock = 26406479;
        m.role = "weth-wsteth";
        m.parameters.name = "weth-wsteth";
        m.parameters.guardianGroup = keccak256("weth-wsteth");

        m.parameters.market.loanToken = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        m.parameters.market.collateralToken = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        m.parameters.market.oracle = 0x20a078F9940dC05C46De4153D1bCbd54D2b5b151;
        m.parameters.market.guardianSignals = 0xc8a8CBBF4c55980F85332fD8470DF0fC52d690aC;
        m.parameters.market.lltv = 0.98e18;
        m.parameters.market.supplyCap = 5_000 ether;

        m.parameters.market.activationConfig.minActivationDelay = 2 hours;
        m.parameters.market.activationConfig.maxActivationDelay = 8 hours;
        m.parameters.market.activationConfig.maxDelayInflow = 1_000 ether;
        m.parameters.market.activationConfig.minDepositAmount = 1 ether;
        m.parameters.market.activationConfig.activatingLockDuration = 0;
        m.parameters.market.activationConfig.minActivationAmount = 10 ether;
        m.parameters.market.activationConfig.maxGuardiansQuorumDelay = 48 hours;
        m.parameters.market.activationConfig.delayPerStrike = 12 hours;
        m.parameters.market.activationConfig.delayPerSuspect = 12 hours;

        m.parameters.market.settlementConfig.sliceFloorBps = 100;
        m.parameters.market.settlementConfig.sliceFloorAssets = 10 ether;
        m.parameters.market.settlementConfig.fullCutBelowCollateral = 10 ether;
        m.parameters.market.settlementConfig.ltvStepBps = 100;

        m.parameters.wrapper.name = "Lido Lend WETH (wstETH)";
        m.parameters.wrapper.symbol = "lendWETHwstETH";

        m.parameters.committee.guardians = new address[](1);
        m.parameters.committee.guardians[0] = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E;
        m.parameters.committee.quorum = 1;
        m.parameters.committee.suspectWindow = 1 days;

        m.parameters.curve.curveSteepness = 4e18;
        m.parameters.curve.adjustmentSpeed = 1_585_489_599_188;
        m.parameters.curve.targetUtilization = 0.9e18;
        m.parameters.curve.initialRateAtTarget = 637_898_291;
        m.parameters.curve.minRateAtTarget = 31_709_791;
        m.parameters.curve.maxRateAtTarget = 1_417_551_758;
        m.parameters.curve.maxBorrowRate = 1_417_551_758;

        m.priceFeedKind = "wsteth-rate";
        m.priceFeed.wstEth = m.parameters.market.collateralToken;

        m.contracts.id = Id.wrap(0xe4af8961b4e5a779b85d8c461be1007e4b78a7933976e0a5f23121682020de29);
        m.contracts.controller = 0xCF1B266d320CA9c0d4e13eF2C46465962F040e88;
        m.contracts.vault = 0xd8765FA896be3D30A49B9a7d95453E34E2c7A056;
        m.contracts.guardianSignals = m.parameters.market.guardianSignals;
        m.contracts.irmConfig = 0x6076f89f5Cd68c526C73eA1F730d9ce8f05301a6;
        m.contracts.params = MarketParams({
            loanToken: m.parameters.market.loanToken,
            collateralToken: m.parameters.market.collateralToken,
            oracle: m.parameters.market.oracle,
            irm: 0x81B7cC9523B30429110282d90db2fa90ff443d91,
            lltv: m.parameters.market.lltv
        });
    }
}
