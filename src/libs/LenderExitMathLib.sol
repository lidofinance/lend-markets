// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LenderExitMathLib
/// @author Lido Lending contributors.
/// @notice Pure per-fill settlement split for the lender withdrawal queue. One fill redeems part
///         of a request and produces `assetsOut`; this splits it between the exiting lender, the
///         keeper that did the work, and the protocol.
/// @dev The request fixes a share price at creation. Per fill the lender is owed only the filled
///      shares valued at that fixed price; the yield accrued above it (the difference between the
///      live `assetsOut` and the fixed-price `owed`) is the keeper's reward, so a longer wait pays
///      the keeper more. The priority fee is a Dutch auction: the lender sets a cap, and the fee a
///      fill earns ramps from 0 at request creation to that cap at the deadline (`feeRampBps`),
///      scaled by the share fraction this fill covers (`filledShares / sizeTotal`). It is funded out
///      of the lender's owed; the unramped remainder stays with the lender. The protocol takes a cut
///      of the keeper's gross reward; the lender's owed is unaffected by that cut.
library LenderExitMathLib {
    // ---
    // CONSTANTS
    // ---

    /// @dev WAD scale for the fixed `pricePerShare` (assets per share).
    uint256 internal constant WAD = 1e18;
    /// @dev Basis-point denominator for the fee ramp and the protocol cut.
    uint256 internal constant BPS = 10_000;

    // ---
    // PURE MATH
    // ---

    /// @param assetsOut Assets produced by redeeming/withdrawing `filledShares` this fill.
    /// @param filledShares Shares filled by this fill.
    /// @param sizeTotal Original request shares, the denominator for the priority-fee fraction.
    /// @param pricePerShare Assets per share fixed at request creation, WAD-scaled.
    /// @param maxPriorityFee Priority-fee cap over the whole request (loan-asset units).
    /// @param feeRampBps Dutch-auction ramp position, in basis points: 0 at creation, `BPS` at the
    ///        deadline. The fill earns `maxPriorityFee * filledShares / sizeTotal * feeRampBps / BPS`.
    /// @param protocolFeeBps Protocol cut of the keeper's gross reward, in basis points (≤ `BPS`).
    /// @return lenderAssets Owed assets credited to the exiting lender, net of the priority fee.
    /// @return keeperFee Keeper reward (accrued yield + priority fee), net of the protocol cut.
    /// @return protocolFee Protocol cut of the keeper's gross reward.
    function splitFill(
        uint256 assetsOut,
        uint256 filledShares,
        uint256 sizeTotal,
        uint256 pricePerShare,
        uint256 maxPriorityFee,
        uint256 feeRampBps,
        uint256 protocolFeeBps
    ) internal pure returns (uint256 lenderAssets, uint256 keeperFee, uint256 protocolFee) {
        // Lender's entitlement at the fixed request price, capped by what the fill actually produced
        // (a price drop / loss leaves no yield and trims the owed).
        uint256 owed = Math.min(Math.mulDiv(filledShares, pricePerShare, WAD), assetsOut);
        uint256 accruedYield = assetsOut - owed;

        // Priority fee comes out of the owed: the cap scaled by this fill's share fraction and the
        // Dutch ramp. Never more than the owed.
        uint256 fee = Math.mulDiv(maxPriorityFee, filledShares, sizeTotal) * feeRampBps / BPS;
        if (fee > owed) fee = owed;

        uint256 keeperGross = accruedYield + fee;
        protocolFee = keeperGross * protocolFeeBps / BPS;
        keeperFee = keeperGross - protocolFee;
        lenderAssets = owed - fee;
    }
}
