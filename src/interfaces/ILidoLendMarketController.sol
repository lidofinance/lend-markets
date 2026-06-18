// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../libs/CollateralActivationLib.sol";
import {SlicePolicy} from "../types/SettlementTypes.sol";

/// @title ILidoLendMarketController
/// @notice Full external surface of `LidoLendMarketController`: the core hook interface and AccessControl
///         (both inherited), the Lido-policy levers, freeze/pause, the settlement-queue views, and the
///         borrower dashboard. The controller implements this interface, so it is the single source for
///         the dashboard struct, events, errors, and the function docs the contract inherits.
interface ILidoLendMarketController is ILidoLendBaseMarketController, IAccessControl {
    /* EVENTS */

    /// @notice Emitted when the market is frozen or unfrozen.
    event FrozenSet(bool frozen, address indexed account);

    /// @notice Emitted when the borrow utilization gap is set (WAD; 0 = no gap).
    event BorrowUtilizationGapSet(uint256 borrowUtilizationGap);

    /* ERRORS */

    /// @notice Thrown when the hook caller is not the core.
    error Unauthorized();

    /// @notice Thrown when the hook id is not this controller's market.
    error InvalidMarketId();

    /// @notice Thrown when the hook event is unrecognized.
    error UnknownHookEvent();

    /// @notice Thrown when a freeze blocks the action.
    error MarketIsFrozen();

    /// @notice Thrown when a banned address borrows, receives a borrow, or initiates one.
    error AddressBanned();

    /// @notice Thrown when a risk-steward lever would loosen a parameter instead of tightening it.
    error ConfigNotTightened();

    /// @notice Thrown when active (matured) collateral cannot cover the debt at the market LLTV.
    error InsufficientActiveCollateral();

    /// @notice Thrown when a withdrawal would draw a borrower's collateral below the activation minimum
    ///         while it still owes debt. Repaying to zero lifts the floor.
    error CollateralFloorBreached();

    /// @notice Thrown when a borrow would push borrow utilization above the cap (WAD - borrowUtilizationGap).
    error MaxBorrowUtilizationExceeded();

    /// @notice Thrown when the borrow utilization gap is set to WAD or more (would freeze borrowing).
    error BorrowUtilizationGapTooHigh();

    /// @notice Thrown when a core-applied position delta exceeds the controller's read of that position.
    ///         The controller's accounting mirrors the core, so a divergence reverts instead of masking it.
    error PositionAccountingMismatch();

    /// @notice Thrown when the settlement-queue root is bad debt.
    error SettlementRootBadDebt();

    /// @notice Thrown when the settle target is neither the queue root nor watermarked.
    error SettlementIneligible();

    /// @notice Thrown when the requested cut exceeds the policy-allowed slice.
    error SettlementExceedsAllowed();

    /// @notice Thrown when the cut's shares exceed the borrower's debt.
    error SettlementExceedsDebt();

    /// @notice Thrown when the seized collateral is zero or exceeds the borrower's collateral.
    error SettlementInvalidSeize();

    /* TYPES */

    /// @notice One-read borrower snapshot for off-chain dashboards: collateral split, activation timer,
    ///         guardian signal, debt, personal watermark, and live settle exposure.
    /// @param active Matured collateral, borrowable.
    /// @param activating Collateral inside the activation timer, not yet borrowable.
    /// @param dust Collateral below the activation threshold, withdrawable.
    /// @param unlockTime Activation unlock timestamp, 0 when there is no timer.
    /// @param strikes Effective guardian strike count driving the activation surcharge.
    /// @param banned Hard-blocked by a latched guardian ban.
    /// @param debtAssets Current borrow debt, in loan assets.
    /// @param watermarkLtv Borrower's personal settle-down target LTV (WAD), 0 when unset.
    /// @param isQueueRoot The borrower is the settlement-queue root, next in line to cut.
    /// @param allowedSlice Loan assets that may be cut from this position in one settle now.
    struct BorrowerPosition {
        uint256 active;
        uint256 activating;
        uint256 dust;
        uint256 unlockTime;
        uint256 strikes;
        bool banned;
        uint256 debtAssets;
        uint256 watermarkLtv;
        bool isQueueRoot;
        uint256 allowedSlice;
    }

    /* ROLES */

    function MANAGER_ROLE() external view returns (bytes32);
    function RISK_STEWARD_ROLE() external view returns (bytes32);
    function FREEZER_ROLE() external view returns (bytes32);
    function UNFREEZER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function RESUMER_ROLE() external view returns (bytes32);

    /* COLLATERAL ACTIVATION */

    /// @notice Update the governance-tunable activation parameters. Risk-increasing path: the role is meant
    ///         to be held by the EasyTrack factory, which adds the objection window.
    function setConfig(CollateralActivationLib.Config calldata cfg) external;

