// LidoLendMarketController unit tests: each rule pins one view function's exact value against the mirrored state.

import "LidoLendMarketController_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_core_view.spec";
import "../setup/GuardianSignals/GuardianSignals_cvl.spec";

// MC-UT-01: The deposit limit the market reports is the room left under the supply cap, and zero while paused.
rule utMcMaxDepositMatchesCapHeadroom(env e) {

    setupLidoLendMarketControllerValidState(e);
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    mathint cap = ghostMcSupplyCap256;
    mathint tSA = to_mathint(ghostLlCvlTotalSupplyAssets);

    mathint room = maxDeposit(e);

    assert(paused => room == 0, "a paused market takes no deposit");
    assert((!paused && cap == 0) => room == max_uint256, "an unset cap leaves the room open");
    assert((!paused && cap != 0) => room == (cap > tSA ? cap - tSA : 0), "the room is the cap headroom");
}

// MC-UT-02: A supplier's reported withdrawable amount is their own supply capped by idle liquidity, and zero while paused.
rule utMcMaxWithdrawableMatchesFormula(env e, address s) {

    setupLidoLendMarketControllerValidState(e);
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    mathint shares = to_mathint(ghostLlCvlPosSupplyShares[s]);
    mathint tSA = to_mathint(ghostLlCvlTotalSupplyAssets);
    mathint tSS = to_mathint(ghostLlCvlTotalSupplyShares);
    mathint tBA = to_mathint(ghostLlCvlTotalBorrowAssets);

    mathint withdrawable = maxWithdrawableAssets(e, s);

    // toAssetsDown against the free liquidity (totalSupply minus totalBorrow), both floored.
    mathint supplyAssets = shares * (tSA + 1) / (tSS + VIRTUAL_SHARES_MC_CVL());
    mathint liquidity = tSA > tBA ? tSA - tBA : 0;
    mathint expected = supplyAssets < liquidity ? supplyAssets : liquidity;

    assert(paused => withdrawable == 0, "a paused market withdraws nothing");
    assert(!paused => withdrawable == expected, "the limit is the smaller of position and liquidity");
}

// MC-UT-03: The market reports bad debt exactly when the riskiest queued borrower's debt exceeds their collateral value.
rule utMcHasBadDebtMatchesRootPredicate(env e) {

    setupLidoLendMarketControllerValidState(e);
    address root = ghostMcHeapNodeAccount[1];
    mathint bs = to_mathint(ghostLlCvlPosBorrowShares[root]);
    mathint debtUp = debtAssetsUpMcCVL(root);
    mathint collVal = collateralValueMcCVL(root);

    bool bad = hasBadDebt(e);

    assert(ghostMcHeapNodesLength <= 1 => !bad, "an empty queue reports no bad debt");
    assert(ghostMcHeapNodesLength > 1 => (bad <=> (bs != 0 && debtUp > collVal)),
        "the flag is the root's debt over its collateral value");
}

// MC-UT-04: The next borrower to settle is the riskiest one in the queue, and an empty queue offers none.
rule utMcNextSettlementBorrowerIsHeapRoot(env e, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);

    address b; LidoLendMarketController.SettlementSlice slice;
    b, slice = nextSettlementBorrower(e, budgetSupplyShares);

    assert(ghostMcHeapNodesLength > 1 => b == ghostMcHeapNodeAccount[1],
        "the next borrower is the queue root");
    assert(ghostMcHeapNodesLength <= 1
            => (b == 0 && slice.supplyShares == 0 && slice.borrowShares == 0 && slice.remainingBorrowShares == 0),
        "an empty queue offers no settlement");
}

