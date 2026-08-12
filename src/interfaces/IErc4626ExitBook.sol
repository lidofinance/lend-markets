// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IExitBook} from "./IExitBook.sol";
import {PriorityRamp} from "../types/ExitBookTypes.sol";

/// @title IErc4626ExitBook
/// @notice Exit book backed by shares of governance-allowed ERC-4626 vaults. Extends the common exit-book
///         surface (`IExitBook`) with vault placement and allow-list admin.
interface IErc4626ExitBook is IExitBook {
    /// @notice Whether `vault` is allowed for new requests.
    /// @param vault The vault to query.
    function isVaultAllowed(IERC4626 vault) external view returns (bool);

    /// @notice The source vault request `id` was placed against (zero if none).
    /// @param id The request id.
    function vaultOf(uint256 id) external view returns (IERC4626);

    /// @notice Allow or disallow `vault` for new requests. `ALLOWLIST_MANAGER_ROLE` only.
    /// @param vault The vault to allow or disallow.
    /// @param allowed True to allow new requests; false to block them without changing existing fill eligibility.
    function setVaultAllowed(IERC4626 vault, bool allowed) external;

    /// @notice Open an asset-denominated exit against the caller's shares in an allowed `vault`. Nothing is
    ///         escrowed. Placement snapshots the full request's `previewWithdraw` share quote and requires enough
    ///         current balance and allowance, but does not reserve either. Each fill debits and withdraws the same
    ///         exact asset amount.
    /// @param vault The allowed ERC-4626 vault.
    /// @param assets Loan-asset amount to debit across fills. Must fit `uint128`.
    /// @param receiver Address credited the filled amount minus the priority fee.
    /// @param minFillAssets Smallest amount a non-final fill may process; 0 for no minimum. A fill that
    ///        closes the whole remaining request always qualifies. Values above `assets` are capped to `assets`.
    /// @param maxShareBurn Nominal full-request vault-share budget. A fill may burn at most
    ///        `ceil(maxShareBurn * fillAssets / assetsTotal)`. Across a split request, total burn may exceed this
    ///        value by at most one raw share unit per additional fill. Must fit `uint128`; 0 disables the limit,
    ///        and a non-zero value must cover the placement share quote.
    /// @param ramp Priority-fee schedule (see `PriorityRamp`): start rate, end rate, hold, and ramp end.
    /// @param deadline Strictly future fill cutoff, at most `now + MAX_REQUEST_LIFETIME` and not before the ramp ends.
    /// @return id The new request id.
    function placeExitRequest(
        IERC4626 vault,
        uint256 assets,
        address receiver,
        uint256 minFillAssets,
        uint256 maxShareBurn,
        PriorityRamp calldata ramp,
        uint256 deadline
    ) external returns (uint256 id);
}
