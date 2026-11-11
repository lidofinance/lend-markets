// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {DeploymentSnapshot, RecordedMarket, CircuitBreakerParameters} from "../../DeploymentTypes.sol";

library Deployment {
    function snapshot() internal pure returns (DeploymentSnapshot memory d) {
        d.protocol.chainId = 560048;
        d.protocol.core = 0x78d3262E82A35d290507bCF9B4834735DdA6b854;
        d.protocol.factory = 0x1ba98E8Cb00dC00a00E41E10cc17692917aEe896;
        d.protocol.ownerFacade = 0x5B2BdE06288a5db7289C028Fd4C8C175B5E3985B;
        d.protocol.irmRouter = 0x88b624325385B3db69Db73A65DAdbaa15DE4406d;
        d.protocol.adaptiveCurveIrm = 0x781f04920A82504B5AE13E02678dFc696eCca892;
        d.protocol.irmConfigFactory = 0xcE80DA265F3b982a0B85192697c87df516c9555f;
        d.protocol.dashboard = 0xc249abf58AC31dDEB3C715d7B395119aeeF729d1;
        d.protocol.circuitBreaker = 0x3d7f98a7aDa46DB97C100f09746bf3A0Ff4BE192;
        d.protocol.resealManager = 0x05172CbCDb7307228F781436b327679e4DAE166B;
        d.protocol.agent = 0x0534aA41907c9631fae990960bCC72d75fA7cfeD;
        d.protocol.executor = 0x79a20FD0FA36453B2F45eAbab19bfef43575Ba9E;
        d.circuitBreakerParameters = CircuitBreakerParameters({
            minPauseDuration: 60,
            maxPauseDuration: 60 days,
            minHeartbeatInterval: 30 days,
            maxHeartbeatInterval: 1095 days,
            initialPauseDuration: 300,
            initialHeartbeatInterval: 365 days
        });
        d.books.chainId = d.protocol.chainId;
        d.books.morpho = 0xE626f019B04930fd0992A524FbE162695E99644D;
        d.books.erc4626 = 0xc0DB4417ee3F4510fa60eabFEfC0227e5a1CF127;
        d.bookPauser = 0xe65b86bB03Bd1B11BF39C6d87060c7A52236988D;
        d.bookLifetime = 90 days;
        d.weth = 0xE69a5c6dd88cA798b93c3C92fc50c51Fd5305eB4;
        d.wstEth = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
        d.stEth = 0x3508A952176b3c15387C97BE809eaffB1982176a;
        d.markets = new RecordedMarket[](3);
        d.markets[0] = _usdcUsdy();
        d.markets[1] = _usdtUsdy();
        d.markets[2] = _wethWsteth();
    }

    function _common() private pure returns (RecordedMarket memory m) {
        m.parameters.guardianGroup = keccak256("shared");
        m.parameters.market.lltv = 0.95e18;
        m.parameters.market.guardianSignals = 0xF46eB3bf7783825B0ffb5f532C148A261Ec518a9;
        m.parameters.market.activationConfig.minActivationDelay = 600;
        m.parameters.market.activationConfig.maxActivationDelay = 7200;
        m.parameters.market.activationConfig.maxGuardiansQuorumDelay = 129600;
        m.parameters.market.activationConfig.delayPerStrike = 7200;
        m.parameters.market.activationConfig.delayPerSuspect = 7200;
        m.parameters.market.settlementConfig.sliceFloorBps = 100;
        m.parameters.market.settlementConfig.ltvStepBps = 100;
        m.parameters.committee.guardians = new address[](2);
        m.parameters.committee.guardians[0] = 0xe9bFDBB915b734D10aA53B3838371F67a7704102;
        m.parameters.committee.guardians[1] = 0xA6b2dbCCE7895347A62b4409d29bA7ce29A74655;
        m.parameters.committee.quorum = 1;
        m.parameters.committee.suspectWindow = 1 days;
        m.parameters.curve.curveSteepness = 4e18;
        m.parameters.curve.adjustmentSpeed = 1585489599188;
        m.parameters.curve.minRateAtTarget = 31709791;
        m.contracts.guardianSignals = m.parameters.market.guardianSignals;
    }

    function _wethWsteth() private pure returns (RecordedMarket memory m) {
        m = _common();
        m.role = "weth-wsteth";
        m.parameters.name = "weth-wsteth";
        m.deployedBlock = 3641150;
        m.parameters.market.loanToken = 0xE69a5c6dd88cA798b93c3C92fc50c51Fd5305eB4;
        m.parameters.market.collateralToken = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
        m.parameters.market.oracle = 0x2ae747342805632E4909c1230AC2124937074545;
        m.parameters.market.supplyCap = 10_000 ether;
        m.parameters.market.activationConfig.maxDelayInflow = 10_000 ether;
        m.parameters.market.activationConfig.minActivationAmount = 10 ether;
        m.parameters.market.activationConfig.minDepositAmount = 1 ether;
        m.parameters.market.settlementConfig.sliceFloorAssets = 10 ether;
        m.parameters.market.settlementConfig.fullCutBelowCollateral = 10 ether;
        m.parameters.wrapper.name = "Lido wstETH/WETH Vault (hoodi)";
        m.parameters.wrapper.symbol = "hoodiWSTETH-WETH";
        m.parameters.curve.targetUtilization = 0.9e18;
        m.parameters.curve.initialRateAtTarget = 713470319;
        m.parameters.curve.maxRateAtTarget = 1585489597;
        m.parameters.curve.maxBorrowRate = 1585489597;
        m.priceFeedKind = "wsteth-rate";
        m.priceFeed.wstEth = m.parameters.market.collateralToken;
        m.contracts.id = Id.wrap(0x6a1c794db6232d046223fa809c14c59be90eedeb58ba10b9ee00d36e5b8f2f35);
        m.contracts.controller = 0x567032366c3Ccc84Af77647fffb3e7a00B8b3008;
        m.contracts.vault = 0xA5597eF950A9BAA5e00f7138E0fdC9F8bA5a43eE;
        m.contracts.irmConfig = 0xe01a9F7FB41B7557f00Db1B485bb51cda1A2a003;
        _params(m);
    }

    function _usdy() private pure returns (RecordedMarket memory m) {
        m = _common();
        m.parameters.market.collateralToken = 0xE22a71d42632aBAC08F44FCbd41221A8D8C56972;
        m.parameters.market.supplyCap = 25_000_000e6;
        m.parameters.market.activationConfig.maxDelayInflow = 25_000_000 ether;
        m.parameters.market.activationConfig.minActivationAmount = 25_000 ether;
        m.parameters.market.activationConfig.minDepositAmount = 2500 ether;
        m.parameters.market.settlementConfig.fullCutBelowCollateral = 25_000 ether;
        m.parameters.curve.targetUtilization = 0.95e18;
        m.parameters.curve.initialRateAtTarget = 1014713343;
        m.parameters.curve.maxRateAtTarget = 2254918540;
        m.parameters.curve.maxBorrowRate = 2254918540;
        m.priceFeedKind = "usdy-stable";
        m.priceFeed.usdySource = 0xd6237FecDF9C1D9b023A5205C17549E3037EeEec;
        m.priceFeed.collateralToken = m.parameters.market.collateralToken;
        m.priceFeed.minPrice = 1e23;
        m.priceFeed.maxPrice = 1e26;
        m.contracts.irmConfig = 0x611401E778143B4f7BAA816F49FF5A4A35cf2101;
    }

    function _usdcUsdy() private pure returns (RecordedMarket memory m) {
        m = _usdy();
        m.role = "usdy-usdc";
        m.parameters.name = "usdc-usdy";
        m.deployedBlock = 3641155;
        m.parameters.market.loanToken = 0x97bb030B93faF4684eAC76bA0bf3be5ec7140F36;
        m.parameters.market.oracle = 0x323b989e0056388A1207823bde6706cF3266A8B4;
        m.parameters.wrapper.name = "Lido USDC/USDY Vault (hoodi)";
        m.parameters.wrapper.symbol = "hoodiUSDC-USDY";
        m.priceFeed.loanToken = m.parameters.market.loanToken;
        m.priceFeed.feed = 0x9d156F7F5ed1fEbDc4996CAA835CD964A10bd650;
        m.contracts.id = Id.wrap(0x30f38864da6d3e8527220bb16de06dd27e8f6eda8ca202a5dd334d9f1dbdd938);
        m.contracts.controller = 0x5BFA5af36D4f102650EE4FeCcB16bba3ccefE06e;
        m.contracts.vault = 0xCa29509BCF7D123009e1870F527437D79846F733;
        _params(m);
    }

    function _usdtUsdy() private pure returns (RecordedMarket memory m) {
        m = _usdy();
        m.role = "usdy-usdt";
        m.parameters.name = "usdt-usdy";
        m.deployedBlock = 3641152;
        m.parameters.market.loanToken = 0x64f1904d1b419c6889BDf3238e31A138E258eA68;
        m.parameters.market.oracle = 0x53D670DD018A09Af8BfBAdD9817E383fDdf2fb27;
        m.parameters.wrapper.name = "Lido USDT/USDY Vault (hoodi)";
        m.parameters.wrapper.symbol = "hoodiUSDT-USDY";
        m.priceFeed.loanToken = m.parameters.market.loanToken;
        m.priceFeed.feed = 0xeC3785b13b21c226D66B5bC2E82BB2f4226f715e;
        m.contracts.id = Id.wrap(0x860960f21264e07a94a3f77295952ac3be97bcbece961dd7e22e8da847ddc1f9);
        m.contracts.controller = 0xa868D126231D32CE6e930c59E9a279f13b0D2BFe;
        m.contracts.vault = 0x823D546AD911fbC6305588448eae9EC794E7AC29;
        _params(m);
    }

    function _params(RecordedMarket memory m) private pure {
        m.contracts.params = MarketParams({
            loanToken: m.parameters.market.loanToken,
            collateralToken: m.parameters.market.collateralToken,
            oracle: m.parameters.market.oracle,
            irm: 0x88b624325385B3db69Db73A65DAdbaa15DE4406d,
            lltv: m.parameters.market.lltv
        });
    }
}
