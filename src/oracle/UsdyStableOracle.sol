// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

interface IRWADynamicOracle {
    /// @notice Current USDY redemption value (NAV) in USD, scaled by 1e18.
    function getPrice() external view returns (uint256);
}

interface IChainlinkAggregator {
    /// @notice Latest round; `answer` is the price scaled by the feed's decimals (8 for USD feeds).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title UsdyStableOracle
/// @notice Morpho oracle for USDY collateral quoted in a USD stablecoin (USDC/USDT) loan asset.
/// @dev    USDY is valued by its redemption value (NAV) from Ondo's dynamic-rate oracle, not a market
///         price: USDY is transfer-gated and its secondary market is thin, so the NAV is the only sound
///         basis and is not gameable. The stablecoin leg divides by its Chainlink USD feed, so a
///         stablecoin depeg is reflected in the collateral valuation. No staleness/bounds guards
///         (matches Morpho's stock oracle behaviour, which avoids bricking the market on a transient
///         feed condition).
///
///         price() = getPrice() * SCALE / stableUsdPrice
///         SCALE   = 10^(36 + loanDecimals + feedDecimals - collateralDecimals - usdyOracleDecimals)
///                 = 10^(36 + 6 + 8 - 18 - 18) = 1e14
///         for USDY collateral (18 dec), USDC/USDT loan (6 dec), Ondo oracle (1e18), Chainlink (1e8).
///
///         This matches Morpho's IOracle convention: price of 1 collateral asset (USDY) quoted in 1
///         loan asset (stablecoin), scaled by 1e36.
contract UsdyStableOracle layout at erc7201("lido.lending.storage.UsdyStableOracle") is IOracle, Initializable {
    /// @dev Fixed for the supported decimals only: USDY collateral 18, Ondo oracle 1e18, stablecoin
    ///      loan 6, Chainlink USD feed 8. Deploying against assets with other decimals misprices.
    uint256 internal constant SCALE = 1e14;

    IRWADynamicOracle public usdyOracle;
    IChainlinkAggregator public stableUsdFeed;

    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Sets the NAV oracle and stablecoin feed.
    /// @param usdyOracle_ Ondo USDY dynamic-rate (NAV) oracle; `getPrice()` scaled by 1e18.
    /// @param stableUsdFeed_ Chainlink USD feed for the loan stablecoin (USDC/USD or USDT/USD), 8 dec.
    function initialize(address usdyOracle_, address stableUsdFeed_) external initializer {
        if (usdyOracle_ == address(0) || stableUsdFeed_ == address(0)) revert ZeroAddress();
        usdyOracle = IRWADynamicOracle(usdyOracle_);
        stableUsdFeed = IChainlinkAggregator(stableUsdFeed_);
    }

    function price() external view override returns (uint256) {
        (, int256 stableUsdPrice,,,) = stableUsdFeed.latestRoundData();
        return Math.mulDiv(usdyOracle.getPrice(), SCALE, uint256(stableUsdPrice));
    }
}
