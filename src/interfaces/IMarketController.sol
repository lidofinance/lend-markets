// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

/// @title IMarketController
/// @notice Optional per-market policy hooks used by the Lido Lending Morpho fork.
/// @dev A zero controller means ordinary Morpho behavior plus any core extension explicitly
///      enabled on the market. A non-zero controller is trusted market policy configured by
///      governance, never user-selected calldata.
///
///      The core dispatches all controller callbacks through a single entrypoint and the
///      controller decodes the payload. This keeps the fork surface inside the core minimal —
///      one helper function plus one line per call site.
interface IMarketController {
    /// @notice Per-market controller configuration.
    struct MarketConfig {
        uint64 minMaturationDelay; // Default lower bound for collateral activation delay.
        uint64 maxMaturationDelay; // Default upper bound for collateral activation delay.
        // Minimum collateral amount that can enter activation.
        uint128 minCollateralActivationAmount;
        uint128 maturationRatePerHour; // Global throttle.
        uint128 lenderMinDeposit; // Lender-side minimum deposit, default 0.
        uint128 supplyCap; // Aggregate supply cap, default unlimited.
        uint128 borrowCap; // Aggregate borrow cap, default unlimited.
        // Window-based adaptive delay (Spark ALM RateLimits.sol pattern).
        // The window-based formula is disabled when both `inflowDecayPerSecond == 0` and
        // `inflowReferenceSize == 0`; in that case the controller falls back to the legacy
        // size-based ratio against totalMaturedCollateral. When enabled, both must be non-zero
        // (validated in `_validateConfig`), and `inflowMaxAccumulator` must be at least the
        // reference size so the accumulator can saturate the formula.
        // When set, delay = min(maxDelay, minDelay + span * (depositSize + currentInflow) / referenceSize).
        uint128 inflowDecayPerSecond; // Accumulator decay rate, tokens/sec.
        uint128 inflowReferenceSize; // Effective load that maps to maxDelay.
        uint128 inflowMaxAccumulator; // Cap to bound accumulator (overflow safety).
    }

    /// @notice Deleverage waterfall policy. Borrowers are tracked in a max-heap keyed by
    ///         `borrowShares × 1e18 / rawCollateral` (see `DeleverageHeap`). The iteration
    ///         peeks the root, computes a slice that brings the root's key down to (or below)
    ///         the higher-keyed child, and repeats until target debt is covered, the heap is
    ///         empty, or `maxIterations` is exhausted.
    struct DeleverageHeapConfig {
        uint128 sliceFloorAssets; // Minimum loan-asset slice per cut. Avoids micro-cuts when root and runner-up are
        // nearly tied.
        uint32 maxIterations; // Hard cap on per-call cut iterations. Bounds gas.
    }

    /// @notice Controller's collateral classification for one borrower position.
    struct CollateralState {
        uint128 maturedCollateral; // Counts for borrow capacity.
        uint128 activatingCollateral; // Eligible pending collateral after activation-threshold check.
        uint128 dustCollateral; // Deposited/withdrawable, never matures until separately batched.
        uint64 pendingMaturationStart; // 0 if no active pending lot.
        uint64 pendingMaturationDelay; // Computed at supplyCollateral time.
    }

    /// @notice Controller-level state for one market.
    struct ControllerMarketState {
        uint128 totalMaturedCollateral;
        uint128 totalActivatingCollateral;
        uint128 totalDustCollateral;
        uint64 maturationBudgetWindowStart;
        uint128 maturationBudgetUsed;
        // Window-based delay accumulator (set if MarketConfig.inflowReferenceSize != 0).
        // Snapshot value at inflowLastUpdate; effective value at time t is decayed linearly.
        uint128 inflowAccumulator;
        uint64 inflowLastUpdate;
        bool isFrozen;
        bool isPaused;
        bool configured;
    }

    /// @notice Strict action-hook selector. Core dispatches one callback per market action through a
    ///         single `IMarketController.on(id, e, data)` entrypoint with the data ABI-encoded.
    ///         Lido constraints are enforced by reverting from inside strict callbacks. Each action
    ///         hook is called at the action's policy/sync point: after input normalization and
    ///         action-specific amount computation, before any external callback or token transfer.
    enum HookEvent {
        Supply,
        Withdraw,
        Borrow,
        Repay,
        SupplyCollateral,
        WithdrawCollateral,
        Liquidate,
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

    struct BorrowHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
        uint256 shares;
    }

    struct RepayHookData {
        address caller;
        address onBehalf;
        uint256 assets;
        uint256 shares;
    }

