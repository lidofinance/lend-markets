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
import {NavOracleCheckParams} from "../types/NavOracleTypes.sol";

interface IChainlinkAggregator {
    /// @notice Latest round; `answer` is the price scaled by `decimals()`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Decimals the feed's `answer` is scaled by.
    function decimals() external view returns (uint8);
}

/// @title NavOracleBase
/// @author Lido
/// @notice Lido Lend oracle for collateral priced from an issuer-published net asset value, quoted in a USD
///         stablecoin loan token at one loan token per USD. The price is the live source value held under an
///         upper bound that grows from a stored reference price and above a floor that falls from a stored
///         checkpoint price by one step per elapsed interval, and it reverts while the source sits outside a
///         band around the expected price or the loan token is off its peg.
/// @dev Concrete oracles bind one source in their constructor and override `_readSource()` with its ABI. All
///      of them share one storage namespace, so one can replace another behind the proxy without losing the
///      stored prices. `price()` is a view: the floor falls with time and needs no call. The checkpoint price
///      and the reference price move through `checkpoint()` and `moveReferencePrice()`, both open to anyone
///      and both unable to change the current price, or through the configurator role. A check parameter
///      change keeps the expected price and the floor where they were, so it never changes the price by
///      itself, except that a changed growth tolerance moves the upper bound at once.
abstract contract NavOracleBase is AccessControlEnumerableUpgradeable, IOracle {
    // ---
    // ROLES
    // ---

    /// @notice Sets the check parameters and accepts the current source price as the new reference and
    ///         checkpoint price.
    bytes32 public constant CONFIG_ROLE = keccak256("CONFIG_ROLE");

    // ---
    // CONSTANTS AND IMMUTABLES
    // ---

    /// @dev Seconds the yearly growth rate is spread over.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev 10^(36 + loanDecimals - collateralDecimals - 18): the 1e36 scaling of an 18-decimal NAV.
    uint256 public immutable PRICE_SCALE;
    /// @dev Chainlink USD feed of the loan token, read as a peg signal only.
    IChainlinkAggregator public immutable LOAN_TOKEN_FEED;
    /// @dev One USD in the feed's decimals.
    uint256 public immutable ONE_USD_IN_FEED_DECIMALS;

    // ---
    // ERRORS
    // ---

    /// @notice An address argument was the zero address.
    error ZeroAddress();
    /// @notice The loan and collateral decimals leave no room for the 1e36 convention.
    error UnsupportedDecimals(uint256 loanDecimals, uint256 collateralDecimals);
    /// @notice The fall limit has no interval, no step, or a step that drops the floor to zero in one interval.
    error InvalidFallLimit(uint256 maxFallPerInterval, uint40 fallInterval);
    /// @notice The revert band would allow the price to reach zero or would sit inside the upper bound.
    error InvalidRevertBand(uint256 maxDrawdown, uint256 maxOvershoot, uint256 growthTolerance);
    /// @notice The reference interval does not let the floor cross the corridor between two reference moves.
    error ReferenceIntervalTooShort(uint40 referenceInterval, uint256 leastAllowed);
    /// @notice The loan token deviation reaches a whole unit.
    error InvalidLoanTokenDeviation(uint256 maxLoanTokenDeviation);
    /// @notice The minimum price ratio is unset.
    error InvalidMinPriceRatio(uint256 minPriceRatio);
    /// @notice The released tolerance is under the current growth tolerance or over the protected one.
    error InvalidReleasedTolerance(uint256 released, uint256 growthTolerance, uint256 protectedGrowthTolerance);
    /// @notice The drawdown and the tolerance let the price fall further across one reference move than the
    ///         minimum price ratio allows, once grown by the interest debt accrues while the floor crosses the
    ///         corridor.
    error PriceRatioBelowMinimum(uint256 priceRatio, uint256 leastPriceRatio);
    /// @notice The source returned zero.
    error SourceReturnedZero();
    /// @notice The source price sits outside the revert band around the expected price.
    error PriceOutOfBounds(uint256 sourcePrice, uint256 lowestAllowed, uint256 highestAllowed);
    /// @notice The loan token's feed answer is outside its allowed deviation.
    error LoanTokenOffPeg();
    /// @notice The fall interval has not passed since the last checkpoint.
    error CheckpointIntervalNotElapsed(uint40 checkpointAt, uint40 fallInterval);
    /// @notice The reference interval has not passed since the reference price last moved.
    error ReferenceIntervalNotElapsed(uint40 referencePriceSetAt, uint40 referenceInterval);
    /// @notice The floor holds the price above the source, so the checkpoint cannot move.
    error SourceBelowFloor(uint256 sourcePrice, uint256 floor);
    /// @notice The source price is under the floor or over the upper bound, so the reference price move that
    ///         must keep the price cannot run.
    error SourceOutsideFloorAndBound(uint256 sourcePrice, uint256 floor, uint256 upperBound);
    /// @notice The source price sits further under the expected price than the growth tolerance.
    error SourceBelowGrowthTolerance(uint256 sourcePrice, uint256 lowestAllowed);
    /// @notice The accepted range is empty.
    error InvalidAcceptRange(uint256 lowest, uint256 highest);
    /// @notice The source price sits outside the range the configurator accepts.
    error SourceOutsideAcceptRange(uint256 sourcePrice, uint256 lowest, uint256 highest);

    // ---
    // EVENTS
    // ---

    /// @notice The checkpoint price the floor falls from was set: to the source price or the expected price,
    ///         whichever is lower, by a checkpoint, to the source price by an acceptance, or to the current
    ///         floor when the fall limit changed.
    event CheckpointSet(uint256 checkpointPrice, uint40 checkpointAt);
    /// @notice The reference price was set: to the source price by an open move or by the configurator's
    ///         acceptance, `accepted` telling which, or to the current expected price when the growth rate
    ///         changed.
    event ReferencePriceSet(uint256 referencePrice, uint40 referencePriceSetAt, bool accepted);
    /// @notice Check parameters changed.
    event CheckParamsSet(NavOracleCheckParams params);
    /// @notice The protected growth tolerance changed: raised with the growth tolerance, or released by the
    ///         configurator.
    event ProtectedGrowthToleranceSet(uint256 protectedGrowthTolerance);

    // ---
    // STORAGE
    // ---

    /// @dev Check parameters the configurator can change.
    NavOracleCheckParams internal _checkParams;

    /// @dev Price the expected price grows from.
    uint256 public referencePrice;
    /// @dev Price the floor falls from.
    uint256 public checkpointPrice;
    /// @dev When the reference price was set.
    uint40 public referencePriceSetAt;
    /// @dev When the checkpoint price was set.
    uint40 public checkpointAt;
    /// @dev The largest growth tolerance debt may still have been taken under: it rises with the tolerance and
    ///      falls only through `releaseGrowthTolerance()`.
    uint256 public protectedGrowthTolerance;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param loanToken Loan stablecoin; its decimals set the returned domain.
    /// @param collateralToken Collateral token; its decimals set the returned domain.
    /// @param loanTokenFeed Chainlink USD feed of the loan token.
    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address loanToken, address collateralToken, address loanTokenFeed) {
        if (loanToken == address(0) || collateralToken == address(0) || loanTokenFeed == address(0)) {
            revert ZeroAddress();
        }
        uint256 loanDecimals = IERC20Metadata(loanToken).decimals();
        uint256 collateralDecimals = IERC20Metadata(collateralToken).decimals();
        if (36 + loanDecimals < collateralDecimals + 18) revert UnsupportedDecimals(loanDecimals, collateralDecimals);
        PRICE_SCALE = 10 ** (36 + loanDecimals - collateralDecimals - 18);
        LOAN_TOKEN_FEED = IChainlinkAggregator(loanTokenFeed);
        ONE_USD_IN_FEED_DECIMALS = 10 ** IChainlinkAggregator(loanTokenFeed).decimals();
        _disableInitializers();
    }

    // ---
    // INITIALIZATION
    // ---

    /// @notice Grants the admin, stores the check parameters, and seeds the reference price and the
    ///         checkpoint price from the current source price.
    function initialize(address admin, NavOracleCheckParams calldata params) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _storeCheckParams(params);
        _setReferenceAndCheckpoint(_sourcePrice(), true);
    }

    // ---
    // EXTERNAL
    // ---

    /// @inheritdoc IOracle
    function price() external view override returns (uint256) {
        NavOracleCheckParams memory params = _checkParams;
        (uint256 expectedPrice, uint256 sourcePrice) = _checkedSourcePrice(params);
        return _boundedPrice(params, expectedPrice, sourcePrice);
    }

    /// @notice Current check parameters.
    function checkParams() external view returns (NavOracleCheckParams memory) {
        return _checkParams;
    }

    /// @notice Raises the floor by setting the checkpoint at the source price, or at the expected price
    ///         while the source sits above it, once the fall interval has passed since the last checkpoint.
    ///         The floor trails an honest source and never climbs above the expected path, so a print above
    ///         it is never recorded and its reversal is held by nothing but the path. Refused while the floor
    ///         holds the price above the source, so a call can never lift a held price or restart a fall.
    function checkpoint() external {
        NavOracleCheckParams memory params = _checkParams;
        if (block.timestamp - checkpointAt < params.fallInterval) {
            revert CheckpointIntervalNotElapsed(checkpointAt, params.fallInterval);
        }
        (uint256 expectedPrice, uint256 sourcePrice) = _checkedSourcePrice(params);
        uint256 floor = _floorPrice(params);
        if (sourcePrice < floor) revert SourceBelowFloor(sourcePrice, floor);
        _setCheckpoint(Math.min(sourcePrice, expectedPrice));
    }

    /// @notice Moves the reference price to the current source price, once the reference interval has
    ///         passed since the last move. Allowed only while the source sits within the growth tolerance of
    ///         the expected price and between the floor and the upper bound, so the move corrects the drift
    ///         between the configured and the realized yield without changing the price or touching the floor.
    function moveReferencePrice() external {
        NavOracleCheckParams memory params = _checkParams;
        if (block.timestamp - referencePriceSetAt < params.referenceInterval) {
            revert ReferenceIntervalNotElapsed(referencePriceSetAt, params.referenceInterval);
        }
        (uint256 expectedPrice, uint256 sourcePrice) = _checkedSourcePrice(params);
        uint256 lowestAllowed = Math.mulDiv(expectedPrice, WAD - params.growthTolerance, WAD);
        if (sourcePrice < lowestAllowed) revert SourceBelowGrowthTolerance(sourcePrice, lowestAllowed);
        _requireSourceBetweenFloorAndBound(params, expectedPrice, sourcePrice);
        _setReferencePrice(sourcePrice, false);
    }

    /// @notice Moves the reference price and the checkpoint price to the current source price, provided it
    ///         sits inside the accepted range: the way out of a revert on the band, and the way to admit a
    ///         rise above the upper bound or a fall faster than the floor. The range is the one the
    ///         configurator decided on, so a source that moved since cannot be accepted by mistake.
    function acceptCurrentPrice(uint256 lowest, uint256 highest) external onlyRole(CONFIG_ROLE) {
        if (lowest > highest) revert InvalidAcceptRange(lowest, highest);
        uint256 sourcePrice = _sourcePrice();
        if (sourcePrice < lowest || sourcePrice > highest) {
            revert SourceOutsideAcceptRange(sourcePrice, lowest, highest);
        }
        _setReferenceAndCheckpoint(sourcePrice, true);
    }

    /// @notice Sets the yearly growth rate of the expected price and the tolerance of the upper bound above it.
    ///         A new rate applies from now on, the expected price stays where it is. A changed tolerance moves
    ///         the upper bound at once.
    function setGrowthLimit(uint256 yearlyGrowthRate, uint256 growthTolerance) external onlyRole(CONFIG_ROLE) {
        NavOracleCheckParams memory params = _checkParams;
        params.yearlyGrowthRate = yearlyGrowthRate;
        params.growthTolerance = growthTolerance;
        _storeCheckParams(params);
    }

    /// @notice Sets the floor's step per interval and the interval, which is also the least time between two
    ///         checkpoints. The new step and interval apply from now on, the floor stays where it is.
    function setFallLimit(uint256 maxFallPerInterval, uint40 fallInterval) external onlyRole(CONFIG_ROLE) {
        NavOracleCheckParams memory params = _checkParams;
        params.maxFallPerInterval = maxFallPerInterval;
        params.fallInterval = fallInterval;
        _storeCheckParams(params);
    }

    /// @notice Sets the revert band around the expected price and the interval between two open reference
    ///         price moves.
    function setRevertBand(uint256 maxDrawdown, uint256 maxOvershoot, uint40 referenceInterval)
        external
        onlyRole(CONFIG_ROLE)
    {
        NavOracleCheckParams memory params = _checkParams;
        params.maxDrawdown = maxDrawdown;
        params.maxOvershoot = maxOvershoot;
        params.referenceInterval = referenceInterval;
        _storeCheckParams(params);
    }

    /// @notice Sets what the corridor answers for that only the market knows: the lowest ratio the drawdown and
    ///         the tolerance may leave between the lowest and the highest returnable price across one reference
    ///         move, which the market's LLTV and liquidation incentive decide, and the highest borrow rate per
    ///         second its interest rate model can charge, which sets how much debt grows while the floor holds
    ///         the price.
    function setMarketLimits(uint256 minPriceRatio, uint256 maxBorrowRate) external onlyRole(CONFIG_ROLE) {
        NavOracleCheckParams memory params = _checkParams;
        params.minPriceRatio = minPriceRatio;
        params.maxBorrowRate = maxBorrowRate;
        _storeCheckParams(params);
    }

    /// @notice Lowers the protected growth tolerance, the one the corridor check still answers for after the
    ///         growth tolerance was lowered, to `released`, no lower than the current growth tolerance. Debt
    ///         taken under the old upper bound may still be open, so this is the configurator's statement
    ///         that it no longer needs the old room.
    function releaseGrowthTolerance(uint256 released) external onlyRole(CONFIG_ROLE) {
        if (released < _checkParams.growthTolerance || released > protectedGrowthTolerance) {
            revert InvalidReleasedTolerance(released, _checkParams.growthTolerance, protectedGrowthTolerance);
        }
        protectedGrowthTolerance = released;
        emit ProtectedGrowthToleranceSet(released);
    }

    /// @notice Sets the allowed deviation of the loan token's feed answer from 1 USD.
    function setLoanTokenPegCheck(uint256 maxLoanTokenDeviation) external onlyRole(CONFIG_ROLE) {
        NavOracleCheckParams memory params = _checkParams;
        params.maxLoanTokenDeviation = maxLoanTokenDeviation;
        _storeCheckParams(params);
    }

    // ---
    // INTERNAL
    // ---

    /// @dev Reads the source's NAV with 18 decimals in the NAV's currency. Reverts with the source.
    function _readSource() internal view virtual returns (uint256 nav);

    /// @dev The source value scaled to the returned domain.
    function _sourcePrice() internal view returns (uint256 sourcePrice) {
        uint256 nav = _readSource();
        if (nav == 0) revert SourceReturnedZero();
        return nav * PRICE_SCALE;
    }

    /// @dev The expected price and the source price after every check that makes `price()` revert: the
    ///      loan token peg and the revert band.
    function _checkedSourcePrice(NavOracleCheckParams memory params)
        internal
        view
        returns (uint256 expectedPrice, uint256 sourcePrice)
    {
        if (_isLoanTokenOffPeg(params)) revert LoanTokenOffPeg();
        expectedPrice = _expectedPrice(params);
        sourcePrice = _sourcePrice();
        uint256 lowestAllowed = Math.mulDiv(expectedPrice, WAD - params.maxDrawdown, WAD);
        uint256 highestAllowed = Math.mulDiv(expectedPrice, WAD + params.maxOvershoot, WAD);
        if (sourcePrice < lowestAllowed || sourcePrice > highestAllowed) {
            revert PriceOutOfBounds(sourcePrice, lowestAllowed, highestAllowed);
        }
    }

    /// @dev min(upperBound, max(sourcePrice, floor)): the source held under the upper bound and above the
    ///      floor. Every move that sets the floor keeps it at or under the expected price of its time, which
    ///      the upper bound never goes below, so the floor sits under the bound whatever the tolerance.
    function _boundedPrice(NavOracleCheckParams memory params, uint256 expectedPrice, uint256 sourcePrice)
        internal
        view
        returns (uint256)
    {
        uint256 upperBound = _upperPriceBound(params, expectedPrice);
        return Math.min(upperBound, Math.max(sourcePrice, _floorPrice(params)));
    }

    /// @dev Reverts unless the source price sits between the floor and the upper bound, both inclusive. Then
    ///      `price()` returns the source itself and the move cannot change it.
    function _requireSourceBetweenFloorAndBound(
        NavOracleCheckParams memory params,
        uint256 expectedPrice,
        uint256 sourcePrice
    ) internal view {
        uint256 floor = _floorPrice(params);
        uint256 upperBound = _upperPriceBound(params, expectedPrice);
        if (sourcePrice < floor || sourcePrice > upperBound) {
            revert SourceOutsideFloorAndBound(sourcePrice, floor, upperBound);
        }
    }

    /// @dev referencePrice × (1 + yearlyGrowthRate × elapsed / year), rounded down: where an honest source
    ///      is expected to sit now.
    function _expectedPrice(NavOracleCheckParams memory params) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - referencePriceSetAt;
        uint256 growth = WAD + Math.mulDiv(params.yearlyGrowthRate, elapsed, SECONDS_PER_YEAR);
        return Math.mulDiv(referencePrice, growth, WAD);
    }

    /// @dev expectedPrice × (1 + growthTolerance), rounded down.
    function _upperPriceBound(NavOracleCheckParams memory params, uint256 expectedPrice)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(expectedPrice, WAD + params.growthTolerance, WAD);
    }

    /// @dev checkpointPrice × (1 − intervalsPassed × maxFallPerInterval), rounded down, zero once the steps
    ///      add up to the whole price. Falls with time alone, so a source under the floor reaches the price one
    ///      step per interval whether anyone calls or not.
    function _floorPrice(NavOracleCheckParams memory params) internal view returns (uint256) {
        uint256 intervalsPassed = (block.timestamp - checkpointAt) / params.fallInterval;
        uint256 fall = intervalsPassed * params.maxFallPerInterval;
        if (fall >= WAD) return 0;
        return Math.mulDiv(checkpointPrice, WAD - fall, WAD);
    }

    /// @dev The feed's latest answer is outside the allowed deviation from 1 USD, whatever its age: a round
    ///      going stale does not mean the peg came back. A feed that reverts, returns too little data or a
    ///      non-positive answer is ignored, so the feed cannot stop the oracle by failing. The call is
    ///      low-level because `try` does not cover a malformed return, and only the answer is read, since
    ///      decoding the other fields could fail on values outside their types.
    function _isLoanTokenOffPeg(NavOracleCheckParams memory params) internal view returns (bool) {
        (bool success, bytes memory data) =
            address(LOAN_TOKEN_FEED).staticcall(abi.encodeCall(IChainlinkAggregator.latestRoundData, ()));
        if (!success || data.length < 160) return false;
        int256 answer;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            answer := mload(add(data, 64))
        }
        if (answer <= 0) return false;
        uint256 allowedDeviation = Math.mulDiv(params.maxLoanTokenDeviation, ONE_USD_IN_FEED_DECIMALS, WAD);
        uint256 answerInUsd = uint256(answer);
        return answerInUsd < ONE_USD_IN_FEED_DECIMALS - allowedDeviation
            || answerInUsd > ONE_USD_IN_FEED_DECIMALS + allowedDeviation;
    }

    /// @dev Sets the checkpoint the floor falls from to `newCheckpointPrice` at the current time.
    function _setCheckpoint(uint256 newCheckpointPrice) internal {
        checkpointPrice = newCheckpointPrice;
        checkpointAt = uint40(block.timestamp);
        emit CheckpointSet(newCheckpointPrice, checkpointAt);
    }

    /// @dev Sets the reference price to `newReferencePrice` at the current time.
    function _setReferencePrice(uint256 newReferencePrice, bool accepted) internal {
        referencePrice = newReferencePrice;
        referencePriceSetAt = uint40(block.timestamp);
        emit ReferencePriceSet(newReferencePrice, referencePriceSetAt, accepted);
    }

    /// @dev Sets both stored prices to `newPrice` at the current time.
    function _setReferenceAndCheckpoint(uint256 newPrice, bool accepted) internal {
        _setReferencePrice(newPrice, accepted);
        _setCheckpoint(newPrice);
    }

    /// @dev Stores the check parameters once they pass the validator. A changed growth rate moves the reference
    ///      price to the current expected price and a changed step or interval moves the checkpoint to the
    ///      current floor, both at the current time, so the expected price and the floor stay where they were
    ///      and the new values apply from now on. The protected tolerance rises with the growth tolerance and
    ///      falls only through `releaseGrowthTolerance()`, because debt taken at an old upper bound stays open
    ///      across any number of later parameter changes.
    function _storeCheckParams(NavOracleCheckParams memory params) internal {
        NavOracleCheckParams memory oldParams = _checkParams;
        bool initialized = referencePriceSetAt != 0;

        if (params.fallInterval == 0 || params.maxFallPerInterval == 0 || params.maxFallPerInterval >= WAD) {
            revert InvalidFallLimit(params.maxFallPerInterval, params.fallInterval);
        }
        if (params.maxDrawdown >= WAD || params.maxOvershoot <= params.growthTolerance) {
            revert InvalidRevertBand(params.maxDrawdown, params.maxOvershoot, params.growthTolerance);
        }
        uint256 stepsAcrossCorridor =
            Math.ceilDiv(params.maxDrawdown + params.growthTolerance, params.maxFallPerInterval);
        uint256 corridorCrossing = stepsAcrossCorridor * params.fallInterval;
        uint256 leastReferenceInterval = Math.max(params.fallInterval, corridorCrossing);
        if (params.referenceInterval < leastReferenceInterval) {
            revert ReferenceIntervalTooShort(params.referenceInterval, leastReferenceInterval);
        }
        if (params.maxLoanTokenDeviation >= WAD) revert InvalidLoanTokenDeviation(params.maxLoanTokenDeviation);
        if (params.minPriceRatio == 0) revert InvalidMinPriceRatio(params.minPriceRatio);
        uint256 protectedTolerance = Math.max(protectedGrowthTolerance, params.growthTolerance);
        uint256 lowestFactor = Math.mulDiv(WAD - params.maxDrawdown, WAD - params.growthTolerance, WAD);
        uint256 priceRatio = Math.mulDiv(lowestFactor, WAD, WAD + protectedTolerance);
        // A liquidation may only pay once the floor reaches the source, so debt keeps accruing for up to one
        // corridor crossing at the market's highest rate, compounded as the core compounds it.
        uint256 heldInterest = MathLib.wTaylorCompounded(params.maxBorrowRate, corridorCrossing);
        uint256 leastPriceRatio = Math.mulDiv(params.minPriceRatio, WAD + heldInterest, WAD, Math.Rounding.Ceil);
        if (priceRatio < leastPriceRatio) revert PriceRatioBelowMinimum(priceRatio, leastPriceRatio);
        if (protectedTolerance != protectedGrowthTolerance) {
            protectedGrowthTolerance = protectedTolerance;
            emit ProtectedGrowthToleranceSet(protectedTolerance);
        }

        if (initialized && params.yearlyGrowthRate != oldParams.yearlyGrowthRate) {
            _setReferencePrice(_expectedPrice(oldParams), false);
        }
        if (
            initialized
                && (params.maxFallPerInterval != oldParams.maxFallPerInterval
                    || params.fallInterval != oldParams.fallInterval)
        ) _setCheckpoint(_floorPrice(oldParams));
        _checkParams = params;
        emit CheckParamsSet(params);
    }
}
