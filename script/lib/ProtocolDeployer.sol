// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IMorpho} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {IrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/IrmConfigFactory.sol";

import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {IIrmRouterView, LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";

import {LidoLendPrimitives} from "./LidoLendPrimitives.sol";
import {ProtocolConfig, ProtocolDeployment} from "./ProtocolConfigFile.sol";
import {GuardianSignalsConfig, GuardianSignalsConfigFile} from "./GuardianSignalsConfigFile.sol";
import {ExitBookConfig} from "./ExitBookConfigFile.sol";

interface ICircuitBreakerConfig {
    function ADMIN() external view returns (address);
}

abstract contract ProtocolDeployer is LidoLendPrimitives {
    error AgentCannotBeDeployer();
    error AgentCannotBeExecutor();
    error ExecutorCannotBeDeployer();
    error UnexpectedChainId(uint256 expected, uint256 actual);
    error UnexpectedAdmin(address expected, address actual);
    error UnexpectedProxyAdmin(address expected, address actual);
    error ExecutorHasDirectMarketRole();
    error DeployerHasDirectMarketRole();
    error MissingCircuitBreaker();
    error CircuitBreakerNotContract(address circuitBreaker);
    error UnexpectedCircuitBreakerAdmin(address expected, address actual);
    error DuplicateMarketId(string firstMarket, string secondMarket);

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
        d.agent = cfg.agent;
        d.evmScriptExecutor = cfg.evmScriptExecutor;

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
        address vaultImpl = address(new LidoLendERC4626(d.core));
        d.guardianSignalsImpl = address(new GuardianSignals());

        d.factory = address(
            new LidoLendMarketFactory(
                LidoLendMarketFactory.Implementations({
                    controller: controllerImpl, vault: vaultImpl, guardianSignals: d.guardianSignalsImpl
                }),
                ILidoLendOwner(d.ownerFacade),
                IIrmRouterView(d.irmRouter),
                d.riskStewardDashboard
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

    /// @dev The facade is the only operational manager.
    function _deployGuardianSignals(string memory name, address factory, address agent)
        internal
        returns (address guardianSignals)
    {
        GuardianSignalsConfig memory cfg = GuardianSignalsConfigFile.read(name);
        if (cfg.admin != agent) revert UnexpectedAdmin(agent, cfg.admin);
        if (cfg.proxyAdmin != agent) revert UnexpectedProxyAdmin(agent, cfg.proxyAdmin);
        address[] memory managers = new address[](0);

        guardianSignals = LidoLendMarketFactory(factory)
            .deployGuardianSignals(
                LidoLendMarketFactory.GuardianSpec({
                    guardians: cfg.guardians, quorum: cfg.quorum, suspectWindow: cfg.suspectWindow
                }),
                LidoLendMarketFactory.GuardianRoles({
                    admin: cfg.admin, proxyAdmin: cfg.proxyAdmin, managers: managers, accessLimiter: cfg.accessLimiter
                })
            );
    }

    function _requireMarketRolePolicy(
        LidoLendMarketFactory.MarketRoles memory roles,
        address agent,
        address executor,
        address deployer
    ) internal view {
        if (roles.admin != agent) revert UnexpectedAdmin(agent, roles.admin);
        if (roles.proxyAdmin != agent) revert UnexpectedProxyAdmin(agent, roles.proxyAdmin);
        if (roles.pausers.length == 0) revert MissingCircuitBreaker();
        address circuitBreaker = roles.pausers[0];
        if (circuitBreaker.code.length == 0) revert CircuitBreakerNotContract(circuitBreaker);
        address actualAdmin = ICircuitBreakerConfig(circuitBreaker).ADMIN();
        if (actualAdmin != executor) revert UnexpectedCircuitBreakerAdmin(executor, actualAdmin);

        _requireNoDirectMarketRole(roles.managers, executor, deployer);
        _requireNoDirectMarketRole(roles.pausers, executor, deployer);
        _requireNoDirectMarketRole(roles.freezers, executor, deployer);
        _requireNoDirectMarketRole(roles.unfreezers, executor, deployer);
        _requireNoDirectMarketRole(roles.resumers, executor, deployer);
    }

    function _requireNoDirectMarketRole(address[] memory holders, address executor, address deployer) private pure {
        for (uint256 i; i < holders.length; ++i) {
            if (holders[i] == executor) revert ExecutorHasDirectMarketRole();
            if (holders[i] == deployer) revert DeployerHasDirectMarketRole();
        }
    }

    function _requireProxyAdmin(address target, address agent) internal view {
        address actual = OssifiableProxy(payable(target)).proxy__getAdmin();
        if (actual != agent) revert UnexpectedProxyAdmin(agent, actual);
    }

    /// @dev The shared IRM router makes these four inputs sufficient to detect duplicate market ids.
    function _requireUniqueMarketIds(string[] memory names, LidoLendMarketFactory.MarketSpec[] memory markets)
        internal
        pure
    {
        for (uint256 i; i < markets.length; ++i) {
            bytes32 current = _marketIdInputHash(markets[i]);
            for (uint256 j; j < i; ++j) {
                if (current == _marketIdInputHash(markets[j])) revert DuplicateMarketId(names[j], names[i]);
            }
        }
    }

    function _marketIdInputHash(LidoLendMarketFactory.MarketSpec memory market) private pure returns (bytes32) {
        return keccak256(abi.encode(market.loanToken, market.collateralToken, market.oracle, market.lltv));
    }

    function _deployExitBooks(ExitBookConfig memory cfg, address deployer)
        internal
        returns (address morphoExitBook, address erc4626ExitBook)
    {
        if (cfg.agent == deployer) revert AgentCannotBeDeployer();
        if (cfg.evmScriptExecutor == deployer) revert ExecutorCannotBeDeployer();
        if (cfg.agent == cfg.evmScriptExecutor) revert AgentCannotBeExecutor();

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
        book.grantRole(book.DEFAULT_ADMIN_ROLE(), cfg.agent);
        book.revokeRole(book.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
