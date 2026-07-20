// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";

import {ILidoLendOwner} from "../interfaces/ILidoLendOwner.sol";
import {LidoLendMarketFactory} from "./LidoLendMarketFactory.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../types/SettlementTypes.sol";

/// @notice The addresses that must hold a market controller's roles. The operational roles are arrays — a
///         role can have any number of holders (an empty array means nobody).
/// @param admin       Controller `DEFAULT_ADMIN_ROLE`.
/// @param proxyAdmin  `OssifiableProxy` admin for the controller and vault.
/// @param managers    Controller `MANAGER_ROLE`.
/// @param pausers     Controller `PAUSER_ROLE`.
/// @param freezers    Controller `FREEZER_ROLE`.
/// @param unfreezers  Controller `UNFREEZER_ROLE`.
/// @param resumers    Controller `RESUMER_ROLE`.
struct MarketRoles {
    address admin;
    address proxyAdmin;
    address[] managers;
    address[] pausers;
    address[] freezers;
    address[] unfreezers;
    address[] resumers;
}

/// @notice The config a `GuardianSignals` instance is seeded and checked against.
/// @param guardians     The guardian set.
/// @param quorum        Signal quorum.
/// @param suspectWindow Suspect window (seconds).
/// @param accessLimiter `ACCESS_LIMITER_ROLE` (`ban`) holder; zero means the role is left for the DAO to
///                       grant later, and no holder is expected at validation time.
struct GuardianConfig {
    address[] guardians;
    uint256 quorum;
    uint256 suspectWindow;
    address accessLimiter;
}

interface IReadController {
    function marketId() external view returns (Id);
    function guardianSignals() external view returns (address);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function MANAGER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function FREEZER_ROLE() external view returns (bytes32);
    function UNFREEZER_ROLE() external view returns (bytes32);
    function RESUMER_ROLE() external view returns (bytes32);
}

interface IReadVault {
    function controller() external view returns (address);
    function marketId() external view returns (Id);
}

interface IReadProxy {
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
}

interface IReadGuardianSignals {
    function getQuorum() external view returns (uint256);
    function getSuspectWindow() external view returns (uint256);
    function getGuardians() external view returns (address[] memory);
    function isGuardian(address account) external view returns (bool);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function MANAGER_ROLE() external view returns (bytes32);
    function ACCESS_RESTORER_ROLE() external view returns (bytes32);
    function ACCESS_LIMITER_ROLE() external view returns (bytes32);
    function setSuspectWindow(uint256 window) external;
}

