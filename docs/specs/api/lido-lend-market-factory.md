<!-- GENERATED FROM NatSpec by tools/gen_api_from_artifacts.py — do not edit by hand; run `make doc`. -->

# LidoLendMarketFactory

Deploys controllers, ERC-4626 wrappers, and guardian registries at fixed implementations, assigns their final roles, and validates the resulting bindings. Market creation on the core remains a separate governance action.

The contract is permissionless and has no mutable storage. Role wiring:

- A new `LidoLendMarketController` or `GuardianSignals` instance grants the factory temporary `DEFAULT_ADMIN_ROLE`.
- `LIDO_LEND_OWNER` receives `MANAGER_ROLE` and `UNFREEZER_ROLE` on `LidoLendMarketController`.
- `RISK_STEWARD_DASHBOARD` receives `MANAGER_ROLE` and `FREEZER_ROLE` on `LidoLendMarketController`.
- `CIRCUIT_BREAKER` receives `PAUSER_ROLE` on `LidoLendMarketController`; `RESUMER_ROLE` has no initial holder.
- `LIDO_LEND_OWNER` receives `MANAGER_ROLE` and `ACCESS_RESTORER_ROLE` on `GuardianSignals`.
- `ADMIN` administers every deployed proxy and receives `DEFAULT_ADMIN_ROLE` on both role-bearing contracts.
- `ACCESS_LIMITER_ROLE` on `GuardianSignals` has no initial holder.
- Every validated role, including `DEFAULT_ADMIN_ROLE` and roles without initial holders, is administered by `DEFAULT_ADMIN_ROLE`.
- The factory revokes every temporary role before returning.
- ERC-4626 wrappers have no roles.

## Structs

### `Implementations`

```solidity
struct Implementations {
    address controller;
    address erc4626Wrapper;
    address guardianSignals;
}
```

Fixed implementations used for every component deployed by the factory.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `controller` | `address` | Controller implementation bound to the configured core. |
| `erc4626Wrapper` | `address` | ERC-4626 wrapper implementation bound to the configured core. |
| `guardianSignals` | `address` | GuardianSignals implementation. |

### `Dependencies`

```solidity
struct Dependencies {
    address lidoLend;
    address irmRouter;
    address lidoLendOwner;
    address circuitBreaker;
    address riskStewardDashboard;
}
```

Protocol-wide dependencies used when wiring deployed components.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `lidoLend` | `address` | Core against which component bindings are checked. |
| `irmRouter` | `address` | Router fixed as the IRM in every market id produced by the factory. |
| `lidoLendOwner` | `address` | Governance facade granted controller and guardian-management roles. |
| `circuitBreaker` | `address` | Sole initial controller pauser. |
| `riskStewardDashboard` | `address` | Bounded dashboard granted controller manager and freezer roles. |

### `MarketSpec`

```solidity
struct MarketSpec {
    address loanToken;
    address collateralToken;
    address oracle;
    uint256 lltv;
    address guardianSignals;
    CollateralActivationConfig activationConfig;
    SettlementConfig settlementConfig;
}
```

Input for one controller and its LidoLend market id.

The market IRM is always `IRM_ROUTER` and therefore is not caller-supplied.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `loanToken` | `address` | Market loan asset. |
| `collateralToken` | `address` | Market collateral asset. |
| `oracle` | `address` | Market oracle contract. Deployment checks only that the address has code. |
| `lltv` | `uint256` | Liquidation loan-to-value ratio, in WAD and strictly below 1e18. |
| `guardianSignals` | `address` | Guardian registry read by the controller. Deployment checks only that the address has code; registry configuration is validated through `validateGuardianSignals`. |
| `activationConfig` | `CollateralActivationConfig` | Initial collateral-activation configuration. |
| `settlementConfig` | `SettlementConfig` | Initial settlement configuration. |

### `ERC4626WrapperSpec`

```solidity
struct ERC4626WrapperSpec {
    string name;
    string symbol;
}
```

ERC-4626 metadata for a wrapper deployed over a market controller.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `name` | `string` | ERC-20 name of the wrapper shares. |
| `symbol` | `string` | ERC-20 symbol of the wrapper shares. |

### `GuardianSpec`

```solidity
struct GuardianSpec {
    address[] guardians;
    uint256 quorum;
    uint256 suspectWindow;
}
```

Initial membership and timing configuration for a guardian registry.

**Fields**

| Name | Type | Description |
| --- | --- | --- |
| `guardians` | `address[]` | Exact initial guardian set; addresses must be nonzero and unique. |
| `quorum` | `uint256` | Number of distinct guardian flags required to latch a ban; between one and the guardian count. |
| `suspectWindow` | `uint256` | Duration for which a suspect report remains active, in seconds, bounded by the registry's maximum. |

