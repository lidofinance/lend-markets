// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {DeploymentSnapshot, RecordedMarket} from "../DeploymentSnapshot.sol";
import {CircuitBreakerPlan} from "../DeploymentTypes.sol";

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
        d.circuitBreakerPlan = CircuitBreakerPlan({
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
        d.usdt = 0x64f1904d1b419c6889BDf3238e31A138E258eA68;
        d.usdy = 0xE22a71d42632aBAC08F44FCbd41221A8D8C56972;
        d.ondoOracle = 0xd6237FecDF9C1D9b023A5205C17549E3037EeEec;
        d.markets = new RecordedMarket[](3);
        d.markets[0] = _usdcUsdy();
        d.markets[1] = _usdtUsdy();
        d.markets[2] = _wethWsteth();
    }

    function _common() private pure returns (RecordedMarket memory m) {
        m.plan.guardianGroup = keccak256("shared");
        m.plan.market.lltv = 0.95e18;
        m.plan.market.guardianSignals = 0xF46eB3bf7783825B0ffb5f532C148A261Ec518a9;
        m.plan.market.activationConfig.minActivationDelay = 600;
        m.plan.market.activationConfig.maxActivationDelay = 7200;
        m.plan.market.activationConfig.maxGuardiansQuorumDelay = 129600;
        m.plan.market.activationConfig.delayPerStrike = 7200;
        m.plan.market.activationConfig.delayPerSuspect = 7200;
        m.plan.market.settlementConfig.sliceFloorBps = 100;
        m.plan.market.settlementConfig.ltvStepBps = 100;
        m.plan.committee.guardians = new address[](2);
        m.plan.committee.guardians[0] = 0xe9bFDBB915b734D10aA53B3838371F67a7704102;
        m.plan.committee.guardians[1] = 0xA6b2dbCCE7895347A62b4409d29bA7ce29A74655;
        m.plan.committee.quorum = 1;
        m.plan.committee.suspectWindow = 1 days;
        m.plan.curve.curveSteepness = 4e18;
        m.plan.curve.adjustmentSpeed = 1585489599188;
        m.plan.curve.minRateAtTarget = 31709791;
        m.contracts.guardianSignals = m.plan.market.guardianSignals;
    }

    function _wethWsteth() private pure returns (RecordedMarket memory m) {
        m = _common();
        m.role = "weth-wsteth";
        m.plan.name = "weth-wsteth";
        m.deployedBlock = 3641150;
        m.plan.market.loanToken = 0xE69a5c6dd88cA798b93c3C92fc50c51Fd5305eB4;
        m.plan.market.collateralToken = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
        m.plan.market.oracle = 0x2ae747342805632E4909c1230AC2124937074545;
        m.plan.market.supplyCap = 10_000 ether;
        m.plan.market.activationConfig.maxDelayInflow = 10_000 ether;
        m.plan.market.activationConfig.minActivationAmount = 10 ether;
        m.plan.market.activationConfig.minDepositAmount = 1 ether;
        m.plan.market.settlementConfig.sliceFloorAssets = 10 ether;
        m.plan.market.settlementConfig.fullCutBelowCollateral = 10 ether;
        m.plan.wrapper.name = "Lido wstETH/WETH Vault (hoodi)";
        m.plan.wrapper.symbol = "hoodiWSTETH-WETH";
        m.plan.curve.targetUtilization = 0.9e18;
        m.plan.curve.initialRateAtTarget = 713470319;
        m.plan.curve.maxRateAtTarget = 1585489597;
        m.plan.curve.maxBorrowRate = 1585489597;
        m.priceFeedKind = "wsteth-rate";
        m.priceFeed.wstEth = m.plan.market.collateralToken;
        m.contracts.id = Id.wrap(0x6a1c794db6232d046223fa809c14c59be90eedeb58ba10b9ee00d36e5b8f2f35);
        m.contracts.controller = 0x567032366c3Ccc84Af77647fffb3e7a00B8b3008;
        m.contracts.vault = 0xA5597eF950A9BAA5e00f7138E0fdC9F8bA5a43eE;
        m.contracts.irmConfig = 0xe01a9F7FB41B7557f00Db1B485bb51cda1A2a003;
        _params(m);
    }

    function _usdy() private pure returns (RecordedMarket memory m) {
        m = _common();
        m.plan.market.collateralToken = 0xE22a71d42632aBAC08F44FCbd41221A8D8C56972;
        m.plan.market.supplyCap = 25_000_000e6;
        m.plan.market.activationConfig.maxDelayInflow = 25_000_000 ether;
        m.plan.market.activationConfig.minActivationAmount = 25_000 ether;
        m.plan.market.activationConfig.minDepositAmount = 2500 ether;
        m.plan.market.settlementConfig.fullCutBelowCollateral = 25_000 ether;
        m.plan.curve.targetUtilization = 0.95e18;
        m.plan.curve.initialRateAtTarget = 1014713343;
        m.plan.curve.maxRateAtTarget = 2254918540;
        m.plan.curve.maxBorrowRate = 2254918540;
        m.priceFeedKind = "usdy-stable";
        m.priceFeed.usdySource = 0xd6237FecDF9C1D9b023A5205C17549E3037EeEec;
        m.priceFeed.collateralToken = m.plan.market.collateralToken;
        m.priceFeed.minPrice = 1e23;
        m.priceFeed.maxPrice = 1e26;
        m.contracts.irmConfig = 0x611401E778143B4f7BAA816F49FF5A4A35cf2101;
    }

    function _usdcUsdy() private pure returns (RecordedMarket memory m) {
        m = _usdy();
        m.role = "usdy-usdc";
        m.plan.name = "usdc-usdy";
        m.deployedBlock = 3641155;
        m.plan.market.loanToken = 0x97bb030B93faF4684eAC76bA0bf3be5ec7140F36;
        m.plan.market.oracle = 0x323b989e0056388A1207823bde6706cF3266A8B4;
        m.plan.wrapper.name = "Lido USDC/USDY Vault (hoodi)";
        m.plan.wrapper.symbol = "hoodiUSDC-USDY";
        m.priceFeed.loanToken = m.plan.market.loanToken;
        m.priceFeed.feed = 0x9d156F7F5ed1fEbDc4996CAA835CD964A10bd650;
        m.contracts.id = Id.wrap(0x30f38864da6d3e8527220bb16de06dd27e8f6eda8ca202a5dd334d9f1dbdd938);
        m.contracts.controller = 0x5BFA5af36D4f102650EE4FeCcB16bba3ccefE06e;
        m.contracts.vault = 0xCa29509BCF7D123009e1870F527437D79846F733;
        _params(m);
    }

    function _usdtUsdy() private pure returns (RecordedMarket memory m) {
        m = _usdy();
        m.role = "usdy-usdt";
        m.plan.name = "usdt-usdy";
        m.deployedBlock = 3641152;
        m.plan.market.loanToken = 0x64f1904d1b419c6889BDf3238e31A138E258eA68;
        m.plan.market.oracle = 0x53D670DD018A09Af8BfBAdD9817E383fDdf2fb27;
        m.plan.wrapper.name = "Lido USDT/USDY Vault (hoodi)";
        m.plan.wrapper.symbol = "hoodiUSDT-USDY";
        m.priceFeed.loanToken = m.plan.market.loanToken;
        m.priceFeed.feed = 0xeC3785b13b21c226D66B5bC2E82BB2f4226f715e;
        m.contracts.id = Id.wrap(0x860960f21264e07a94a3f77295952ac3be97bcbece961dd7e22e8da847ddc1f9);
        m.contracts.controller = 0xa868D126231D32CE6e930c59E9a279f13b0D2BFe;
        m.contracts.vault = 0x823D546AD911fbC6305588448eae9EC794E7AC29;
        _params(m);
    }

    function _params(RecordedMarket memory m) private pure {
        m.contracts.params = MarketParams({
            loanToken: m.plan.market.loanToken,
            collateralToken: m.plan.market.collateralToken,
            oracle: m.plan.market.oracle,
            irm: 0x88b624325385B3db69Db73A65DAdbaa15DE4406d,
            lltv: m.plan.market.lltv
        });
    }
}
