// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {WethWstethMarket} from "../../script/deployment/mainnet/WethWstethMarket.sol";
import {Protocol as MainnetProtocol} from "../../script/deployment/mainnet/Protocol.sol";
import {ProtocolDeployment} from "../../script/deployment/ProtocolDeployment.sol";
import {
    ProtocolAddresses,
    ProtocolPlan,
    MarketPlan,
    MarketDeploymentResult,
    MarketActivation,
    ExitBookAddresses
} from "../../script/deployment/DeploymentTypes.sol";
import {ExitBookConfig} from "../../script/deployment/ExitBookPlan.sol";
import {
    PeripheryDeployment,
    BundlerPlan,
    BundlerAddresses,
    VaultV2Plan,
    VaultV2Addresses
} from "../../script/deployment/PeripheryDeployment.sol";
import {MarketPreparation} from "./MarketPreparation.sol";

import {DeploymentSnapshot, RecordedMarket} from "../../script/deployment/DeploymentSnapshot.sol";

contract ForkFixture is ProtocolDeployment, PeripheryDeployment, MarketPreparation, WethWstethMarket {
    function prepare() external returns (DeploymentSnapshot memory) {
        return _prepareFixture(true);
    }

    function prepareInert() external returns (DeploymentSnapshot memory) {
        return _prepareFixture(false);
    }

    /// @dev Recorded markets are authoritative; absent primary market uses the reviewed Solidity recipe.
    function prepareExisting(
        ProtocolAddresses memory p,
        ExitBookAddresses memory books,
        RecordedMarket[] memory recorded
    ) external returns (RecordedMarket[] memory markets) {
        require(p.chainId == 1, "ForkFixture: preparation recipe is mainnet-only");
        _checkProtocol(p);
        for (uint256 i; i < recorded.length; ++i) {
            require(
                recorded[i].plan.market.loanToken == WETH && recorded[i].plan.market.collateralToken == WSTETH,
                "ForkFixture: recorded market has no preparation recipe"
            );
            require(
                bytes(recorded[i].role).length != 0 && bytes(recorded[i].plan.name).length != 0,
                "Missing market identity"
            );
            for (uint256 j; j < i; ++j) {
                require(
                    keccak256(bytes(recorded[i].role)) != keccak256(bytes(recorded[j].role)), "Duplicate market role"
                );
                require(
                    keccak256(bytes(recorded[i].plan.name)) != keccak256(bytes(recorded[j].plan.name)),
                    "Duplicate market name"
                );
            }
        }
        RecordedMarket[] memory required = _requiredMarkets();
        bool[] memory present = new bool[](required.length);
        uint256 missing;
        for (uint256 i; i < required.length; ++i) {
            for (uint256 j; j < recorded.length; ++j) {
                if (keccak256(bytes(required[i].role)) == keccak256(bytes(recorded[j].role))) present[i] = true;
            }
            if (!present[i]) ++missing;
        }
        markets = new RecordedMarket[](recorded.length + missing);
        for (uint256 i; i < recorded.length; ++i) {
            markets[i] = recorded[i];
        }
        uint256 next = recorded.length;
        for (uint256 i; i < required.length; ++i) {
            if (!present[i]) markets[next++] = required[i];
        }
        address riskSteward = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E;
        MarketActivation memory activation = MarketActivation({
            pauser: 0x604B13eD638663AA0C1eEF0c3482e51f228BA2E1,
            steward: riskSteward,
            enableSettlement: true,
            exitBooks: books
        });
        for (uint256 i; i < markets.length; ++i) {
            if (markets[i].contracts.controller == address(0)) {
                for (uint256 j; j < i; ++j) {
                    if (markets[i].plan.market.oracle == address(0)) {
                        markets[i].plan.market.oracle = markets[j].contracts.params.oracle;
                    }
                    if (
                        markets[i].plan.market.guardianSignals == address(0)
                            && markets[i].plan.guardianGroup == markets[j].plan.guardianGroup
                            && keccak256(abi.encode(markets[i].plan.committee))
                                == keccak256(abi.encode(markets[j].plan.committee))
                    ) markets[i].plan.market.guardianSignals = markets[j].contracts.guardianSignals;
                }
            }
            markets[i].priceFeedKind = "wsteth-rate";
            markets[i].contracts = _prepareMarket(p, markets[i].plan, markets[i].contracts, activation);
        }
    }

    function _requiredMarkets() internal pure virtual returns (RecordedMarket[] memory markets) {
        markets = new RecordedMarket[](1);
        address[] memory guardians = new address[](1);
        guardians[0] = 0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E;
        markets[0].role = "weth-wsteth";
        markets[0].plan = _wethWstethPlan(guardians);
    }

    function _prepareFixture(bool activateMarkets) private returns (DeploymentSnapshot memory d) {
        ProtocolPlan memory protocolPlan = MainnetProtocol.plan();
        d.circuitBreakerPlan = protocolPlan.circuitBreakerPlan;
        d.bookLifetime = 365 days;
        d.weth = WETH;
        d.wstEth = WSTETH;
        d.stEth = STETH;
        d.protocol = _deployProtocol(protocolPlan, address(this));
        d.bookPauser = makeAddr("fork.exitBookPauser");
        d.books.chainId = block.chainid;
        (d.books.morpho, d.books.erc4626) = _deployExitBooks(
            ExitBookConfig({
                core: d.protocol.core,
                agent: d.protocol.agent,
                evmScriptExecutor: d.protocol.executor,
                pauser: d.bookPauser,
                maxRequestLifetime: 365 days
            }),
            address(this)
        );
        d.markets = new RecordedMarket[](2);
        address[] memory guardians = new address[](1);
        guardians[0] = d.protocol.agent;
        MarketActivation memory activation = MarketActivation({
            pauser: d.protocol.agent, steward: d.protocol.agent, enableSettlement: true, exitBooks: d.books
        });
        for (uint256 i; i < d.markets.length; ++i) {
            MarketPlan memory plan = _wethWstethPlan(guardians);
            plan.name = i == 0 ? "weth-wsteth" : "weth-wsteth-secondary";
            plan.market.lltv = i == 0 ? 0.945e18 : 0.94e18;
            // Fixture choices preserve the scenarios' liquidation/settlement and guardian timing boundaries.
            plan.market.activationConfig.maxGuardiansQuorumDelay = 0;
            plan.market.activationConfig.delayPerSuspect = 0;
            plan.market.settlementConfig.sliceFloorAssets = 0;
            plan.committee.suspectWindow = 0;
            plan.curve.initialRateAtTarget = 1_268_391_679;
            plan.curve.maxRateAtTarget = 63_419_583_967;
            plan.curve.maxBorrowRate = 0;
            if (i != 0) {
                plan.market.oracle = d.markets[0].contracts.params.oracle;
                plan.market.guardianSignals = d.markets[0].contracts.guardianSignals;
            }
            MarketDeploymentResult memory empty;
            d.markets[i].priceFeedKind = "wsteth-rate";
            d.markets[i].role = plan.name;
            d.markets[i].contracts =
                activateMarkets ? _prepareMarket(d.protocol, plan, empty, activation) : _deployMarket(d.protocol, plan);
            d.markets[i].plan = plan;
        }
        VaultV2Addresses memory vault =
            _deployVaultV2(d.protocol, VaultV2Plan({name: "weth-wsteth", owner: d.protocol.agent, asset: WETH}));
        d.markets[0].vaultV2 = vault.vault;
        d.markets[0].adapter = vault.adapter;
        BundlerAddresses memory bundler = _deployBundler(d.protocol, BundlerPlan({weth: WETH, wstEth: WSTETH}));
        d.bundler = bundler.bundler;
        d.generalAdapter = bundler.generalAdapter;
        d.vaultAdapter = bundler.vaultAdapter;
    }
}