## Events

### `ProxyDeployed`

```solidity
event ProxyDeployed(address indexed proxy, address indexed implementation, address admin, bytes initData, bytes32 salt);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `proxy` | `address` | Deployed proxy. |
| `implementation` | `address` | Implementation the proxy delegates to. |
| `admin` | `address` | Proxy admin the proxy is constructed with. |
| `initData` | `bytes` | Initialization call the proxy delegates to the implementation on construction. |
| `salt` | `bytes32` | `CREATE2` salt the proxy was deployed under. |

Emitted for every proxy the factory deploys, before the component behind it is configured or validated.

### `MarketControllerDeployed`

```solidity
event MarketControllerDeployed(Id indexed marketId, address indexed controller, address indexed guardianSignals);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | Market id bound to the controller. |
| `controller` | `address` | Deployed controller proxy. |
| `guardianSignals` | `address` | Existing guardian registry bound to the controller. |

Emitted after a controller has been deployed, role-wired, and validated.

### `ERC4626WrapperDeployed`

```solidity
event ERC4626WrapperDeployed(Id indexed marketId, address indexed controller, address indexed erc4626Wrapper);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | Market id cached by the wrapper. |
| `controller` | `address` | Controller bound to the wrapper. |
| `erc4626Wrapper` | `address` | Deployed wrapper proxy. |

Emitted after an ERC-4626 wrapper has been deployed and validated.

### `MarketComponentsDeployed`

```solidity
event MarketComponentsDeployed(Id indexed marketId, address indexed controller, address indexed erc4626Wrapper, address guardianSignals);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | Market id shared by both components. |
| `controller` | `address` | Deployed controller proxy. |
| `erc4626Wrapper` | `address` | Deployed wrapper proxy. |
| `guardianSignals` | `address` | Existing guardian registry bound to the controller. |

Emitted after a controller and an ERC-4626 wrapper have been deployed together.

### `GuardianSignalsDeployed`

```solidity
event GuardianSignalsDeployed(address indexed guardianSignals);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardianSignals` | `address` | Deployed guardian-registry proxy. |

Emitted after a guardian registry has been deployed, configured, role-wired, and validated.

## Errors

### `NotContract`

