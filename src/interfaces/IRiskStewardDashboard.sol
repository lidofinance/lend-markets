// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

/// @title IRiskStewardDashboard
/// @notice Dashboard-specific external surface: per-market steward management and bounded risk-reduction levers.
///         Access-control membership and administration use the inherited `IAccessControlEnumerable` surface.
interface IRiskStewardDashboard is IAccessControlEnumerable {
    // ---
    // EVENTS
    // ---

    /// @notice Emitted when a steward is appointed to or removed from a market.
    event MarketStewardSet(Id indexed marketId, address indexed steward, bool enabled);

    /// @notice Emitted after an accepted non-decreasing update to a market's activation delay floor, cap, and
    ///         guardian-quorum fallback.
    event ActivationDelaysIncreased(
        Id indexed marketId,
        uint256 newMinActivationDelay,
        uint256 newMaxActivationDelay,
        uint256 newMaxGuardiansQuorumDelay
    );

    /// @notice Emitted after an accepted update to a market's activating-lock duration.
    event ActivatingLockDurationIncreased(Id indexed marketId, uint256 newDuration);

    /// @notice Emitted after an accepted update to a market's minimum deposit.
    event MinDepositAmountIncreased(Id indexed marketId, uint256 newMinDepositAmount);

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

    /// @notice Raise the activation delay floor, cap, and guardian-quorum fallback. Reverts unless all values rise
    ///         or hold. The controller bounds the cap and fallback to 7 days and enforces floor <= cap and a
    ///         nonzero fallback > cap on write.
    function increaseActivationDelays(
        Id marketId,
        uint32 newMinActivationDelay,
        uint32 newMaxActivationDelay,
        uint32 newMaxGuardiansQuorumDelay
    ) external;

    /// @notice Raise the activating-lock duration; a decrease reverts. The controller still bounds the duration
    ///         on write.
    function increaseActivatingLockDuration(Id marketId, uint32 newDuration) external;

    /// @notice Increase the minimum non-instant deposit. It cannot decrease or exceed `minActivationAmount`.
    function increaseMinDepositAmount(Id marketId, uint128 newMinDepositAmount) external;

    /// @notice Set a caller's instant activation permission to false on a market. Risk-reducing, so no direction
    ///         guard; the controller records and emits the requested false value even if it was already false.
    function revokeInstantActivation(Id marketId, address caller) external;

    /// @notice Freeze a market. Only an appointed steward of that market may call.
    function freezeMarket(Id marketId) external;
}
