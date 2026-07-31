// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {IIrmRouter} from "@lido-lend-irm/src/irm-router/interfaces/IIrmRouter.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {LidoLendMarketController} from "../controllers/LidoLendMarketController.sol";
import {GuardianSignals} from "../GuardianSignals.sol";
import {IGuardianSignals} from "../interfaces/IGuardianSignals.sol";
import {IGuardianSignalsView} from "../interfaces/IGuardianSignalsView.sol";
import {ILidoLendERC4626} from "../interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";
import {WAD} from "../libs/Constants.sol";
import {LidoLendERC4626} from "../LidoLendERC4626.sol";
import {OssifiableProxy} from "../proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../types/SettlementTypes.sol";

interface ILidoLendBound {
    function LIDO_LEND() external view returns (address);
}

/// @notice Deploys inert market components at fixed implementations, assigns their final roles, and validates the
///         resulting bindings. Market creation on the core remains a separate governance action.
/// @dev The contract is permissionless and stateless. Role wiring:
///      - A new controller or guardian registry grants the factory temporary `DEFAULT_ADMIN_ROLE`.
///      - `LIDO_LEND_OWNER` receives controller `MANAGER_ROLE` and `UNFREEZER_ROLE`.
///      - `RISK_STEWARD_DASHBOARD` receives controller `MANAGER_ROLE` and `FREEZER_ROLE`.
///      - `CIRCUIT_BREAKER` receives controller `PAUSER_ROLE`; no initial holder receives `RESUMER_ROLE`.
///      - `LIDO_LEND_OWNER` receives guardian `MANAGER_ROLE` and `ACCESS_RESTORER_ROLE`.
///      - `ADMIN` administers every deployed proxy and receives controller and guardian `DEFAULT_ADMIN_ROLE`.
///      - `ACCESS_LIMITER_ROLE` has no initial holder.
///      - The factory revokes every temporary role before returning.
///      - Vaults have no roles.
contract LidoLendMarketFactory {
    using MarketParamsLib for MarketParams;

    // ---
    // TYPES
    // ---

    /// @notice Fixed implementations used for every component deployed by the factory.
    struct Implementations {
        address controller;
        address vault;
        address guardianSignals;
    }

    /// @notice Protocol-wide dependencies shared by every component deployed by the factory.
    struct Dependencies {
        address lidoLend;
        address irmRouter;
        address lidoLendOwner;
        address circuitBreaker;
        address riskStewardDashboard;
    }

    /// @notice Complete input for one controller and its LidoLend market id.
    struct MarketSpec {
        address loanToken;
        address collateralToken;
        address oracle;
        uint256 lltv;
        address guardianSignals;
        CollateralActivationConfig activationConfig;
        SettlementConfig settlementConfig;
    }

    /// @notice ERC-4626 metadata for a vault deployed over a market controller.
    struct VaultSpec {
        string name;
        string symbol;
    }

    /// @notice Initial membership and timing configuration for a guardian registry.
    struct GuardianSpec {
        address[] guardians;
        uint256 quorum;
        uint256 suspectWindow;
    }

    /// @notice Controller and first vault deployed for one inert market.
    struct MarketComponents {
        Id marketId;
        address controller;
        address vault;
    }

    // ---
    // ERRORS
    // ---

    error NotContract(address account);
    error LidoLendMismatch(address component, address expected, address actual);
    error InvalidLltv(uint256 lltv);
    error MarketAlreadyExists(Id marketId);
    error RegisteredControllerMismatch(Id marketId, address expected, address actual);
    error ProxyAdminMismatch(address proxy, address expected, address actual);
    error MarketIdMismatch(bytes32 expected, bytes32 actual);
    error ControllerGuardianMismatch(address expected, address actual);
    error VaultControllerMismatch(address expected, address actual);
    error GuardianQuorumMismatch(uint256 expected, uint256 actual);
    error GuardianSuspectWindowMismatch(uint256 expected, uint256 actual);
    error GuardianCountMismatch(uint256 expected, uint256 actual);
    error MissingGuardian(address guardian);
    error MissingRole(address target, bytes32 role, address account);
    error UnexpectedRole(address target, bytes32 role, address account);
    error RoleMemberCountMismatch(address target, bytes32 role, uint256 expected, uint256 actual);

    // ---
    // EVENTS
    // ---

    event MarketControllerDeployed(Id indexed marketId, address indexed controller, address indexed guardianSignals);
    event VaultDeployed(Id indexed marketId, address indexed controller, address indexed vault);
    event MarketComponentsDeployed(
        Id indexed marketId, address indexed controller, address indexed vault, address guardianSignals
    );
    event GuardianSignalsDeployed(address indexed guardianSignals);

    // ---
    // CONSTANTS
    // ---

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    // ---
    // IMMUTABLES
    // ---

    /// @notice Controller implementation used by every controller proxy deployed by the factory.
    address public immutable CONTROLLER_IMPL;
    /// @notice ERC-4626 implementation used by every vault proxy deployed by the factory.
    address public immutable VAULT_IMPL;
    /// @notice GuardianSignals implementation used by every guardian proxy deployed by the factory.
    address public immutable GUARDIAN_SIGNALS_IMPL;

    /// @notice Core shared by the factory's implementations and protocol dependencies.
    address public immutable LIDO_LEND;
    /// @notice IRM router embedded in every market id produced from a `MarketSpec`.
    address public immutable IRM_ROUTER;
    /// @notice Sole initial holder of every deployed controller's `PAUSER_ROLE`.
    address public immutable CIRCUIT_BREAKER;
    /// @notice Governance facade wired into every deployed controller and guardian registry.
    address public immutable LIDO_LEND_OWNER;
    /// @notice Bounded steward dashboard wired into every deployed controller.
    address public immutable RISK_STEWARD_DASHBOARD;

    /// @notice Proxy admin and sole initial `DEFAULT_ADMIN_ROLE` holder for deployed components.
    address public immutable ADMIN;

    // ---
    // CONSTRUCTOR
    // ---

    /// @dev Zero-address and code-presence checks are intentionally omitted. Deployment tooling is responsible for
    ///      validating inputs; the constructor only verifies that core-bound components reference `lidoLend`.
    constructor(Implementations memory implementations, Dependencies memory dependencies, address admin) {
        _requireLidoLend(dependencies.lidoLend, implementations.vault);
        _requireLidoLend(dependencies.lidoLend, implementations.controller);

        _requireLidoLend(dependencies.lidoLend, dependencies.lidoLendOwner);
        _requireLidoLend(dependencies.lidoLend, dependencies.riskStewardDashboard);

        address routerCore = IIrmRouter(dependencies.irmRouter).MORPHO();
        if (dependencies.lidoLend != routerCore) {
            revert LidoLendMismatch(dependencies.irmRouter, dependencies.lidoLend, routerCore);
        }


        LIDO_LEND = dependencies.lidoLend;
        IRM_ROUTER = dependencies.irmRouter;
        CIRCUIT_BREAKER = dependencies.circuitBreaker;
        LIDO_LEND_OWNER = dependencies.lidoLendOwner;
        RISK_STEWARD_DASHBOARD = dependencies.riskStewardDashboard;

        VAULT_IMPL = implementations.vault;
        CONTROLLER_IMPL = implementations.controller;
        GUARDIAN_SIGNALS_IMPL = implementations.guardianSignals;

        ADMIN = admin;
    }

    // ---
    // DEPLOYMENT
    // ---

    /// @notice Atomically deploys a controller and the first ERC-4626 vault over it.
    function deployMarketComponents(MarketSpec calldata market, VaultSpec calldata vaultSpec)
        external
        returns (MarketComponents memory components)
    {
        MarketParams memory marketParams;
        (marketParams, components.marketId) = _validateMarketSpec(market);

        components.controller = _deployMarketController(components.marketId, marketParams, market);
        components.vault = _deployVault(components.controller, components.marketId, marketParams, vaultSpec);

        emit MarketComponentsDeployed(
            components.marketId, components.controller, components.vault, market.guardianSignals
        );
    }

    /// @notice Deploys and fully role-wires a controller without deploying an ERC-4626 vault.
    function deployMarketController(MarketSpec calldata market) external returns (Id marketId, address controller) {
        MarketParams memory marketParams;
        (marketParams, marketId) = _validateMarketSpec(market);
        controller = _deployMarketController(marketId, marketParams, market);
    }

    /// @notice Deploys an ERC-4626 vault for an existing or not-yet-activated controller.
    function deployVault(address controller, MarketParams calldata marketParams, VaultSpec calldata spec)
        external
        returns (address vault)
    {
        Id marketId = marketParams.id();
        vault = _deployVault(controller, marketId, marketParams, spec);
    }

    /// @notice Deploys and fully role-wires a guardian registry that may be shared by multiple markets.
    function deployGuardianSignals(GuardianSpec calldata spec) external returns (address guardianSignalsAddress) {
        guardianSignalsAddress = _deployProxy(
            GUARDIAN_SIGNALS_IMPL,
            abi.encodeCall(GuardianSignals.initialize, (address(this), spec.guardians, spec.quorum))
        );

        IGuardianSignals guardianSignals = IGuardianSignals(guardianSignalsAddress);

        bytes32 managerRole = guardianSignals.MANAGER_ROLE();
        bytes32 restorerRole = guardianSignals.ACCESS_RESTORER_ROLE();

        guardianSignals.grantRole(managerRole, address(this));
        guardianSignals.setSuspectWindow(spec.suspectWindow);
        guardianSignals.revokeRole(managerRole, address(this));

        guardianSignals.grantRole(managerRole, LIDO_LEND_OWNER);
        guardianSignals.grantRole(restorerRole, LIDO_LEND_OWNER);

        guardianSignals.grantRole(DEFAULT_ADMIN_ROLE, ADMIN);
        guardianSignals.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        _validateGuardianSignals(guardianSignalsAddress, spec);

        emit GuardianSignalsDeployed(guardianSignalsAddress);
    }

    // ---
    // VALIDATION
    // ---

    /// @notice Reverts unless `controller` has the expected binding, proxy admin, and roles.
    function validateMarketController(address controller, Id marketId, address guardianSignals) external view {
        _validateMarketController(controller, marketId, guardianSignals);
    }

    /// @notice Reverts unless `vault` has the expected binding and proxy admin.
    function validateVault(address vault, address controller, MarketParams calldata marketParams) external view {
        Id marketId = marketParams.id();
        _validateVaultBinding(controller, marketId);
        _validateVault(vault, controller, marketId);
    }

    /// @notice Reverts unless `guardianSignals` has the expected config, proxy admin, and roles.
    function validateGuardianSignals(address guardianSignals, GuardianSpec calldata spec) external view {
        _validateGuardianSignals(guardianSignals, spec);
    }

    // ---
    // INPUT VALIDATION
    // ---

    function _validateMarketSpec(MarketSpec calldata market)
        private
        view
        returns (MarketParams memory marketParams, Id marketId)
    {
        marketParams = MarketParams({
            loanToken: market.loanToken,
            collateralToken: market.collateralToken,
            oracle: market.oracle,
            irm: IRM_ROUTER,
            lltv: market.lltv
        });

        if (market.lltv >= WAD) revert InvalidLltv(market.lltv);

        marketId = marketParams.id();
        if (ILidoLend(LIDO_LEND).market(marketId).lastUpdate != 0) revert MarketAlreadyExists(marketId);

        if (market.oracle.code.length == 0) revert NotContract(market.oracle);
        if (market.guardianSignals.code.length == 0) revert NotContract(market.guardianSignals);
    }

    // ---
    // DEPLOYMENT INTERNALS
    // ---

    function _deployMarketController(Id marketId, MarketParams memory marketParams, MarketSpec calldata market)
        private
        returns (address controllerAddress)
    {
        controllerAddress = _deployProxy(
            CONTROLLER_IMPL,
            abi.encodeCall(
                LidoLendMarketController.initialize,
                (
                    marketId,
                    address(this),
                    IGuardianSignalsView(market.guardianSignals),
                    market.activationConfig,
                    market.settlementConfig
                )
            )
        );

        ILidoLendMarketController controller = ILidoLendMarketController(controllerAddress);
        controller.grantRole(controller.MANAGER_ROLE(), LIDO_LEND_OWNER);
        controller.grantRole(controller.MANAGER_ROLE(), RISK_STEWARD_DASHBOARD);
        controller.grantRole(controller.PAUSER_ROLE(), CIRCUIT_BREAKER);
        controller.grantRole(controller.FREEZER_ROLE(), RISK_STEWARD_DASHBOARD);
        controller.grantRole(controller.UNFREEZER_ROLE(), LIDO_LEND_OWNER);

        controller.grantRole(DEFAULT_ADMIN_ROLE, ADMIN);
        controller.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        _validateMarketController(controllerAddress, marketId, market.guardianSignals);

        emit MarketControllerDeployed(marketId, controllerAddress, market.guardianSignals);
    }

    function _deployVault(address controller, Id marketId, MarketParams memory marketParams, VaultSpec calldata spec)
        private
        returns (address vault)
    {
        _validateVaultBinding(controller, marketId);

        vault = _deployProxy(
            VAULT_IMPL, abi.encodeCall(LidoLendERC4626.initialize, (marketParams, controller, spec.name, spec.symbol))
        );

        _validateVault(vault, controller, marketId);
        emit VaultDeployed(marketId, controller, vault);
    }

    // ---
    // COMPONENT VALIDATION
    // ---

    function _validateVaultBinding(address controllerAddress, Id marketId) private view {
        _requireLidoLend(LIDO_LEND, controllerAddress);

        ILidoLendMarketController controller = ILidoLendMarketController(controllerAddress);
        Id actual = controller.marketId();
        if (Id.unwrap(actual) != Id.unwrap(marketId)) {
            revert MarketIdMismatch(Id.unwrap(marketId), Id.unwrap(actual));
        }

        ILidoLend lidoLend = ILidoLend(LIDO_LEND);
        if (lidoLend.market(marketId).lastUpdate != 0) {
            address registeredController = lidoLend.marketController(marketId);
            if (registeredController != controllerAddress) {
                revert RegisteredControllerMismatch(marketId, registeredController, controllerAddress);
            }
        }
    }

    function _validateMarketController(address controllerAddress, Id marketId, address guardianSignals) private view {
        // Proxy administration.
        _requireProxyAdmin(controllerAddress);

        // Controller bindings fixed during initialization.
        ILidoLendMarketController controller = ILidoLendMarketController(controllerAddress);
        Id actualMarketId = controller.marketId();
        if (Id.unwrap(actualMarketId) != Id.unwrap(marketId)) {
            revert MarketIdMismatch(Id.unwrap(marketId), Id.unwrap(actualMarketId));
        }

        address actualGuardianSignals = controller.guardianSignals();
        if (actualGuardianSignals != guardianSignals) {
            revert ControllerGuardianMismatch(guardianSignals, actualGuardianSignals);
        }

        // The factory-wide admin must be the sole default admin.
        _requireExactRoleHolder(controllerAddress, DEFAULT_ADMIN_ROLE, ADMIN);

        // Governance and bounded steward management are the only manager paths.
        bytes32 managerRole = controller.MANAGER_ROLE();
        _requireRoleMemberCount(controllerAddress, managerRole, 2);
        _requireRole(controllerAddress, managerRole, LIDO_LEND_OWNER);
        _requireRole(controllerAddress, managerRole, RISK_STEWARD_DASHBOARD);

        // Fast controls have one fixed path each; finite pauses have no early resumer by default.
        _requireExactRoleHolder(controllerAddress, controller.PAUSER_ROLE(), CIRCUIT_BREAKER);
        _requireExactRoleHolder(controllerAddress, controller.FREEZER_ROLE(), RISK_STEWARD_DASHBOARD);
        _requireExactRoleHolder(controllerAddress, controller.UNFREEZER_ROLE(), LIDO_LEND_OWNER);
        _requireRoleMemberCount(controllerAddress, controller.RESUMER_ROLE(), 0);
        _requireNotHolder(controllerAddress, DEFAULT_ADMIN_ROLE, address(this));
    }

    function _validateVault(address vaultAddress, address controllerAddress, Id marketId) private view {
        _requireProxyAdmin(vaultAddress);

        ILidoLendERC4626 vault = ILidoLendERC4626(vaultAddress);
        Id actualMarketId = vault.marketId();
        if (Id.unwrap(actualMarketId) != Id.unwrap(marketId)) {
            revert MarketIdMismatch(Id.unwrap(marketId), Id.unwrap(actualMarketId));
        }

        address actualController = address(vault.controller());
        if (actualController != controllerAddress) {
            revert VaultControllerMismatch(controllerAddress, actualController);
        }
    }

    function _validateGuardianSignals(address guardianSignalsAddress, GuardianSpec calldata spec) private view {
        _requireProxyAdmin(guardianSignalsAddress);
        IGuardianSignals guardianSignals = IGuardianSignals(guardianSignalsAddress);

        uint256 actualQuorum = guardianSignals.getQuorum();
        if (actualQuorum != spec.quorum) revert GuardianQuorumMismatch(spec.quorum, actualQuorum);

        uint256 actualSuspectWindow = guardianSignals.getSuspectWindow();
        if (actualSuspectWindow != spec.suspectWindow) {
            revert GuardianSuspectWindowMismatch(spec.suspectWindow, actualSuspectWindow);
        }

        uint256 actualCount = guardianSignals.getGuardianCount();
        if (actualCount != spec.guardians.length) revert GuardianCountMismatch(spec.guardians.length, actualCount);
        for (uint256 i; i < spec.guardians.length; ++i) {
            if (!guardianSignals.isGuardian(spec.guardians[i])) revert MissingGuardian(spec.guardians[i]);
        }

        bytes32 managerRole = guardianSignals.MANAGER_ROLE();
        bytes32 restorerRole = guardianSignals.ACCESS_RESTORER_ROLE();
        bytes32 limiterRole = guardianSignals.ACCESS_LIMITER_ROLE();

        _requireExactRoleHolder(guardianSignalsAddress, DEFAULT_ADMIN_ROLE, ADMIN);

        _requireExactRoleHolder(guardianSignalsAddress, managerRole, LIDO_LEND_OWNER);
        _requireExactRoleHolder(guardianSignalsAddress, restorerRole, LIDO_LEND_OWNER);
        _requireRoleMemberCount(guardianSignalsAddress, limiterRole, 0);

        _requireNotHolder(guardianSignalsAddress, DEFAULT_ADMIN_ROLE, address(this));
        _requireNotHolder(guardianSignalsAddress, managerRole, address(this));
    }

    // ---
    // VALIDATION HELPERS
    // ---

    function _requireLidoLend(address lidoLend, address component) private view {
        address actual = ILidoLendBound(component).LIDO_LEND();
        if (actual != lidoLend) revert LidoLendMismatch(component, lidoLend, actual);
    }

    function _requireProxyAdmin(address proxy) private view {
        address actualAdmin = OssifiableProxy(payable(proxy)).proxy__getAdmin();
        if (actualAdmin != ADMIN) revert ProxyAdminMismatch(proxy, ADMIN, actualAdmin);
    }

    function _requireExactRoleHolder(address target, bytes32 role, address expectedHolder) private view {
        _requireRoleMemberCount(target, role, 1);
        _requireRole(target, role, expectedHolder);
    }

    function _requireRoleMemberCount(address target, bytes32 role, uint256 expectedCount) private view {
        IAccessControlEnumerable access = IAccessControlEnumerable(target);
        uint256 actualCount = access.getRoleMemberCount(role);
        if (actualCount != expectedCount) revert RoleMemberCountMismatch(target, role, expectedCount, actualCount);
    }

    function _requireRole(address target, bytes32 role, address account) private view {
        if (!IAccessControlEnumerable(target).hasRole(role, account)) revert MissingRole(target, role, account);
    }

    function _requireNotHolder(address target, bytes32 role, address account) private view {
        if (IAccessControlEnumerable(target).hasRole(role, account)) revert UnexpectedRole(target, role, account);
    }

    // ---
    // PROXY DEPLOYMENT
    // ---

    function _deployProxy(address implementation, bytes memory initData) private returns (address proxy) {
        proxy = address(new OssifiableProxy(implementation, ADMIN, initData));
    }
}
