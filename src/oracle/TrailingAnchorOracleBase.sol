// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {WAD} from "../libs/Constants.sol";

/// @title TrailingAnchorOracleBase
/// @author Lido
/// @notice Oracle for a market. It returns the price of the collateral token in the loan token. The price comes from
///         an external source. The oracle returns it only while it is near a stored anchor price. If the source
///         moves far from the anchor, `price()` reverts. The anchor then moves to the new price only after a delay,
///         which gives time to pause the market.
/// @dev Each adapter reads one source in `_currentPrice()`. Each adapter has its own storage namespace, so an
///      upgrade to a different adapter does not read the old anchor.
///
///      The oracle assumes that one loan token is worth one unit of the source currency, for example 1 USDC = 1 USD.
///
///      Anyone can call `updateAnchor()`:
///      - Price inside the bounds: the anchor moves toward the price, limited by the rise and fall rates. This is a
///        drift.
///      - Price outside the bounds: the update records it as the pending anchor. If the price stays outside for
///        `reanchorDelay`, the next update moves the anchor onto it. This is a re-anchor.
///
///      A drift cannot move the anchor below the floor. A re-anchor cannot move it below the floor or above the
///      ceiling. Only `acceptPrice()` moves it further.
abstract contract TrailingAnchorOracleBase is AccessControlEnumerableUpgradeable, IOracle {
    // ---
    // TYPES
    // ---

    /// @notice The values that `initialize()` and `setParameters()` store. Each field has the units of the getter with
    ///         the same name.
    struct Parameters {
        uint64 maxPriceAboveAnchor;
        uint64 maxPriceBelowAnchor;
        uint64 maxAnchorContinuousRiseRate;
        uint64 maxAnchorContinuousFallRate;
        uint64 maxAnchorBelowBase;
        uint64 maxAnchorAboveBase;
        uint40 reanchorDelay;
        uint40 reanchorWindow;
    }

    /// @notice The result of one `updateAnchor()` call:
    ///         - `WithinBounds`: the price is inside the bounds. The anchor drifted toward it as far as the rates and
    ///           the floor permit, and the pending anchor was dropped.
    ///         - `PendingAnchorRecorded`: the price is outside the bounds, and it became the pending anchor.
    ///         - `PendingAnchorHeld`: the held pending anchor is still in its delay. Nothing changed.
    ///         - `PendingAnchorApplied`: the anchor moved onto the pending anchor or the price, whichever is nearer,
    ///           but not past the floor or the ceiling. A price still outside the new bounds became the next pending
    ///           anchor.
    ///         - `AnchorOnFloor`: the delay is over, but the anchor is on or below the floor. Nothing changed.
    ///         - `AnchorOnCeiling`: the delay is over, but the anchor is on or above the ceiling. Nothing changed.
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

    /// @notice Can set the parameters and suspend pricing.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @notice Can accept the current price as the anchor, at any distance from the old anchor.
    bytes32 public constant PRICE_ACCEPTOR_ROLE = keccak256("PRICE_ACCEPTOR_ROLE");

    // ---
    // CONSTANTS AND IMMUTABLES
    // ---

    /// @dev Decimals of the price that an adapter returns and of the stored prices.
    uint256 internal constant PRICE_DECIMALS = 18;
    /// @dev Decimals of the price that the core reads: the price of one collateral unit in loan units, scaled by 1e36.
    uint256 internal constant ORACLE_PRICE_DECIMALS = 36;

    /// @notice Factor that converts a source price to the price that the core reads.
    /// @dev 10^(ORACLE_PRICE_DECIMALS + loanDecimals − collateralDecimals − PRICE_DECIMALS).
    uint256 public immutable PRICE_SCALE;

    /// @notice Shortest permitted `reanchorDelay`.
    uint256 public constant MIN_REANCHOR_DELAY = 1 hours;
    /// @notice Longest time that one call can suspend pricing, counted from that call.
    uint256 public constant MAX_PRICING_SUSPENSION = 7 days;
    /// @dev The period of the rise rate and the fall rate.
    uint256 private constant YEAR = 365 days;

    // ---
    // ERRORS
    // ---

    /// @notice An address argument is zero.
    error ZeroAddress();
    /// @notice The token decimals give a negative exponent for `PRICE_SCALE`.
    error UnsupportedDecimals(uint256 loanDecimals, uint256 collateralDecimals);
    /// @notice A parameter is outside the range that `setParameters()` permits.
    error InvalidParameters();
    /// @notice `resumesAt` is more than `MAX_PRICING_SUSPENSION` after the current time.
    error InvalidPricingResumesAt(uint40 resumesAt);
    /// @notice The source returned a zero price.
    error ZeroPrice();
    /// @notice The current price is outside the bounds around the anchor price.
    error PriceOutOfBounds(uint256 currentPrice, uint256 lowerBound, uint256 upperBound);
    /// @notice Pricing is suspended until `resumesAt`.
    error PricingSuspended(uint40 resumesAt);
    /// @notice The current price is outside the range that the caller gave.
    error UnexpectedPrice(uint256 currentPrice, uint256 minPrice, uint256 maxPrice);

    // ---
    // EVENTS
    // ---

    /// @notice The anchor changed. `accepted` is true for the seed in `initialize()` and for `acceptPrice()`, and
    ///         false for an update.
    event AnchorSet(uint256 anchorPrice, uint40 anchorAt, bool accepted);
    /// @notice An update recorded a pending anchor.
    event PendingAnchorSet(uint256 pendingAnchorPrice, uint40 pendingAnchorAt);
    /// @notice The pending anchor was dropped.
    event PendingAnchorCleared();
    /// @notice An `updateAnchor()` call completed, with its result and the current price that it read. The call emits
    ///         this event after the events of its state changes.
    event AnchorUpdated(UpdateOutcome indexed outcome, uint256 currentPrice);
    /// @notice The parameters changed.
    event ParametersSet(Parameters parameters);
    /// @notice The time at which pricing resumes changed.
    event PricingResumesAtSet(uint40 resumesAt);

    // ---
    // STORAGE
    // ---

    // Slot layout, counted from the base slot of the adapter's namespace. `price()` reads only slots 0 and 1.
    // 0: maxPriceAboveAnchor, maxPriceBelowAnchor, anchorAt, pricingResumesAt
    // 1: anchorPrice
    // 2: maxAnchorContinuousRiseRate, maxAnchorContinuousFallRate, reanchorDelay, reanchorWindow, pendingAnchorAt
    // 3: pendingAnchorPrice
    // 4: maxAnchorBelowBase, maxAnchorAboveBase
    // 5: basePrice

    /// @notice Upper bound: how far above the anchor price the current price can be, as a fraction of the anchor
    ///         price, WAD. Above it, `price()` reverts. 0.0005e18 is 0.05%.
    uint64 public maxPriceAboveAnchor;
    /// @notice Lower bound: how far below the anchor price the current price can be, as a fraction of the anchor
    ///         price, WAD. Below it, `price()` reverts. 0.001e18 is 0.1%.
    uint64 public maxPriceBelowAnchor;
    /// @notice Time when the anchor price was last set.
    uint40 public anchorAt;
    /// @notice Time before which `price()` reverts with `PricingSuspended`.
    uint40 public pricingResumesAt;

    /// @notice Price that the bounds are measured from, with `PRICE_DECIMALS` decimals.
    uint256 public anchorPrice;

    /// @notice Largest rate at which a drift can raise the anchor, continuously compounded per year, WAD. 0.06e18
    ///         permits a rise of e^0.06 − 1, about 6.18%, in a year. The update schedule does not change that.
    uint64 public maxAnchorContinuousRiseRate;
    /// @notice Largest rate at which a drift can lower the anchor, continuously compounded per year, WAD. 0.01e18
    ///         permits a fall of 1 − e^−0.01, about 0.995%, in a year. The update schedule does not change that.
    uint64 public maxAnchorContinuousFallRate;
    /// @notice Seconds that a pending anchor must wait before an update can re-anchor.
    uint40 public reanchorDelay;
    /// @notice Seconds after the delay in which an update can re-anchor. After the window, the pending anchor expires:
    ///         the next update drops it or records a new one.
    uint40 public reanchorWindow;
    /// @notice Time when the pending anchor was recorded. Zero means no pending anchor.
    uint40 public pendingAnchorAt;

    /// @notice Price of the pending anchor, with `PRICE_DECIMALS` decimals. Zero means no pending anchor.
    uint256 public pendingAnchorPrice;

    /// @notice Floor: how far below `basePrice` an update can move the anchor, as a fraction of that price, WAD.
    ///         0.01e18 is 1%.
    uint64 public maxAnchorBelowBase;

    /// @notice Ceiling: how far above `basePrice` a re-anchor can move the anchor, as a fraction of that price,
    ///         WAD. 0.002e18 is 0.2%.
    uint64 public maxAnchorAboveBase;

    /// @notice Price that the floor and the ceiling are measured from, with `PRICE_DECIMALS` decimals. It starts at the
    ///         seed price, and `acceptPrice()` restarts it at the accepted price. A drift up raises it. A re-anchor
    ///         does not change it, so a re-anchor up can leave the anchor above it, up to the ceiling.
    uint256 public basePrice;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param loanToken Loan token of the market. Its decimals set `PRICE_SCALE`.
    /// @param collateralToken Collateral token of the market. Its decimals set `PRICE_SCALE`.
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

    /// @notice Grants the admin role, stores the parameters and sets the first anchor to the current price. The call
    ///         reverts if the current price is outside `minPrice` and `maxPrice`.
    /// @param admin First holder of `DEFAULT_ADMIN_ROLE`.
    /// @param parameters The parameters, with the same checks as in `setParameters()`.
    /// @param minPrice Lowest current price to accept, inclusive, with `PRICE_DECIMALS` decimals.
    /// @param maxPrice Highest current price to accept, inclusive, with `PRICE_DECIMALS` decimals.
    function initialize(address admin, Parameters calldata parameters, uint256 minPrice, uint256 maxPrice)
        external
        initializer
    {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setParameters(parameters);
        _acceptPrice(minPrice, maxPrice);
    }

    // ---
    // EXTERNAL
    // ---

    /// @inheritdoc IOracle
    /// @dev Reverts while pricing is suspended, on a zero price, and while the current price is outside the bounds.
    function price() external view override returns (uint256) {
        if (block.timestamp < pricingResumesAt) revert PricingSuspended(pricingResumesAt);
        uint256 currentPrice = _currentPrice();
        if (currentPrice == 0) revert ZeroPrice();
        _requireWithinBounds(currentPrice);
        return currentPrice * PRICE_SCALE;
    }

    /// @notice Updates the anchor from the current price. Anyone can call it in any block, also while `price()`
    ///         reverts.
    ///         - Price inside the bounds: the anchor drifts toward it, and the pending anchor is dropped.
    ///         - Price outside the bounds with no held pending anchor: the price becomes the pending anchor.
    ///         - Held pending anchor in its delay: nothing changes.
    ///         - Held pending anchor after its delay: the anchor moves onto the pending anchor or the price,
    ///           whichever is nearer.
    ///
    ///         No update moves the anchor below the floor, and no re-anchor moves it above the ceiling. An anchor that
    ///         is already past one of them does not move further past it.
    /// @dev The call uses `block.timestamp`. A few seconds of validator skew change the drift limit, the delay and
    ///      the window by those seconds.
    /// @return outcome The result of the call. A keeper can read it with `eth_call` before it sends the transaction.
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

    /// @notice Sets the anchor and `basePrice` to the current price, at any distance from the old anchor, and
    ///         drops the pending anchor. It ends a revert on the bounds without the delay. It is the only way to
    ///         move the anchor past the floor or the ceiling.
    /// @dev The call reverts if the current price is outside `minPrice` and `maxPrice`. Thus a price that changed
    ///      after the caller checked it is not accepted.
    /// @param minPrice Lowest current price to accept, inclusive, with `PRICE_DECIMALS` decimals.
    /// @param maxPrice Highest current price to accept, inclusive, with `PRICE_DECIMALS` decimals.
    function acceptPrice(uint256 minPrice, uint256 maxPrice) external onlyRole(PRICE_ACCEPTOR_ROLE) {
        _acceptPrice(minPrice, maxPrice);
    }

    /// @notice Makes `price()` revert until `resumesAt`. Liquidations stop during that time, and borrowers can still
    ///         repay. A time that is not in the future ends the suspension. `updateAnchor()` and `acceptPrice()`
    ///         still work during a suspension.
    /// @param resumesAt Time at which pricing resumes, at most `MAX_PRICING_SUSPENSION` after the current time.
    function setPricingResumesAt(uint40 resumesAt) external onlyRole(MANAGER_ROLE) {
        if (resumesAt > block.timestamp + MAX_PRICING_SUSPENSION) revert InvalidPricingResumesAt(resumesAt);
        pricingResumesAt = resumesAt;
        emit PricingResumesAtSet(resumesAt);
    }

    /// @notice Sets all parameters and drops the pending anchor. The anchor and `basePrice` do not change. The
    ///         call reverts unless:
    ///         - each bound is above zero and below 1e18;
    ///         - `maxAnchorBelowBase` and `maxAnchorAboveBase` are below 1e18;
    ///         - each rate is at most 1e18;
    ///         - the delay is at least `MIN_REANCHOR_DELAY`, and the window is above zero;
    ///         - a source that moves at a rate for one delay stays inside the bound on that side.
    /// @dev The oracle does not know the markets that read it, so it does not check the parameters against their
    ///      LLTV. The manager must keep this rule for each market: a position borrowed at the LLTV against the highest
    ///      price still covers its debt and the liquidation incentive at the lowest price.
    ///      Highest price = ceiling × (1 + maxPriceAboveAnchor).
    ///      Lowest price = floor × (1 − maxPriceBelowAnchor).
    function setParameters(Parameters calldata parameters) external onlyRole(MANAGER_ROLE) {
        _setParameters(parameters);
    }

    // ---
    // INTERNAL
    // ---

    /// @dev Reads the current price from the source, with `PRICE_DECIMALS` decimals, in the currency of the loan
    ///      token. Reverts when the source reverts.
    function _currentPrice() internal view virtual returns (uint256 currentPrice);

    // ---
    // PRIVATE
    // ---

    /// @dev Drift. Moves the anchor toward `currentPrice`, limited by the rise or fall rate for the time since the
    ///      anchor was last set. A move down stops at the floor. A move up raises `basePrice` by the part of
    ///      the move above both the old anchor and that price, so the gap that a re-anchor up left between them
    ///      stays the same. The caller passes a price inside the bounds, so one move does not go past a bound after
    ///      a long rest.
    function _moveAnchorTowards(uint256 currentPrice) private {
        uint256 elapsed = block.timestamp - anchorAt;
        uint256 rise = Math.mulDiv(anchorPrice, _compoundedRise(maxAnchorContinuousRiseRate, elapsed), WAD);
        uint256 fall = Math.mulDiv(anchorPrice, _compoundedFall(maxAnchorContinuousFallRate, elapsed), WAD);
        uint256 lowest = Math.max(anchorPrice - fall, _lowestAnchor());
        uint256 newAnchorPrice = Math.min(Math.max(currentPrice, lowest), anchorPrice + rise);
        if (newAnchorPrice == anchorPrice) return;
        uint256 top = Math.max(anchorPrice, basePrice);
        if (newAnchorPrice > top) basePrice += newAnchorPrice - top;
        _setAnchor(newAnchorPrice, false);
    }

    /// @dev e^(rate × elapsed / YEAR) − 1 from its first three Taylor terms, WAD, rounded down. The three terms are
    ///      at most the exact value. Thus the total rise in a time T is at most e^(rate × T) − 1 for any schedule
    ///      of updates.
    function _compoundedRise(uint256 rate, uint256 elapsed) private pure returns (uint256) {
        return MathLib.wTaylorCompounded(Math.mulDiv(rate, elapsed, YEAR), 1);
    }

    /// @dev 1 − e^(−rate × elapsed / YEAR), computed as c / (1 + c) with c from `_compoundedRise`, WAD, rounded
    ///      down. The result is below 1e18. The total fall in a time T is at most 1 − e^(−rate × T) for any
    ///      schedule of updates.
    function _compoundedFall(uint256 rate, uint256 elapsed) private pure returns (uint256) {
        uint256 compounded = _compoundedRise(rate, elapsed);
        return Math.mulDiv(compounded, WAD, WAD + compounded);
    }

    /// @dev The lowest anchor that an update can set: the floor, or the anchor when it is already below the floor.
    ///      Floor = `basePrice` × (1 − maxAnchorBelowBase), with the subtracted part rounded down.
    function _lowestAnchor() private view returns (uint256) {
        uint256 floor = basePrice - Math.mulDiv(basePrice, maxAnchorBelowBase, WAD);
        return Math.min(floor, anchorPrice);
    }

    /// @dev The highest anchor that a re-anchor can set: the ceiling, or the anchor when it is already above the
    ///      ceiling. Ceiling = `basePrice` × (1 + maxAnchorAboveBase), with the added part rounded down.
    function _highestAnchor() private view returns (uint256) {
        uint256 ceiling = basePrice + Math.mulDiv(basePrice, maxAnchorAboveBase, WAD);
        return Math.max(ceiling, anchorPrice);
    }

    /// @dev Records `currentPrice`, which is outside the bounds, as the pending anchor at the current time.
    function _recordPendingAnchor(uint256 currentPrice) private {
        pendingAnchorPrice = currentPrice;
        pendingAnchorAt = uint40(block.timestamp);
        emit PendingAnchorSet(currentPrice, pendingAnchorAt);
    }

    /// @dev Re-anchor, for a held pending anchor after its delay. Moves the anchor onto the pending anchor or
    ///      `currentPrice`, whichever is nearer, so the move is not larger than the recorded one. The move stops at
    ///      the floor or the ceiling. An anchor that is already on or past that line does not move. After a move,
    ///      `currentPrice` becomes the next pending anchor if it is still outside the bounds. If not, the pending
    ///      anchor is dropped.
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

    /// @dev True if a pending anchor exists, has not expired, and is on the same side of the anchor as
    ///      `currentPrice`. The caller passes a price outside the bounds.
    function _isPendingAnchorHeld(uint256 currentPrice) private view returns (bool) {
        if (pendingAnchorAt == 0 || block.timestamp > uint256(pendingAnchorAt) + reanchorDelay + reanchorWindow) {
            return false;
        }
        return (pendingAnchorPrice > anchorPrice) == (currentPrice > anchorPrice);
    }

    /// @dev Reverts with `PriceOutOfBounds` if `currentPrice` is outside the bounds.
    function _requireWithinBounds(uint256 currentPrice) private view {
        (uint256 lowerBound, uint256 upperBound) = _bounds();
        if (currentPrice < lowerBound || currentPrice > upperBound) {
            revert PriceOutOfBounds(currentPrice, lowerBound, upperBound);
        }
    }

    /// @dev True if `currentPrice` is inside the bounds. The two bounds are inclusive.
    function _isWithinBounds(uint256 currentPrice) private view returns (bool) {
        (uint256 lowerBound, uint256 upperBound) = _bounds();
        return currentPrice >= lowerBound && currentPrice <= upperBound;
    }

    /// @dev The lowest and highest current price that the bounds permit, both rounded down.
    function _bounds() private view returns (uint256 lowerBound, uint256 upperBound) {
        lowerBound = Math.mulDiv(anchorPrice, WAD - maxPriceBelowAnchor, WAD);
        upperBound = Math.mulDiv(anchorPrice, WAD + maxPriceAboveAnchor, WAD);
    }

    /// @dev Sets the anchor to `newAnchorPrice` at the current time. If `accepted` is true, also sets
    ///      `basePrice` to that price.
    function _setAnchor(uint256 newAnchorPrice, bool accepted) private {
        anchorPrice = newAnchorPrice;
        anchorAt = uint40(block.timestamp);
        if (accepted) basePrice = newAnchorPrice;
        emit AnchorSet(newAnchorPrice, anchorAt, accepted);
    }

    /// @dev Sets the anchor and `basePrice` to the current price and drops the pending anchor. Reverts if the
    ///      price is zero or outside `minPrice` and `maxPrice`.
    function _acceptPrice(uint256 minPrice, uint256 maxPrice) private {
        uint256 currentPrice = _currentPrice();
        if (currentPrice == 0) revert ZeroPrice();
        if (currentPrice < minPrice || currentPrice > maxPrice) {
            revert UnexpectedPrice(currentPrice, minPrice, maxPrice);
        }
        _setAnchor(currentPrice, true);
        _clearPendingAnchor();
    }

    /// @dev Drops the pending anchor, if one exists.
    function _clearPendingAnchor() private {
        if (pendingAnchorAt == 0) return;
        delete pendingAnchorPrice;
        delete pendingAnchorAt;
        emit PendingAnchorCleared();
    }

    /// @dev Checks the parameters as `setParameters()` describes, stores them and drops the pending anchor.
    function _setParameters(Parameters calldata p) private {
        if (p.maxPriceAboveAnchor == 0 || p.maxPriceBelowAnchor == 0) revert InvalidParameters();
        if (p.maxPriceAboveAnchor >= WAD || p.maxPriceBelowAnchor >= WAD) revert InvalidParameters();
        if (p.maxAnchorBelowBase >= WAD || p.maxAnchorAboveBase >= WAD) revert InvalidParameters();
        if (p.maxAnchorContinuousRiseRate > WAD || p.maxAnchorContinuousFallRate > WAD) revert InvalidParameters();
        if (p.reanchorDelay < MIN_REANCHOR_DELAY || p.reanchorWindow == 0) revert InvalidParameters();
        // A source that moves at a rate must stay inside its bound for one delay. If not, each re-anchor stops short
        // of the price and records a new pending anchor.
        if (_compoundedRise(p.maxAnchorContinuousRiseRate, p.reanchorDelay) > p.maxPriceAboveAnchor) {
            revert InvalidParameters();
        }
        if (_compoundedFall(p.maxAnchorContinuousFallRate, p.reanchorDelay) > p.maxPriceBelowAnchor) {
            revert InvalidParameters();
        }

        maxPriceAboveAnchor = p.maxPriceAboveAnchor;
        maxPriceBelowAnchor = p.maxPriceBelowAnchor;
        maxAnchorContinuousRiseRate = p.maxAnchorContinuousRiseRate;
        maxAnchorContinuousFallRate = p.maxAnchorContinuousFallRate;
        maxAnchorBelowBase = p.maxAnchorBelowBase;
        maxAnchorAboveBase = p.maxAnchorAboveBase;
        reanchorDelay = p.reanchorDelay;
        reanchorWindow = p.reanchorWindow;
        emit ParametersSet(p);
        _clearPendingAnchor();
    }
}
