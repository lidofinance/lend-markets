// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IExitBook} from "./IExitBook.sol";
import {PriorityRamp} from "../types/ExitBookTypes.sol";

/// @title IErc4626ExitBook
/// @notice Exit book backed by shares of governance-allowed ERC-4626 vaults. Extends the common exit-book
///         surface (`IExitBook`) with vault placement and allow-list admin.
interface IErc4626ExitBook is IExitBook {
    /// @notice Whether `vault` is allowed for new requests.
    /// @param vault The vault to query.
    /// @return True if `vault` is allowed.
    function isVaultAllowed(IERC4626 vault) external view returns (bool);

    /// @notice The source vault request `id` was placed against (zero if none).
    /// @param id The request id.
    /// @return The vault backing the request.
    function vaultOf(uint256 id) external view returns (IERC4626);

    /// @notice Allow or disallow `vault` for new requests. Owner only.
    /// @param vault The vault to allow or disallow.
    /// @param allowed True to allow new requests against it; false to block them (already-placed ones still fill).
    function setVaultAllowed(IERC4626 vault, bool allowed) external;

    /// @notice Open an exit backed by `shares` of an allowed `vault`. Permission-only: the caller must have
    ///         approved this book for `shares` and hold them; the fill redeems them via the allowance.
    /// @param vault The allowed ERC-4626 vault.
    /// @param shares Vault shares to exit.
    /// @param ramp Priority-fee schedule (see `PriorityRamp`): start rate, end rate, and ramp duration.
    /// @param deadline Fill cutoff; capped at `now + MAX_REQUEST_LIFETIME` and `>= now + ramp.rampDuration`.
    /// @param fullFillOnly When true a fill must cover the whole remaining size in one shot.
    /// @return id The new request id.
    function placeExitRequest(
        IERC4626 vault,
        uint256 shares,
        PriorityRamp calldata ramp,
        uint256 deadline,
        bool fullFillOnly
    ) external returns (uint256 id);
}
