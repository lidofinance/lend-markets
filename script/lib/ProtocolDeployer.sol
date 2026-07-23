// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IMorpho} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";

import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {ILidoLendOwner} from "../../src/interfaces/ILidoLendOwner.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {LidoLendMarketBuilder, GuardianConfig} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {RiskStewardDashboard} from "../../src/periphery/RiskStewardDashboard.sol";
import {ExitBookBase} from "../../src/periphery/ExitBookBase.sol";
import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";
import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";
import {GuardianSignals} from "../../src/GuardianSignals.sol";

import {LidoLendPrimitives} from "./LidoLendPrimitives.sol";
import {ProtocolConfig, ProtocolDeployment} from "./ProtocolConfigFile.sol";
import {GuardianSignalsConfig, GuardianSignalsConfigFile} from "./GuardianSignalsConfigFile.sol";
import {ExitBookConfig} from "./ExitBookConfigFile.sol";

/// @notice Production deploy engine: backbone (core, facade, router, curve, dashboard, factory/builder) +
///         optional exit books + per-market components, over `LidoLendPrimitives`. `DeployProtocol` and
///         `AddMarket` inherit this and compose.
abstract contract ProtocolDeployer is LidoLendPrimitives {
    error AgentCannotBeDeployer();
    error AgentCannotBeExecutor();
    error ExecutorCannotBeDeployer();
    error UnexpectedChainId(uint256 expected, uint256 actual);

    function _requireChainId(uint256 expected) internal view {
        if (block.chainid != expected) revert UnexpectedChainId(expected, block.chainid);
    }

    /// @dev Backbone: core, facade, router, dashboard, factory/builder + the C1/routine role split. Dashboard
    ///      is deployed before the builder so the builder can grant it each new controller's `MANAGER_ROLE`.
    function _deployBackbone(ProtocolConfig memory cfg, address deployer)
        internal
        returns (ProtocolDeployment memory d)
    {
        if (cfg.agent == deployer) revert AgentCannotBeDeployer();
        if (cfg.agent == cfg.evmScriptExecutor) revert AgentCannotBeExecutor();

        d.core = _deployCore(deployer);
        d.ownerFacade = _deployOwnerFacade(d.core, deployer, address(0), address(0));
        ILidoLend(d.core).setOwner(d.ownerFacade);
        d.irmRouter = _deployIrm(d.core, deployer);

        RiskStewardDashboard dashboard = new RiskStewardDashboard(deployer, ILidoLend(d.core));
        dashboard.grantRole(dashboard.STEWARD_ADMIN_ROLE(), cfg.evmScriptExecutor);
        dashboard.grantRole(dashboard.DEFAULT_ADMIN_ROLE(), cfg.agent);
        dashboard.revokeRole(dashboard.DEFAULT_ADMIN_ROLE(), deployer);
        d.riskStewardDashboard = address(dashboard);

        // The IRM curve is a protocol singleton (per-id state), so it deploys with the backbone; owner/manager
        // go straight to their final holders since per-market params are set at activation.
        d.adaptiveCurveIrm = address(new AdaptiveCurveIrm(d.irmRouter, cfg.agent, cfg.evmScriptExecutor));

        // Impls are deployed here and injected: the factory cannot `new` them without overflowing its
        // EIP-3860 initcode limit.
        address controllerImpl = address(new LidoLendMarketController(IMorpho(d.core)));
        address vaultImpl = address(new LidoLendERC4626(d.core));
        d.guardianSignalsImpl = address(new GuardianSignals());

        d.factory = address(new LidoLendMarketFactory(controllerImpl, vaultImpl, d.guardianSignalsImpl));
        d.builder = address(
            new LidoLendMarketBuilder(
                LidoLendMarketFactory(d.factory),
                ILidoLendOwner(d.ownerFacade),
                IIrmRouter(d.irmRouter),
                d.riskStewardDashboard
            )
        );

        LidoLendOwner facade = LidoLendOwner(d.ownerFacade);
        facade.grantRole(facade.MARKET_CREATOR_ROLE(), cfg.evmScriptExecutor);
        IrmRouter(d.irmRouter).setManager(cfg.evmScriptExecutor);

        facade.grantRole(facade.DEFAULT_ADMIN_ROLE(), cfg.agent);
        facade.revokeRole(facade.DEFAULT_ADMIN_ROLE(), deployer);
        IrmRouter(d.irmRouter).transferOwnership(cfg.agent);
    }

    /// @dev Deploys a market's `GuardianSignals` instance via the builder, mapping `guardians/<name>.toml`
    ///      onto its arguments (the executor is the sole `manager`).
    function _buildGuardianSignals(string memory name, address builder) internal returns (address guardianSignals) {
        GuardianSignalsConfig memory cfg = GuardianSignalsConfigFile.read(name);
        address[] memory managers = new address[](1);
        managers[0] = cfg.evmScriptExecutor;

        guardianSignals = LidoLendMarketBuilder(builder)
            .buildGuardianSignals(
                GuardianConfig({
                    guardians: cfg.guardians,
                    quorum: cfg.quorum,
                    suspectWindow: cfg.suspectWindow,
                    accessLimiter: cfg.accessLimiter
                }),
                cfg.admin,
                managers,
                cfg.proxyAdmin
            );
    }

    /// @dev The protocol's two exit books; `ALLOWLIST_MANAGER_ROLE` → executor, fee/recovery/admin → agent.
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
        // ALLOWLIST_MANAGER to the executor (so an activation motion can allow-list a market/vault) AND to the
        // agent (so a standalone allow-list / de-list, which has no dedicated EasyTrack factory, is a direct
        // DAO action without a grant-then-call dance).
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), cfg.evmScriptExecutor);
        book.grantRole(book.ALLOWLIST_MANAGER_ROLE(), cfg.agent);
        book.grantRole(book.FEE_MANAGER_ROLE(), cfg.agent);
        book.grantRole(book.RECOVERER_ROLE(), cfg.agent);
        book.grantRole(book.DEFAULT_ADMIN_ROLE(), cfg.agent);
        book.revokeRole(book.DEFAULT_ADMIN_ROLE(), deployer);
    }
}
