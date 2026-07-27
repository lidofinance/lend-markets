// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendMarketConfigurator} from "./ILidoLendMarketConfigurator.sol";
import {IPausableUntil} from "./IPausableUntil.sol";
import {SettlementConfig} from "../types/SettlementTypes.sol";

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

    // ---
    // ERRORS
    // ---

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

    /// @notice Thrown when a supply would push the market's total supplied loan assets above the cap.
    error SupplyCapExceeded(uint256 cap, uint256 attempted);

    /// @notice Thrown when active (matured) collateral cannot cover the debt at the market LLTV.
    error InsufficientActiveCollateral();

    /// @notice Thrown when a borrow would mint borrow shares while transferring zero loan assets.
    error ZeroBorrowAssets();

    /// @notice Thrown when a borrow draws fewer than `minimum` loan assets while the market's total borrow assets
    ///         are still below that floor — the dust regime where borrow-share inflation would be cheap.
    error BorrowBelowDustMarketMinimum(uint256 minimum, uint256 attempted);

    /// @notice Thrown when a core-applied position delta exceeds the controller's read of that position.
    ///         The controller's accounting mirrors the core, so a divergence reverts instead of masking it.
    error PositionAccountingMismatch();

    /// @notice Thrown when a tracked borrower is bad debt, blocking settlement.
    error SettlementBadDebt();

    /// @notice Thrown when the requested cut exceeds the policy-allowed slice (a zero slice means ineligible).
    error SettlementExceedsAllowed();

    // ---
    // TYPES
    // ---

    /// @notice One-read borrower snapshot for off-chain dashboards: collateral split, activation timer,
    ///         guardian signal, debt, personal settle-down LTV, and live settle exposure.
    /// @param active Matured collateral, borrowable.
    /// @param activating Collateral inside the activation timer, not yet borrowable.
    /// @param dust Collateral below the activation threshold, withdrawable.
    /// @param unlockTime Activation unlock timestamp, 0 when there is no timer.
    /// @param flagCount Raw guardian flags on the account, regardless of status.
    /// @param banned Hard-blocked by a latched guardian ban.
    /// @param debtAssets Current borrow debt, in loan assets.
    /// @param settlementLtv Borrower's personal settle-down target LTV (WAD), 0 when unset.
    /// @param isNextToSettle The borrower is next in line to be settled.
    /// @param slice Loan assets that may be cut from this position in one settle now.
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
        uint256 slice;
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

    /// @notice While the market's total borrow assets sit below this amount, every borrow must draw at least
    ///         this much loan assets. It fences borrow-share inflation by keeping the market out of the dust
    ///         regime where a 1-wei borrow mints a disproportionate slice of the outstanding shares.
    function DUST_MARKET_MIN_BORROW() external view returns (uint256);

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

    /// @notice Whitelist a trusted caller contract (e.g. a router supplying on behalf of users) so its supplies
    ///         cross straight into `active`, skipping the activation timer and inflow throttle. Risk-increasing
    ///         path (waives the anti-flash/Sybil delay): reserved for trusted, access-gated callers — never a
    ///         permissionless helper, which would waive the throttle for everyone routing through it. Keyed on
    ///         the supply caller, not the position owner. Ban and freeze still gate as usual.
    function grantInstantActivation(address caller) external;

    /// @notice Whether `caller`'s supplies skip the activation timer.
    function hasInstantActivation(address caller) external view returns (bool);

    // ---
    // SETTLEMENT QUEUE
    // ---

    /// @notice Set the settlement config in one shot — the knobs size the same cut and move together. A cut
    ///         is the largest of `sliceFloorBps` of the debt, `sliceFloorAssets`, and the cut that lowers the
    ///         borrower's LTV by `ltvStepBps`. `fullCutBelowCollateral` lifts the cut to the full debt when
    ///         the post-cut collateral would be dust.
    function setSettlementConfig(SettlementConfig calldata config) external;

    /// @notice The current settlement config.
    function settlementConfig() external view returns (SettlementConfig memory);

    /// @notice Borrower opts into auto-settle down to a target post-cut LTV (WAD). 0 clears it.
    function setSettlementLtv(uint256 ltv) external;

    /// @notice Borrower's personal settle-down target LTV (WAD) and the slice it currently implies.
    function settlementLtv(address borrower) external view returns (uint256 ltv, uint256 sliceAssets);

    /// @notice Number of borrowers tracked in the settlement queue.
    function settlementBorrowersCount() external view returns (uint256);

    /// @notice True if any tracked borrower is bad debt — its debt value exceeds its collateral value.
    /// @dev O(1): it checks the riskiest tracked position (the highest debt/collateral), whose solvency
    ///      implies every tracked position is solvent, so the settle gate need only check that one.
    function hasBadDebt() external view returns (bool);

    /// @notice The settle cut the policy allows against the queue root (the borrower a head-first settle cuts
    ///         first): `settlementFor` applied to it, with the root address. `borrower` is address(0) when empty.
    function nextSettlementBorrower()
        external
        view
        returns (address borrower, uint256 supplyShares, uint256 borrowShares, uint256 remainingBorrowShares);

    /// @notice The settle cut the policy allows against `borrower`, as the two anchors a core `settle` accepts:
    ///         the caller passes one and 0 for the other — `supplyShares` to settle supply-anchored, `borrowShares`
    ///         borrow-anchored. `remainingBorrowShares` is the debt left after the cut, 0 for a full close. All
    ///         zero when ineligible.
    function settlementFor(address borrower)
        external
        view
        returns (uint256 supplyShares, uint256 borrowShares, uint256 remainingBorrowShares);

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
    ///         maturation is deferred. Debt-free positions can still withdraw their collateral.
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
    ///         personal settle-down LTV, and live settle exposure (next-to-settle flag + slice).
    function positionOf(address borrower) external view returns (BorrowerPosition memory);
}