    /// @notice Fast risk-reducing lever: raise the activation delay floor. Reverts if it would lower.
    function increaseMinActivationDelay(uint64 newMinActivationDelay) external;

    /// @notice Fast risk-reducing lever: raise the activation delay cap. Reverts if it would lower.
    function increaseMaxActivationDelay(uint64 newMaxActivationDelay) external;

    /// @notice Risk-steward lever (Sybil protection): hold up to `activatingHold` of each position's
    ///         activating collateral unwithdrawable until it matures. 0 (the default) disables it.
    function setActivatingHold(uint128 activatingHold) external;

    /// @notice Current decayed activation inflow (the throttle accumulator) — for monitoring and tests.
    function currentInflow() external view returns (uint256);

    /* BORROW UTILIZATION GAP */

    /// @notice Set the minimum gap kept between borrow utilization and 100% (WAD; 0 = no gap, must be < WAD).
    ///         Reserves that share of supply for lender withdrawals — a borrow that would close the gap
    ///         reverts. Risk-increasing path (shrinking or disabling the gap): meant for the EasyTrack factory.
    function setBorrowUtilizationGap(uint256 newBorrowUtilizationGap) external;

    /// @notice Fast risk-reducing lever: widen the gap. Reverts if it would not raise it.
    function increaseBorrowUtilizationGap(uint256 newBorrowUtilizationGap) external;

    /// @notice The minimum gap kept between borrow utilization and 100% (WAD; 0 = no gap).
    function borrowUtilizationGap() external view returns (uint256);

    /// @notice Max borrow utilization permitted (WAD), i.e. WAD - borrowUtilizationGap. WAD when no gap is set.
    function maxBorrowUtilization() external view returns (uint256);

    /// @notice The market's current borrow utilization (borrowed / supplied, WAD) with pending interest accrued.
    function currentBorrowUtilization() external view returns (uint256);

    /* SETTLEMENT QUEUE */

    /// @notice Set the settle slice policy in one shot — the knobs tune the same cut and move together.
    ///         The root cut is the largest of `sliceFloorBps` of the debt, `sliceFloorAssets`, and the cut
    ///         that lowers the root's LTV by `ltvStepBps`. `fullCutBelowCollateral` lifts the cut to the full
    ///         debt when the post-cut collateral would be dust.
    function setSlicePolicy(SlicePolicy calldata policy) external;

    /// @notice The current settle slice policy.
    function slicePolicy() external view returns (SlicePolicy memory);

    /// @notice Borrower opts into auto-settle down to a target post-cut LTV (WAD). 0 clears it.
    function setBorrowerWatermark(uint256 ltv) external;

    /// @notice Borrower's personal watermark LTV and the corresponding watermark-derived slice.
    function watermarkInfo(address borrower) external view returns (uint256 watermarkLtv, uint256 sliceAssets);

    /// @notice Number of borrowers tracked in the settlement queue.
    function settlementQueueSize() external view returns (uint256);

    /// @notice True if the queue root (the riskiest borrower) is bad debt: its debt value exceeds its
    ///         collateral value. The root is the highest debt/collateral position, so a solvent root means
    ///         no tracked position is bad debt, which is why the settle gate need only check the root.
    function rootHasBadDebt() external view returns (bool);

    /// @notice Next borrower to cut (queue root) and the max slice the policy allows for it: the larger of
    ///         the root-policy slice and the root's own watermark slice (the same bound the hook caps at,
    ///         and the same value `allowedSliceFor` returns). `borrower` is address(0) when the queue is empty.
    function nextSettlementCut() external view returns (address borrower, uint256 sliceAssets);

    /// @notice Maximum loan-asset slice the policy allows for a single settle cut against `borrower` (max of
    ///         root-policy slice and watermark slice). Zero means ineligible.
    function allowedSliceFor(address borrower) external view returns (uint256);

    /// @notice Borrowers currently in the queue (approximate top-down order) and their risk keys.
    function eligibleBorrowers(uint256 maxCount)
        external
        view
        returns (address[] memory borrowers, uint256[] memory keys);

    /* FREEZE & PAUSE */

    /// @notice Freeze the market: new borrows and debt-bearing collateral withdrawals revert, and activation
    ///         settlement is deferred. Debt-free positions can still withdraw their collateral.
    function freeze() external;

    /// @notice Lift the freeze.
    function unfreeze() external;

    /// @notice Pause every hook for `duration` seconds. Pass PAUSE_INFINITELY for an indefinite pause.
    function pauseFor(uint256 duration) external;

    /// @notice Lift the pause.
    function resume() external;

    /// @notice Whether the market is frozen.
    function isFrozen() external view returns (bool);

    /* POSITION VIEW */

    /// @notice One-call borrower dashboard: collateral split, activation unlock, guardian signal, debt,
    ///         personal watermark, and live settle exposure (queue root + allowed slice).
    function positionOf(address borrower) external view returns (BorrowerPosition memory);
}
