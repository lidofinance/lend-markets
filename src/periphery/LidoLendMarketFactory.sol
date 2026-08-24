// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

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

/// @title LidoLendMarketFactory
/// @author Lido Lending contributors.
/// @notice Deploys controllers, ERC-4626 wrappers, and guardian registries at fixed implementations, assigns their
///         final roles, and validates the resulting bindings. Market creation on the core remains a separate
///         governance action.
/// @dev The contract is permissionless and has no mutable storage. Role wiring:
///      - A new `LidoLendMarketController` or `GuardianSignals` instance grants the factory temporary
///        `DEFAULT_ADMIN_ROLE`.
///      - `LIDO_LEND_OWNER` receives `MANAGER_ROLE` and `UNFREEZER_ROLE` on `LidoLendMarketController`.
///      - `RISK_STEWARD_DASHBOARD` receives `MANAGER_ROLE` and `FREEZER_ROLE` on `LidoLendMarketController`.
///      - `CIRCUIT_BREAKER` receives `PAUSER_ROLE` on `LidoLendMarketController`; `RESUMER_ROLE` has no initial holder.
///      - `LIDO_LEND_OWNER` receives `MANAGER_ROLE` and `ACCESS_RESTORER_ROLE` on `GuardianSignals`.
///      - `ADMIN` administers every deployed proxy and receives `DEFAULT_ADMIN_ROLE` on both role-bearing contracts.
///      - `ACCESS_LIMITER_ROLE` on `GuardianSignals` has no initial holder.
///      - Every validated role, including `DEFAULT_ADMIN_ROLE` and roles without initial holders, is administered by
///        `DEFAULT_ADMIN_ROLE`.
///      - The factory revokes every temporary role before returning.
///      - ERC-4626 wrappers have no roles.
contract LidoLendMarketFactory {
    using MarketParamsLib for MarketParams;

    // ---
    // TYPES
    // ---

    /// @notice Fixed implementations used for every component deployed by the factory.
    /// @param controller Controller implementation bound to the configured core.
    /// @param erc4626Wrapper ERC-4626 wrapper implementation bound to the configured core.
    /// @param guardianSignals GuardianSignals implementation.
    struct Implementations {
        address controller;
        address erc4626Wrapper;
        address guardianSignals;
    }

    /// @notice Protocol-wide dependencies used when wiring deployed components.
    /// @param lidoLend Core against which component bindings are checked.
    /// @param irmRouter Router fixed as the IRM in every market id produced by the factory.
    /// @param lidoLendOwner Governance facade granted controller and guardian-management roles.
    /// @param circuitBreaker Sole initial controller pauser.
    /// @param riskStewardDashboard Bounded dashboard granted controller manager and freezer roles.
    struct Dependencies {
        address lidoLend;
        address irmRouter;
        address lidoLendOwner;
        address circuitBreaker;
        address riskStewardDashboard;
    }

    /// @notice Input for one controller and its LidoLend market id.
    /// @dev The market IRM is always `IRM_ROUTER` and therefore is not caller-supplied.
    /// @param loanToken Market loan asset.
    /// @param collateralToken Market collateral asset.
    /// @param oracle Market oracle contract. Deployment checks only that the address has code.
    /// @param lltv Liquidation loan-to-value ratio, in WAD and strictly below 1e18.
    /// @param guardianSignals Guardian registry read by the controller. Deployment checks only that the address has
    ///                        code; registry configuration is validated through `validateGuardianSignals`.
    /// @param activationConfig Initial collateral-activation configuration.
    /// @param settlementConfig Initial settlement configuration.
    struct MarketSpec {
        address loanToken;
        address collateralToken;
        address oracle;
        uint256 lltv;
        address guardianSignals;
        CollateralActivationConfig activationConfig;
        SettlementConfig settlementConfig;
    }

    /// @notice ERC-4626 metadata for a wrapper deployed over a market controller.
    /// @param name ERC-20 name of the wrapper shares.
    /// @param symbol ERC-20 symbol of the wrapper shares.
    struct ERC4626WrapperSpec {
        string name;
        string symbol;
    }

    /// @notice Initial membership and timing configuration for a guardian registry.
    /// @param guardians Exact initial guardian set; addresses must be nonzero and unique.
    /// @param quorum Number of distinct guardian flags required to latch a ban; between one and the guardian count.
    /// @param suspectWindow Duration for which a suspect report remains active, in seconds, bounded by the registry's
    ///                      maximum.
    struct GuardianSpec {
        address[] guardians;
        uint256 quorum;
        uint256 suspectWindow;
    }

    // ---
    // ERRORS
    // ---

    /// @notice A required market oracle or guardian-registry address has no code.
    /// @param account Address without runtime code.
    error NotContract(address account);

    /// @notice A component is bound to a different LidoLend core.
    /// @param component Component whose binding was queried.
    /// @param expected Core configured in the factory.
    /// @param actual Core reported by the component.
    error LidoLendMismatch(address component, address expected, address actual);

    /// @notice A market LLTV is not strictly below WAD.
    error InvalidLltv(uint256 lltv);

    /// @notice The market described by the deployment input already exists on the core.
    error MarketAlreadyExists(Id marketId);

    /// @notice An existing market is registered with a controller other than the one being validated.
    /// @param marketId Existing market whose registration was checked.
    /// @param expected Controller registered on the core.
    /// @param actual Controller supplied for validation.
    error RegisteredControllerMismatch(Id marketId, address expected, address actual);

    /// @notice A deployed proxy is administered by an address other than `ADMIN`.
    /// @param proxy Proxy whose admin was queried.
    /// @param expected Factory-wide `ADMIN`.
    /// @param actual Admin reported by the proxy.
    error ProxyAdminMismatch(address proxy, address expected, address actual);

    /// @notice A component's stored market id differs from the expected market id.
    /// @param expected Market id supplied for validation.
    /// @param actual Market id reported by the component.
    error MarketIdMismatch(bytes32 expected, bytes32 actual);

    /// @notice A controller is bound to an unexpected guardian registry.
    /// @param expected Guardian registry supplied for validation.
    /// @param actual Guardian registry reported by the controller.
    error ControllerGuardianMismatch(address expected, address actual);

    /// @notice An ERC-4626 wrapper is bound to an unexpected controller.
    /// @param expected Controller supplied for validation.
    /// @param actual Controller reported by the wrapper.
    error ERC4626WrapperControllerMismatch(address expected, address actual);

    /// @notice An ERC-4626 wrapper exposes an unexpected underlying asset.
    /// @param expected Loan token from the expected market parameters.
    /// @param actual Asset reported by the wrapper.
    error ERC4626WrapperAssetMismatch(address expected, address actual);

    /// @notice A guardian registry's quorum differs from the expected value.
    /// @param expected Quorum from the guardian specification.
    /// @param actual Quorum reported by the registry.
    error GuardianQuorumMismatch(uint256 expected, uint256 actual);

    /// @notice A guardian registry's suspect window differs from the expected value.
    /// @param expected Suspect window from the guardian specification.
    /// @param actual Suspect window reported by the registry.
    error GuardianSuspectWindowMismatch(uint256 expected, uint256 actual);

    /// @notice A guardian registry contains an unexpected number of guardians.
    /// @param expected Number of guardians in the guardian specification.
    /// @param actual Number of guardians reported by the registry.
    error GuardianCountMismatch(uint256 expected, uint256 actual);

    /// @notice The expected guardian list contains the same guardian more than once.
    error DuplicateGuardian(address guardian);

    /// @notice An expected guardian is absent from the registry.
    error MissingGuardian(address guardian);

    /// @notice An expected role holder is absent.
    /// @param target Role-bearing contract.
    /// @param role Role missing the required holder.
    /// @param account Required holder.
    error MissingRole(address target, bytes32 role, address account);

    /// @notice An account retains a role that the final topology excludes.
    /// @param target Role-bearing contract.
    /// @param role Role that must not be held.
    /// @param account Unexpected holder.
    error UnexpectedRole(address target, bytes32 role, address account);

    /// @notice A role has a different number of holders than the final topology requires.
    /// @param target Role-bearing contract.
    /// @param role Enumerated role.
    /// @param expected Required holder count.
    /// @param actual Enumerated holder count.
    error RoleMemberCountMismatch(address target, bytes32 role, uint256 expected, uint256 actual);

    /// @notice A role is administered by a role other than `DEFAULT_ADMIN_ROLE`.
    /// @param target Role-bearing contract.
    /// @param role Role whose administrator was queried.
    /// @param expected Required administrator role.
    /// @param actual Administrator role reported by the contract.
    error RoleAdminMismatch(address target, bytes32 role, bytes32 expected, bytes32 actual);

    // ---
    // EVENTS
    // ---

    /// @notice Emitted for every proxy the factory deploys, before the component behind it is configured or
    ///         validated.
    /// @param proxy Deployed proxy.
    /// @param implementation Implementation the proxy delegates to.
    /// @param admin Proxy admin the proxy is constructed with.
    /// @param initData Initialization call the proxy delegates to the implementation on construction.
    /// @param salt `CREATE2` salt the proxy was deployed under.
    event ProxyDeployed(
        address indexed proxy, address indexed implementation, address admin, bytes initData, bytes32 salt
    );

    /// @notice Emitted after a controller has been deployed, role-wired, and validated.
    /// @param marketId Market id bound to the controller.
    /// @param controller Deployed controller proxy.
    /// @param guardianSignals Existing guardian registry bound to the controller.
    event MarketControllerDeployed(Id indexed marketId, address indexed controller, address indexed guardianSignals);

    /// @notice Emitted after an ERC-4626 wrapper has been deployed and validated.
    /// @param marketId Market id cached by the wrapper.
    /// @param controller Controller bound to the wrapper.
    /// @param erc4626Wrapper Deployed wrapper proxy.
    event ERC4626WrapperDeployed(Id indexed marketId, address indexed controller, address indexed erc4626Wrapper);

    /// @notice Emitted after a controller and an ERC-4626 wrapper have been deployed together.
    /// @param marketId Market id shared by both components.
    /// @param controller Deployed controller proxy.
    /// @param erc4626Wrapper Deployed wrapper proxy.
    /// @param guardianSignals Existing guardian registry bound to the controller.
    event MarketComponentsDeployed(
        Id indexed marketId, address indexed controller, address indexed erc4626Wrapper, address guardianSignals
    );

    /// @notice Emitted after a guardian registry has been deployed, configured, role-wired, and validated.
    /// @param guardianSignals Deployed guardian-registry proxy.
    event GuardianSignalsDeployed(address indexed guardianSignals);

    // ---
    // CONSTANTS
    // ---

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @dev For a component whose every distinguishing field already reaches its initialization data, and which is
    ///      therefore never wanted twice over identical inputs.
    bytes32 private constant NO_CALLER_SALT = bytes32(0);

    // ---
    // IMMUTABLES
    // ---

    /// @notice Controller implementation used by every controller proxy deployed by the factory.
    address public immutable CONTROLLER_IMPL;
    /// @notice ERC-4626 implementation used by every wrapper proxy deployed by the factory.
    address public immutable ERC4626_WRAPPER_IMPL;
    /// @notice GuardianSignals implementation used by every guardian proxy deployed by the factory.
    address public immutable GUARDIAN_SIGNALS_IMPL;

    /// @notice Core expected by controller and wrapper implementations and core-bound dependencies.
    address public immutable LIDO_LEND;
    /// @notice IRM router embedded in every market id produced from a `MarketSpec`.
    address public immutable IRM_ROUTER;
    /// @notice Sole initial holder of every deployed controller's `PAUSER_ROLE`.
    address public immutable CIRCUIT_BREAKER;
    /// @notice Governance facade wired into every deployed controller and guardian registry.
    address public immutable LIDO_LEND_OWNER;
    /// @notice Bounded steward dashboard wired into every deployed controller.
    address public immutable RISK_STEWARD_DASHBOARD;

    /// @notice Admin of every deployed proxy and sole initial `DEFAULT_ADMIN_ROLE` holder on controllers and
    ///         guardian registries.
    address public immutable ADMIN;

    // ---
    // CONSTRUCTOR
    // ---

    /// @notice Fixes the implementations, protocol dependencies, and final administrator used by every deployment.
    /// @dev The factory deployer must validate all constructor addresses before deployment. The constructor verifies
    ///      only the core bindings exposed by the controller and wrapper implementations, owner facade, risk
    ///      dashboard, and IRM router.
    /// @param implementations Implementations used behind newly deployed proxies.
    /// @param dependencies Core and protocol-wide role recipients embedded in newly deployed components.
    /// @param admin Proxy admin for every deployment and sole initial `DEFAULT_ADMIN_ROLE` holder on controllers and
    ///              guardian registries.
    constructor(Implementations memory implementations, Dependencies memory dependencies, address admin) {
        _requireLidoLendBinding(implementations.erc4626Wrapper, dependencies.lidoLend);
        _requireLidoLendBinding(implementations.controller, dependencies.lidoLend);

        _requireLidoLendBinding(dependencies.lidoLendOwner, dependencies.lidoLend);
        _requireLidoLendBinding(dependencies.riskStewardDashboard, dependencies.lidoLend);
        _requireIrmRouterBinding(dependencies.irmRouter, dependencies.lidoLend);

        LIDO_LEND = dependencies.lidoLend;
        IRM_ROUTER = dependencies.irmRouter;
        CIRCUIT_BREAKER = dependencies.circuitBreaker;
        LIDO_LEND_OWNER = dependencies.lidoLendOwner;
        RISK_STEWARD_DASHBOARD = dependencies.riskStewardDashboard;

        ERC4626_WRAPPER_IMPL = implementations.erc4626Wrapper;
        CONTROLLER_IMPL = implementations.controller;
        GUARDIAN_SIGNALS_IMPL = implementations.guardianSignals;

        ADMIN = admin;
    }

    // ---
    // DEPLOYMENT
    // ---

    /// @notice Atomically deploys a controller and an ERC-4626 wrapper over it.
    /// @dev The components remain inert: this function does not create the market on the core or configure its IRM.
    /// @param market Market identity and initial controller configuration.
    /// @param wrapperSpec ERC-20 metadata for the wrapper shares.
    /// @return marketId Market id derived using the factory's fixed `IRM_ROUTER`.
    /// @return controller Deployed and role-wired controller proxy.
    /// @return erc4626Wrapper Deployed ERC-4626 wrapper proxy.
    function deployMarketComponents(MarketSpec calldata market, ERC4626WrapperSpec calldata wrapperSpec)
        external
        returns (Id marketId, address controller, address erc4626Wrapper)
    {
        MarketParams memory marketParams;
        (marketParams, marketId, controller) = _deployMarketController(market);
        erc4626Wrapper = _deployERC4626Wrapper(controller, marketId, marketParams, wrapperSpec);

        emit MarketComponentsDeployed(marketId, controller, erc4626Wrapper, market.guardianSignals);
    }

    /// @notice Deploys and fully role-wires a controller without deploying an ERC-4626 wrapper.
    /// @dev The controller remains inert until governance creates the market on the core.
    /// @param market Market identity and initial controller configuration.
    /// @return marketId Market id derived using the factory's fixed `IRM_ROUTER`.
    /// @return controller Deployed and role-wired controller proxy.
    function deployMarketController(MarketSpec calldata market) external returns (Id marketId, address controller) {
        (, marketId, controller) = _deployMarketController(market);
    }

    /// @notice Deploys an ERC-4626 wrapper for an existing or not-yet-activated controller.
    /// @dev The controller must use the same core and market id. If the market exists, it must be the controller
    ///      registered on the core.
    /// @param controller Controller the wrapper forwards market limits to.
    /// @param marketParams Exact market parameters cached by the wrapper.
    /// @param spec ERC-20 metadata for the wrapper shares.
    /// @return erc4626Wrapper Deployed ERC-4626 wrapper proxy.
    function deployERC4626Wrapper(
        address controller,
        MarketParams calldata marketParams,
        ERC4626WrapperSpec calldata spec
    ) external returns (address erc4626Wrapper) {
        Id marketId = marketParams.id();
        erc4626Wrapper = _deployERC4626Wrapper(controller, marketId, marketParams, spec);
    }

    /// @notice Deploys and fully role-wires a guardian registry that may be shared by multiple markets.
    /// @dev `suspectWindow` is applied after initialization and so does not reach the deployment address. Two
    ///      committees that differ only by it, or that are identical and still want registries of their own, are
    ///      separated by `salt`.
    /// @param spec Initial guardian membership, quorum, and suspect window.
    /// @param salt Caller-chosen label distinguishing registries this caller wants as separate instances.
    /// @return guardianSignalsAddress Deployed and role-wired guardian-registry proxy.
    function deployGuardianSignals(GuardianSpec calldata spec, bytes32 salt)
        external
        returns (address guardianSignalsAddress)
    {
        guardianSignalsAddress = _deployProxy(
            GUARDIAN_SIGNALS_IMPL,
            abi.encodeCall(GuardianSignals.initialize, (address(this), spec.guardians, spec.quorum)),
            salt
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
    // EXTERNAL VALIDATION
    // ---

    /// @notice Reverts unless `controller` is bound to the expected core, market, guardian registry, proxy admin,
    ///         canonical core registration when the market exists, and role topology.
    /// @dev Role topology covers exact holders and holder counts, and requires every known role to be administered
    ///      by `DEFAULT_ADMIN_ROLE`.
    /// @param controller Controller proxy to validate.
    /// @param marketId Expected market id.
    /// @param guardianSignals Expected guardian registry.
    function validateMarketController(address controller, Id marketId, address guardianSignals) external view {
        _validateMarketController(controller, marketId, guardianSignals);
    }

    /// @notice Reverts unless `erc4626Wrapper` has the expected core, market parameters, asset, controller, and
    ///         proxy admin.
    /// @dev The supplied controller is also validated against the core and market id, including canonical
    ///      registration when the market exists.
    /// @param erc4626Wrapper Wrapper proxy to validate.
    /// @param controller Expected controller.
    /// @param marketParams Expected market parameters.
    function validateERC4626Wrapper(address erc4626Wrapper, address controller, MarketParams calldata marketParams)
        external
        view
    {
        Id marketId = marketParams.id();
        _requireControllerBinding(controller, marketId);
        _validateERC4626Wrapper(erc4626Wrapper, controller, marketParams);
    }

    /// @notice Reverts unless `guardianSignals` has the expected config, proxy admin, and role topology.
    /// @dev Role topology covers exact holders and holder counts, and requires every known role to be administered
    ///      by `DEFAULT_ADMIN_ROLE`.
    /// @param guardianSignals Guardian-registry proxy to validate.
    /// @param spec Expected guardian membership, quorum, and suspect window.
    function validateGuardianSignals(address guardianSignals, GuardianSpec calldata spec) external view {
        _validateGuardianSignals(guardianSignals, spec);
    }

    // ---
    // DEPLOYMENT INPUT VALIDATION
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

    function _requireControllerBinding(address controllerAddress, Id marketId) private view {
        _requireLidoLendBinding(controllerAddress, LIDO_LEND);

        ILidoLendMarketController controller = ILidoLendMarketController(controllerAddress);
        _requireMarketIdMatch(marketId, controller.marketId());

        ILidoLend lidoLend = ILidoLend(LIDO_LEND);
        if (lidoLend.market(marketId).lastUpdate != 0) {
            address registeredController = lidoLend.marketController(marketId);
            if (registeredController != controllerAddress) {
                revert RegisteredControllerMismatch(marketId, registeredController, controllerAddress);
            }
        }
    }

    // ---
    // DEPLOYMENT INTERNALS
    // ---

    function _deployMarketController(MarketSpec calldata market)
        private
        returns (MarketParams memory marketParams, Id marketId, address controllerAddress)
    {
        (marketParams, marketId) = _validateMarketSpec(market);

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
            ),
            NO_CALLER_SALT
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

    function _deployERC4626Wrapper(
        address controller,
        Id marketId,
        MarketParams memory marketParams,
        ERC4626WrapperSpec calldata spec
    ) private returns (address erc4626Wrapper) {
        _requireControllerBinding(controller, marketId);

        erc4626Wrapper = _deployProxy(
            ERC4626_WRAPPER_IMPL,
            abi.encodeCall(LidoLendERC4626.initialize, (marketParams, controller, spec.name, spec.symbol)),
            NO_CALLER_SALT
        );

        _validateERC4626Wrapper(erc4626Wrapper, controller, marketParams);
        emit ERC4626WrapperDeployed(marketId, controller, erc4626Wrapper);
    }

    // ---
    // DEPLOYMENT RESULT VALIDATION
    // ---

    function _validateMarketController(address controllerAddress, Id marketId, address guardianSignals) private view {
        _requireControllerBinding(controllerAddress, marketId);

        // Proxy administration.
        _requireConfiguredProxyAdmin(controllerAddress);

        // Controller bindings fixed during initialization.
        ILidoLendMarketController controller = ILidoLendMarketController(controllerAddress);
        address actualGuardianSignals = controller.guardianSignals();
        if (actualGuardianSignals != guardianSignals) {
            revert ControllerGuardianMismatch(guardianSignals, actualGuardianSignals);
        }

        // The factory-wide admin must be the sole default admin.
        _requireSoleRoleMember(controllerAddress, DEFAULT_ADMIN_ROLE, ADMIN);

        // Governance and bounded steward management are the only manager paths.
        bytes32 managerRole = controller.MANAGER_ROLE();
        bytes32 pauserRole = controller.PAUSER_ROLE();
        bytes32 freezerRole = controller.FREEZER_ROLE();
        bytes32 unfreezerRole = controller.UNFREEZER_ROLE();
        bytes32 resumerRole = controller.RESUMER_ROLE();
        _requireRoleMemberCount(controllerAddress, managerRole, 2);
        _requireRoleMember(controllerAddress, managerRole, LIDO_LEND_OWNER);
        _requireRoleMember(controllerAddress, managerRole, RISK_STEWARD_DASHBOARD);

        // Fast controls have one fixed path each; finite pauses have no early resumer by default.
        _requireSoleRoleMember(controllerAddress, pauserRole, CIRCUIT_BREAKER);
        _requireSoleRoleMember(controllerAddress, freezerRole, RISK_STEWARD_DASHBOARD);
        _requireSoleRoleMember(controllerAddress, unfreezerRole, LIDO_LEND_OWNER);
        _requireRoleMemberCount(controllerAddress, resumerRole, 0);

        // Only the default admin may change the validated role topology.
        _requireDefaultRoleAdmin(controllerAddress, DEFAULT_ADMIN_ROLE);
        _requireDefaultRoleAdmin(controllerAddress, managerRole);
        _requireDefaultRoleAdmin(controllerAddress, pauserRole);
        _requireDefaultRoleAdmin(controllerAddress, freezerRole);
        _requireDefaultRoleAdmin(controllerAddress, unfreezerRole);
        _requireDefaultRoleAdmin(controllerAddress, resumerRole);

        _requireNotRoleMember(controllerAddress, DEFAULT_ADMIN_ROLE, address(this));
    }

    function _validateERC4626Wrapper(
        address wrapperAddress,
        address controllerAddress,
        MarketParams memory marketParams
    ) private view {
        _requireLidoLendBinding(wrapperAddress, LIDO_LEND);
        _requireConfiguredProxyAdmin(wrapperAddress);

        ILidoLendERC4626 wrapper = ILidoLendERC4626(wrapperAddress);
        Id marketId = marketParams.id();
        _requireMarketIdMatch(marketId, wrapper.marketId());
        _requireMarketIdMatch(marketId, wrapper.marketParams().id());

        address actualAsset = wrapper.asset();
        if (actualAsset != marketParams.loanToken) {
            revert ERC4626WrapperAssetMismatch(marketParams.loanToken, actualAsset);
        }

        address actualController = address(wrapper.controller());
        if (actualController != controllerAddress) {
            revert ERC4626WrapperControllerMismatch(controllerAddress, actualController);
        }
    }

    function _validateGuardianSignals(address guardianSignalsAddress, GuardianSpec calldata spec) private view {
        _requireUniqueGuardians(spec.guardians);
        _requireConfiguredProxyAdmin(guardianSignalsAddress);
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

        _requireSoleRoleMember(guardianSignalsAddress, DEFAULT_ADMIN_ROLE, ADMIN);
        _requireSoleRoleMember(guardianSignalsAddress, managerRole, LIDO_LEND_OWNER);
        _requireSoleRoleMember(guardianSignalsAddress, restorerRole, LIDO_LEND_OWNER);
        _requireRoleMemberCount(guardianSignalsAddress, limiterRole, 0);

        _requireDefaultRoleAdmin(guardianSignalsAddress, DEFAULT_ADMIN_ROLE);
        _requireDefaultRoleAdmin(guardianSignalsAddress, managerRole);
        _requireDefaultRoleAdmin(guardianSignalsAddress, restorerRole);
        _requireDefaultRoleAdmin(guardianSignalsAddress, limiterRole);

        _requireNotRoleMember(guardianSignalsAddress, DEFAULT_ADMIN_ROLE, address(this));
        _requireNotRoleMember(guardianSignalsAddress, managerRole, address(this));
    }

    // ---
    // VALIDATION HELPERS
    // ---

    function _requireLidoLendBinding(address component, address expectedLidoLend) private view {
        address actual = ILidoLendBound(component).LIDO_LEND();
        if (actual != expectedLidoLend) revert LidoLendMismatch(component, expectedLidoLend, actual);
    }

    function _requireIrmRouterBinding(address irmRouter, address expectedLidoLend) private view {
        address actual = IIrmRouter(irmRouter).MORPHO();
        if (actual != expectedLidoLend) revert LidoLendMismatch(irmRouter, expectedLidoLend, actual);
    }

    function _requireMarketIdMatch(Id expected, Id actual) private pure {
        if (Id.unwrap(actual) != Id.unwrap(expected)) {
            revert MarketIdMismatch(Id.unwrap(expected), Id.unwrap(actual));
        }
    }

    function _requireUniqueGuardians(address[] calldata guardians) private pure {
        for (uint256 i; i < guardians.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (guardians[i] == guardians[j]) revert DuplicateGuardian(guardians[i]);
            }
        }
    }

    function _requireConfiguredProxyAdmin(address proxy) private view {
        address actualAdmin = OssifiableProxy(payable(proxy)).proxy__getAdmin();
        if (actualAdmin != ADMIN) revert ProxyAdminMismatch(proxy, ADMIN, actualAdmin);
    }

    function _requireSoleRoleMember(address target, bytes32 role, address expectedMember) private view {
        _requireRoleMemberCount(target, role, 1);
        _requireRoleMember(target, role, expectedMember);
    }

    function _requireRoleMemberCount(address target, bytes32 role, uint256 expectedCount) private view {
        IAccessControlEnumerable access = IAccessControlEnumerable(target);
        uint256 actualCount = access.getRoleMemberCount(role);
        if (actualCount != expectedCount) revert RoleMemberCountMismatch(target, role, expectedCount, actualCount);
    }

    function _requireRoleMember(address target, bytes32 role, address account) private view {
        if (!IAccessControlEnumerable(target).hasRole(role, account)) revert MissingRole(target, role, account);
    }

    function _requireNotRoleMember(address target, bytes32 role, address account) private view {
        if (IAccessControlEnumerable(target).hasRole(role, account)) revert UnexpectedRole(target, role, account);
    }

    function _requireDefaultRoleAdmin(address target, bytes32 role) private view {
        bytes32 actualAdmin = IAccessControlEnumerable(target).getRoleAdmin(role);
        if (actualAdmin != DEFAULT_ADMIN_ROLE) {
            revert RoleAdminMismatch(target, role, DEFAULT_ADMIN_ROLE, actualAdmin);
        }
    }

    // ---
    // PROXY DEPLOYMENT
    // ---

    /// @dev `CREATE2` under a salt scoped to the caller, so a component's address is a pure function of this
    ///      factory, the deployer, and the data the component is initialized with. The deployer therefore knows the
    ///      address before sending the transaction and still finds the component there once mined, and no other
    ///      caller can occupy it. Plain `CREATE` would give neither: the address would follow the factory's
    ///      transaction count, which anyone can advance. `callerSalt` separates instances that initialize
    ///      identically; anything that already tells two components apart is part of `initData`, so it moves the
    ///      address on its own and needs no salt of its own.
    function _deployProxy(address implementation, bytes memory initData, bytes32 callerSalt)
        private
        returns (address proxy)
    {
        bytes32 salt = keccak256(abi.encode(msg.sender, callerSalt));
        proxy = address(new OssifiableProxy{salt: salt}(implementation, ADMIN, initData));
        emit ProxyDeployed(proxy, implementation, ADMIN, initData, salt);
    }
}
