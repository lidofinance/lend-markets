// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IRWADynamicOracle {
    /// @notice Current USDY redemption value (NAV) in USD, scaled by 1e18.
    function getPrice() external view returns (uint256);
}

interface IChainlinkAggregator {
    /// @notice Latest round; `answer` is the price scaled by `decimals()`.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Decimals the feed's `answer` is scaled by (8 for USD feeds).
    function decimals() external view returns (uint8);
}

/// @title UsdyStableOracle
/// @author Lido
/// @notice Morpho oracle for USDY collateral quoted in any USD-stablecoin loan asset with a Chainlink feed.
/// @dev Values USDY by its NAV (Ondo dynamic-rate oracle), not a market price; the stablecoin leg divides
///      by its Chainlink USD feed, so a stablecoin depeg flows into the collateral valuation. No staleness
///      guard, matching Morpho's stock oracle; the immutable price band below is the only guard.
///
///      price() = getPrice() * scale / stableUsdPrice
///      scale   = 10^(36 + loanDecimals + feedDecimals - USDY_DECIMALS - NAV_DECIMALS)
///
///      `price()` reverts outside the inclusive band [`MIN_PRICE`, `MAX_PRICE`], so a mis-scaled NAV or a
///      collapsing feed answer stops every price-dependent action instead of repricing every position. The
///      band is a sanity check on the sources, not a risk parameter: it is wide enough that NAV accrual and
///      stablecoin depegs stay inside it.
///
///      The NAV oracle and the band are fixed for the life of an instance, so both are immutable; the
///      per-market stablecoin feed and decimal-derived `scale` are set in `initialize`. The bounds are in
///      the returned 1e36-convention domain, whose magnitude depends on the loan token's decimals, so a
///      band is valid only for the loan token its instance is initialized with. Matches Morpho's IOracle
///      convention: price of 1 collateral asset quoted in 1 loan asset, scaled by 1e36.
contract UsdyStableOracle layout at erc7201("lido.lend.storage.UsdyStableOracle") is Initializable, IOracle {
    // ---
    // CONSTANTS
    // ---

    /// @dev Decimals of USDY, the only collateral this oracle prices.
    uint256 internal constant USDY_DECIMALS = 18;

    /// @dev Decimals of Ondo's USDY NAV `getPrice()` output.
    uint256 internal constant NAV_DECIMALS = 18;

    // ---
    // IMMUTABLES
    // ---

    /// @dev Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` is the redemption value scaled by 1e18.
    IRWADynamicOracle public immutable USDY_ORACLE;

    /// @dev Inclusive lower bound on `price()`, in the returned 1e36-convention domain.
    uint256 public immutable MIN_PRICE;

    /// @dev Inclusive upper bound on `price()`, in the returned 1e36-convention domain.
    uint256 public immutable MAX_PRICE;

    // ---
    // STORAGE
    // ---

    /// @dev Chainlink USD feed for the loan stablecoin.
    IChainlinkAggregator public stableUsdFeed;

    /// @dev 10^(36 + loanDec + feedDec - 18 - 18): the 1e36 scaling for the loan token and feed decimals.
    uint256 public scale;

    // ---
    // ERRORS
    // ---

    /// @notice An address argument was the zero address.
    error ZeroAddress();

    /// @notice The stablecoin USD feed returned a non-positive answer (zero would brick `price()` on a
    ///         division by zero; a negative cast would silently collapse the price toward zero).
    error InvalidStablePrice();

    /// @notice The USDY NAV oracle returned zero, which would collapse the collateral price to zero.
    error InvalidNavPrice();

    /// @notice The constructor's price band was not a usable range: a zero lower bound would admit a
    ///         collapsed price, and an upper bound below the lower one would reject every price.
    error InvalidPriceBounds(uint256 minPrice, uint256 maxPrice);

    /// @notice The computed price fell outside the immutable [`MIN_PRICE`, `MAX_PRICE`] band, so the NAV or
    ///         the feed reported a magnitude this market does not price against.
    error PriceOutOfBounds(uint256 price);

    // ---
    // CONSTRUCTOR
    // ---

    /// @param usdyOracle Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` scaled by 1e18.
    /// @param minPrice Inclusive lower bound on `price()`, scaled by 10^(36 + loanDecimals - USDY_DECIMALS)
    ///        for the loan token passed to `initialize`.
    /// @param maxPrice Inclusive upper bound on `price()`, in the same domain as `minPrice`.
    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address usdyOracle, uint256 minPrice, uint256 maxPrice) {
        if (usdyOracle == address(0)) revert ZeroAddress();
        if (minPrice == 0 || maxPrice < minPrice) revert InvalidPriceBounds(minPrice, maxPrice);
        USDY_ORACLE = IRWADynamicOracle(usdyOracle);
        MIN_PRICE = minPrice;
        MAX_PRICE = maxPrice;
        _disableInitializers();
    }

    // ---
    // INITIALIZATION
    // ---

    /// @notice Bind the per-market stablecoin leg: the Chainlink USD feed and the decimal-derived scale.
    /// @param feed Chainlink USD feed for the loan stablecoin; its `decimals()` set the feed leg.
    /// @param loanToken Loan stablecoin token; its `decimals()` set the loan leg.
    function initialize(address feed, address loanToken) external initializer {
        if (feed == address(0) || loanToken == address(0)) revert ZeroAddress();

        uint256 loanDecimals = IERC20Metadata(loanToken).decimals();
        uint256 feedDecimals = IChainlinkAggregator(feed).decimals();

        stableUsdFeed = IChainlinkAggregator(feed);
        // getPrice()/stableUsdPrice already carries (NAV_DECIMALS - feedDec) decimals, so the IOracle 1e36
        // value (1 USDY in 1 loan) needs 10^(36 + loanDec + feedDec - USDY_DECIMALS - NAV_DECIMALS). The
        // exponent is never negative: USDY_DECIMALS + NAV_DECIMALS == 36.
        scale = 10 ** (36 + loanDecimals + feedDecimals - USDY_DECIMALS - NAV_DECIMALS);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IOracle
    function price() external view override returns (uint256) {
        uint256 navPrice = USDY_ORACLE.getPrice();
        if (navPrice == 0) revert InvalidNavPrice();
        (, int256 stableUsdPrice,,,) = stableUsdFeed.latestRoundData();
        if (stableUsdPrice <= 0) revert InvalidStablePrice();
        uint256 value = Math.mulDiv(navPrice, scale, uint256(stableUsdPrice));
        if (value < MIN_PRICE || value > MAX_PRICE) revert PriceOutOfBounds(value);
        return value;
    }
}
