// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

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

import {CommonBase} from "forge-std/Base.sol";
import {LidoLendPrimitives} from "./LidoLendPrimitives.sol";

/// @dev A protocol's deploy inputs: the governance that receives its roles and its CircuitBreaker's durations.
struct CoreConfig {
    uint256 chainId;
    /// The DAO Agent: administration, ownership and proxy upgrades.
    address admin;
    /// Easy Track's EVMScriptExecutor: market creation and routine governance.
    address manager;
    address resealManager;
    CircuitBreakerParameters circuitBreaker;
}

struct CircuitBreakerParameters {
    uint256 minPauseDuration;
    uint256 maxPauseDuration;
    uint256 minHeartbeatInterval;
    uint256 maxHeartbeatInterval;
    uint256 initialPauseDuration;
    uint256 initialHeartbeatInterval;
}

/// @dev A deployed protocol: what a deploy returns and what a core script records.
struct ProtocolAddresses {
    uint256 chainId;
    address core;
    address factory;
    address ownerFacade;
    address irmRouter;
    address adaptiveCurveIrm;
    address irmConfigFactory;
    address dashboard;
    address circuitBreaker;
    address resealManager;
    address agent;
    address executor;
}

/// @dev The exit books' deploy inputs.
struct ExitBooksConfig {
    address pauser; // PAUSER_ROLE (Risk Steward Committee)
    uint256 maxRequestLifetime; // cap on a request's lifetime (seconds); must be non-zero
}

/// @dev Deployed exit books: what a deploy returns and what an exit-book script records.
struct ExitBookAddresses {
    address morpho;
    address erc4626;
}

interface ICircuitBreakerConfig {
    function ADMIN() external view returns (address);
}

