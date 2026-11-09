// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {IIrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/interfaces/IIrmConfigFactory.sol";
import {IAdaptiveCurveConfig} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {ProtocolAddresses, MarketPlan, MarketDeploymentResult} from "./DeploymentTypes.sol";

interface IDeploymentManager {
    function manager() external view returns (address);
}

interface IDeploymentCircuitBreaker {
    function ADMIN() external view returns (address);
}

interface IDeploymentController {
    function LIDO_LEND() external view returns (address);
    function marketId() external view returns (Id);
    function supplyCap() external view returns (uint256);
}

abstract contract MarketDeployment {
    using MarketParamsLib for MarketParams;

    error WrongChain(uint256 expected, uint256 actual);
    error MissingCode(address account);
    error IncompatibleDependency(bytes32 field, address expected, address actual);
    error MissingCommittee();
    error InvalidMarketRecord();

    function _checkProtocol(ProtocolAddresses memory p) internal view {
        if (block.chainid != p.chainId) revert WrongChain(p.chainId, block.chainid);
        _requireCode(p.core);
        _requireCode(p.factory);
        _requireCode(p.ownerFacade);
        _requireCode(p.irmRouter);
        _requireCode(p.adaptiveCurveIrm);
        _requireCode(p.irmConfigFactory);
        _requireCode(p.dashboard);
        _requireCode(p.circuitBreaker);
        LidoLendMarketFactory f = LidoLendMarketFactory(p.factory);
        _same("core", p.core, f.LIDO_LEND());
        _same("facade", p.ownerFacade, address(f.LIDO_LEND_OWNER()));
        _same("router", p.irmRouter, address(f.IRM_ROUTER()));
        _same("dashboard", p.dashboard, f.RISK_STEWARD_DASHBOARD());
        _same("circuitBreaker", p.circuitBreaker, f.CIRCUIT_BREAKER());
        _same("resealManager", p.resealManager, f.RESEAL_MANAGER());
        _same("agent", p.agent, f.ADMIN());
        _same("core.owner", p.ownerFacade, ILidoLend(p.core).owner());
        _same("router.manager", p.executor, IDeploymentManager(p.irmRouter).manager());
        _same("circuitBreaker.admin", p.executor, IDeploymentCircuitBreaker(p.circuitBreaker).ADMIN());
    }

    function _checkPlan(ProtocolAddresses memory p, MarketPlan memory plan) internal view {
        _checkProtocol(p);
        _requireCode(plan.market.loanToken);
        _requireCode(plan.market.collateralToken);
        if (plan.committee.guardians.length == 0 || plan.committee.quorum == 0) revert MissingCommittee();
        if (plan.market.oracle != address(0)) _checkPriceFeed(p, plan);
        if (plan.market.guardianSignals != address(0)) {
            LidoLendMarketFactory(p.factory).validateGuardianSignals(plan.market.guardianSignals, plan.committee);
        }
    }

    function _deployMarket(ProtocolAddresses memory p, MarketPlan memory plan)
        internal
        returns (MarketDeploymentResult memory d)
    {
        _checkPlan(p, plan);
        if (plan.market.oracle == address(0)) plan.market.oracle = _deployPriceFeed(p, plan);
        _checkPriceFeed(p, plan);
        LidoLendMarketFactory f = LidoLendMarketFactory(p.factory);
        if (plan.market.guardianSignals == address(0)) {
            plan.market.guardianSignals = f.deployGuardianSignals(plan.committee, plan.guardianGroup);
        }
        d.guardianSignals = plan.market.guardianSignals;
        d.irmConfig = IIrmConfigFactory(p.irmConfigFactory).getOrDeployAdaptiveCurveConfig(plan.curve);
        d.params = MarketParams({
            loanToken: plan.market.loanToken,
            collateralToken: plan.market.collateralToken,
            oracle: plan.market.oracle,
            irm: p.irmRouter,
            lltv: plan.market.lltv
        });
        (d.id, d.controller, d.vault) = f.deployMarketComponents(plan.market, plan.wrapper);
        _checkMarket(p, d);
    }

    /// @dev Existing deployments are checked for identity, without resetting governance-controlled parameters.
    function _checkMarket(ProtocolAddresses memory p, MarketDeploymentResult memory d) internal view {
        _checkProtocol(p);
        _requireCode(d.controller);
        _requireCode(d.vault);
        _requireCode(d.guardianSignals);
        _requireCode(d.params.oracle);
        _requireCode(d.irmConfig);
        if (Id.unwrap(d.id) != Id.unwrap(d.params.id()) || d.params.irm != p.irmRouter) revert InvalidMarketRecord();
        ILidoLendERC4626 vault = ILidoLendERC4626(d.vault);
        _same("vault.core", p.core, address(vault.LIDO_LEND()));
        _same("vault.controller", d.controller, address(vault.controller()));
        _same("vault.asset", d.params.loanToken, vault.asset());
        if (Id.unwrap(vault.marketId()) != Id.unwrap(d.id)) revert InvalidMarketRecord();
        ILidoLendMarketController controller = ILidoLendMarketController(d.controller);
        _same("controller.core", p.core, IDeploymentController(d.controller).LIDO_LEND());
        if (Id.unwrap(IDeploymentController(d.controller).marketId()) != Id.unwrap(d.id)) revert InvalidMarketRecord();
        _same("controller.guardians", d.guardianSignals, address(controller.guardianSignals()));
        address registered = ILidoLend(p.core).marketController(d.id);
        if (registered != address(0) || ILidoLend(p.core).market(d.id).lastUpdate != 0) {
            _same("core.controller", d.controller, registered);
        }
    }

    /// @dev Enforces launch parameters and roles before activation.
    function _checkInertMarket(ProtocolAddresses memory p, MarketPlan memory plan, MarketDeploymentResult memory d)
        internal
        view
    {
        LidoLendMarketFactory factory = LidoLendMarketFactory(p.factory);
        factory.validateGuardianSignals(d.guardianSignals, plan.committee);
        factory.validateMarketController(d.controller, d.id, d.guardianSignals);
        factory.validateERC4626Wrapper(d.vault, d.controller, d.params);
        ILidoLendMarketController controller = ILidoLendMarketController(d.controller);
        require(
            keccak256(abi.encode(controller.collateralActivationConfig()))
                == keccak256(abi.encode(plan.market.activationConfig)),
            "Inert activation differs from plan"
        );
        require(
            keccak256(abi.encode(controller.settlementConfig())) == keccak256(abi.encode(plan.market.settlementConfig)),
            "Inert settlement differs from plan"
        );
        require(IDeploymentController(d.controller).supplyCap() == plan.market.supplyCap, "Inert cap differs from plan");
        require(
            keccak256(abi.encode(IAdaptiveCurveConfig(d.irmConfig).getCurveParams()))
                == keccak256(abi.encode(plan.curve)),
            "Inert curve differs from plan"
        );
        IERC20Metadata vault = IERC20Metadata(d.vault);
        require(
            keccak256(bytes(vault.name())) == keccak256(bytes(plan.wrapper.name)), "Inert vault name differs from plan"
        );
        require(
            keccak256(bytes(vault.symbol())) == keccak256(bytes(plan.wrapper.symbol)),
            "Inert vault symbol differs from plan"
        );
    }

    function _deployPriceFeed(ProtocolAddresses memory p, MarketPlan memory plan) internal virtual returns (address);
    function _checkPriceFeed(ProtocolAddresses memory p, MarketPlan memory plan) internal view virtual;

    function _requireCode(address account) internal view {
        if (account.code.length == 0) revert MissingCode(account);
    }

    function _same(bytes32 field, address expected, address actual) internal pure {
        if (expected != actual) revert IncompatibleDependency(field, expected, actual);
    }
}
