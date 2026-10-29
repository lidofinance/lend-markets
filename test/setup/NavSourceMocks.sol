// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

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

/// @notice Centrifuge Spoke for one pool and share class. It refuses any other share class and a read that asks for the
///         validity check, so a price comes back only for the exact call the oracle must make.
contract MockCentrifugeSpoke is INavSourceMock {
    error ShareTokenDoesNotExist();
    error ValidityCheckRequested();

    uint64 public immutable POOL_ID;
    bytes16 public immutable SHARE_CLASS_ID;

    uint256 public currentPrice;
    bool public isDown;

    constructor(uint64 poolId, bytes16 scId) {
        POOL_ID = poolId;
        SHARE_CLASS_ID = scId;
    }

    function setCurrentPrice(uint256 currentPrice_) external {
        require(currentPrice_ <= type(uint128).max, "D18 price above uint128");
        currentPrice = currentPrice_;
    }

    function setDown(bool down) external {
        isDown = down;
    }

    function pricePoolPerShare(uint64 poolId, bytes16 scId, bool checkValidity) external view returns (uint128) {
        if (isDown) revert SourceDown();
        if (checkValidity) revert ValidityCheckRequested();
        if (poolId != POOL_ID || scId != SHARE_CLASS_ID) revert ShareTokenDoesNotExist();
        return uint128(currentPrice);
    }
}
