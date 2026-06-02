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
        // maxDelay. When enabled, both must be non-zero (validated in `_validateConfig`). The
        // accumulator is capped at `maxDelayMaturationLoad`: load beyond that point cannot raise the
        // delay further (already saturated at maxDelay), so a single oversized deposit cannot pin
        // later deposits at maxDelay for longer than the load takes to decay from the cap.
        // When set, delay = min(maxDelay, minDelay + span * (depositSize + currentMaturationLoad) /
        // maxDelayMaturationLoad).
        uint128 maturationLoadDecayPerSecond; // Accumulator decay rate, tokens/sec.
        uint128 maxDelayMaturationLoad; // Effective load that maps to maxDelay; also the accumulator cap.
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
        FallbackExit,
        AccrueInterest
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

    struct FallbackExitHookData {
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
    ///        - FallbackExit: abi.encode(FallbackExitHookData)
    ///        - AccrueInterest: abi.encode(AccrueInterestHookData)
    function on(Id id, HookEvent e, bytes calldata data) external;
}
