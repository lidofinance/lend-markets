// Core-backed reads, attached when the scene runs the real controller with LidoLend in CVL.

import "../LidoLend/LidoLend_cvl.spec";

// Proven in the linked core and controller scene as CL-VS-03; assumed here by isolated rules.
function requireBucketsWithinCollateral(address b) {
    require(ghostMcPosActivating128[b] + ghostMcPosDust128[b]
            <= to_mathint(ghostLlCvlPosCollateral[b]),
        "PROVED: activating plus dust never exceeds the core collateral, CL-VS-03 activationBucketsBackedByCoreCollateral");
}

// A borrower's debt the way the core values it: shares against the market totals, rounded up.
function debtAssetsUpMcCVL(address b) returns mathint {
    mathint shares = to_mathint(ghostLlCvlPosBorrowShares[b]);
    mathint totalAssets = to_mathint(ghostLlCvlTotalBorrowAssets);
    mathint totalShares = to_mathint(ghostLlCvlTotalBorrowShares);
    return (shares * (totalAssets + 1) + totalShares + VIRTUAL_SHARES_MC_CVL() - 1)
        / (totalShares + VIRTUAL_SHARES_MC_CVL());
}

// The oracle valuation of a borrower's collateral, rounded down, as the solvency check reads it.
function collateralValueMcCVL(address b) returns mathint {
    return to_mathint(ghostLlCvlPosCollateral[b])
        * to_mathint(ghostOraclePrice256[ghostLlCvlOracle]) / ORACLE_PRICE_SCALE_MC_CVL();
}

// What `active` collateral can back at the market LLTV: sub-threshold active backs nothing.
function maxBorrowMcCVL(mathint active) returns mathint {
    return active < ghostMcCfgMinActivationAmount128
        ? 0
        : (active * to_mathint(ghostOraclePrice256[ghostLlCvlOracle])
            / ORACLE_PRICE_SCALE_MC_CVL()) * to_mathint(ghostLlCvlLltv) / WAD_MC_CVL();
}

// The activating lot matures when the surcharged wait has passed and the quorum has scanned past it or timed out.
function lotMaturesMcCVL(env e, address b) returns bool {
    mathint start = ghostMcPosActivatingStart40[b];
    mathint surcharge = ghostGsCvlStrikeCount[ghostMcMarketId][b] * ghostMcCfgDelayPerStrike40
        + (start < ghostGsCvlSuspectExpiry256[ghostMcMarketId][b]
            ? ghostGsCvlSuspectCount[ghostMcMarketId][b] * ghostMcCfgDelayPerSuspect40 : 0);
    mathint unlock = start + ghostMcPosActivatingDelay32[b] + surcharge;
    return !ghostMcIsFrozen && start != 0 && !ghostGsCvlBanned[ghostMcMarketId][b]
        && to_mathint(e.block.timestamp) >= unlock
        && (unlock <= ghostGsCvlQuorumFrontier40
            || to_mathint(e.block.timestamp) >= start + ghostMcCfgMaxGuardiansQuorumDelay40);
}
