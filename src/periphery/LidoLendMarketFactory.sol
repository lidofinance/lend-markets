// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {LidoLendMarketController} from "../controllers/LidoLendMarketController.sol";
import {GuardianSignals} from "../GuardianSignals.sol";
import {ILidoLendERC4626} from "../interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";
import {ILidoLendOwner} from "../interfaces/ILidoLendOwner.sol";
import {IGuardianSignals} from "../interfaces/IGuardianSignals.sol";
import {IGuardianSignalsView} from "../interfaces/IGuardianSignalsView.sol";
import {WAD} from "../libs/Constants.sol";
import {LidoLendERC4626} from "../LidoLendERC4626.sol";
import {OssifiableProxy} from "../proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../types/SettlementTypes.sol";

interface IIrmRouterView {
    function MORPHO() external view returns (address);
}

interface ICoreBound {
    function LIDO_LEND() external view returns (address);
}

interface IGuardianSignalsAdmin is IGuardianSignals, IAccessControlEnumerable {
    function MANAGER_ROLE() external view returns (bytes32);
    function ACCESS_RESTORER_ROLE() external view returns (bytes32);
    function ACCESS_LIMITER_ROLE() external view returns (bytes32);
}

/// @notice Deploys inert market components at fixed implementations, assigns their final roles, and validates the
///         resulting bindings. Market creation on the core remains a separate governance action.
/// @dev The contract is permissionless and stateless. It temporarily holds only a newly deployed component's
///      `DEFAULT_ADMIN_ROLE` during the same transaction, then removes itself before returning.
contract LidoLendMarketFactory {
    using MarketParamsLib for MarketParams;

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    address public immutable CONTROLLER_IMPL;
    address public immutable VAULT_IMPL;
    address public immutable GUARDIAN_SIGNALS_IMPL;

    ILidoLendOwner public immutable LIDO_LEND_OWNER;
    IIrmRouterView public immutable IRM_ROUTER;
    ILidoLend public immutable CORE;
    address public immutable RISK_STEWARD_DASHBOARD;

    struct Implementations {
        address controller;
        address vault;
        address guardianSignals;
    }

    struct MarketSpec {
        address loanToken;
        address collateralToken;
        address oracle;
        uint256 lltv;
        address guardianSignals;
        CollateralActivationConfig activationConfig;
        SettlementConfig settlementConfig;
    }

    struct MarketRoles {
        address admin;
        address proxyAdmin;
        /// @dev Additional holders; mandatory protocol holders are granted separately.
        address[] managers;
        address[] pausers;
        address[] freezers;
        /// @dev Additional holders; `LIDO_LEND_OWNER` is granted separately.
        address[] unfreezers;
        address[] resumers;
    }

    struct VaultSpec {
        address proxyAdmin;
        string name;
        string symbol;
    }

    struct MarketComponents {
        Id marketId;
        address controller;
        address vault;
    }

    struct GuardianSpec {
        address[] guardians;
        uint256 quorum;
        uint256 suspectWindow;
    }

    struct GuardianRoles {
        address admin;
        address proxyAdmin;
        /// @dev Additional holders of both `MANAGER_ROLE` and `ACCESS_RESTORER_ROLE`; `LIDO_LEND_OWNER` is granted
        ///      separately.
        address[] managers;
        address accessLimiter;
    }

    error ZeroAddress();
    error NotContract(address account);
    error CoreMismatch(address expected, address actual);
    error ImplementationCoreMismatch(address implementation, address expected, address actual);
    error InvalidLltv(uint256 lltv);
    error MarketAlreadyExists(Id marketId);
    error ZeroRoleHolder();
    error CodehashMismatch(address proxy, bytes32 expected, bytes32 actual);
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

    event MarketControllerDeployed(
        Id indexed marketId, address indexed controller, address indexed guardianSignals, address proxyAdmin
    );
    event VaultDeployed(Id indexed marketId, address indexed controller, address indexed vault, address proxyAdmin);
    event MarketComponentsDeployed(
        Id indexed marketId, address indexed controller, address indexed vault, address guardianSignals
    );
    event GuardianSignalsDeployed(address indexed guardianSignals, address indexed admin, address indexed proxyAdmin);

    constructor(
        Implementations memory implementations,
        ILidoLendOwner lidoLendOwner,
        IIrmRouterView irmRouter,
        address riskStewardDashboard
    ) {
        if (
            implementations.controller == address(0) || implementations.vault == address(0)
                || implementations.guardianSignals == address(0) || address(lidoLendOwner) == address(0)
                || address(irmRouter) == address(0)
        ) revert ZeroAddress();

        ILidoLend core = lidoLendOwner.LIDO_LEND();
        if (address(core) == address(0)) revert ZeroAddress();

        address routerCore = irmRouter.MORPHO();
        if (routerCore != address(core)) revert CoreMismatch(address(core), routerCore);
        _requireImplementationCore(implementations.controller, address(core));
        _requireImplementationCore(implementations.vault, address(core));

        CONTROLLER_IMPL = implementations.controller;
        VAULT_IMPL = implementations.vault;
        GUARDIAN_SIGNALS_IMPL = implementations.guardianSignals;

        LIDO_LEND_OWNER = lidoLendOwner;
        IRM_ROUTER = irmRouter;
        CORE = core;
        RISK_STEWARD_DASHBOARD = riskStewardDashboard;
    }

    /// @notice Deploys and fully role-wires a controller without deploying an ERC-4626 vault.
    function deployMarketController(MarketSpec calldata market, MarketRoles calldata roles)
        external
        returns (Id marketId, address controller)
    {
        MarketParams memory marketParams = _marketParams(market);
        _validateMarketControllerInput(marketParams, market, roles);
        (marketId, controller) = _deployMarketController(marketParams, market, roles);
    }

    /// @notice Deploys an ERC-4626 vault for an existing or not-yet-activated controller.
    function deployVault(
        ILidoLendMarketController controller,
        MarketParams calldata marketParams,
        VaultSpec calldata spec
    ) external returns (address vault) {
        _validateVaultSpec(spec);
        vault = _deployVault(controller, marketParams, spec);
    }

    /// @notice Atomically deploys a controller and the first ERC-4626 vault over it.
    function deployMarketComponents(
        MarketSpec calldata market,
        MarketRoles calldata roles,
        VaultSpec calldata vaultSpec
    ) external returns (MarketComponents memory components) {
        MarketParams memory marketParams = _marketParams(market);
        _validateMarketControllerInput(marketParams, market, roles);
        _validateVaultSpec(vaultSpec);

        (components.marketId, components.controller) = _deployMarketController(marketParams, market, roles);
        components.vault = _deployVault(ILidoLendMarketController(components.controller), marketParams, vaultSpec);

        emit MarketComponentsDeployed(
            components.marketId, components.controller, components.vault, market.guardianSignals
        );
    }

    /// @notice Deploys and fully role-wires a guardian registry that may be shared by multiple markets.
    function deployGuardianSignals(GuardianSpec calldata spec, GuardianRoles calldata roles)
        external
        returns (address guardianSignals)
    {
        _validateGuardianInput(spec, roles);

        guardianSignals = _deployProxy(
            GUARDIAN_SIGNALS_IMPL,
            roles.proxyAdmin,
            abi.encodeCall(GuardianSignals.initialize, (address(this), spec.guardians, spec.quorum))
        );

        _wireGuardianRoles(IGuardianSignalsAdmin(guardianSignals), spec, roles);
        _validateGuardianSignals(guardianSignals, spec, roles);

        emit GuardianSignalsDeployed(guardianSignals, roles.admin, roles.proxyAdmin);
    }

    /// @notice Reverts unless `controller` has the expected implementation, binding, proxy admin, and roles.
    function validateMarketController(
        address controller,
        Id marketId,
        address guardianSignals,
        MarketRoles calldata roles
    ) external view {
        _validateMarketRoles(roles);
        _validateMarketController(controller, marketId, guardianSignals, roles);
    }

    /// @notice Reverts unless `vault` has the expected implementation, binding, and proxy admin.
    function validateVault(
        address vault,
        ILidoLendMarketController controller,
        MarketParams calldata marketParams,
        VaultSpec calldata spec
    ) external view {
        _validateVaultSpec(spec);
        _validateVaultBinding(controller, marketParams);
        _validateVault(vault, controller, marketParams, spec);
    }

    /// @notice Reverts unless `guardianSignals` has the expected implementation, config, proxy admin, and roles.
    function validateGuardianSignals(address guardianSignals, GuardianSpec calldata spec, GuardianRoles calldata roles)
        external
        view
    {
        _validateGuardianInput(spec, roles);
        _validateGuardianSignals(guardianSignals, spec, roles);
    }

    function _marketParams(MarketSpec calldata market) private view returns (MarketParams memory marketParams) {
        marketParams = MarketParams({
            loanToken: market.loanToken,
            collateralToken: market.collateralToken,
            oracle: market.oracle,
            irm: address(IRM_ROUTER),
            lltv: market.lltv
        });
    }

    function _deployMarketController(
        MarketParams memory marketParams,
        MarketSpec calldata market,
        MarketRoles calldata roles
    ) private returns (Id marketId, address controller) {
        marketId = marketParams.id();
        controller = _deployProxy(
            CONTROLLER_IMPL,
            roles.proxyAdmin,
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

        _wireMarketRoles(ILidoLendMarketController(controller), roles);
        _validateMarketController(controller, marketId, market.guardianSignals, roles);

        emit MarketControllerDeployed(marketId, controller, market.guardianSignals, roles.proxyAdmin);
    }

    function _deployVault(
        ILidoLendMarketController controller,
        MarketParams memory marketParams,
        VaultSpec calldata spec
    ) private returns (address vault) {
        _validateVaultBinding(controller, marketParams);

        vault = _deployProxy(
            VAULT_IMPL,
            spec.proxyAdmin,
            abi.encodeCall(LidoLendERC4626.initialize, (marketParams, address(controller), spec.name, spec.symbol))
        );

        _validateVault(vault, controller, marketParams, spec);
        emit VaultDeployed(controller.marketId(), address(controller), vault, spec.proxyAdmin);
    }

    function _wireMarketRoles(ILidoLendMarketController controller, MarketRoles calldata roles) private {
        _grantAll(controller, controller.MANAGER_ROLE(), roles.managers);
        controller.grantRole(controller.MANAGER_ROLE(), address(LIDO_LEND_OWNER));
        controller.grantRole(controller.UNFREEZER_ROLE(), address(LIDO_LEND_OWNER));
        if (RISK_STEWARD_DASHBOARD != address(0)) {
            controller.grantRole(controller.MANAGER_ROLE(), RISK_STEWARD_DASHBOARD);
        }

        _grantAll(controller, controller.PAUSER_ROLE(), roles.pausers);
        _grantAll(controller, controller.FREEZER_ROLE(), roles.freezers);
        _grantAll(controller, controller.UNFREEZER_ROLE(), roles.unfreezers);
        _grantAll(controller, controller.RESUMER_ROLE(), roles.resumers);

        controller.grantRole(DEFAULT_ADMIN_ROLE, roles.admin);
        controller.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    function _wireGuardianRoles(
        IGuardianSignalsAdmin guardianSignals,
        GuardianSpec calldata spec,
        GuardianRoles calldata roles
    ) private {
        bytes32 managerRole = guardianSignals.MANAGER_ROLE();
        bytes32 restorerRole = guardianSignals.ACCESS_RESTORER_ROLE();

        guardianSignals.grantRole(managerRole, address(this));
        guardianSignals.setSuspectWindow(spec.suspectWindow);
        guardianSignals.revokeRole(managerRole, address(this));

        _grantAll(guardianSignals, managerRole, roles.managers);
        _grantAll(guardianSignals, restorerRole, roles.managers);
        guardianSignals.grantRole(managerRole, address(LIDO_LEND_OWNER));
        guardianSignals.grantRole(restorerRole, address(LIDO_LEND_OWNER));
        if (roles.accessLimiter != address(0)) {
            guardianSignals.grantRole(guardianSignals.ACCESS_LIMITER_ROLE(), roles.accessLimiter);
        }

        guardianSignals.grantRole(DEFAULT_ADMIN_ROLE, roles.admin);
        guardianSignals.revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    function _grantAll(IAccessControlEnumerable access, bytes32 role, address[] calldata holders) private {
        for (uint256 i; i < holders.length; ++i) {
            if (holders[i] == address(0)) revert ZeroRoleHolder();
            access.grantRole(role, holders[i]);
        }
    }

    function _validateMarketControllerInput(
        MarketParams memory marketParams,
        MarketSpec calldata market,
        MarketRoles calldata roles
    ) private view {
        _validateMarketRoles(roles);
        if (market.lltv >= WAD) revert InvalidLltv(market.lltv);

        Id marketId = marketParams.id();
        if (CORE.market(marketId).lastUpdate != 0) revert MarketAlreadyExists(marketId);

        if (market.oracle.code.length == 0) revert NotContract(market.oracle);
        if (market.guardianSignals.code.length == 0) revert NotContract(market.guardianSignals);
    }

    function _validateMarketRoles(MarketRoles calldata roles) private pure {
        if (roles.admin == address(0) || roles.proxyAdmin == address(0)) revert ZeroAddress();
    }

    function _validateVaultSpec(VaultSpec calldata spec) private pure {
        if (spec.proxyAdmin == address(0)) revert ZeroAddress();
    }

    function _validateVaultBinding(ILidoLendMarketController controller, MarketParams memory marketParams)
        private
        view
    {
        _requireImplCodehash(address(controller), CONTROLLER_IMPL);

        Id expected = marketParams.id();
        Id actual = controller.marketId();
        if (Id.unwrap(actual) != Id.unwrap(expected)) {
            revert MarketIdMismatch(Id.unwrap(expected), Id.unwrap(actual));
        }
    }

    function _validateGuardianInput(GuardianSpec calldata, GuardianRoles calldata roles) private pure {
        if (roles.admin == address(0) || roles.proxyAdmin == address(0)) revert ZeroAddress();
    }

    function _validateMarketController(
        address controllerAddress,
        Id marketId,
        address guardianSignals,
        MarketRoles calldata roles
    ) private view {
        _requireProxyBinding(controllerAddress, CONTROLLER_IMPL, roles.proxyAdmin);
        _requireImplCodehash(guardianSignals, GUARDIAN_SIGNALS_IMPL);

        ILidoLendMarketController controller = ILidoLendMarketController(controllerAddress);
        Id actualMarketId = controller.marketId();
        if (Id.unwrap(actualMarketId) != Id.unwrap(marketId)) {
            revert MarketIdMismatch(Id.unwrap(marketId), Id.unwrap(actualMarketId));
        }

        address actualGuardianSignals = controller.guardianSignals();
        if (actualGuardianSignals != guardianSignals) {
            revert ControllerGuardianMismatch(guardianSignals, actualGuardianSignals);
        }

        IAccessControlEnumerable access = IAccessControlEnumerable(controllerAddress);
        _requireExactRoleHolder(access, DEFAULT_ADMIN_ROLE, roles.admin);

        bytes32 managerRole = controller.MANAGER_ROLE();
        uint256 managerCount = _uniqueHolderCount(roles.managers);
        if (!_contains(roles.managers, address(LIDO_LEND_OWNER))) ++managerCount;
        if (
            RISK_STEWARD_DASHBOARD != address(0) && RISK_STEWARD_DASHBOARD != address(LIDO_LEND_OWNER)
                && !_contains(roles.managers, RISK_STEWARD_DASHBOARD)
        ) ++managerCount;
        _requireRoleMemberCount(access, managerRole, managerCount);
        _requireAllRoles(access, managerRole, roles.managers);
        _requireRole(access, managerRole, address(LIDO_LEND_OWNER));
        if (RISK_STEWARD_DASHBOARD != address(0)) _requireRole(access, managerRole, RISK_STEWARD_DASHBOARD);

        _requireExactRoleHolders(access, controller.PAUSER_ROLE(), roles.pausers);
        _requireExactRoleHolders(access, controller.FREEZER_ROLE(), roles.freezers);

        bytes32 unfreezerRole = controller.UNFREEZER_ROLE();
        uint256 unfreezerCount = _uniqueHolderCount(roles.unfreezers);
        if (!_contains(roles.unfreezers, address(LIDO_LEND_OWNER))) ++unfreezerCount;
        _requireRoleMemberCount(access, unfreezerRole, unfreezerCount);
        _requireAllRoles(access, unfreezerRole, roles.unfreezers);
        _requireRole(access, unfreezerRole, address(LIDO_LEND_OWNER));

        _requireExactRoleHolders(access, controller.RESUMER_ROLE(), roles.resumers);
        _requireNotHolder(access, DEFAULT_ADMIN_ROLE, address(this));
    }

    function _validateVault(
        address vaultAddress,
        ILidoLendMarketController controller,
        MarketParams memory marketParams,
        VaultSpec calldata spec
    ) private view {
        _requireProxyBinding(vaultAddress, VAULT_IMPL, spec.proxyAdmin);

        ILidoLendERC4626 vault = ILidoLendERC4626(vaultAddress);
        Id expectedMarketId = marketParams.id();
        Id actualMarketId = vault.marketId();
        if (Id.unwrap(actualMarketId) != Id.unwrap(expectedMarketId)) {
            revert MarketIdMismatch(Id.unwrap(expectedMarketId), Id.unwrap(actualMarketId));
        }

        address actualController = address(vault.controller());
        if (actualController != address(controller)) {
            revert VaultControllerMismatch(address(controller), actualController);
        }
    }

    function _validateGuardianSignals(
        address guardianSignalsAddress,
        GuardianSpec calldata spec,
        GuardianRoles calldata roles
    ) private view {
        _requireProxyBinding(guardianSignalsAddress, GUARDIAN_SIGNALS_IMPL, roles.proxyAdmin);
        IGuardianSignalsAdmin guardianSignals = IGuardianSignalsAdmin(guardianSignalsAddress);

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

        _requireExactRoleHolder(guardianSignals, DEFAULT_ADMIN_ROLE, roles.admin);

        uint256 governanceRoleCount = _uniqueHolderCount(roles.managers);
        if (!_contains(roles.managers, address(LIDO_LEND_OWNER))) ++governanceRoleCount;
        _requireRoleMemberCount(guardianSignals, managerRole, governanceRoleCount);
        _requireAllRoles(guardianSignals, managerRole, roles.managers);
        _requireRole(guardianSignals, managerRole, address(LIDO_LEND_OWNER));

        _requireRoleMemberCount(guardianSignals, restorerRole, governanceRoleCount);
        _requireAllRoles(guardianSignals, restorerRole, roles.managers);
        _requireRole(guardianSignals, restorerRole, address(LIDO_LEND_OWNER));

        if (roles.accessLimiter == address(0)) _requireRoleMemberCount(guardianSignals, limiterRole, 0);
        else _requireExactRoleHolder(guardianSignals, limiterRole, roles.accessLimiter);

        _requireNotHolder(guardianSignals, DEFAULT_ADMIN_ROLE, address(this));
        _requireNotHolder(guardianSignals, managerRole, address(this));
    }

    function _requireProxyBinding(address proxy, address implementation, address proxyAdmin) private view {
        _requireImplCodehash(proxy, implementation);
        address actualAdmin = OssifiableProxy(payable(proxy)).proxy__getAdmin();
        if (actualAdmin != proxyAdmin) revert ProxyAdminMismatch(proxy, proxyAdmin, actualAdmin);
    }

    /// @dev Trusts the implementation's runtime code, not its deployment address or the proxy's runtime code.
    function _requireImplCodehash(address proxy, address implementation) private view {
        address actualImplementation = OssifiableProxy(payable(proxy)).proxy__getImplementation();
        bytes32 expectedCodehash = implementation.codehash;
        bytes32 actualCodehash = actualImplementation.codehash;
        if (actualCodehash != expectedCodehash) revert CodehashMismatch(proxy, expectedCodehash, actualCodehash);
    }

    function _requireImplementationCore(address implementation, address expectedCore) private view {
        address actualCore = ICoreBound(implementation).LIDO_LEND();
        if (actualCore != expectedCore) revert ImplementationCoreMismatch(implementation, expectedCore, actualCore);
    }

    function _requireExactRoleHolders(IAccessControlEnumerable access, bytes32 role, address[] calldata expectedHolders)
        private
        view
    {
        _requireRoleMemberCount(access, role, _uniqueHolderCount(expectedHolders));
        _requireAllRoles(access, role, expectedHolders);
    }

    function _requireExactRoleHolder(IAccessControlEnumerable access, bytes32 role, address expectedHolder)
        private
        view
    {
        _requireRoleMemberCount(access, role, 1);
        _requireRole(access, role, expectedHolder);
    }

    function _requireRoleMemberCount(IAccessControlEnumerable access, bytes32 role, uint256 expectedCount)
        private
        view
    {
        uint256 actualCount = access.getRoleMemberCount(role);
        if (actualCount != expectedCount) {
            revert RoleMemberCountMismatch(address(access), role, expectedCount, actualCount);
        }
    }

    function _requireRole(IAccessControlEnumerable access, bytes32 role, address account) private view {
        if (!access.hasRole(role, account)) revert MissingRole(address(access), role, account);
    }

    function _requireNotHolder(IAccessControlEnumerable access, bytes32 role, address account) private view {
        if (access.hasRole(role, account)) revert UnexpectedRole(address(access), role, account);
    }

    function _requireAllRoles(IAccessControlEnumerable access, bytes32 role, address[] calldata accounts) private view {
        for (uint256 i; i < accounts.length; ++i) {
            _requireRole(access, role, accounts[i]);
        }
    }

    function _uniqueHolderCount(address[] calldata holders) private pure returns (uint256 count) {
        for (uint256 i; i < holders.length; ++i) {
            bool seen;
            for (uint256 j; j < i; ++j) {
                if (holders[j] == holders[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) ++count;
        }
    }

    function _contains(address[] calldata holders, address account) private pure returns (bool) {
        for (uint256 i; i < holders.length; ++i) {
            if (holders[i] == account) return true;
        }
        return false;
    }

    function _deployProxy(address implementation, address proxyAdmin, bytes memory initData)
        private
        returns (address proxy)
    {
        proxy = address(new OssifiableProxy(implementation, proxyAdmin, initData));
    }
}
