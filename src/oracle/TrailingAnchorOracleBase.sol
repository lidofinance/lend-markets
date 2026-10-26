// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {WAD} from "../libs/Constants.sol";

/// @dev Decimals of the prices adapters return from `_currentPrice()` and the anchor stores.
uint256 constant PRICE_DECIMALS = 18;
/// @dev Decimals of the price Morpho reads: one collateral unit in loan units, scaled by 1e36.
uint256 constant ORACLE_PRICE_DECIMALS = 36;

/// @title TrailingAnchorOracleBase
/// @author Lido
/// @notice Lido Lend oracle for collateral priced from a source quoted in the loan token's currency, at one loan token
///         per unit of that currency. It returns the current price scaled by `PRICE_SCALE`, and reverts while that
///         price sits outside the bounds around the stored anchor price or while the anchor is older than its lifetime.
/// @dev Concrete oracles bind one source in their constructor and override `_currentPrice()` with its ABI. Each
///      declares its own storage namespace, so an anchor never carries over to an adapter of another kind. Anyone can
///      move the anchor toward the current price, in any block and also while that price sits outside the bounds, by at
///      most `maxAnchorRise` up or `maxAnchorFall` down a year for the time since the anchor last moved, capped at its
///      lifetime. So the bounds are how far the price can move from the anchor at once, and the speeds how fast the
///      anchor, and the bounds with it, can follow a source that keeps moving: a source held at the upper bound gains
///      the bound once and then the rise speed. An update needs a current price other than the one the anchor last
///      moved on, so a source that stops changing moves the anchor at most once more, and the oracle goes stale one
///      lifetime later even while the anchor still trails it. An update refuses a stale anchor, so reviving one, like a
///      move faster than the speeds, needs the price acceptor or the manager.
abstract contract TrailingAnchorOracleBase is AccessControlEnumerableUpgradeable, IOracle {
    using SafeCast for uint256;

    // ---
    // ROLES
    // ---

    /// @notice Sets the allowed price increase and decrease, the anchor lifetime and the anchor's rise and fall speeds.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @notice Accepts the current price as the anchor, whatever its distance from the last one.
    bytes32 public constant PRICE_ACCEPTOR_ROLE = keccak256("PRICE_ACCEPTOR_ROLE");

    // ---
    // CONSTANTS AND IMMUTABLES
    // ---

    /// @dev 10^(ORACLE_PRICE_DECIMALS + loanDecimals - collateralDecimals - PRICE_DECIMALS): the scaling of a price to
    ///      the price Morpho reads.
    uint256 public immutable PRICE_SCALE;

    /// @notice Bound `anchorLifetime` stays below.
    uint256 public constant MAX_ANCHOR_LIFETIME = 30 days;
    /// @dev The period `maxAnchorRise` and `maxAnchorFall` are quoted per.
    uint256 private constant YEAR = 365 days;

    // ---
    // ERRORS
    // ---

    /// @notice An address argument was the zero address.
    error ZeroAddress();
    /// @notice The loan and collateral decimals leave no room for the 1e36 convention.
    error UnsupportedDecimals(uint256 loanDecimals, uint256 collateralDecimals);
    /// @notice The allowed price increase is zero or reaches a whole price.
    error InvalidMaxPriceIncrease(uint256 maxPriceIncrease);
    /// @notice The allowed price decrease is zero or reaches a whole price.
    error InvalidMaxPriceDecrease(uint256 maxPriceDecrease);
    /// @notice The anchor lifetime is zero or not below `MAX_ANCHOR_LIFETIME`.
    error InvalidAnchorLifetime(uint256 anchorLifetime);
    /// @notice The anchor's rise speed is above a whole price a year.
    error InvalidMaxAnchorRise(uint256 maxAnchorRise);
    /// @notice The anchor's fall speed is above a whole price a year.
    error InvalidMaxAnchorFall(uint256 maxAnchorFall);
    /// @notice The source returned zero.
    error ZeroPrice();
    /// @notice The current price sits outside the bounds around the anchor price.
    error PriceOutOfBounds(uint256 currentPrice, uint256 lowerBound, uint256 upperBound);
    /// @notice The anchor is older than its lifetime.
    error StaleAnchor(uint40 anchorAt, uint40 anchorLifetime);
    /// @notice The current price is the one the anchor last moved on: the source has not changed since.
    error SourceUnchanged(uint256 currentPrice);
    /// @notice The update would leave the anchor where it is: the current price equals it, or the speeds allow no move
    ///         yet.
    error AnchorUnchanged(uint256 currentPrice);
    /// @notice The current price sits outside the range the price acceptor passed.
    error UnexpectedPrice(uint256 currentPrice, uint256 minPrice, uint256 maxPrice);

    // ---
    // EVENTS
    // ---

    /// @notice The anchor was set: by an open update, toward the current price as far as the speeds allow, or to the
    ///         current price by the seed in `initialize()` or by `acceptPrice()`, `accepted` telling which.
    event AnchorSet(uint256 anchorPrice, uint40 anchorAt, bool accepted);
    /// @notice The allowed price increase changed.
    event MaxPriceIncreaseSet(uint256 maxPriceIncrease);
    /// @notice The allowed price decrease changed.
    event MaxPriceDecreaseSet(uint256 maxPriceDecrease);
    /// @notice The anchor lifetime changed.
    event AnchorLifetimeSet(uint256 anchorLifetime);
    /// @notice The anchor's rise speed changed.
    event MaxAnchorRiseSet(uint256 maxAnchorRise);
    /// @notice The anchor's fall speed changed.
    event MaxAnchorFallSet(uint256 maxAnchorFall);

    // ---
    // STORAGE
    // ---

    // `price()` reads two slots: the bounds, the lifetime and `anchorAt` share the first and `anchorPrice` fills the
    // second. The speeds share the third and `sourcePrice` fills the fourth; only `updateAnchor()` reads them.

    /// @notice How far the current price may sit above the anchor price before `price()` reverts, as a fraction of the
    ///         anchor price, WAD: the rise the price may make from the anchor at once. 0.0005e18 allows 0.05%.
    uint64 public maxPriceIncrease;
    /// @notice How far the current price may sit below the anchor price before `price()` reverts, as a fraction of the
    ///         anchor price, WAD: the fall the price may make from the anchor at once. 0.001e18 allows 0.1%.
    uint64 public maxPriceDecrease;
    /// @notice Seconds after the anchor last moved before `price()` and `updateAnchor()` revert as stale, so an update
    ///         counts at most one lifetime of movement.
    uint40 public anchorLifetime;

    /// @notice When the anchor price was last set.
    uint40 public anchorAt;
    /// @notice Price the current price is compared with, with `PRICE_DECIMALS` decimals.
    uint256 public anchorPrice;

    /// @notice Yearly speed at which an update may raise the anchor: the fraction of the anchor price it may add per
    ///         year since the anchor last moved, WAD. 0.06e18 lets it rise 6% a year, about 0.016% a day.
    uint64 public maxAnchorRise;
    /// @notice Yearly speed at which an update may lower the anchor: the fraction of the anchor price it may take off
    ///         per year since the anchor last moved, WAD. 0.01e18 lets it fall 1% a year, about 0.003% a day.
    uint64 public maxAnchorFall;

    /// @notice Current price the anchor last moved on, read by the seed, an acceptance or an update, with
    ///         `PRICE_DECIMALS` decimals. An update that reads the same price reverts, so a source that stops changing
    ///         cannot keep the anchor fresh.
    uint256 public sourcePrice;

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

    /// @notice Grants the admin, stores the allowed price increase and decrease, the anchor lifetime and the anchor's
    ///         rise and fall speeds, and seeds the anchor from the current price.
    function initialize(
        address admin,
        uint256 maxPriceIncrease_,
        uint256 maxPriceDecrease_,
        uint256 anchorLifetime_,
        uint256 maxAnchorRise_,
        uint256 maxAnchorFall_
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setMaxPriceIncrease(maxPriceIncrease_);
        _setMaxPriceDecrease(maxPriceDecrease_);
        _setAnchorLifetime(anchorLifetime_);
        _setMaxAnchorRise(maxAnchorRise_);
        _setMaxAnchorFall(maxAnchorFall_);
        uint256 currentPrice = _currentPrice();
        _setAnchor(currentPrice, currentPrice, true);
    }

    // ---
    // EXTERNAL
    // ---

    /// @inheritdoc IOracle
    function price() external view override returns (uint256) {
        _requireFresh();
        uint256 currentPrice = _currentPrice();
        if (currentPrice == 0) revert ZeroPrice();
        _requireWithinBounds(currentPrice);
        return currentPrice * PRICE_SCALE;
    }

    /// @notice Moves the anchor toward the current price, by at most `maxAnchorRise` up or `maxAnchorFall` down a year
    ///         for the time since it last moved, capped at its lifetime. Open to anyone in any block, also while
    ///         `price()` reverts on the bounds: the speeds alone limit how far the anchor follows the source, and since
    ///         each update counts only the time since the last move, the anchor follows at the speeds however often it
    ///         is called. It reverts on a stale anchor, which only the price acceptor or a longer lifetime revives; on
    ///         a source that has not changed since the anchor last moved, so a frozen source cannot keep it fresh; and
    ///         when it would not move the anchor.
    /// @dev `block.timestamp` sets the time counted: a validator's few seconds of skew move the reach by the speeds
    ///      times those seconds. Both reach terms round down, toward the anchor, and the fall term stays under the
    ///      anchor price, since the fall speed is at most a whole price a year and the lifetime under a month.
    function updateAnchor() external {
        _requireFresh();
        uint256 currentPrice = _currentPrice();
        if (currentPrice == 0) revert ZeroPrice();
        if (currentPrice == sourcePrice) revert SourceUnchanged(currentPrice);
        uint256 elapsed = block.timestamp - anchorAt;
        uint256 lowest = anchorPrice - Math.mulDiv(anchorPrice, maxAnchorFall * elapsed, WAD * YEAR);
        uint256 highest = anchorPrice + Math.mulDiv(anchorPrice, maxAnchorRise * elapsed, WAD * YEAR);
        uint256 newAnchorPrice = Math.min(Math.max(currentPrice, lowest), highest);
        if (newAnchorPrice == anchorPrice) revert AnchorUnchanged(currentPrice);
        _setAnchor(newAnchorPrice, currentPrice, false);
    }

    /// @notice Moves the anchor to the current price wherever it sits, once the price acceptor has checked the value:
    ///         the way out of a stale anchor short of a longer lifetime, and out of a revert on the bounds faster than
    ///         the speeds allow. A current price outside `minPrice` and `maxPrice` is refused, so a price that moved
    ///         after the check is not accepted.
    /// @param minPrice Lowest current price to accept, inclusive, with `PRICE_DECIMALS` decimals.
    /// @param maxPrice Highest current price to accept, inclusive, with `PRICE_DECIMALS` decimals.
    function acceptPrice(uint256 minPrice, uint256 maxPrice) external onlyRole(PRICE_ACCEPTOR_ROLE) {
        uint256 currentPrice = _currentPrice();
        if (currentPrice < minPrice || currentPrice > maxPrice) {
            revert UnexpectedPrice(currentPrice, minPrice, maxPrice);
        }
        _setAnchor(currentPrice, currentPrice, true);
    }

    /// @notice Sets the allowed price increase. It applies at once and leaves the anchor where it is.
    function setMaxPriceIncrease(uint256 newMaxPriceIncrease) external onlyRole(MANAGER_ROLE) {
        _setMaxPriceIncrease(newMaxPriceIncrease);
    }

    /// @notice Sets the allowed price decrease. It applies at once and leaves the anchor where it is.
    function setMaxPriceDecrease(uint256 newMaxPriceDecrease) external onlyRole(MANAGER_ROLE) {
        _setMaxPriceDecrease(newMaxPriceDecrease);
    }

    /// @notice Sets the anchor lifetime. It applies at once, also to the time since the anchor last moved, and leaves
    ///         the anchor where it is.
    function setAnchorLifetime(uint256 newAnchorLifetime) external onlyRole(MANAGER_ROLE) {
        _setAnchorLifetime(newAnchorLifetime);
    }

    /// @notice Sets the anchor's yearly rise speed, `maxAnchorRise`. It applies at once, also to the time since the
    ///         anchor last moved, and leaves the anchor where it is.
    function setMaxAnchorRise(uint256 newMaxAnchorRise) external onlyRole(MANAGER_ROLE) {
        _setMaxAnchorRise(newMaxAnchorRise);
    }

    /// @notice Sets the anchor's yearly fall speed, `maxAnchorFall`. It applies at once, also to the time since the
    ///         anchor last moved, and leaves the anchor where it is.
    function setMaxAnchorFall(uint256 newMaxAnchorFall) external onlyRole(MANAGER_ROLE) {
        _setMaxAnchorFall(newMaxAnchorFall);
    }

    // ---
    // INTERNAL
    // ---

    /// @dev Reads the current price from the source, with `PRICE_DECIMALS` decimals in the loan token's currency.
    ///      Reverts with the source.
    function _currentPrice() internal view virtual returns (uint256 currentPrice);

    /// @dev Reverts once the anchor is older than its lifetime; exactly the lifetime old is still fresh.
    function _requireFresh() internal view {
        if (block.timestamp - anchorAt > anchorLifetime) revert StaleAnchor(anchorAt, anchorLifetime);
    }

    /// @dev Reverts unless the current price sits within `maxPriceDecrease` below and `maxPriceIncrease` above the
    ///      anchor price, both edges inclusive and rounded down.
    function _requireWithinBounds(uint256 currentPrice) internal view {
        uint256 lowerBound = Math.mulDiv(anchorPrice, WAD - maxPriceDecrease, WAD);
        uint256 upperBound = Math.mulDiv(anchorPrice, WAD + maxPriceIncrease, WAD);
        if (currentPrice < lowerBound || currentPrice > upperBound) {
            revert PriceOutOfBounds(currentPrice, lowerBound, upperBound);
        }
    }

    /// @dev Sets the anchor to `newAnchorPrice` at the current time, moved on `currentPrice`.
    function _setAnchor(uint256 newAnchorPrice, uint256 currentPrice, bool accepted) internal {
        if (newAnchorPrice == 0) revert ZeroPrice();
        anchorPrice = newAnchorPrice;
        anchorAt = uint40(block.timestamp);
        sourcePrice = currentPrice;
        emit AnchorSet(newAnchorPrice, anchorAt, accepted);
    }

    /// @dev Stores the allowed price increase once it passes the validator.
    function _setMaxPriceIncrease(uint256 newMaxPriceIncrease) internal {
        if (newMaxPriceIncrease == 0 || newMaxPriceIncrease >= WAD) {
            revert InvalidMaxPriceIncrease(newMaxPriceIncrease);
        }
        maxPriceIncrease = newMaxPriceIncrease.toUint64();
        emit MaxPriceIncreaseSet(newMaxPriceIncrease);
    }

    /// @dev Stores the allowed price decrease once it passes the validator.
    function _setMaxPriceDecrease(uint256 newMaxPriceDecrease) internal {
        if (newMaxPriceDecrease == 0 || newMaxPriceDecrease >= WAD) {
            revert InvalidMaxPriceDecrease(newMaxPriceDecrease);
        }
        maxPriceDecrease = newMaxPriceDecrease.toUint64();
        emit MaxPriceDecreaseSet(newMaxPriceDecrease);
    }

    /// @dev Stores the anchor lifetime once it passes the validator.
    function _setAnchorLifetime(uint256 newAnchorLifetime) internal {
        if (newAnchorLifetime == 0 || newAnchorLifetime >= MAX_ANCHOR_LIFETIME) {
            revert InvalidAnchorLifetime(newAnchorLifetime);
        }
        anchorLifetime = newAnchorLifetime.toUint40();
        emit AnchorLifetimeSet(newAnchorLifetime);
    }

    /// @dev Stores the anchor's rise speed once it passes the validator. Zero keeps open updates from raising the
    ///      anchor.
    function _setMaxAnchorRise(uint256 newMaxAnchorRise) internal {
        if (newMaxAnchorRise > WAD) revert InvalidMaxAnchorRise(newMaxAnchorRise);
        maxAnchorRise = newMaxAnchorRise.toUint64();
        emit MaxAnchorRiseSet(newMaxAnchorRise);
    }

    /// @dev Stores the anchor's fall speed once it passes the validator. Zero keeps open updates from lowering the
    ///      anchor.
    function _setMaxAnchorFall(uint256 newMaxAnchorFall) internal {
        if (newMaxAnchorFall > WAD) revert InvalidMaxAnchorFall(newMaxAnchorFall);
        maxAnchorFall = newMaxAnchorFall.toUint64();
        emit MaxAnchorFallSet(newMaxAnchorFall);
    }
}
