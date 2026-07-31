// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @title IRiskStewardDashboard
/// @notice Full external surface of `RiskStewardDashboard`: AccessControlEnumerable (inherited), per-market steward
///         management, and the bounded tighten-only risk levers. The dashboard implements this interface, so
///         it is the single source for the events, errors, and the function docs the contract inherits.
interface IRiskStewardDashboard is IAccessControlEnumerable {
    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a steward is appointed to or removed from a market.
    event MarketStewardSet(Id indexed marketId, address indexed steward, bool enabled);

    /// @notice Emitted when the activation delay floor and cap are raised on a market.
    event ActivationDelaysIncreased(Id indexed marketId, uint40 newMin, uint40 newMax);

    /// @notice Emitted when the Sybil lock amount and duration are raised on a market.
    event ActivatingLockIncreased(Id indexed marketId, uint128 newAmount, uint40 newDuration);

    /// @notice Emitted when a steward revokes a caller's instant activation on a market.
    event InstantActivationRevoked(Id indexed marketId, address indexed caller);

    // ---
    // ERRORS
    // ---

    /// @notice A lever would loosen a parameter instead of tightening it.
    error NotTightened();

    /// @notice The caller is not a steward of the target market.
    error NotMarketSteward();

    /// @notice A zero-address steward was supplied.
    error ZeroSteward();

    /// @notice Thrown when a required address argument is zero.
    error ZeroAddress();

    /// @notice The market id has no controller on the core (unknown or not yet created).
    error UnknownMarket(Id marketId);

    // ---
    // ROLES
    // ---

    /// @notice Role allowed to appoint and remove per-market stewards.
    function STEWARD_ADMIN_ROLE() external view returns (bytes32);

    // ---
    // STEWARDS
    // ---

    /// @notice Appoint a steward to a market.
    function addMarketSteward(Id marketId, address steward) external;

    /// @notice Remove a steward from a market.
    function removeMarketSteward(Id marketId, address steward) external;

    /// @notice The stewards currently appointed for a market.
    function marketStewards(Id marketId) external view returns (address[] memory);

    /// @notice Whether `steward` may pull this dashboard's levers on `marketId`.
    function isMarketSteward(Id marketId, address steward) external view returns (bool);

    // ---
    // RISK LEVERS
    // ---

    /// @notice Raise the activation delay floor and cap. Reverts unless both rise or hold. The controller still
    ///         bounds the cap and enforces floor <= cap on write.
    function increaseActivationDelays(Id marketId, uint40 newMin, uint40 newMax) external;

    /// @notice Raise the Sybil lock amount and duration. Reverts unless both rise or hold. The controller still
    ///         bounds the duration on write.
    function increaseActivatingLock(Id marketId, uint128 newAmount, uint40 newDuration) external;

    /// @notice Revoke a caller's instant activation on a market. Risk-reducing, so no direction guard; forwards
    ///         to the controller, which emits the state change.
    function revokeInstantActivation(Id marketId, address caller) external;
}