abstract contract ProtocolDeployer is CommonBase, LidoLendPrimitives {
    error MissingProtocolGovernance();
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

    /// @notice The protocol backbone over `circuitBreaker`, or over a new CircuitBreaker when it is zero.
    function _deployProtocol(CoreConfig memory c, address circuitBreaker, address deployer)
        internal
        returns (ProtocolAddresses memory)
    {
        _requireChainId(c.chainId);
        if (c.admin == address(0) || c.manager == address(0) || c.resealManager == address(0)) {
            revert MissingProtocolGovernance();
        }
        if (circuitBreaker == address(0)) {
            CircuitBreakerParameters memory b = c.circuitBreaker;
            // The upstream dependency pins solc 0.8.34.
            circuitBreaker = vm.deployCode(
                "CircuitBreaker.sol:CircuitBreaker",
                abi.encode(
                    c.manager,
                    b.minPauseDuration,
                    b.maxPauseDuration,
                    b.minHeartbeatInterval,
                    b.maxHeartbeatInterval,
                    b.initialPauseDuration,
                    b.initialHeartbeatInterval
                )
            );
        }
        return _deployBackbone(c, circuitBreaker, deployer);
    }

    /// @dev The dashboard must exist before the factory grants it market roles.
    function _deployBackbone(CoreConfig memory c, address circuitBreaker, address deployer)
        internal
        returns (ProtocolAddresses memory d)
    {
        if (c.admin == deployer) revert AgentCannotBeDeployer();
        if (c.manager == deployer) revert ExecutorCannotBeDeployer();
        if (c.admin == c.manager) revert AgentCannotBeExecutor();
        _requireCircuitBreakerPolicy(circuitBreaker, c.manager);
        d.chainId = block.chainid;
        d.agent = c.admin;
        d.executor = c.manager;
        d.circuitBreaker = circuitBreaker;
        d.resealManager = c.resealManager;

        d.core = _deployCore(deployer);
        d.ownerFacade = _deployOwnerFacade(d.core, deployer, address(0), address(0));
        ILidoLend(d.core).setFeeRecipient(c.admin);
        ILidoLend(d.core).setOwner(d.ownerFacade);
        d.irmRouter = _deployIrm(d.core, deployer);

        RiskStewardDashboard dashboard = new RiskStewardDashboard(deployer, ILidoLend(d.core));
        dashboard.grantRole(dashboard.STEWARD_ADMIN_ROLE(), c.manager);
        dashboard.grantRole(dashboard.DEFAULT_ADMIN_ROLE(), c.admin);
        dashboard.revokeRole(dashboard.DEFAULT_ADMIN_ROLE(), deployer);
        d.dashboard = address(dashboard);

        d.adaptiveCurveIrm = address(new AdaptiveCurveIrm(d.irmRouter, c.admin, c.manager));
        d.irmConfigFactory = address(new IrmConfigFactory());

        // Injecting implementations keeps the factory below the EIP-3860 initcode limit.
        address controllerImpl = address(new LidoLendMarketController(IMorpho(d.core)));
        address erc4626WrapperImpl = address(new LidoLendERC4626(d.core));
        address guardianSignalsImpl = address(new GuardianSignals());

        d.factory = address(
            new LidoLendMarketFactory(
                LidoLendMarketFactory.Implementations({
                    controller: controllerImpl, erc4626Wrapper: erc4626WrapperImpl, guardianSignals: guardianSignalsImpl
                }),
                LidoLendMarketFactory.Dependencies({
                    lidoLend: d.core,
                    irmRouter: d.irmRouter,
                    lidoLendOwner: d.ownerFacade,
                    circuitBreaker: circuitBreaker,
                    resealManager: c.resealManager,
                    riskStewardDashboard: d.dashboard
                }),
                c.admin
            )
        );

        LidoLendOwner facade = LidoLendOwner(d.ownerFacade);
        facade.grantRole(facade.MARKET_CREATOR_ROLE(), c.manager);
        facade.grantRole(facade.MARKET_MANAGER_ROLE(), c.manager);
        facade.grantRole(facade.GUARDIAN_MANAGER_ROLE(), c.manager);
        IrmRouter(d.irmRouter).setManager(c.manager);

        facade.grantRole(facade.FEE_MANAGER_ROLE(), c.manager);
        facade.grantRole(facade.DEFAULT_ADMIN_ROLE(), c.admin);
        facade.revokeRole(facade.DEFAULT_ADMIN_ROLE(), deployer);
        IrmRouter(d.irmRouter).transferOwnership(c.admin);
        OssifiableProxy(payable(d.core)).proxy__changeAdmin(c.admin);
        OssifiableProxy(payable(d.irmRouter)).proxy__changeAdmin(c.admin);
    }

    function _requireCircuitBreakerPolicy(address circuitBreaker, address executor) internal view {
        if (circuitBreaker == address(0)) revert MissingCircuitBreaker();
        if (circuitBreaker.code.length == 0) revert CircuitBreakerNotContract(circuitBreaker);
        address actualAdmin = ICircuitBreakerConfig(circuitBreaker).ADMIN();
        if (actualAdmin != executor) revert UnexpectedCircuitBreakerAdmin(executor, actualAdmin);
    }

    function _deployExitBooks(ProtocolAddresses memory p, ExitBooksConfig memory c, address deployer)
        internal
        returns (ExitBookAddresses memory books)
    {
        if (p.agent == deployer) revert AgentCannotBeDeployer();
        if (p.executor == deployer) revert ExecutorCannotBeDeployer();
        if (p.agent == p.executor) revert AgentCannotBeExecutor();
        if (c.pauser == address(0)) revert MissingExitBookPauser();
        if (c.pauser == deployer) revert ExitBookPauserCannotBeDeployer();
        if (c.pauser == p.agent) revert ExitBookPauserCannotBeAgent();
        if (c.pauser == p.executor) revert ExitBookPauserCannotBeExecutor();

        MorphoExitBook morpho = new MorphoExitBook(p.core, deployer, c.maxRequestLifetime);
        _handOverExitBook(morpho, p, c.pauser, deployer);
        books.morpho = address(morpho);

        Erc4626ExitBook erc4626 = new Erc4626ExitBook(deployer, c.maxRequestLifetime);
        _handOverExitBook(erc4626, p, c.pauser, deployer);
        books.erc4626 = address(erc4626);
    }

    function _handOverExitBook(ExitBookBase book, ProtocolAddresses memory p, address pauser, address deployer)
        private
    {
        // EasyTrack controls the allow-list; the Agent administers role grants.
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), p.executor);
        book.grantRole(book.PAUSER_ROLE(), pauser);
        // RESUMER_ROLE deliberately starts empty. Governance grants it only when it needs to resume the book.
        book.grantRole(book.DEFAULT_ADMIN_ROLE(), p.agent);
        book.grantRole(book.FEE_MANAGER_ROLE(), deployer);
        book.setServiceFee(p.agent, 0);
        book.revokeRole(book.FEE_MANAGER_ROLE(), deployer);
        book.revokeRole(book.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
