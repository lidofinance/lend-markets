// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "./TrailingAnchorOracleBase.sol";

interface ICentrifugeVault {
    /// @notice The share token of the vault.
    function share() external view returns (address);

    /// @notice The token that the vault takes and pays out.
    function asset() external view returns (address);

    /// @notice The value of `shares` in the asset, at the share price and the pool's price of the asset, rounded
    ///         down.
    function convertToAssets(uint256 shares) external view returns (uint256 assets);

    /// @notice The later of the times when the share price and the asset price were computed.
    function priceLastUpdated() external view returns (uint64);
}

/// @title CentrifugeNavOracle
/// @author Lido
/// @notice NAV oracle for a Centrifuge share class. It reads the share price in the loan token from the share class's
///         Centrifuge vault, whose asset is the loan token.
/// @dev The vault's time stamp is the later of the share price's and the asset price's. The adapter refuses a stamp
///      older than its own `MAX_PRICE_AGE`. The issuer supplies the stamp, so the adapter also refuses one after the
///      block time.
contract CentrifugeNavOracle layout at erc7201("lido.lend.storage.CentrifugeNavOracle") is TrailingAnchorOracleBase {
    // ---
    // IMMUTABLES
    // ---

    /// @notice Centrifuge vault of the collateral token.
    ICentrifugeVault public immutable VAULT;
    /// @notice Largest age of the vault's price stamp that the adapter accepts, in seconds.
    uint256 public immutable MAX_PRICE_AGE;

    // ---
    // ERRORS
    // ---

    /// @notice The share token of the vault is not the collateral token.
    error ShareTokenMismatch(address shareToken, address collateralToken);
    /// @notice The asset of the vault is not the loan token.
    error AssetMismatch(address asset, address loanToken);
    /// @notice `maxPriceAge` is zero.
    error MaxPriceAgeIsZero();
    /// @notice The vault's price stamp `computedAt` is more than `MAX_PRICE_AGE` ago.
    error StalePrice(uint64 computedAt);
    /// @notice The vault's price stamp `computedAt` is after the block time.
    error PriceFromFuture(uint64 computedAt);

    // ---
    // CONSTRUCTOR
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address vault, uint256 maxPriceAge, address loanToken, address collateralToken)
        TrailingAnchorOracleBase(loanToken, collateralToken)
    {
        if (vault == address(0)) revert ZeroAddress();
        if (maxPriceAge == 0) revert MaxPriceAgeIsZero();
        address shareToken = ICentrifugeVault(vault).share();
        if (shareToken != collateralToken) revert ShareTokenMismatch(shareToken, collateralToken);
        address asset = ICentrifugeVault(vault).asset();
        if (asset != loanToken) revert AssetMismatch(asset, loanToken);
        VAULT = ICentrifugeVault(vault);
        MAX_PRICE_AGE = maxPriceAge;
    }

    // ---
    // OVERRIDES
    // ---

    /// @inheritdoc TrailingAnchorOracleBase
    /// @dev The value of `10^36 / PRICE_SCALE` collateral units in loan units is the price with `PRICE_DECIMALS`.
    function _currentPrice() internal view override returns (uint256 currentPrice) {
        uint64 computedAt = VAULT.priceLastUpdated();
        if (computedAt > block.timestamp) revert PriceFromFuture(computedAt);
        if (block.timestamp - computedAt > MAX_PRICE_AGE) revert StalePrice(computedAt);
        return VAULT.convertToAssets(10 ** ORACLE_PRICE_DECIMALS / PRICE_SCALE);
    }
}
