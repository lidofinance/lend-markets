// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {SettlementConfig, SettlementQuote, SettlementSlice} from "../types/SettlementTypes.sol";
import {ILidoLendMarketConfigurator} from "./ILidoLendMarketConfigurator.sol";
import {IPausableUntil} from "./IPausableUntil.sol";

/// @title ILidoLendMarketController
/// @notice Contract-specific external surface of `LidoLendMarketController`: the inherited core hook interface,
///         Lido policy, freeze/pause, settlement-queue views, and the borrower position view. The controller's
///         `BorrowerPosition` struct, events, and errors are declared here.
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
    /// @param frozen The new freeze state.
    /// @param account Caller that set it.
    event FrozenSet(bool frozen, address indexed account);

    /// @notice Emitted when a trusted caller's instant-activation status is set.
    /// @param caller The supply caller whose trusted status was set.
    /// @param enabled Whether that caller's supplies activate instantly.
    event InstantActivationSet(address indexed caller, bool enabled);

    /// @notice Emitted when the supply cap is set.
    /// @param cap The new supply cap.
    /// @param account Caller that set the cap.
    event SupplyCapSet(uint256 cap, address indexed account);

    /// @notice Emitted once when the market binds its guardian-signals registry at initialization.
    /// @param guardianSignals The bound guardian-signals registry.
    event GuardianSignalsSet(address indexed guardianSignals);

    // ---
    // ERRORS
    // ---

    /// @notice The hook caller is not the core.
    error Unauthorized();

    /// @notice A required address argument is zero.
    error ZeroAddress();

    /// @notice The hook id is not this controller's market.
    error InvalidMarketId();

    /// @notice The hook event is unrecognized.
    error UnknownHookEvent();

    /// @notice A freeze blocks the action.
    error MarketIsFrozen();

    /// @notice The borrow's caller, receiver, or borrower is banned.
    error AddressBanned();

    /// @notice The supply would push the market's total supplied loan assets above the cap.
    /// @param cap The supply cap.
    /// @param attempted Total supplied loan assets the deposit would reach.
    error SupplyCapExceeded(uint256 cap, uint256 attempted);

    /// @notice Active (matured) collateral cannot cover the debt at the market LLTV.
    error InsufficientActiveCollateral();

    /// @notice The borrow would mint borrow shares while transferring zero loan assets.
    error ZeroBorrowAssets();

    /// @notice The borrow, repay, or settle would push the market's borrow-share rate over the ceiling.
    error BorrowShareRateExceeded();

    /// @notice A core-applied position delta exceeds the controller's read of that position.
    ///         The controller's accounting mirrors the core, so a divergence reverts instead of masking it.
    error PositionAccountingMismatch();

    /// @notice The settlement queue's root is bad debt, blocking settlement.
    error SettlementBadDebt();

    /// @notice The requested cut exceeds the policy-allowed slice (a zero slice means ineligible).
    error SettlementExceedsAllowed();

    /// @notice The root-policy cut exceeds the lender's illiquid supply tail.
    error SettlementExceedsSettleableSupply();

    // ---
    // TYPES
    // ---

    /// @notice One-read borrower snapshot: collateral split, activation timer, guardian signal, debt,
    ///         personal settlement target, current queue status, and policy quotes.
    /// @param active Derived collateral outside the stored inactive buckets, including matured and instantly
    ///        activated amounts. It supports borrowing only when the total meets the current activation threshold.
    /// @param activating Collateral inside the activation timer, not yet borrowable.
    /// @param dust Stored untimed collateral classified as dust. Configuration changes do not reclassify it, so it
    ///        need not remain below the current activation threshold. It is not borrowable.
    /// @param unlockTime Activation unlock timestamp, 0 when there is no timer.
    /// @param flagCount Raw guardian flags on the account, regardless of status.
    /// @param banned Effective guardian ban: either the stored latch or a flag count at or above the current quorum.
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
    ///         exempt). Near an empty debt book, borrow-and-near-full-repay cycles would otherwise inflate the
    ///         share total toward overflow.
    function MAX_BORROW_SHARE_RATE() external view returns (uint256);

    // ---
    // LENDER LIMITS
    // ---

    /// @notice Loan assets the market still accepts from lenders: the remaining supply-cap headroom,
    ///         `type(uint256).max` when uncapped, 0 while paused.
    function maxDeposit() external view returns (uint256);

    /// @notice Loan assets `supplier` can withdraw from its market supply right now: its position capped by
    ///         the market's free liquidity, 0 while paused.
    function maxWithdrawableAssets(address supplier) external view returns (uint256);

    /// @notice The guardian-signals registry.
    function guardianSignals() external view returns (address);

    // ---
    // COLLATERAL ACTIVATION
    // ---

    /// @notice Current decayed activation inflow: the throttle accumulator.
    function currentInflow() external view returns (uint256);

    /// @notice Base inflow-throttle delay for a hypothetical `inflowIncrement` at the current decayed inflow.
    ///         Excludes instant activation, any existing dust, the minimum amount, and guardian surcharges; it is
    ///         not a complete quote for a specific collateral supply.
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

    /// @notice Whether the current settlement-queue root has bad debt: its debt value exceeds its collateral value.
    ///         While true, every settlement path is blocked, so a lender cannot exit at full value and leave the
    ///         unrealized loss to the remaining lenders.
    /// @dev O(1): checks only the root selected by the rounded borrow-share/raw-collateral key. It does not scan all
    ///      tracked borrowers. Equal keys and separate debt/collateral valuation rounding mean that a solvent root
    ///      does not prove every other tracked position is solvent.
    function hasBadDebt() external view returns (bool);

    /// @notice The queue root and the cut it is eligible for: the larger of the root policy's allowance and the
    ///         borrower's own settlement-LTV allowance, shrunk to what `budgetSupplyShares` of core supply funds.
    ///         Pass 0 to get the policy cut unshrunk. A cut above the settlement-LTV allowance must fit the
    ///         settling lender's illiquid supply tail in full. `borrower` is address(0) when the queue is empty,
    ///         and the slice quotes zero `borrowShares` when no executable cut is available.
    function nextSettlementBorrower(uint256 budgetSupplyShares)
        external
        view
        returns (address borrower, SettlementSlice memory slice);

    /// @notice The borrower's personal cut and its prospective queue-root cut, each shrunk to what
    ///         `budgetSupplyShares` of core supply funds. Pass 0 to get the policy cuts unshrunk. The queue-root
    ///         quote does not assert that the borrower is currently the root. A candidate that grants no cut
    ///         quotes zero `borrowShares`, including one whose cut would be too small to seize a whole collateral
    ///         unit, which the core rejects.
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
    ///         maturation is deferred. Freeze blocks risk-increasing actions while repay, liquidation,
    ///         settlement, and lender exits remain available; it adds no debt gate to debt-free withdrawals,
    ///         though existing activation locks still apply.
    function freeze() external;

    /// @notice Lift the freeze.
    function unfreeze() external;

    /// @notice Pause every hook for `duration` seconds: unlike a freeze, this stops every market action,
    ///         including repay, liquidation, and settlement, for incidents in which even those are unsafe.
    ///         Pass PAUSE_INFINITELY for an indefinite pause.
    function pauseFor(uint256 duration) external;

    /// @notice Lift the pause.
    function resume() external;

    /// @notice Whether the market is frozen.
    function isFrozen() external view returns (bool);

    // ---
    // POSITION VIEW
    // ---

    /// @notice One-call borrower snapshot: collateral split, activation unlock, guardian signal, debt,
    ///         personal settlement target, current queue status, and policy quotes.
    function positionOf(address borrower) external view returns (BorrowerPosition memory);
}