```solidity
error NotContract(address account);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `account` | `address` | Address without runtime code. |

A required market oracle or guardian-registry address has no code.

### `LidoLendMismatch`

```solidity
error LidoLendMismatch(address component, address expected, address actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `component` | `address` | Component whose binding was queried. |
| `expected` | `address` | Core configured in the factory. |
| `actual` | `address` | Core reported by the component. |

A component is bound to a different LidoLend core.

### `InvalidLltv`

```solidity
error InvalidLltv(uint256 lltv);
```

A market LLTV is not strictly below WAD.

### `MarketAlreadyExists`

```solidity
error MarketAlreadyExists(Id marketId);
```

The market described by the deployment input already exists on the core.

### `RegisteredControllerMismatch`

```solidity
error RegisteredControllerMismatch(Id marketId, address expected, address actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | Existing market whose registration was checked. |
| `expected` | `address` | Controller registered on the core. |
| `actual` | `address` | Controller supplied for validation. |

An existing market is registered with a controller other than the one being validated.

### `ProxyAdminMismatch`

```solidity
error ProxyAdminMismatch(address proxy, address expected, address actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `proxy` | `address` | Proxy whose admin was queried. |
| `expected` | `address` | Factory-wide `ADMIN`. |
| `actual` | `address` | Admin reported by the proxy. |

A deployed proxy is administered by an address other than `ADMIN`.

### `MarketIdMismatch`

```solidity
error MarketIdMismatch(bytes32 expected, bytes32 actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `expected` | `bytes32` | Market id supplied for validation. |
| `actual` | `bytes32` | Market id reported by the component. |

A component's stored market id differs from the expected market id.

### `ControllerGuardianMismatch`

```solidity
error ControllerGuardianMismatch(address expected, address actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `expected` | `address` | Guardian registry supplied for validation. |
| `actual` | `address` | Guardian registry reported by the controller. |

A controller is bound to an unexpected guardian registry.

### `ERC4626WrapperControllerMismatch`

```solidity
error ERC4626WrapperControllerMismatch(address expected, address actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `expected` | `address` | Controller supplied for validation. |
| `actual` | `address` | Controller reported by the wrapper. |

An ERC-4626 wrapper is bound to an unexpected controller.

### `ERC4626WrapperAssetMismatch`

```solidity
error ERC4626WrapperAssetMismatch(address expected, address actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `expected` | `address` | Loan token from the expected market parameters. |
| `actual` | `address` | Asset reported by the wrapper. |

An ERC-4626 wrapper exposes an unexpected underlying asset.

### `GuardianQuorumMismatch`

```solidity
error GuardianQuorumMismatch(uint256 expected, uint256 actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `expected` | `uint256` | Quorum from the guardian specification. |
| `actual` | `uint256` | Quorum reported by the registry. |

A guardian registry's quorum differs from the expected value.

### `GuardianSuspectWindowMismatch`

```solidity
error GuardianSuspectWindowMismatch(uint256 expected, uint256 actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `expected` | `uint256` | Suspect window from the guardian specification. |
| `actual` | `uint256` | Suspect window reported by the registry. |

A guardian registry's suspect window differs from the expected value.

### `GuardianCountMismatch`

```solidity
error GuardianCountMismatch(uint256 expected, uint256 actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `expected` | `uint256` | Number of guardians in the guardian specification. |
| `actual` | `uint256` | Number of guardians reported by the registry. |

A guardian registry contains an unexpected number of guardians.

### `DuplicateGuardian`

```solidity
error DuplicateGuardian(address guardian);
```

The expected guardian list contains the same guardian more than once.

### `MissingGuardian`

```solidity
error MissingGuardian(address guardian);
```

An expected guardian is absent from the registry.

### `MissingRole`

```solidity
error MissingRole(address target, bytes32 role, address account);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `target` | `address` | Role-bearing contract. |
| `role` | `bytes32` | Role missing the required holder. |
| `account` | `address` | Required holder. |

An expected role holder is absent.

### `UnexpectedRole`

```solidity
error UnexpectedRole(address target, bytes32 role, address account);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `target` | `address` | Role-bearing contract. |
| `role` | `bytes32` | Role that must not be held. |
| `account` | `address` | Unexpected holder. |

An account retains a role that the final topology excludes.

### `RoleMemberCountMismatch`

```solidity
error RoleMemberCountMismatch(address target, bytes32 role, uint256 expected, uint256 actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `target` | `address` | Role-bearing contract. |
| `role` | `bytes32` | Enumerated role. |
| `expected` | `uint256` | Required holder count. |
| `actual` | `uint256` | Enumerated holder count. |

A role has a different number of holders than the final topology requires.

### `RoleAdminMismatch`

```solidity
error RoleAdminMismatch(address target, bytes32 role, bytes32 expected, bytes32 actual);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `target` | `address` | Role-bearing contract. |
| `role` | `bytes32` | Role whose administrator was queried. |
| `expected` | `bytes32` | Required administrator role. |
| `actual` | `bytes32` | Administrator role reported by the contract. |

A role is administered by a role other than `DEFAULT_ADMIN_ROLE`.

## Functions

### `constructor`

```solidity
constructor(
    Implementations memory implementations,
    Dependencies memory dependencies,
    address admin
);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `implementations` | `Implementations` | Implementations used behind newly deployed proxies. |
| `dependencies` | `Dependencies` | Core and protocol-wide role recipients embedded in newly deployed components. |
| `admin` | `address` | Proxy admin for every deployment and sole initial `DEFAULT_ADMIN_ROLE` holder on controllers and guardian registries. |

Fixes the implementations, protocol dependencies, and final administrator used by every deployment.

The factory deployer must validate all constructor addresses before deployment. The constructor verifies only the core bindings exposed by the controller and wrapper implementations, owner facade, risk dashboard, and IRM router.

### `deployMarketComponents`

```solidity
function deployMarketComponents(
    MarketSpec calldata market,
    ERC4626WrapperSpec calldata wrapperSpec
) external returns (Id marketId, address controller, address erc4626Wrapper);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `market` | `MarketSpec` | Market identity and initial controller configuration. |
| `wrapperSpec` | `ERC4626WrapperSpec` | ERC-20 metadata for the wrapper shares. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | Market id derived using the factory's fixed `IRM_ROUTER`. |
| `controller` | `address` | Deployed and role-wired controller proxy. |
| `erc4626Wrapper` | `address` | Deployed ERC-4626 wrapper proxy. |

Atomically deploys a controller and an ERC-4626 wrapper over it.

The components remain inert: this function does not create the market on the core or configure its IRM.

### `deployMarketController`

```solidity
function deployMarketController(
    MarketSpec calldata market
) external returns (Id marketId, address controller);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `market` | `MarketSpec` | Market identity and initial controller configuration. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `marketId` | `Id` | Market id derived using the factory's fixed `IRM_ROUTER`. |
| `controller` | `address` | Deployed and role-wired controller proxy. |

Deploys and fully role-wires a controller without deploying an ERC-4626 wrapper.

The controller remains inert until governance creates the market on the core.

### `deployERC4626Wrapper`

```solidity
function deployERC4626Wrapper(
    address controller,
    MarketParams calldata marketParams,
    ERC4626WrapperSpec calldata spec
) external returns (address erc4626Wrapper);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `controller` | `address` | Controller the wrapper forwards market limits to. |
| `marketParams` | `MarketParams` | Exact market parameters cached by the wrapper. |
| `spec` | `ERC4626WrapperSpec` | ERC-20 metadata for the wrapper shares. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `erc4626Wrapper` | `address` | Deployed ERC-4626 wrapper proxy. |

Deploys an ERC-4626 wrapper for an existing or not-yet-activated controller.

The controller must use the same core and market id. If the market exists, it must be the controller registered on the core.

### `deployGuardianSignals`

```solidity
function deployGuardianSignals(
    GuardianSpec calldata spec,
    bytes32 salt
) external returns (address guardianSignalsAddress);
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `spec` | `GuardianSpec` | Initial guardian membership, quorum, and suspect window. |
| `salt` | `bytes32` | Caller-chosen label distinguishing registries this caller wants as separate instances. |

**Returns**

| Name | Type | Description |
| --- | --- | --- |
| `guardianSignalsAddress` | `address` | Deployed and role-wired guardian-registry proxy. |

Deploys and fully role-wires a guardian registry that may be shared by multiple markets.

`suspectWindow` is applied after initialization and so does not reach the deployment address. Two committees that differ only by it, or that are identical and still want registries of their own, are separated by `salt`.

### `validateMarketController`

```solidity
function validateMarketController(
    address controller,
    Id marketId,
    address guardianSignals
) external view;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `controller` | `address` | Controller proxy to validate. |
| `marketId` | `Id` | Expected market id. |
| `guardianSignals` | `address` | Expected guardian registry. |

Reverts unless `controller` is bound to the expected core, market, guardian registry, proxy admin, canonical core registration when the market exists, and role topology.

Role topology covers exact holders and holder counts, and requires every known role to be administered by `DEFAULT_ADMIN_ROLE`.

### `validateERC4626Wrapper`

```solidity
function validateERC4626Wrapper(
    address erc4626Wrapper,
    address controller,
    MarketParams calldata marketParams
) external view;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `erc4626Wrapper` | `address` | Wrapper proxy to validate. |
| `controller` | `address` | Expected controller. |
| `marketParams` | `MarketParams` | Expected market parameters. |

Reverts unless `erc4626Wrapper` has the expected core, market parameters, asset, controller, and proxy admin.

The supplied controller is also validated against the core and market id, including canonical registration when the market exists.

### `validateGuardianSignals`

```solidity
function validateGuardianSignals(
    address guardianSignals,
    GuardianSpec calldata spec
) external view;
```

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `guardianSignals` | `address` | Guardian-registry proxy to validate. |
| `spec` | `GuardianSpec` | Expected guardian membership, quorum, and suspect window. |

Reverts unless `guardianSignals` has the expected config, proxy admin, and role topology.

Role topology covers exact holders and holder counts, and requires every known role to be administered by `DEFAULT_ADMIN_ROLE`.

## State variables

| Name | Type | Description |
| --- | --- | --- |
| `CONTROLLER_IMPL` | `address` (immutable) | Controller implementation used by every controller proxy deployed by the factory. |
| `ERC4626_WRAPPER_IMPL` | `address` (immutable) | ERC-4626 implementation used by every wrapper proxy deployed by the factory. |
| `GUARDIAN_SIGNALS_IMPL` | `address` (immutable) | GuardianSignals implementation used by every guardian proxy deployed by the factory. |
| `LIDO_LEND` | `address` (immutable) | Core expected by controller and wrapper implementations and core-bound dependencies. |
| `IRM_ROUTER` | `address` (immutable) | IRM router embedded in every market id produced from a `MarketSpec`. |
| `CIRCUIT_BREAKER` | `address` (immutable) | Sole initial holder of every deployed controller's `PAUSER_ROLE`. |
| `LIDO_LEND_OWNER` | `address` (immutable) | Governance facade wired into every deployed controller and guardian registry. |
| `RISK_STEWARD_DASHBOARD` | `address` (immutable) | Bounded steward dashboard wired into every deployed controller. |
| `ADMIN` | `address` (immutable) | Admin of every deployed proxy and sole initial `DEFAULT_ADMIN_ROLE` holder on controllers and guardian registries. |
