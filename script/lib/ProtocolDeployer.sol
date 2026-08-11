// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IMorpho} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {IrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/IrmConfigFactory.sol";

import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {LidoLendPrimitives} from "./LidoLendPrimitives.sol";
import {ProtocolConfig, ProtocolDeployment} from "./ProtocolConfigFile.sol";
import {ExitBookConfig} from "./ExitBookConfigFile.sol";

interface ICircuitBreakerConfig {
    function ADMIN() external view returns (address);
}

abstract contract ProtocolDeployer is LidoLendPrimitives {
    error AgentCannotBeDeployer();
    error AgentCannotBeExecutor();
    error ExitBookPauserCannotBeAgent();
    error ExitBookPauserCannotBeDeployer();
    error ExitBookPauserCannotBeExecutor();
    error ExecutorCannotBeDeployer();
    error UnexpectedChainId(uint256 expected, uint256 actual);
    error MissingCircuitBreaker();
    error CircuitBreakerNotContract(address circuitBreaker);
    error UnexpectedCircuitBreakerAdmin(address expected, address actual);
    error MissingExitBookPauser();

    function _requireChainId(uint256 expected) internal view {
        if (block.chainid != expected) revert UnexpectedChainId(expected, block.chainid);
    }

    /// @dev The dashboard must exist before the factory grants it market roles.
    function _deployBackbone(ProtocolConfig memory cfg, address deployer)
        internal
        returns (ProtocolDeployment memory d)
    {
        if (cfg.agent == deployer) revert AgentCannotBeDeployer();
        if (cfg.evmScriptExecutor == deployer) revert ExecutorCannotBeDeployer();
        if (cfg.agent == cfg.evmScriptExecutor) revert AgentCannotBeExecutor();
        _requireCircuitBreakerPolicy(cfg.circuitBreaker, cfg.evmScriptExecutor);
        d.agent = cfg.agent;
        d.evmScriptExecutor = cfg.evmScriptExecutor;
        d.circuitBreaker = cfg.circuitBreaker;

        d.core = _deployCore(deployer);
        d.ownerFacade = _deployOwnerFacade(d.core, deployer, address(0), address(0));
        ILidoLend(d.core).setOwner(d.ownerFacade);
        d.irmRouter = _deployIrm(d.core, deployer);

        RiskStewardDashboard dashboard = new RiskStewardDashboard(deployer, ILidoLend(d.core));
        dashboard.grantRole(dashboard.STEWARD_ADMIN_ROLE(), cfg.evmScriptExecutor);
        dashboard.grantRole(dashboard.DEFAULT_ADMIN_ROLE(), cfg.agent);
        dashboard.revokeRole(dashboard.DEFAULT_ADMIN_ROLE(), deployer);
        d.riskStewardDashboard = address(dashboard);

        d.adaptiveCurveIrm = address(new AdaptiveCurveIrm(d.irmRouter, cfg.agent, cfg.evmScriptExecutor));
        d.irmConfigFactory = address(new IrmConfigFactory());

        // Injecting implementations keeps the factory below the EIP-3860 initcode limit.
        address controllerImpl = address(new LidoLendMarketController(IMorpho(d.core)));
        address erc4626WrapperImpl = address(new LidoLendERC4626(d.core));
        d.guardianSignalsImpl = address(new GuardianSignals());

        d.factory = address(
            new LidoLendMarketFactory(
                LidoLendMarketFactory.Implementations({
                    controller: controllerImpl,
                    erc4626Wrapper: erc4626WrapperImpl,
                    guardianSignals: d.guardianSignalsImpl
                }),
                LidoLendMarketFactory.Dependencies({
                    lidoLend: d.core,
                    irmRouter: d.irmRouter,
                    lidoLendOwner: d.ownerFacade,
                    circuitBreaker: cfg.circuitBreaker,
                    riskStewardDashboard: d.riskStewardDashboard
                }),
                cfg.agent
            )
        );

        LidoLendOwner facade = LidoLendOwner(d.ownerFacade);
        facade.grantRole(facade.MARKET_CREATOR_ROLE(), cfg.evmScriptExecutor);
        facade.grantRole(facade.MARKET_MANAGER_ROLE(), cfg.evmScriptExecutor);
        facade.grantRole(facade.GUARDIAN_MANAGER_ROLE(), cfg.evmScriptExecutor);
        IrmRouter(d.irmRouter).setManager(cfg.evmScriptExecutor);

        facade.grantRole(facade.FEE_MANAGER_ROLE(), cfg.agent);
        facade.grantRole(facade.DEFAULT_ADMIN_ROLE(), cfg.agent);
        facade.revokeRole(facade.DEFAULT_ADMIN_ROLE(), deployer);
        IrmRouter(d.irmRouter).transferOwnership(cfg.agent);
        OssifiableProxy(payable(d.core)).proxy__changeAdmin(cfg.agent);
        OssifiableProxy(payable(d.irmRouter)).proxy__changeAdmin(cfg.agent);
    }

    function _requireCircuitBreakerPolicy(address circuitBreaker, address executor) internal view {
        if (circuitBreaker == address(0)) revert MissingCircuitBreaker();
        if (circuitBreaker.code.length == 0) revert CircuitBreakerNotContract(circuitBreaker);
        address actualAdmin = ICircuitBreakerConfig(circuitBreaker).ADMIN();
        if (actualAdmin != executor) revert UnexpectedCircuitBreakerAdmin(executor, actualAdmin);
    }

    function _deployExitBooks(ExitBookConfig memory cfg, address deployer)
        internal
        returns (address morphoExitBook, address erc4626ExitBook)
    {
        if (cfg.agent == deployer) revert AgentCannotBeDeployer();
        if (cfg.evmScriptExecutor == deployer) revert ExecutorCannotBeDeployer();
        if (cfg.agent == cfg.evmScriptExecutor) revert AgentCannotBeExecutor();
        if (cfg.pauser == address(0)) revert MissingExitBookPauser();
        if (cfg.pauser == deployer) revert ExitBookPauserCannotBeDeployer();
        if (cfg.pauser == cfg.agent) revert ExitBookPauserCannotBeAgent();
        if (cfg.pauser == cfg.evmScriptExecutor) revert ExitBookPauserCannotBeExecutor();

        MorphoExitBook morpho = new MorphoExitBook(cfg.core, deployer, cfg.maxRequestLifetime);
        _handOverExitBook(morpho, cfg, deployer);
        morphoExitBook = address(morpho);

        Erc4626ExitBook erc4626 = new Erc4626ExitBook(deployer, cfg.maxRequestLifetime);
        _handOverExitBook(erc4626, cfg, deployer);
        erc4626ExitBook = address(erc4626);
    }

    function _handOverExitBook(ExitBookBase book, ExitBookConfig memory cfg, address deployer) private {
        // EasyTrack and the Agent both need independent allow-list control.
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), cfg.evmScriptExecutor);
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), cfg.agent);
        book.grantRole(book.FEE_MANAGER_ROLE(), cfg.agent);
        book.grantRole(book.RECOVERER_ROLE(), cfg.agent);
        book.grantRole(book.PAUSER_ROLE(), cfg.pauser);
        // RESUMER_ROLE deliberately starts empty. Governance grants it only when it needs to resume the book.
        book.grantRole(book.DEFAULT_ADMIN_ROLE(), cfg.agent);
        book.revokeRole(book.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