// MC-UT-05: A borrower's position summary reports their collateral split, debt and unlock time, and a banned borrower's collateral never unlocks.
rule utMcPositionOfUnlockTimeFormula(env e, address b) {

    setupLidoLendMarketControllerValidState(e);
    requireBucketsWithinCollateral(b);
    mathint start = ghostMcPosActivatingStart40[b];
    // Strikes always surcharge; suspicions only for a lot started before the snapshot lapses.
    mathint surcharge = ghostGsCvlStrikeCount[ghostMcMarketId][b] * ghostMcCfgDelayPerStrike40
        + (start < ghostGsCvlSuspectExpiry256[ghostMcMarketId][b]
            ? ghostGsCvlSuspectCount[ghostMcMarketId][b] * ghostMcCfgDelayPerSuspect40 : 0);

    ILidoLendMarketController.BorrowerPosition dash = positionOf(e, b);

    assert(start == 0 => to_mathint(dash.unlockTime) == 0, "no timer means no unlock time");
    assert((start != 0 && ghostGsCvlBanned[ghostMcMarketId][b]) => to_mathint(dash.unlockTime) == max_uint256,
        "a banned borrower never unlocks");
    assert((start != 0 && !ghostGsCvlBanned[ghostMcMarketId][b])
        => to_mathint(dash.unlockTime) == start + ghostMcPosActivatingDelay32[b] + surcharge,
        "unlock is start plus frozen delay plus surcharge");
    assert(to_mathint(dash.activating) == ghostMcPosActivating128[b]
        && to_mathint(dash.dust) == ghostMcPosDust128[b], "the buckets are reported verbatim");
    assert(dash.banned == ghostGsCvlBanned[ghostMcMarketId][b]
        && to_mathint(dash.flagCount) == ghostGsCvlStrikeCount[ghostMcMarketId][b],
        "the guardian opinion is reported verbatim");
    assert(to_mathint(dash.active) == to_mathint(ghostLlCvlPosCollateral[b])
            - ghostMcPosActivating128[b] - ghostMcPosDust128[b],
        "active collateral is what the two timed buckets leave");
    assert(to_mathint(dash.debtAssets) == debtAssetsUpMcCVL(b),
        "the debt is the borrower's shares valued up");
    assert(to_mathint(dash.settlementLtv) == to_mathint(ghostMcSettlementLtv256[b]),
        "the personal settlement ltv is reported verbatim");
    assert(dash.isNextToSettle <=> (ghostMcHeapNodesLength > 1
            ? ghostMcHeapNodeAccount[1] == b : b == 0),
        "a borrower is next to settle exactly when they hold the queue root");
}

// MC-UT-06: The manager's new supply cap is exactly the cap the market then reports.
rule utMcSetSupplyCapStoresValue(env e, uint256 cap) {

    setupLidoLendMarketControllerValidState(e);

    setSupplyCap(e, cap);

    assert(to_mathint(supplyCap(e)) == to_mathint(cap),
        "the view reports the cap the manager just set");
}

// MC-UT-07: The market reports itself frozen as soon as the freezer freezes it.
rule utMcFreezeLatchesFlag(env e) {

    setupLidoLendMarketControllerValidState(e);

    freeze(e);

    assert(isFrozen(e), "the view reports the freeze the freezer just latched");
}

// MC-UT-10: The six authorities the controller recognizes are six distinct roles.
rule utMcRoleIdsArePairwiseDistinct() {

    bytes32 admin = _Controller.DEFAULT_ADMIN_ROLE();
    bytes32 manager = _Controller.MANAGER_ROLE();
    bytes32 freezer = _Controller.FREEZER_ROLE();
    bytes32 unfreezer = _Controller.UNFREEZER_ROLE();
    bytes32 pauser = _Controller.PAUSER_ROLE();
    bytes32 resumer = _Controller.RESUMER_ROLE();

    assert(admin != manager && admin != freezer && admin != unfreezer
        && admin != pauser && admin != resumer,
        "no operational role collides with the default admin");
    assert(manager != freezer && manager != unfreezer && manager != pauser && manager != resumer,
        "the manager is its own authority");
    assert(freezer != unfreezer && freezer != pauser && freezer != resumer,
        "freezing is not unfreezing, pausing or resuming");
    assert(unfreezer != pauser && unfreezer != resumer && pauser != resumer,
        "the remaining pairs are distinct");
}

// MC-UT-11: The controller reports the guardian registry it was wired to.
rule utMcGuardianSignalsViewMirrorsStorage(env e) {

    setupLidoLendMarketControllerValidState(e);

    assert(guardianSignals(e) == ghostMcGuardianSignals,
        "the registry view reports the wired registry");
}

// MC-UT-12: Granting or revoking instant activation lands on the named caller alone.
rule utMcSetInstantActivationStoresFlag(env e, address caller, bool enabled, address other) {

    setupLidoLendMarketControllerValidState(e);
    require(other != caller, "SCOPE: any key but the one the toggle names");
    bool otherBefore = ghostMcInstantActivationCallers[other];

    setInstantActivation(e, caller, enabled);

    assert(hasInstantActivation(e, caller) == enabled,
        "the view reports the flag the manager just set, grant and revoke alike");
    assert(ghostMcInstantActivationCallers[other] == otherBefore,
        "no other caller's grant moves with it");
}
