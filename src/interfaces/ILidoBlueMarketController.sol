// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

/// @title ILidoBlueMarketController
/// @notice The market controller's interface. The core dispatches every action through a single
///         `on(id, e, data)` entrypoint (HookEvent order and struct layouts must match the core so the
///         abi-encoded hook payloads stay compatible). It also declares the read views the ERC-4626
///         wrapper consumes (`nextDeleverageCut`, `allowedSliceFor`).
interface ILidoBlueMarketController {
    enum HookEvent {
        Supply,
        Withdraw,
        Borrow,
        Repay,
        SupplyCollateral,
        WithdrawCollateral,
        Liquidate,
        AccrueInterest,
        Deleverage
    }

    struct SupplyHookData {
        address caller;
        address onBehalf;
        uint256 assets;
        uint256 shares;
    }

    struct WithdrawHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
        uint256 shares;
    }

    struct AccrueInterestHookData {
        address caller;
    }

    struct SupplyCollateralHookData {
        address caller;
        address onBehalf;
        uint256 assets;
    }

    struct BorrowHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
        uint256 shares;
    }

    struct WithdrawCollateralHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
    }

    struct RepayHookData {
        address caller;
        address onBehalf;
        uint256 assets;
        uint256 shares;
    }

    struct LiquidateHookData {
        address caller;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
    }

    struct DeleverageHookData {
        address caller;
        address onBehalf;
        address borrower;
        address receiver;
        uint256 assetsToCancel; // computed in core (debtCanceled)
        uint256 collateralSeized; // computed in core; controller debits buckets by exactly this (lockstep with raw)
    }

    /// @notice The single market id this controller manages. Checked at market binding.
    function MARKET_ID() external view returns (Id);

    /// @notice Next borrower to cut (queue root) and the max slice the policy allows for it (heap
    ///         re-order or the root's watermark, whichever is larger). `borrower` is address(0) when the
    ///         queue is empty. Read by the ERC-4626 wrapper's fallback-exit loop.
    function nextDeleverageCut() external view returns (address borrower, uint256 sliceAssets);

    /// @notice Maximum loan-asset slice the policy allows for a single deleverage cut against `borrower`.
    function allowedSliceFor(address borrower) external view returns (uint256);

    /// @notice Strict action callback. Reverts to abort the calling action.
    function on(Id id, HookEvent hookEvent, bytes calldata data) external;
}
