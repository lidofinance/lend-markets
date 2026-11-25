// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Every source mock reverts with this while it is down, so the shared suites expect one error for any adapter.
error SourceDown();

/// @notice A NAV source the shared suites drive in the oracle's own price units, whatever ABI its adapter reads.
interface INavSourceMock {
    /// @notice The value the adapter's `_currentPrice()` returns, with `PRICE_DECIMALS` decimals.
    function currentPrice() external view returns (uint256);

    function isDown() external view returns (bool);

    /// @notice Sets the value the adapter's `_currentPrice()` returns.
    function setCurrentPrice(uint256 currentPrice_) external;

    /// @notice Makes every read of the source revert with `SourceDown`.
    function setDown(bool down) external;
}

/// @notice A source that stamps its price: the stamp is the block time plus `priceAhead` minus `priceAge`.
interface IStampedSourceMock {
    function priceAge() external view returns (uint256);

    function priceAhead() external view returns (uint256);

    function setPriceAge(uint256 priceAge_) external;

    /// @dev Seconds after the block time that the price is stamped: the issuer supplies the stamp.
    function setPriceAhead(uint256 priceAhead_) external;
}

/// @notice Ondo's USDY price getter.
contract MockOndoPriceGetter is INavSourceMock {
    uint256 public currentPrice;
    bool public isDown;

    function setCurrentPrice(uint256 currentPrice_) external {
        currentPrice = currentPrice_;
    }

    function setDown(bool down) external {
        isDown = down;
    }

    function getPrice() external view returns (uint256) {
        if (isDown) revert SourceDown();
        return currentPrice;
    }
}

/// @notice Centrifuge vault of a share token for one asset. It converts shares at `currentPrice`, the share price in
///         the asset with 18 decimals, rounded down, and refuses more shares than its manager's `uint128` cast takes.
///         Its price stamp is `priceAge` seconds before the block time plus `priceAhead`, both zero unless a test sets
///         them.
contract MockCentrifugeVault is INavSourceMock, IStampedSourceMock {
    uint256 public currentPrice;
    bool public isDown;
    uint256 public priceAge;
    uint256 public priceAhead;
    address public share;
    address public asset;

    constructor(address share_, address asset_) {
        share = share_;
        asset = asset_;
    }

    function setShare(address share_) external {
        share = share_;
    }

    function setAsset(address asset_) external {
        asset = asset_;
    }

    function setPriceAge(uint256 priceAge_) external {
        priceAge = priceAge_;
    }

    function setPriceAhead(uint256 priceAhead_) external {
        priceAhead = priceAhead_;
    }

    function setCurrentPrice(uint256 currentPrice_) external {
        require(currentPrice_ <= type(uint128).max, "D18 price above uint128");
        currentPrice = currentPrice_;
    }

    function setDown(bool down) external {
        isDown = down;
    }

    function priceLastUpdated() external view returns (uint64) {
        if (isDown) revert SourceDown();
        return uint64(block.timestamp + priceAhead - priceAge);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        if (isDown) revert SourceDown();
        require(shares <= type(uint128).max, "shares above uint128");
        uint256 shareUnit = 10 ** IERC20Metadata(share).decimals();
        uint256 assetUnit = 10 ** IERC20Metadata(asset).decimals();
        return Math.mulDiv(shares, currentPrice * assetUnit, shareUnit * 1e18);
    }
}

/// @notice A feed with Chainlink's aggregator interface and `decimals` decimals. Its answer is `currentPrice` at those
///         decimals, rounded down, unless a test sets a raw answer. The value is `priceAge` seconds old at every read,
///         zero unless a test sets it. The round fields are constants.
contract MockChainlinkFeed is INavSourceMock, IStampedSourceMock {
    uint8 public immutable decimals;

    uint256 public currentPrice;
    bool public isDown;
    uint256 public priceAge;
    uint256 public priceAhead;
    int256 internal _rawAnswer;
    bool internal _hasRawAnswer;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setCurrentPrice(uint256 currentPrice_) external {
        require(currentPrice_ <= uint256(type(int256).max), "answer above int256");
        currentPrice = currentPrice_;
        _hasRawAnswer = false;
    }

    /// @dev An answer that no `currentPrice` gives, such as a negative one, until the next `setCurrentPrice`.
    function setRawAnswer(int256 answer) external {
        _rawAnswer = answer;
        _hasRawAnswer = true;
    }

    function setDown(bool down) external {
        isDown = down;
    }

    function setPriceAge(uint256 priceAge_) external {
        priceAge = priceAge_;
    }

    function setPriceAhead(uint256 priceAhead_) external {
        priceAhead = priceAhead_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (isDown) revert SourceDown();
        answer = _hasRawAnswer ? _rawAnswer : int256(currentPrice / 10 ** (18 - decimals));
        return (1, answer, 0, block.timestamp + priceAhead - priceAge, 1);
    }
}
