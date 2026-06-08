// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {IMorphoStaticTyping, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";

/// @title ILidoBlue
/// @notice Full typed surface of the `LidoBlue` core: the upstream Morpho interface plus the
///         fork-added primitives. Consumers (the ERC-4626 vault, the deploy script, tests) type the
///         core through this single interface instead of rolling per-call shims.
/// @dev Extends `IMorphoStaticTyping`, not `IMorpho`: the core's public mapping getters
///      (`position` / `market` / `idToMarketParams`) are tuple-typed, so the core can only satisfy the
///      static-typing variant. This mirrors upstream `Morpho is IMorphoStaticTyping`. Where a library
///      wants the struct-returning `IMorpho` (e.g. `MorphoBalancesLib`), cast the same core address to
///      `IMorpho`; both views are ABI-identical.
interface ILidoBlue is IMorphoStaticTyping {
    /// @notice Fork-added overload of `createMarket` that atomically binds the market's controller and
    ///         deleverage flag. Both are immutable for the life of the market.
    function createMarket(MarketParams memory marketParams, address controller, bool deleverageEnabled) external;

    /// @notice Fork-added single-borrower deleverage primitive. Not part of upstream `IMorpho`.
    function deleverage(
        MarketParams memory marketParams,
        uint256 supplyShares,
        address borrower,
        address onBehalf,
        address receiver
    ) external returns (uint256 collateralSeized, uint256 debtCanceled);
}