/// @notice Deploys and self-validates a market's contracts (`buildMarketContracts`) or a GuardianSignals
///         instance (`buildGuardianSignals`) over `LidoLendMarketFactory`, wiring every role in one call. The
///         output is INERT; activation is a later governance step.
/// @dev Draft, not audited. Immutable, no versioning: a `MarketSpec` / `MarketRoles` ABI change needs a new
///      builder. The `public view` validators are reusable standalone, but their "listed holders are the whole
///      set" completeness holds only inside a build call, where this contract created the target in-transaction
///      as its sole admin; a standalone call cannot prove it from state, as `AccessControl` has no enumeration.
contract LidoLendMarketBuilder {
    using MarketParamsLib for MarketParams;

    LidoLendMarketFactory public immutable FACTORY;
    ILidoLendOwner public immutable LIDO_LEND_OWNER;
    IIrmRouter public immutable IRM_ROUTER;
    address public immutable CORE;

    /// @notice Domain-wide `RiskStewardDashboard`, granted each new controller's `MANAGER_ROLE` so its
    ///         tighten-only levers can write config back. `address(0)` skips the grant (domain without one).
    address public immutable RISK_STEWARD_DASHBOARD;

    /// @notice The new market's economic identity and per-market policy. `enableSettlement` is intentionally
    ///         absent — it is a bind-time argument decided at activation (`facade.createMarket`), not here.
    ///         `guardianSignals` is a pre-deployed GuardianSignals address; deploying (or reusing) it is the
    ///         caller script's job, not this contract's.
    struct MarketSpec {
        address loanToken;
        address collateralToken;
        address oracle;
        uint256 lltv;
        address guardianSignals;
        CollateralActivationConfig activationConfig;
        SettlementConfig settlementConfig;
        string vaultName;
        string vaultSymbol;
    }

    /// @notice Addresses produced by `buildMarketContracts`.
    struct MarketContracts {
        Id marketId;
        address controller;
        address vault;
    }

    error ZeroFactory();
    error ZeroLidoLendOwner();
    error ZeroIrmRouter();
    error ZeroCore();
    error CoreMismatch();
    error MarketAlreadyExists(Id marketId);
    error OracleNotContract();
    error GuardianSignalsNotContract();
    error ZeroRoleHolder();
    error ZeroAdmin();
    error ZeroProxyAdmin();
    error CodehashMismatch(address impl, bytes32 expected, bytes32 actual);
    error ProxyAdminMismatch(address proxy, address expected, address actual);
    error MarketIdMismatch(bytes32 expected, bytes32 actual);
    error VaultControllerMismatch(address expected, address actual);
    error GuardianSignalsMismatch(address expected, address actual);
    error MissingRoleHolder(address target, bytes32 role, address holder);
    error UnexpectedRoleHolder(address target, bytes32 role, address holder);
    error GuardianQuorumMismatch(uint256 expected, uint256 actual);
    error GuardianSuspectWindowMismatch(uint256 expected, uint256 actual);
    error GuardianSetSizeMismatch(uint256 expected, uint256 actual);
    error MissingGuardian(address guardian);

    /// @dev `roles` is emitted as one ABI tuple rather than flattened into separate event arguments, since
    ///      flattening its five arrays overflows the `via_ir = false` stack limit in the emit.
    event MarketContractsDeployed(
        Id indexed marketId,
        address controller,
        address vault,
        address guardianSignals,
        address oracle,
        MarketRoles roles
    );

    event GuardianSignalsDeployed(
        address indexed guardianSignals, address admin, address proxyAdmin, address[] managers, GuardianConfig config
    );

    constructor(
        LidoLendMarketFactory factory,
        ILidoLendOwner lidoLendOwner,
        IIrmRouter irmRouter,
        address riskStewardDashboard
    ) {
        if (address(factory) == address(0)) revert ZeroFactory();
        if (address(lidoLendOwner) == address(0)) revert ZeroLidoLendOwner();
        if (address(irmRouter) == address(0)) revert ZeroIrmRouter();

        address core = address(lidoLendOwner.LIDO_LEND());
        if (core == address(0)) revert ZeroCore();
        if (irmRouter.MORPHO() != core) revert CoreMismatch();

        FACTORY = factory;
        LIDO_LEND_OWNER = lidoLendOwner;
        IRM_ROUTER = irmRouter;
        CORE = core;
        RISK_STEWARD_DASHBOARD = riskStewardDashboard;
    }

    /// @notice Builds the controller and vault via `FACTORY`, wires every role to its final holder, and
    ///         self-checks the result with `validateMarketContracts` before returning. The result is inert: not
    ///         created on the core, not routed, not registered on any CircuitBreaker — those are the
    ///         activation step (governance / EasyTrack). Reverts on a zero `roles.admin` / `roles.proxyAdmin`,
    ///         when the market is already created on the core, or when `market.oracle` /
    ///         `market.guardianSignals` carries no code (zero or typo'd address).
    function buildMarketContracts(MarketSpec calldata market, MarketRoles calldata roles)
        external
        returns (MarketContracts memory built)
    {
        if (roles.admin == address(0)) revert ZeroAdmin();
        if (roles.proxyAdmin == address(0)) revert ZeroProxyAdmin();

        MarketParams memory params = MarketParams({
            loanToken: market.loanToken,
            collateralToken: market.collateralToken,
            oracle: market.oracle,
            irm: address(IRM_ROUTER),
            lltv: market.lltv
        });
        built.marketId = params.id();

        if (IMorpho(CORE).market(built.marketId).lastUpdate != 0) revert MarketAlreadyExists(built.marketId);

        if (market.oracle.code.length == 0) revert OracleNotContract();
        if (market.guardianSignals.code.length == 0) revert GuardianSignalsNotContract();

        (built.controller, built.vault) = FACTORY.deployMarketContracts(
            params,
            market.activationConfig,
            market.settlementConfig,
            market.guardianSignals,
            roles.proxyAdmin,
            market.vaultName,
            market.vaultSymbol
        );

        _grantRoles(built.controller, roles);
        validateMarketContracts(
            built.controller, built.vault, built.marketId, market.guardianSignals, address(this), roles
        );

        _emitMarketContractsDeployed(built, market.oracle, market.guardianSignals, roles);
    }

    function _grantRoles(address controller, MarketRoles calldata roles) internal {
        IReadController ctrl = IReadController(controller);

        _grantAll(controller, ctrl.MANAGER_ROLE(), roles.managers);
        // Domain risk-steward dashboard also holds MANAGER_ROLE so its tighten-only levers can write config.
        if (RISK_STEWARD_DASHBOARD != address(0)) {
            IAccessControl(controller).grantRole(ctrl.MANAGER_ROLE(), RISK_STEWARD_DASHBOARD);
        }
        _grantAll(controller, ctrl.PAUSER_ROLE(), roles.pausers);
        _grantAll(controller, ctrl.FREEZER_ROLE(), roles.freezers);
        _grantAll(controller, ctrl.UNFREEZER_ROLE(), roles.unfreezers);
        _grantAll(controller, ctrl.RESUMER_ROLE(), roles.resumers);
        IAccessControl(controller).grantRole(ctrl.DEFAULT_ADMIN_ROLE(), roles.admin);
        IAccessControl(controller).revokeRole(ctrl.DEFAULT_ADMIN_ROLE(), address(this));
    }

    /// @dev A zero holder can only be a config mistake, so it reverts rather than granting to `address(0)`.
    function _grantAll(address target, bytes32 role, address[] calldata holders) internal {
        for (uint256 i; i < holders.length; ++i) {
            if (holders[i] == address(0)) revert ZeroRoleHolder();
            IAccessControl(target).grantRole(role, holders[i]);
        }
    }

    /// @notice Builds a `GuardianSignals` registry via `FACTORY`, wires every role to its final holder, and
    ///         self-checks the result with `validateGuardianSignals` before returning. Always its own
    ///         transaction, run BEFORE the `buildMarketContracts` call that will reference the returned
    ///         address — `buildMarketContracts` never deploys or reuses a GuardianSignals instance on its
    ///         own initiative.
    function buildGuardianSignals(
        GuardianConfig calldata cfg,
        address admin,
        address[] calldata managers,
        address proxyAdmin
    ) external returns (address guardianSignals) {
        if (admin == address(0)) revert ZeroAdmin();
        if (proxyAdmin == address(0)) revert ZeroProxyAdmin();

        guardianSignals = FACTORY.deployGuardianSignals(proxyAdmin, cfg.guardians, cfg.quorum);
        _grantGuardianRoles(guardianSignals, admin, managers, cfg);

        validateGuardianSignals(guardianSignals, address(this), admin, proxyAdmin, managers, cfg);

        _emitGuardianSignalsDeployed(guardianSignals, admin, proxyAdmin, managers, cfg);
    }

    /// @dev Takes `MANAGER_ROLE` on itself transiently because `setSuspectWindow` is manager-gated, then drops
    ///      it before seeding the final holders.
    function _grantGuardianRoles(
        address guardianSignals,
        address admin,
        address[] calldata managers,
        GuardianConfig calldata cfg
    ) internal {
        IReadGuardianSignals gs = IReadGuardianSignals(guardianSignals);

        bytes32 managerRole = gs.MANAGER_ROLE();
        IAccessControl(guardianSignals).grantRole(managerRole, address(this));
        gs.setSuspectWindow(cfg.suspectWindow);
        IAccessControl(guardianSignals).revokeRole(managerRole, address(this));

        _grantAll(guardianSignals, managerRole, managers);
        _grantAll(guardianSignals, gs.ACCESS_RESTORER_ROLE(), managers);
        if (cfg.accessLimiter != address(0)) {
            IAccessControl(guardianSignals).grantRole(gs.ACCESS_LIMITER_ROLE(), cfg.accessLimiter);
        }
        IAccessControl(guardianSignals).grantRole(gs.DEFAULT_ADMIN_ROLE(), admin);
        IAccessControl(guardianSignals).revokeRole(gs.DEFAULT_ADMIN_ROLE(), address(this));
    }

    /// @dev Extracted so the emit doesn't push `buildGuardianSignals`'s frame past the `via_ir = false` limit.
    function _emitGuardianSignalsDeployed(
        address guardianSignals,
        address admin,
        address proxyAdmin,
        address[] calldata managers,
        GuardianConfig calldata cfg
    ) internal {
        emit GuardianSignalsDeployed(guardianSignals, admin, proxyAdmin, managers, cfg);
    }

    /// @dev Extracted so the emit doesn't push `buildMarketContracts`'s frame past the `via_ir = false` limit.
    function _emitMarketContractsDeployed(
        MarketContracts memory built,
        address oracle,
        address guardianSignals,
        MarketRoles calldata roles
    ) internal {
        emit MarketContractsDeployed(built.marketId, built.controller, built.vault, guardianSignals, oracle, roles);
    }

    // ---
    // VALIDATION (public view — see the contract NatSpec: reusable outside a build call)
    // ---

    /// @notice Reverts unless the deployed `controller` / `vault` match every expected impl, proxy admin,
    ///         binding, and role holder.
    function validateMarketContracts(
        address controller,
        address vault,
        Id marketId,
        address guardianSignals,
        address builder,
        MarketRoles calldata roles
    ) public view {
        _requireImplCodehash(controller, FACTORY.CONTROLLER_IMPL());
        _requireImplCodehash(vault, FACTORY.VAULT_IMPL());
        _requireProxyAdmin(controller, roles.proxyAdmin);
        _requireProxyAdmin(vault, roles.proxyAdmin);
        _validateBindings(controller, vault, marketId, guardianSignals);
        _validateRoles(controller, roles, builder);
    }

    function _validateBindings(address controller, address vault, Id marketId, address guardianSignals) internal view {
        Id controllerMarketId = IReadController(controller).marketId();
        if (Id.unwrap(controllerMarketId) != Id.unwrap(marketId)) {
            revert MarketIdMismatch(Id.unwrap(marketId), Id.unwrap(controllerMarketId));
        }

        address vaultController = IReadVault(vault).controller();
        if (vaultController != controller) revert VaultControllerMismatch(controller, vaultController);

        Id vaultMarketId = IReadVault(vault).marketId();
        if (Id.unwrap(vaultMarketId) != Id.unwrap(marketId)) {
            revert MarketIdMismatch(Id.unwrap(marketId), Id.unwrap(vaultMarketId));
        }

        address controllerGuardian = IReadController(controller).guardianSignals();
        if (controllerGuardian != guardianSignals) revert GuardianSignalsMismatch(guardianSignals, controllerGuardian);
    }

    function _validateRoles(address controller, MarketRoles calldata roles, address builder) internal view {
        IReadController ctrl = IReadController(controller);
        bytes32 adminRole = ctrl.DEFAULT_ADMIN_ROLE();

        _requireHas(controller, adminRole, roles.admin);
        _requireAllHave(controller, ctrl.MANAGER_ROLE(), roles.managers);
        _requireAllHave(controller, ctrl.PAUSER_ROLE(), roles.pausers);
        _requireAllHave(controller, ctrl.FREEZER_ROLE(), roles.freezers);
        _requireAllHave(controller, ctrl.UNFREEZER_ROLE(), roles.unfreezers);
        _requireAllHave(controller, ctrl.RESUMER_ROLE(), roles.resumers);

        // No leftover-MANAGER check here, unlike the guardian branch: on the controller the builder never
        // takes MANAGER transiently (only DEFAULT_ADMIN), so there is nothing to leak.
        _requireNotHolder(controller, adminRole, builder);
        _requireNotHolder(controller, adminRole, address(FACTORY));
    }

    /// @notice Reverts unless the deployed `guardianSignals` matches every expected impl, proxy admin, config,
    ///         and role holder. Its `managers` / `accessLimiter` completeness holds only at the tail of
    ///         `buildGuardianSignals` — see the contract NatSpec.
    function validateGuardianSignals(
        address guardianSignals,
        address builder,
        address admin,
        address proxyAdmin,
        address[] calldata managers,
        GuardianConfig calldata cfg
    ) public view {
        _requireImplCodehash(guardianSignals, FACTORY.GUARDIAN_SIGNALS_IMPL());
        _requireProxyAdmin(guardianSignals, proxyAdmin);
        _validateGuardianConfig(guardianSignals, cfg);
        _validateGuardianRoles(guardianSignals, admin, managers, cfg.accessLimiter, builder);
    }

    function _validateGuardianConfig(address guardianSignals, GuardianConfig calldata cfg) internal view {
        IReadGuardianSignals gs = IReadGuardianSignals(guardianSignals);

        uint256 quorum = gs.getQuorum();
        if (quorum != cfg.quorum) revert GuardianQuorumMismatch(cfg.quorum, quorum);

        uint256 suspectWindow = gs.getSuspectWindow();
        if (suspectWindow != cfg.suspectWindow) revert GuardianSuspectWindowMismatch(cfg.suspectWindow, suspectWindow);

        address[] memory actualGuardians = gs.getGuardians();
        if (actualGuardians.length != cfg.guardians.length) {
            revert GuardianSetSizeMismatch(cfg.guardians.length, actualGuardians.length);
        }
        for (uint256 i; i < cfg.guardians.length; ++i) {
            if (!gs.isGuardian(cfg.guardians[i])) revert MissingGuardian(cfg.guardians[i]);
        }
    }

    function _validateGuardianRoles(
        address guardianSignals,
        address admin,
        address[] calldata managers,
        address accessLimiter,
        address builder
    ) internal view {
        IReadGuardianSignals gs = IReadGuardianSignals(guardianSignals);

        bytes32 adminRole = gs.DEFAULT_ADMIN_ROLE();
        bytes32 managerRole = gs.MANAGER_ROLE();
        _requireHas(guardianSignals, adminRole, admin);
        _requireAllHave(guardianSignals, managerRole, managers);
        _requireAllHave(guardianSignals, gs.ACCESS_RESTORER_ROLE(), managers);
        if (accessLimiter != address(0)) _requireHas(guardianSignals, gs.ACCESS_LIMITER_ROLE(), accessLimiter);

        _requireNotHolder(guardianSignals, adminRole, builder);
        _requireNotHolder(guardianSignals, adminRole, address(FACTORY));
        // Leftover-MANAGER check: `_grantGuardianRoles` holds MANAGER transiently for `setSuspectWindow`, so a
        // forgotten revoke would slip past the DEFAULT_ADMIN-only checks above.
        _requireNotHolder(guardianSignals, managerRole, builder);
    }

    /// @dev Compares codehashes, not addresses: a redeploy of the exact same bytecode at a different address
    ///      must still pass, since it is the code — not the address — that the domain trusts.
    function _requireImplCodehash(address proxy, address expectedImpl) internal view {
        address actual = IReadProxy(proxy).proxy__getImplementation();
        if (actual.codehash != expectedImpl.codehash) {
            revert CodehashMismatch(proxy, expectedImpl.codehash, actual.codehash);
        }
    }

    function _requireProxyAdmin(address proxy, address expected) internal view {
        address actual = IReadProxy(proxy).proxy__getAdmin();
        if (actual != expected) revert ProxyAdminMismatch(proxy, expected, actual);
    }

    function _requireNotHolder(address target, bytes32 role, address account) internal view {
        if (IAccessControl(target).hasRole(role, account)) revert UnexpectedRoleHolder(target, role, account);
    }

    function _requireHas(address target, bytes32 role, address holder) internal view {
        if (!IAccessControl(target).hasRole(role, holder)) revert MissingRoleHolder(target, role, holder);
    }

    function _requireAllHave(address target, bytes32 role, address[] calldata holders) internal view {
        for (uint256 i; i < holders.length; ++i) {
            _requireHas(target, role, holders[i]);
        }
    }
}
