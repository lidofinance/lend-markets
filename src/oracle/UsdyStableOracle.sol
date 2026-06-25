// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

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
/// @dev    USDY is valued by its redemption value (NAV) from Ondo's dynamic-rate oracle, not a market price:
///         USDY is transfer-gated and its secondary market is thin, so the NAV is the only sound basis and is
///         not gameable. The stablecoin leg divides by its Chainlink USD feed, so a stablecoin depeg is
///         reflected in the collateral valuation. No staleness/bounds guards (matches Morpho's stock oracle
///         behaviour, which avoids bricking the market on a transient feed condition).
///
///         price() = getPrice() * SCALE / stableUsdPrice
///         SCALE   = 10^(36 + loanDecimals + feedDecimals - USDY_DECIMALS - NAV_DECIMALS)
///
///         USDY is the only collateral (18 dec, NAV scaled 1e18), but the loan stablecoin is free: its token
///         decimals and its Chainlink feed decimals are read at construction, so the same contract serves any
///         Chainlink-priced stablecoin (USDC, USDT, DAI, ...). Matches Morpho's IOracle convention: price of
///         1 collateral asset quoted in 1 loan asset, scaled by 1e36.
contract UsdyStableOracle is IOracle {
    // ---
    // CONSTANTS
    // ---

    /// @dev USDY collateral decimals — the only collateral this oracle prices.
    uint256 internal constant USDY_DECIMALS = 18;

    /// @dev Decimals of Ondo's USDY NAV `getPrice()` output.
    uint256 internal constant NAV_DECIMALS = 18;

    // ---
    // IMMUTABLES
    // ---

    /// @dev Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` is the redemption value scaled by 1e18.
    IRWADynamicOracle public immutable USDY_ORACLE;

    /// @dev Chainlink USD feed for the loan stablecoin. The valuation divides by it, so a depeg flows through.
    IChainlinkAggregator public immutable STABLE_USD_FEED;

    /// @dev 10^(36 + loanDec + feedDec - 18 - 18): the 1e36 scaling for the loan token and feed decimals.
    uint256 public immutable SCALE;

    // ---
    // ERRORS
    // ---

    /// @notice A constructor address argument was the zero address.
    error ZeroAddress();

    // ---
    // CONSTRUCTOR
    // ---

    /// @param usdyOracle Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` scaled by 1e18.
    /// @param stableUsdFeed Chainlink USD feed for the loan stablecoin; its `decimals()` set the feed leg.
    /// @param loanToken Loan stablecoin token; its `decimals()` set the loan leg.
    constructor(address usdyOracle, address stableUsdFeed, address loanToken) {
        if (usdyOracle == address(0) || stableUsdFeed == address(0) || loanToken == address(0)) {
            revert ZeroAddress();
        }

        uint256 loanDecimals = IERC20Metadata(loanToken).decimals();
        uint256 feedDecimals = IChainlinkAggregator(stableUsdFeed).decimals();

        USDY_ORACLE = IRWADynamicOracle(usdyOracle);
        STABLE_USD_FEED = IChainlinkAggregator(stableUsdFeed);
        // getPrice()/stableUsdPrice already carries (NAV_DECIMALS - feedDec) decimals, so the IOracle 1e36
        // value (1 USDY in 1 loan) needs 10^(36 + loanDec + feedDec - USDY_DECIMALS - NAV_DECIMALS). The
        // exponent is never negative: USDY_DECIMALS + NAV_DECIMALS == 36.
        SCALE = 10 ** (36 + loanDecimals + feedDecimals - USDY_DECIMALS - NAV_DECIMALS);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IOracle
    function price() external view override returns (uint256) {
        (, int256 stableUsdPrice,,,) = STABLE_USD_FEED.latestRoundData();
        return Math.mulDiv(USDY_ORACLE.getPrice(), SCALE, uint256(stableUsdPrice));
    }
}
