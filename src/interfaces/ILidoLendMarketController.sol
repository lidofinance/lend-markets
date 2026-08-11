// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendMarketConfigurator} from "./ILidoLendMarketConfigurator.sol";
import {IPausableUntil} from "./IPausableUntil.sol";
import {SettlementConfig, SettlementQuote, SettlementSlice} from "../types/SettlementTypes.sol";

/// @title ILidoLendMarketController
/// @notice Full external surface of `LidoLendMarketController`: the core hook interface and AccessControlEnumerable
///         (both inherited), the Lido-policy levers, freeze/pause, the settlement-queue views, and the
///         borrower dashboard. The controller implements this interface, so it is the single source for
///         the dashboard struct, events, errors, and the function docs the contract inherits.
interface ILidoLendMarketController is
    ILidoLendBaseMarketController,
    IAccessControlEnumerable,
    ILidoLendMarketConfigurator,
    IPausableUntil
{
    // ---
    // EVENTS
    // ---

    /// @notice Emitted when the market is frozen or unfrozen.
    event FrozenSet(bool frozen, address indexed account);

    /// @notice Emitted when a trusted caller's instant-activation status is set.
    event InstantActivationSet(address indexed caller, bool enabled);

    /// @notice Emitted when the supply cap is set.
    event SupplyCapSet(uint256 cap, address indexed account);

    /// @notice Emitted once when the market binds its guardian-signals registry at initialization.
    event GuardianSignalsSet(address indexed guardianSignals);

    // ---
    // ERRORS
    // ---

    /// @notice Thrown when the hook caller is not the core.
    error Unauthorized();

    /// @notice Thrown when a required address argument is zero.
    error ZeroAddress();

    /// @notice Thrown when the hook id is not this controller's market.
    error InvalidMarketId();

    /// @notice Thrown when the hook event is unrecognized.
    error UnknownHookEvent();

    /// @notice Thrown when a freeze blocks the action.
    error MarketIsFrozen();

    /// @notice Thrown when a banned address borrows, receives a borrow, or initiates one.
    error AddressBanned();

    /// @notice Thrown when a supply would push the market's total supplied loan assets above the cap.
    error SupplyCapExceeded(uint256 cap, uint256 attempted);

    /// @notice Thrown when active (matured) collateral cannot cover the debt at the market LLTV.
    error InsufficientActiveCollateral();

    /// @notice Thrown when a withdrawal would leave raw collateral below the amount still held in the
    ///         un-matured buckets (a locked activating lot plus dust).
    error ActivationLockActive();

    /// @notice Thrown when a borrow would mint borrow shares while transferring zero loan assets.
    error ZeroBorrowAssets();

    /// @notice Thrown when a borrow, repay, or settle would push the market's borrow-share rate over the ceiling.
    error BorrowShareRateExceeded();

    /// @notice Thrown when a core-applied position delta exceeds the controller's read of that position.
    ///         The controller's accounting mirrors the core, so a divergence reverts instead of masking it.
    error PositionAccountingMismatch();

    /// @notice Thrown when a tracked borrower is bad debt, blocking settlement.
    error SettlementBadDebt();

    /// @notice Thrown when the requested cut exceeds the policy-allowed slice (a zero slice means ineligible).
    error SettlementExceedsAllowed();

    /// @notice Thrown when a root-policy cut exceeds the lender's illiquid supply tail.
    error SettlementExceedsSettleableSupply();

    // ---
    // TYPES
    // ---

    /// @notice One-read borrower snapshot for off-chain dashboards: collateral split, activation timer,
    ///         guardian signal, debt, personal settlement target, current queue status, and policy quotes.
    /// @param active Matured collateral, borrowable.
    /// @param activating Collateral inside the activation timer, not yet borrowable.
    /// @param dust Collateral below the activation threshold, withdrawable.
    /// @param unlockTime Activation unlock timestamp, 0 when there is no timer.
    /// @param flagCount Raw guardian flags on the account, regardless of status.
    /// @param banned Hard-blocked by a latched guardian ban.
    /// @param debtAssets Current borrow debt, in loan assets.
    /// @param settlementLtv Borrower's personal post-cut target LTV (WAD), 0 when unset.
    /// @param isNextToSettle The borrower is next in line to be settled.
    /// @param personalSliceAssets Personal settlement-LTV allowance in loan assets.
    /// @param queueRootSliceAssets Prospective queue-root policy allowance in loan assets.
    struct BorrowerPosition {
        uint256 active;
        uint256 activating;
        uint256 dust;
        uint256 unlockTime;
        uint256 flagCount;
        bool banned;
        uint256 debtAssets;
        uint256 settlementLtv;
        bool isNextToSettle;
        uint256 personalSliceAssets;
        uint256 queueRootSliceAssets;
    }

    // ---
    // ROLES
    // ---

    /// @notice The single governance role: full activation and settlement config, the supply cap, and
    ///         grant and revoke instant activation.
    function MANAGER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to freeze the market.
    function FREEZER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to lift a freeze.
    function UNFREEZER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to pause the hooks.
    function PAUSER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to lift a pause.
    function RESUMER_ROLE() external view returns (bytes32);

    // ---
    // CONFIG
    // ---

    /// @notice Ceiling on the market's borrow-share rate; borrow/repay/settle may not push past it (liquidation
    ///         exempt). Bounds rounding-driven borrow-share inflation.
    function MAX_BORROW_SHARE_RATE() external view returns (uint256);

    // ---
    // LENDER LIMITS
    // ---

    /// @notice Loan assets the market still accepts from lenders: the remaining supply-cap headroom,
    ///         `type(uint256).max` when uncapped, 0 while paused.
    function maxDeposit() external view returns (uint256);

    /// @notice Loan assets `supplier` can withdraw from its market supply right now: its position capped by
    ///         the idle liquidity, 0 while paused.
    function maxWithdrawableAssets(address supplier) external view returns (uint256);

    /// @notice The guardian-signals registry this controller reads for the borrow gate and activation scaling.
    function guardianSignals() external view returns (address);

    // ---
    // COLLATERAL ACTIVATION
    // ---

    /// @notice Current decayed activation inflow (the throttle accumulator) — for monitoring and tests.
    function currentInflow() external view returns (uint256);

    /// @notice Activation delay a deposit of `inflowIncrement` would incur at the current inflow — for
    ///         borrowers gauging the wait.
    function currentActivationDelay(uint256 inflowIncrement) external view returns (uint256);

    /// @notice Whether `caller`'s supplies skip the activation timer.
    function hasInstantActivation(address caller) external view returns (bool);

    // ---
    // SETTLEMENT QUEUE
    // ---

    /// @notice Sets all queue-root settlement sizing parameters atomically. The nominal queue-root cut is the
    ///         maximum of `sliceFloorBps` of its debt, `sliceFloorAssets`, and the cut required to lower its LTV by
    ///         `ltvStepBps`. If that cut would leave collateral below `fullCutBelowCollateral`, the queue-root
    ///         allowance is promoted to the full debt. Personal settlement-LTV quotes are unaffected.
    function setSettlementConfig(SettlementConfig calldata config) external;

    /// @notice The current settlement config.
    function settlementConfig() external view returns (SettlementConfig memory);

    /// @notice Sets the caller's personal post-cut target LTV (WAD). When current LTV exceeds it, the position may
    ///         be settled without being the queue root. 0 clears it.
    function setSettlementLtv(uint256 ltv) external;

    /// @notice Borrower's personal post-cut target LTV (WAD) and its target-LTV slice, excluding root policy.
    function settlementLtv(address borrower) external view returns (uint256 ltv, uint256 sliceAssets);

    /// @notice Number of borrowers tracked in the settlement queue.
    function settlementBorrowersCount() external view returns (uint256);

    /// @notice True if any tracked borrower is bad debt — its debt value exceeds its collateral value.
    /// @dev O(1): it checks the riskiest tracked position (the highest debt/collateral), whose solvency
    ///      implies every tracked position is solvent, so the settle gate need only check that one.
    function hasBadDebt() external view returns (bool);

    /// @notice The queue root and the cut it is eligible for — whichever is larger, the root policy's allowance
    ///         or the borrower's own settlement-LTV allowance — shrunk to what `budgetSupplyShares` of core supply
    ///         funds. Pass 0 for the policy cut itself, unshrunk. A concrete lender may execute the root-policy
    ///         part only against its illiquid supply tail. `borrower` is address(0) when the queue is empty.
    function nextSettlementBorrower(uint256 budgetSupplyShares)
        external
        view
        returns (address borrower, SettlementSlice memory slice);

    /// @notice The borrower's personal cut and its prospective queue-root cut, each shrunk to what
    ///         `budgetSupplyShares` of core supply funds. Pass 0 for the policy cuts themselves, unshrunk. The
    ///         queue-root quote does not assert that the borrower is currently the root. A candidate that grants
    ///         no cut is represented by an all-zero slice.
    function settlementFor(address borrower, uint256 budgetSupplyShares)
        external
        view
        returns (SettlementQuote memory quote);

    /// @notice A window of queued borrowers (approximate top-down order) and their risk keys: up to
    ///         `maxCount` starting at `offset`. Past the end the arrays are empty, so callers can page.
    function settlementBorrowers(uint256 offset, uint256 maxCount)
        external
        view
        returns (address[] memory borrowers, uint256[] memory keys);

    // ---
    // FREEZE & PAUSE
    // ---

    /// @notice Freeze the market: new borrows and debt-bearing collateral withdrawals revert, and activation
    ///         maturation is deferred. Freeze adds no debt gate to debt-free withdrawals, but existing activation
    ///         locks still apply.
    function freeze() external;

    /// @notice Lift the freeze.
    function unfreeze() external;

    /// @notice Pause every hook for `duration` seconds. Pass PAUSE_INFINITELY for an indefinite pause.
    function pauseFor(uint256 duration) external;

    /// @notice Lift the pause.
    function resume() external;

    /// @notice Whether the market is frozen.
    function isFrozen() external view returns (bool);

    // ---
    // POSITION VIEW
    // ---

    /// @notice One-call borrower dashboard: collateral split, activation unlock, guardian signal, debt,
    ///         personal settlement target, current queue status, and policy quotes.
    function positionOf(address borrower) external view returns (BorrowerPosition memory);
}