    struct SupplyCollateralHookData {
        address caller;
        address onBehalf;
        uint256 assets;
    }

    struct WithdrawCollateralHookData {
        address caller;
        address onBehalf;
        address receiver;
        uint256 assets;
        uint256 borrowerBorrowShares;
    }

    struct LiquidateHookData {
        address caller;
        address borrower;
        uint256 seizedAssets;
        uint256 repaidShares;
    }

    struct DeleverageHookData {
        address caller;
        address lender;
        address borrower;
        address receiver;
        uint256 assetsToCancel;
        uint256 borrowerBorrowAssets;
        uint256 borrowerRawCollateral;
        uint256 collateralPrice;
        uint256 collateralSeized;
    }

    /// @notice Lido lending core contract this controller accepts hooks from.
    function MARKET() external view returns (address);

    /// @notice The only market id this controller is allowed to manage.
    function MARKET_ID() external view returns (Id);

    /// @notice Deployment-scoped access restriction registry used by this controller.
    function MARKET_ACCESS_REGISTRY() external view returns (address);

    function collateralState(Id id, address borrower) external view returns (CollateralState memory);

    function marketState(Id id) external view returns (ControllerMarketState memory);

    function marketConfig(Id id) external view returns (MarketConfig memory);

    function deleverageHeapConfig(Id id) external view returns (DeleverageHeapConfig memory);

    /// @notice Number of borrowers currently tracked in the deleverage heap.
    function deleverageHeapSize(Id id) external view returns (uint256);

    /// @notice Borrowers currently in the deleverage heap, top-down, up to `maxCount`.
    function eligibleBorrowers(Id id, uint256 maxCount)
        external
        view
        returns (address[] memory borrowers, uint256[] memory keys);

    /// @notice Next borrower to cut (heap root) and the loan-asset slice size for that cut.
    ///         `borrower` is address(0) if the heap is empty.
    function nextDeleverageCut(Id id) external view returns (address borrower, uint256 sliceAssets);

    /// @notice Maximum slice (in loan assets) the controller's policy allows for a single
    ///         `deleverage` call against `borrower`. Mirrors the slice cap enforced in the
    ///         controller's deleverage hook: `max(heapSlice, watermarkSlice)`. Zero means the
    ///         borrower is not eligible for deleverage at all.
    function allowedSliceFor(Id id, address borrower) external view returns (uint256);

    /// @notice True if the heap root (riskiest borrower) is bad debt (debt > collateral value).
    function rootHasBadDebt(Id id) external view returns (bool);

    struct WatermarkInfo {
        // WAD-scaled target post-cut LTV. 0 means the borrower has not opted in.
        uint256 watermarkLtv;
        // Loan-asset cut size that brings the borrower's LTV down to `watermarkLtv` at the live
        // oracle price. 0 when no watermark, no debt/collateral, or current LTV already at/under
        // the target.
        uint256 sliceAssets;
    }

    /// @notice Borrower's personal watermark and the corresponding watermark-derived slice.
    function watermarkInfo(Id id, address borrower) external view returns (WatermarkInfo memory);

    /// @notice Convenience getter for `watermarkInfo(...).watermarkLtv` — 0 if borrower hasn't
    ///         opted in to a personal watermark.
    function borrowerWatermark(Id id, address borrower) external view returns (uint256);

    /// @notice Borrower sets their own personal watermark (target post-cut LTV in WAD).
    /// @dev `msg.sender` is the borrower. `ltv` must be `< 1e18`; 0 clears the watermark.
    function setBorrowerWatermark(Id id, uint256 ltv) external;

    /// @notice Strict action callback. Reverts to abort the calling action.
    /// @dev The core calls each action hook after input normalization and action-specific amount
    ///      computation, before the matching core state mutation and before any external
    ///      callback/token transfer. A revert rolls the entire action back.
    ///
    ///      Payload encoding per `HookEvent`:
    ///        - Supply: abi.encode(SupplyHookData)
    ///        - Withdraw: abi.encode(WithdrawHookData)
    ///        - Borrow: abi.encode(BorrowHookData)
    ///        - Repay: abi.encode(RepayHookData)
    ///        - SupplyCollateral: abi.encode(SupplyCollateralHookData)
    ///        - WithdrawCollateral: abi.encode(WithdrawCollateralHookData)
    ///        - Liquidate: abi.encode(LiquidateHookData)
    ///        - Deleverage: abi.encode(DeleverageHookData)
    function on(Id id, HookEvent e, bytes calldata data) external;
}
