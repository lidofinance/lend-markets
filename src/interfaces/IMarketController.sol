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
        uint64 minMaturationDelay; // Default lower bound for collateral maturation delay.
        uint64 maxMaturationDelay; // Default upper bound for collateral maturation delay.
        // Minimum collateral amount that can enter maturation.
        uint128 minMaturationAmount;
        uint128 fallbackMinRequest; // Anti-dust on lender side of fallback.
        uint128 lenderMinDeposit; // Lender-side minimum deposit, default 0.
        uint128 supplyCap; // Aggregate supply cap, default unlimited.
        uint128 borrowCap; // Aggregate borrow cap, default unlimited.
        // Load-scaled adaptive delay (Spark ALM RateLimits.sol pattern).
        // The load-scaled formula is disabled when both `maturationLoadDecayPerSecond == 0` and
        // `maxDelayMaturationLoad == 0`; in that case the controller applies a conservative fixed
        // maxDelay. When enabled, all three must be non-zero (validated in `_validateConfig`), and
        // `maturationLoadCap` must be at least `maxDelayMaturationLoad` so the accumulator can reach
        // the reference. A larger cap lets a large or sustained inflow hold the delay at maxDelay for
        // longer: the accumulator can climb above the reference before decaying back, so the tail of
        // elevated delay lasts until it drains from the cap.
        // When set, delay = min(maxDelay, minDelay + span * (depositSize + currentMaturationLoad) /
        // maxDelayMaturationLoad).
        uint128 maturationLoadDecayPerSecond; // Accumulator decay rate, tokens/sec.
        uint128 maxDelayMaturationLoad; // Load at which the delay reaches maxDelay (formula reference).
        uint128 maturationLoadCap; // Accumulator upper bound; >= maxDelayMaturationLoad. Controls tail length.
    }

    /// @notice Deleverage waterfall policy. See `MaxHeapLib` for the heap key formula.
    /// @dev `maxIterations` is the vault-side loop bound (consumed by
    ///      `MorphoBlueForkERC4626Vault._deleverageFromHeap`), not by the controller itself.
    struct DeleverageConfig {
        uint128 sliceFloorAssets; // Minimum loan-asset slice per cut.
        uint32 maxIterations; // Per-call iteration cap consumed by the vault loop.
    }

    /// @notice Controller's collateral classification for one borrower position.
    struct CollateralState {
        uint128 maturedCollateral; // Counts for borrow capacity.
        uint128 maturingCollateral; // Eligible pending collateral after maturation-threshold check.
        uint128 dustCollateral; // Deposited/withdrawable, never matures until separately batched.
        uint64 pendingMaturationStart; // 0 if no active pending lot.
        uint64 pendingMaturationDelay; // Computed at supplyCollateral time.
    }

    /// @notice Controller-level state for one market.
    struct ControllerMarketState {
        uint128 totalMaturedCollateral;
        uint128 totalMaturingCollateral;
        uint128 totalDustCollateral;
        // Load-scaled delay accumulator (set if MarketConfig.maxDelayMaturationLoad != 0).
        // Snapshot value at maturationLoadUpdatedAt; effective value at time t is decayed linearly.
        uint128 maturationLoad;
        uint64 maturationLoadUpdatedAt;
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

    struct AccrueInterestHookData {
        address caller;
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

    function deleverageConfig(Id id) external view returns (DeleverageConfig memory);

    /// @notice Number of borrowers currently tracked in the deleverage heap.
    function deleverageHeapSize(Id id) external view returns (uint256);

    /// @notice Borrowers currently in the deleverage heap, in approximate top-down order (heap
    ///         array layout — not a strict sort), up to `maxCount`.
    function eligibleBorrowers(Id id, uint256 maxCount)
        external
        view
        returns (address[] memory borrowers, uint256[] memory keys);

    /// @notice Next borrower to cut and the loan-asset slice for that cut.
    /// @dev Heap-eligible borrower == the current heap root (the highest-key entry). Callers
    ///      MUST NOT assume top-N semantics. `borrower` is address(0) when the heap is empty;
    ///      `sliceAssets` is `type(uint256).max` when there is exactly one borrower in the heap
    ///      (no runner-up to bound the cut against).
    function nextDeleverageCut(Id id) external view returns (address borrower, uint256 sliceAssets);

    /// @notice Maximum slice (in loan assets) the controller's policy allows for a single
    ///         `deleverage` call against `borrower`. Mirrors the slice cap enforced in the
    ///         controller's deleverage hook: `max(heapSlice, watermarkSlice)`. Zero means the
    ///         borrower is not eligible for deleverage at all (not the heap root and no
    ///         personal watermark).
    function allowedSliceFor(Id id, address borrower) external view returns (uint256);

    /// @notice True if the heap root (riskiest borrower) is bad debt (debt > collateral value).
    /// @dev Computes against accrued totals via `MorphoBalancesLib.expectedMarketBalances`, so the
    ///      answer is up-to-date even when called without a prior `accrueInterest` in the same tx.
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
    ///        - AccrueInterest: abi.encode(AccrueInterestHookData)
    ///        - Deleverage: abi.encode(DeleverageHookData)
    function on(Id id, HookEvent e, bytes calldata data) external;
}
