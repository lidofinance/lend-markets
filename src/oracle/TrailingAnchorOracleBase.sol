// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WAD} from "../libs/Constants.sol";

/// @dev Decimals of the prices adapters return from `_currentPrice()` and the anchor stores.
uint256 constant PRICE_DECIMALS = 18;
/// @dev Decimals of the price Morpho reads: one collateral unit in loan units, scaled by 1e36.
uint256 constant ORACLE_PRICE_DECIMALS = 36;

/// @title TrailingAnchorOracleBase
/// @author Lido
/// @notice Lido Lend oracle for collateral priced from a source quoted in the loan token's currency, at one loan token
///         per unit of that currency. It returns the current price scaled by `PRICE_SCALE`, and reverts while that
///         price sits outside the bounds around the anchor price and while the manager suspends pricing.
/// @dev Concrete oracles bind one source in their constructor and override `_currentPrice()` with its ABI. Each
///      declares its own storage namespace, so an anchor never carries over to an adapter of another kind.
///
///      Anyone can call `updateAnchor()`. A current price within the bounds drags the anchor toward it at the yearly
///      speeds, so the bounds follow a source that changes slowly. A current price outside them is recorded as a
///      pending anchor. While the price stays outside the bounds on the pending anchor's side the anchor holds still,
///      and once the pending anchor has waited `reanchorDelay` an update within `reanchorWindow` moves the anchor onto
///      the pending anchor, or onto the price if it sits nearer the anchor. So a move past the bounds becomes the price
///      only after it has been public for a whole delay: the time to stop the markets that read the oracle.
///
///      No update takes the anchor more than `maxAnchorBelowMark` below `highWaterMark`, and no re-anchor more than
///      `maxAnchorAboveMark` above it. That mark is the seed or the last accepted price, and only a drift up raises it,
///      so however many steps a source takes past the bounds, it moves the anchor at most down to the floor and up to
///      the ceiling; going further takes `acceptPrice()`.
abstract contract TrailingAnchorOracleBase is AccessControlEnumerableUpgradeable, IOracle {
    // ---
    // TYPES
    // ---

    /// @notice What `initialize()` and `setParameters()` store, in the units of the getters of the same names.
    struct Parameters {
        uint64 maxPriceAboveAnchor;
        uint64 maxPriceBelowAnchor;
        uint64 maxAnchorRisePerYear;
        uint64 maxAnchorFallPerYear;
        uint64 maxAnchorBelowMark;
        uint64 maxAnchorAboveMark;
        uint40 reanchorDelay;
        uint40 reanchorWindow;
    }

    /// @notice What one `updateAnchor()` call did, by the case it took:
    ///         - `WithinBounds`: the anchor moved toward the price as far as the speeds and the floor allow, and the
    ///           pending anchor, if any, was dropped;
    ///         - `PendingAnchorRecorded`: the price, outside the bounds with no held pending anchor, became the pending
    ///           anchor;
    ///         - `PendingAnchorHeld`: the held pending anchor waits out its delay; nothing changed;
    ///         - `PendingAnchorApplied`: the anchor moved onto the pending anchor or the price, whichever is nearer,
    ///           and no further than the floor or the ceiling; a price still outside the new bounds became the next
    ///           pending anchor;
    ///         - `AnchorOnFloor`: the delay passed, but the anchor sits on or below the floor; nothing changed;
    ///         - `AnchorOnCeiling`: the delay passed, but the anchor sits on or above the ceiling; nothing changed.
    enum UpdateOutcome {
        WithinBounds,
        PendingAnchorRecorded,
        PendingAnchorHeld,
        PendingAnchorApplied,
        AnchorOnFloor,
        AnchorOnCeiling
    }

    // ---
    // ROLES
    // ---

    /// @notice Sets the parameters and suspends pricing.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @notice Accepts the current price as the anchor, whatever its distance from the last one.
    bytes32 public constant PRICE_ACCEPTOR_ROLE = keccak256("PRICE_ACCEPTOR_ROLE");

    // ---
    // CONSTANTS AND IMMUTABLES
    // ---

    /// @dev 10^(ORACLE_PRICE_DECIMALS + loanDecimals - collateralDecimals - PRICE_DECIMALS): the scaling of a price to
    ///      the price Morpho reads.
    uint256 public immutable PRICE_SCALE;

    /// @notice Shortest `reanchorDelay`.
    uint256 public constant MIN_REANCHOR_DELAY = 1 hours;
    /// @notice Longest a pricing suspension may run from the call that sets it.
    uint256 public constant MAX_PRICING_SUSPENSION = 7 days;
    /// @dev The period `maxAnchorRisePerYear` and `maxAnchorFallPerYear` are quoted per.
    uint256 private constant YEAR = 365 days;

    // ---
    // ERRORS
    // ---

    /// @notice An address argument was the zero address.
    error ZeroAddress();
    /// @notice The loan and collateral decimals leave no room for the 1e36 convention.
    error UnsupportedDecimals(uint256 loanDecimals, uint256 collateralDecimals);
    /// @notice A parameter is outside the range `setParameters()` names.
    error InvalidParameters();
    /// @notice The suspension would end more than `MAX_PRICING_SUSPENSION` from now.
    error InvalidPricingResumesAt(uint40 resumesAt);
    /// @notice The source returned zero.
    error ZeroPrice();
    /// @notice The current price sits outside the bounds around the anchor price.
    error PriceOutOfBounds(uint256 currentPrice, uint256 lowerBound, uint256 upperBound);
    /// @notice Pricing is suspended until `resumesAt`.
    error PricingSuspended(uint40 resumesAt);
    /// @notice The current price sits outside the range the price acceptor passed.
    error UnexpectedPrice(uint256 currentPrice, uint256 minPrice, uint256 maxPrice);

    // ---
    // EVENTS
    // ---

    /// @notice The anchor was set; `accepted` is true for the seed in `initialize()` and for `acceptPrice()`, false for
    ///         an update.
    event AnchorSet(uint256 anchorPrice, uint40 anchorAt, bool accepted);
    /// @notice An update recorded a pending anchor.
    event PendingAnchorSet(uint256 pendingAnchorPrice, uint40 pendingAnchorAt);
    /// @notice The pending anchor was dropped.
    event PendingAnchorCleared();
    /// @notice An `updateAnchor()` call ran: what it did and the current price it read. Emitted after the events of
    ///         the state it changed.
    event AnchorUpdated(UpdateOutcome indexed outcome, uint256 currentPrice);
    /// @notice The parameters changed.
    event ParametersSet(Parameters parameters);
    /// @notice The time pricing resumes at changed.
    event PricingResumesAtSet(uint40 resumesAt);

    // ---
    // STORAGE
    // ---

    // Slot layout; `price()` reads only the first two:
    // 0: maxPriceAboveAnchor, maxPriceBelowAnchor, anchorAt, pricingResumesAt
    // 1: anchorPrice
    // 2: maxAnchorRisePerYear, maxAnchorFallPerYear, reanchorDelay, reanchorWindow, pendingAnchorAt
    // 3: pendingAnchorPrice
    // 4: maxAnchorBelowMark, maxAnchorAboveMark
    // 5: highWaterMark

    /// @notice How far the current price may sit above the anchor price before `price()` reverts, as a fraction of it,
    ///         WAD. 0.0005e18 allows 0.05%.
    uint64 public maxPriceAboveAnchor;
    /// @notice How far the current price may sit below the anchor price before `price()` reverts, as a fraction of it,
    ///         WAD. 0.001e18 allows 0.1%.
    uint64 public maxPriceBelowAnchor;
    /// @notice When the anchor price was last set.
    uint40 public anchorAt;
    /// @notice Time before which `price()` reverts with `PricingSuspended`.
    uint40 public pricingResumesAt;

    /// @notice Price the current price is compared with, with `PRICE_DECIMALS` decimals.
    uint256 public anchorPrice;

    /// @notice Yearly speed at which an update may raise the anchor toward a price within the bounds, as a fraction of
    ///         the anchor price, WAD. 0.06e18 lets it rise 6% a year, about 0.016% a day.
    uint64 public maxAnchorRisePerYear;
    /// @notice Yearly speed at which an update may lower the anchor toward a price within the bounds, as a fraction of
    ///         the anchor price, WAD. 0.01e18 lets it fall 1% a year, about 0.003% a day.
    uint64 public maxAnchorFallPerYear;
    /// @notice Seconds a pending anchor waits before an update can re-anchor.
    uint40 public reanchorDelay;
    /// @notice Seconds after the delay during which an update can re-anchor; after them the pending anchor expires, and
    ///         the next update drops it or replaces it with a current price outside the bounds.
    uint40 public reanchorWindow;
    /// @notice When the pending anchor was recorded; zero for none.
    uint40 public pendingAnchorAt;

    /// @notice Current price an update recorded outside the bounds, with `PRICE_DECIMALS` decimals; zero for none. The
    ///         next re-anchor moves the anchor at most onto it: onto the current price if that sits nearer, and never
    ///         past the floor or the ceiling.
    uint256 public pendingAnchorPrice;

    /// @notice How far below `highWaterMark` an update may take the anchor, as a fraction of it, WAD. 0.01e18
    ///         allows 1%.
    uint64 public maxAnchorBelowMark;

    /// @notice How far above `highWaterMark` a re-anchor may take the anchor, as a fraction of it, WAD. 0.002e18
    ///         allows 0.2%.
    uint64 public maxAnchorAboveMark;

    /// @notice Price the floor and the ceiling are measured from, with `PRICE_DECIMALS` decimals: the seed or the last
    ///         accepted price, raised by a drift up, onto the new anchor when that passes it, or by the drift's step
    ///         while the anchor already sits above it. A re-anchor never moves it, so a re-anchor up may leave the
    ///         anchor above it, up to the ceiling.
    uint256 public highWaterMark;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param loanToken Loan token; its decimals set `PRICE_SCALE`.
    /// @param collateralToken Collateral token; its decimals set `PRICE_SCALE`.
    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address loanToken, address collateralToken) {
        if (loanToken == address(0) || collateralToken == address(0)) revert ZeroAddress();
        uint256 loanDecimals = IERC20Metadata(loanToken).decimals();
        uint256 collateralDecimals = IERC20Metadata(collateralToken).decimals();
        if (ORACLE_PRICE_DECIMALS + loanDecimals < collateralDecimals + PRICE_DECIMALS) {
            revert UnsupportedDecimals(loanDecimals, collateralDecimals);
        }
        PRICE_SCALE = 10 ** (ORACLE_PRICE_DECIMALS + loanDecimals - collateralDecimals - PRICE_DECIMALS);
        _disableInitializers();
    }

    // ---
    // INITIALIZATION
    // ---

    /// @notice Grants the admin, stores the parameters as `setParameters()` does and seeds the anchor from the current
    ///         price.
    function initialize(address admin, Parameters calldata parameters) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setParameters(parameters);
        _setAnchor(_currentPrice(), true);
    }

    // ---
    // EXTERNAL
    // ---

    /// @inheritdoc IOracle
    function price() external view override returns (uint256) {
        if (block.timestamp < pricingResumesAt) revert PricingSuspended(pricingResumesAt);
        uint256 currentPrice = _currentPrice();
        if (currentPrice == 0) revert ZeroPrice();
        _requireWithinBounds(currentPrice);
        return currentPrice * PRICE_SCALE;
    }

    /// @notice Moves the anchor toward a current price within the bounds, or, once a pending anchor has waited out the
    ///         delay with the price outside the bounds on its side, onto the pending anchor or the price, whichever is
    ///         nearer the anchor; records any other current price outside the bounds as the pending anchor. Neither
    ///         move takes the anchor under the floor, `maxAnchorBelowMark` below `highWaterMark`, nor a re-anchor over
    ///         the ceiling, `maxAnchorAboveMark` above it; an anchor already past one moves no further past it. Open to
    ///         anyone in any block, also while `price()` reverts. Each call emits `AnchorUpdated`.
    /// @dev `block.timestamp` sets the time counted: a validator's few seconds of skew move the speeds' reach and the
    ///      pending anchor's delay and window by those seconds.
    /// @return outcome What the call did; a keeper can read it with `eth_call` before sending the call.
    function updateAnchor() external returns (UpdateOutcome outcome) {
        uint256 currentPrice = _currentPrice();
        if (currentPrice == 0) revert ZeroPrice();

        if (_isWithinBounds(currentPrice)) {
            _moveAnchorTowards(currentPrice);
            _clearPendingAnchor();
            outcome = UpdateOutcome.WithinBounds;
        } else if (!_isPendingAnchorHeld(currentPrice)) {
            _recordPendingAnchor(currentPrice);
            outcome = UpdateOutcome.PendingAnchorRecorded;
        } else if (block.timestamp < uint256(pendingAnchorAt) + reanchorDelay) {
            outcome = UpdateOutcome.PendingAnchorHeld;
        } else {
            outcome = _applyPendingAnchor(currentPrice);
        }
        emit AnchorUpdated(outcome, currentPrice);
    }

    /// @notice Moves the anchor to the current price wherever it sits, once the price acceptor has checked the value,
    ///         restarts `highWaterMark` there and drops the pending anchor: the way out of a revert on the bounds
    ///         without waiting out the delay, and the only way under the floor or over the ceiling. A current price
    ///         outside `minPrice` and `maxPrice` is refused, so a price that moved after the check is not accepted.
    /// @param minPrice Lowest current price to accept, inclusive, with `PRICE_DECIMALS` decimals.
    /// @param maxPrice Highest current price to accept, inclusive, with `PRICE_DECIMALS` decimals.
    function acceptPrice(uint256 minPrice, uint256 maxPrice) external onlyRole(PRICE_ACCEPTOR_ROLE) {
        uint256 currentPrice = _currentPrice();
        if (currentPrice < minPrice || currentPrice > maxPrice) {
            revert UnexpectedPrice(currentPrice, minPrice, maxPrice);
        }
        _setAnchor(currentPrice, true);
        _clearPendingAnchor();
    }

    /// @notice Makes `price()` revert until `resumesAt`, at most `MAX_PRICING_SUSPENSION` from now, so liquidations
    ///         wait while borrowers can still repay. A time not in the future lifts the suspension. Updates and
    ///         acceptances run during a suspension.
    function setPricingResumesAt(uint40 resumesAt) external onlyRole(MANAGER_ROLE) {
        if (resumesAt > block.timestamp + MAX_PRICING_SUSPENSION) revert InvalidPricingResumesAt(resumesAt);
        pricingResumesAt = resumesAt;
        emit PricingResumesAtSet(resumesAt);
    }

    /// @notice Sets every parameter at once and drops the pending anchor; the anchor and `highWaterMark` stay where
    ///         they are. Each bound must be above zero and below a whole price, each speed at most a whole price a
    ///         year, `maxAnchorBelowMark` and `maxAnchorAboveMark` below a whole price, the delay at least
    ///         `MIN_REANCHOR_DELAY` and no longer than the rise speed takes to cover the upper bound, and the window
    ///         above zero.
    function setParameters(Parameters calldata parameters) external onlyRole(MANAGER_ROLE) {
        _setParameters(parameters);
    }

    // ---
    // INTERNAL
    // ---

    /// @dev Reads the current price from the source, with `PRICE_DECIMALS` decimals in the loan token's currency.
    ///      Reverts with the source.
    function _currentPrice() internal view virtual returns (uint256 currentPrice);

    // ---
    // PRIVATE
    // ---

    /// @dev Moves the anchor toward `currentPrice` by at most the yearly speeds for the time since it was last set, and
    ///      down never past the floor. A move up raises `highWaterMark` by its part above both the anchor and that
    ///      mark, so the gap a re-anchor up left between them stays. Callers pass a price within the bounds, so one
    ///      move never passes the bound however long the anchor rested; the fall term is capped at the anchor price
    ///      for the same reason.
    function _moveAnchorTowards(uint256 currentPrice) private {
        uint256 elapsed = block.timestamp - anchorAt;
        uint256 rise = Math.mulDiv(anchorPrice, maxAnchorRisePerYear * elapsed, WAD * YEAR);
        uint256 fall = Math.min(Math.mulDiv(anchorPrice, maxAnchorFallPerYear * elapsed, WAD * YEAR), anchorPrice);
        uint256 lowest = Math.max(anchorPrice - fall, _lowestAnchor());
        uint256 newAnchorPrice = Math.min(Math.max(currentPrice, lowest), anchorPrice + rise);
        if (newAnchorPrice == anchorPrice) return;
        uint256 top = Math.max(anchorPrice, highWaterMark);
        if (newAnchorPrice > top) highWaterMark += newAnchorPrice - top;
        _setAnchor(newAnchorPrice, false);
    }

    /// @dev The lowest anchor an update may set: the floor, `maxAnchorBelowMark` below `highWaterMark` with the
    ///      distance rounded down, or the anchor itself when it already sits lower.
    function _lowestAnchor() private view returns (uint256) {
        uint256 floor = highWaterMark - Math.mulDiv(highWaterMark, maxAnchorBelowMark, WAD);
        return Math.min(floor, anchorPrice);
    }

    /// @dev The highest anchor a re-anchor may set: the ceiling, `maxAnchorAboveMark` above `highWaterMark` with the
    ///      distance rounded down, or the anchor itself when it already sits higher.
    function _highestAnchor() private view returns (uint256) {
        uint256 ceiling = highWaterMark + Math.mulDiv(highWaterMark, maxAnchorAboveMark, WAD);
        return Math.max(ceiling, anchorPrice);
    }

    /// @dev Records `currentPrice`, outside the bounds, as the pending anchor at the current time.
    function _recordPendingAnchor(uint256 currentPrice) private {
        pendingAnchorPrice = currentPrice;
        pendingAnchorAt = uint40(block.timestamp);
        emit PendingAnchorSet(currentPrice, pendingAnchorAt);
    }

    /// @dev For a held pending anchor past its delay: moves the anchor onto it or `currentPrice`, whichever is nearer,
    ///      so never further than the published move, and never past the floor down or the ceiling up. Then drops the
    ///      pending anchor, or records `currentPrice` as the next one while it stays outside the bounds. An anchor
    ///      already on or past the floor or the ceiling it moves toward stays there until the price comes back or the
    ///      price acceptor accepts one.
    function _applyPendingAnchor(uint256 currentPrice) private returns (UpdateOutcome) {
        bool up = pendingAnchorPrice > anchorPrice;
        uint256 newAnchorPrice = up
            ? Math.min(Math.min(pendingAnchorPrice, currentPrice), _highestAnchor())
            : Math.max(Math.max(pendingAnchorPrice, currentPrice), _lowestAnchor());
        if (newAnchorPrice == anchorPrice) return up ? UpdateOutcome.AnchorOnCeiling : UpdateOutcome.AnchorOnFloor;
        _setAnchor(newAnchorPrice, false);
        if (_isWithinBounds(currentPrice)) _clearPendingAnchor();
        else _recordPendingAnchor(currentPrice);
        return UpdateOutcome.PendingAnchorApplied;
    }

    /// @dev Whether there is an unexpired pending anchor and `currentPrice`, outside the bounds, sits on its side of
    ///      the anchor price.
    function _isPendingAnchorHeld(uint256 currentPrice) private view returns (bool) {
        if (pendingAnchorAt == 0 || block.timestamp > uint256(pendingAnchorAt) + reanchorDelay + reanchorWindow) {
            return false;
        }
        return (pendingAnchorPrice > anchorPrice) == (currentPrice > anchorPrice);
    }

    /// @dev Reverts with `PriceOutOfBounds` unless `currentPrice` sits within the bounds around the anchor price.
    function _requireWithinBounds(uint256 currentPrice) private view {
        (uint256 lowerBound, uint256 upperBound) = _bounds();
        if (currentPrice < lowerBound || currentPrice > upperBound) {
            revert PriceOutOfBounds(currentPrice, lowerBound, upperBound);
        }
    }

    /// @dev Whether `currentPrice` sits within the bounds around the anchor price, both inclusive.
    function _isWithinBounds(uint256 currentPrice) private view returns (bool) {
        (uint256 lowerBound, uint256 upperBound) = _bounds();
        return currentPrice >= lowerBound && currentPrice <= upperBound;
    }

    /// @dev The lowest and highest prices the bounds allow around the anchor price, both rounded down.
    function _bounds() private view returns (uint256 lowerBound, uint256 upperBound) {
        lowerBound = Math.mulDiv(anchorPrice, WAD - maxPriceBelowAnchor, WAD);
        upperBound = Math.mulDiv(anchorPrice, WAD + maxPriceAboveAnchor, WAD);
    }

    /// @dev Sets the anchor to `newAnchorPrice` at the current time. The seed and an acceptance also restart
    ///      `highWaterMark` there.
    function _setAnchor(uint256 newAnchorPrice, bool accepted) private {
        if (newAnchorPrice == 0) revert ZeroPrice();
        anchorPrice = newAnchorPrice;
        anchorAt = uint40(block.timestamp);
        if (accepted) highWaterMark = newAnchorPrice;
        emit AnchorSet(newAnchorPrice, anchorAt, accepted);
    }

    /// @dev Drops the pending anchor, if there is one.
    function _clearPendingAnchor() private {
        if (pendingAnchorAt == 0) return;
        delete pendingAnchorPrice;
        delete pendingAnchorAt;
        emit PendingAnchorCleared();
    }

    /// @dev Stores the parameters once they pass the ranges `setParameters()` names, and drops the pending anchor.
    function _setParameters(Parameters calldata p) private {
        if (p.maxPriceAboveAnchor == 0 || p.maxPriceBelowAnchor == 0) revert InvalidParameters();
        if (p.maxPriceAboveAnchor >= WAD || p.maxPriceBelowAnchor >= WAD) revert InvalidParameters();
        if (p.maxAnchorBelowMark >= WAD || p.maxAnchorAboveMark >= WAD) revert InvalidParameters();
        if (p.maxAnchorRisePerYear > WAD || p.maxAnchorFallPerYear > WAD) revert InvalidParameters();
        if (p.reanchorDelay < MIN_REANCHOR_DELAY || p.reanchorWindow == 0) revert InvalidParameters();
        // A source rising at the rise speed must stay within the upper bound over one delay, or each re-anchor upward
        // would land short of the price and record the next pending anchor.
        if (uint256(p.reanchorDelay) * p.maxAnchorRisePerYear > uint256(p.maxPriceAboveAnchor) * YEAR) {
            revert InvalidParameters();
        }

        maxPriceAboveAnchor = p.maxPriceAboveAnchor;
        maxPriceBelowAnchor = p.maxPriceBelowAnchor;
        maxAnchorRisePerYear = p.maxAnchorRisePerYear;
        maxAnchorFallPerYear = p.maxAnchorFallPerYear;
        maxAnchorBelowMark = p.maxAnchorBelowMark;
        maxAnchorAboveMark = p.maxAnchorAboveMark;
        reanchorDelay = p.reanchorDelay;
        reanchorWindow = p.reanchorWindow;
        emit ParametersSet(p);
        _clearPendingAnchor();
    }
}
