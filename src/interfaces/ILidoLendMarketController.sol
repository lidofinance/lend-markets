// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";
import {CollateralActivationLib} from "../libs/CollateralActivationLib.sol";
import {SettlementConfig} from "../types/SettlementTypes.sol";

/// @title ILidoLendMarketController
/// @notice Full external surface of `LidoLendMarketController`: the core hook interface and AccessControl
///         (both inherited), the Lido-policy levers, freeze/pause, the settlement-queue views, and the
///         borrower dashboard. The controller implements this interface, so it is the single source for
///         the dashboard struct, events, errors, and the function docs the contract inherits.
interface ILidoLendMarketController is ILidoLendBaseMarketController, IAccessControl {
    // ---
    // EVENTS
    // ---

    /// @notice Emitted when the market is frozen or unfrozen.
    event FrozenSet(bool frozen, address indexed account);

    /// @notice Emitted when a borrower's instant-activation (no maturation timer) status is set.
    event InstantActivationSet(address indexed borrower, bool enabled);

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

    /// @notice Thrown when a risk-steward lever would loosen a parameter instead of tightening it.
    error ConfigNotTightened();

    /// @notice Thrown when active (matured) collateral cannot cover the debt at the market LLTV.
    error InsufficientActiveCollateral();

    /// @notice Thrown when a withdrawal would draw a borrower's collateral below the activation minimum
    ///         while it still owes debt. Repaying to zero lifts the floor.
    error CollateralFloorBreached();

    /// @notice Thrown when a core-applied position delta exceeds the controller's read of that position.
    ///         The controller's accounting mirrors the core, so a divergence reverts instead of masking it.
    error PositionAccountingMismatch();

    /// @notice Thrown when a tracked borrower is bad debt, blocking settlement.
    error SettlementBadDebt();

    /// @notice Thrown when the settle target is neither next in line to settle nor has a settlement LTV set.
    error SettlementIneligible();

    /// @notice Thrown when the requested cut exceeds the policy-allowed slice.
    error SettlementExceedsAllowed();

    /// @notice Thrown when the cut's shares exceed the borrower's debt.
    error SettlementExceedsDebt();

    /// @notice Thrown when the seized collateral is zero or exceeds the borrower's collateral.
    error SettlementInvalidSeize();

    // ---
    // TYPES
    // ---

    /// @notice One-read borrower snapshot for off-chain dashboards: collateral split, activation timer,
    ///         guardian signal, debt, personal settle-down LTV, and live settle exposure.
    /// @param active Matured collateral, borrowable.
    /// @param activating Collateral inside the activation timer, not yet borrowable.
    /// @param dust Collateral below the activation threshold, withdrawable.
    /// @param unlockTime Activation unlock timestamp, 0 when there is no timer.
    /// @param strikes Effective guardian strike count driving the activation surcharge (0 while immune).
    /// @param flagCount Raw guardian flags on the account, regardless of status (visible even while immune).
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
        uint256 strikes;
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

    /// @notice Role gating the risk-increasing levers: full activation config, granting instant activation,
    ///         and the settlement config. Meant for the EasyTrack factory.
    function MANAGER_ROLE() external view returns (bytes32);

    /// @notice Role gating the fast risk-reducing levers, each one-directional toward tighter policy: raise the
    ///         activation delay floor/cap, set the Sybil hold, revoke instant activation.
    function RISK_STEWARD_ROLE() external view returns (bytes32);

    /// @notice Role allowed to freeze the market.
    function FREEZER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to lift a freeze.
    function UNFREEZER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to pause the hooks.
    function PAUSER_ROLE() external view returns (bytes32);

    /// @notice Role allowed to lift a pause.
    function RESUMER_ROLE() external view returns (bytes32);

    // ---
    // COLLATERAL ACTIVATION
    // ---

    /// @notice Update the governance-tunable activation parameters. Risk-increasing path: the role is meant
    ///         to be held by the EasyTrack factory, which adds the objection window.
    function setConfig(CollateralActivationLib.Config calldata cfg) external;

    /// @notice Fast risk-reducing lever: raise the activation delay floor. Reverts if it would lower.
    function increaseMinActivationDelay(uint40 newMinActivationDelay) external;

    /// @notice Fast risk-reducing lever: raise the activation delay cap. Reverts if it would lower.
    function increaseMaxActivationDelay(uint40 newMaxActivationDelay) external;

    /// @notice Risk-steward lever (Sybil protection): hold up to `activatingHold` of each position's
    ///         activating collateral unwithdrawable until it matures. 0 (the default) disables it.
    function setActivatingHold(uint128 activatingHold) external;

    /// @notice Current decayed activation inflow (the throttle accumulator) — for monitoring and tests.
    function currentInflow() external view returns (uint256);

    /// @notice Whitelist `borrower` to skip the activation maturation timer — its collateral becomes active on
    ///         deposit. Risk-increasing path (waives the anti-flash/Sybil delay): meant for the EasyTrack
    ///         factory and reserved for trusted addresses. Ban and freeze still gate as usual.
    function grantInstantActivation(address borrower) external;

    /// @notice Fast risk-reducing lever: remove `borrower`'s instant activation, restoring the timer.
    function revokeInstantActivation(address borrower) external;

    /// @notice Whether `borrower` skips the activation maturation timer.
    function hasInstantActivation(address borrower) external view returns (bool);

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

    /// @notice The next borrower the settlement would cut and the max slice allowed for it (the larger of the
    ///         config slice and the borrower's settlement-LTV slice, the bound the hook caps at), as both loan
    ///         assets and the equivalent Morpho supply shares. `borrower` is address(0) when the queue is empty.
    function nextSettlementBorrower() external view returns (address borrower, uint256 sliceAssets, uint256 sliceShares);

    /// @notice Maximum slice allowed for a single settle cut against `borrower` (the larger of the config
    ///         slice and the borrower's settlement-LTV slice), as both loan assets and the equivalent Morpho
    ///         supply shares. Zero means ineligible.
    function settlementFor(address borrower) external view returns (uint256 sliceAssets, uint256 sliceShares);

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

    // ---
    // POSITION VIEW
    // ---

    /// @notice One-call borrower dashboard: collateral split, activation unlock, guardian signal, debt,
    ///         personal settle-down LTV, and live settle exposure (next-to-settle flag + slice).
    function positionOf(address borrower) external view returns (BorrowerPosition memory);
}
