// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ActivationMotionConfig} from "../../script/deployment/DeployMarketBase.s.sol";
import {ForkStack} from "./helpers/ForkStack.sol";

/// @dev The CircuitBreaker's pauser of a pausable contract.
interface ICircuitBreakerPausers {
    function getPauser(address pausable) external view returns (address);
}

/// @dev The IRM router's route and the adaptive curve IRM's config of a market, by its id: the IRM package pins its own
///      copy of the core's `Id`.
interface IIrmReads {
    function marketIrm(bytes32 id) external view returns (address);
    function marketCurveConfig(bytes32 id) external view returns (address);
}

/// @notice The activation's effects on a market the run creates, against its script's motion config: the controller,
///         settlement, the fee, the IRM route and curve config, the steward, the pauser and the preseed. Skips a market
///         that existed at the block, which governance may have changed since.
contract MarketActivationForkTest is ForkStack {
    function setUp() public {
        _setUpTarget();
        if (!createdByTest) vm.skip(true, "MarketActivation: the market existed at the block");
    }

    function test_activation_wiresTheMarketAsItsMotionConfigures() public view {
        ActivationMotionConfig memory a = script.getActivationMotionConfig();
        assertEq(market.core.marketController(market.id), deployment.controller, "the market's controller");
        assertEq(market.core.isSettlementEnabled(market.id), a.enableSettlement, "settlement");
        assertEq(market.core.market(market.id).fee, a.fee, "the fee");
        assertEq(market.params.irm, protocol.irmRouter, "the market's IRM is the router");
        assertEq(
            IIrmReads(protocol.irmRouter).marketIrm(Id.unwrap(market.id)), protocol.adaptiveCurveIrm, "the IRM route"
        );
        assertEq(
            IIrmReads(protocol.adaptiveCurveIrm).marketCurveConfig(Id.unwrap(market.id)),
            deployment.irmConfig,
            "the curve config"
        );
        assertTrue(_dashboard().isMarketSteward(market.id, a.steward), "the steward");
        assertEq(
            ICircuitBreakerPausers(protocol.circuitBreaker).getPauser(deployment.controller), a.pauser, "the pauser"
        );
    }

    /// @dev The preseed holds at least `MIN_SEED_SHARES` in the vault and as a direct core supply beside the vault's.
    function test_activation_preseedsTheCoreAndTheVault() public view {
        uint256 coreShares = market.core.market(market.id).totalSupplyShares;
        uint256 vaultCoreShares = market.core.position(market.id, deployment.vault).supplyShares;
        assertGe(coreShares - vaultCoreShares, MIN_SEED_SHARES, "the core's direct preseed");
        assertGe(market.vault.totalSupply(), MIN_SEED_SHARES, "the vault's preseed");
    }
}
