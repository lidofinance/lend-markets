// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {LidoLendMarketController} from "../controllers/LidoLendMarketController.sol";
import {LidoLendERC4626} from "../LidoLendERC4626.sol";
import {GuardianSignals} from "../GuardianSignals.sol";
import {IGuardianSignalsView} from "../interfaces/IGuardianSignalsView.sol";
import {OssifiableProxy} from "../proxy/OssifiableProxy.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../types/SettlementTypes.sol";

/// @notice Bare-construction layer: deploys a market's controller + vault, a standalone vault, or a
///         GuardianSignals instance, each behind an `OssifiableProxy` at the shared impl. No pre-checks and no
///         role policy — `msg.sender` gets the controller's / instance's `DEFAULT_ADMIN_ROLE`, and the caller
///         (`LidoLendMarketBuilder`) owns everything else.
/// @dev Draft, not audited. Immutable, no versioning: a controller/vault/GuardianSignals ABI change needs a
///      new factory + a new `LidoLendMarketBuilder` (its validators read the expected impls from here). Impls
///      are injected, not `new`-ed here — their creation code would push the factory past the EIP-3860 initcode
///      limit (49152 B); each disables its own initializers and is shared across every build.
contract LidoLendMarketFactory {
    using MarketParamsLib for MarketParams;

    address public immutable CONTROLLER_IMPL;
    address public immutable VAULT_IMPL;
    address public immutable GUARDIAN_SIGNALS_IMPL;

    error ZeroImpl();

    constructor(address controllerImpl, address vaultImpl, address guardianSignalsImpl) {
        if (controllerImpl == address(0) || vaultImpl == address(0) || guardianSignalsImpl == address(0)) {
            revert ZeroImpl();
        }
        CONTROLLER_IMPL = controllerImpl;
        VAULT_IMPL = vaultImpl;
        GUARDIAN_SIGNALS_IMPL = guardianSignalsImpl;
    }

    /// @notice Deploys the controller and vault proxies for `params`'s market id. The controller's
    ///         `DEFAULT_ADMIN_ROLE` goes to `msg.sender` — the caller owns every further role decision. Does
    ///         not check whether the market already exists on the core, whether `params.oracle` or
    ///         `guardianSignals` carries code, or reject a zero role holder: those are the caller's job.
    function deployMarketContracts(
        MarketParams calldata params,
        CollateralActivationConfig calldata activationConfig,
        SettlementConfig calldata settlementConfig,
        address guardianSignals,
        address proxyAdmin,
        string calldata vaultName,
        string calldata vaultSymbol
    ) external returns (address controller, address vault) {
        Id marketId = params.id();

        bytes memory controllerInit = abi.encodeCall(
            LidoLendMarketController.initialize,
            (marketId, msg.sender, IGuardianSignalsView(guardianSignals), activationConfig, settlementConfig)
        );
        controller = address(new OssifiableProxy(CONTROLLER_IMPL, proxyAdmin, controllerInit));

        vault = deployVault(params, controller, vaultName, vaultSymbol, proxyAdmin);
    }

    /// @notice Deploys a vault proxy bound to `controller`, at the shared implementation. Standalone and
    ///         reusable — not only the step `deployMarketContracts` takes internally — e.g. to add a second vault
    ///         flavour over an already-activated market. Carries no role at all: `LidoLendERC4626` has no
    ///         `AccessControl` surface, so there is no admin dance here.
    /// @dev Every vault on one market shares that market's supply cap and pause (both `controller`-level
    ///      state), not a cap/pause each. `initialize` reverts `ControllerMarketMismatch` when `controller`
    ///      governs a market other than the one `params` hashes to.
    function deployVault(
        MarketParams calldata params,
        address controller,
        string calldata vaultName,
        string calldata vaultSymbol,
        address proxyAdmin
    ) public returns (address vault) {
        bytes memory vaultInit = abi.encodeCall(
            LidoLendERC4626.initialize, (params, controller, vaultName, vaultSymbol)
        );
        vault = address(new OssifiableProxy(VAULT_IMPL, proxyAdmin, vaultInit));
    }

    /// @notice Deploys a `GuardianSignals` registry proxy at the shared implementation, seeded with
    ///         `guardians` / `quorum`. The GuardianSignals instance's `DEFAULT_ADMIN_ROLE` goes to `msg.sender`
    ///         — same rule as `deployMarketContracts` — so the caller owns every further role decision (suspect
    ///         window, manager / access-restorer / access-limiter grants, final admin handover).
    function deployGuardianSignals(address proxyAdmin, address[] calldata guardians, uint256 quorum)
        external
        returns (address guardianSignals)
    {
        bytes memory init = abi.encodeCall(GuardianSignals.initialize, (msg.sender, guardians, quorum));
        guardianSignals = address(new OssifiableProxy(GUARDIAN_SIGNALS_IMPL, proxyAdmin, init));
    }
}
