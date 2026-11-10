// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external method call.
// Once proven, other spec files assume them via setupMorphoExitBookValidState, which narrows the Prover's arbitrary
// storage havoc down to reachable states and so cuts down on the false counterexamples those files hit.

import "../setup/MorphoExitBook_LinkedCore/MorphoExitBook_LinkedCore.spec";

// ME-VS-41 meParamsRowCanonical takes a market id, so consumers pin it per id at the point of use.
function requireMorphoExitBookInvariants(env e) {
    requireInvariant meServiceFeeCapped(e);
    requireInvariant meServiceFeeHasRecipient(e);
    requireInvariant meZeroIdNeverCreated(e);
    requireInvariant meForwardIdsNeverCreated(e);
    requireInvariant meIssuedIdsDense(e);
    requireInvariant meUncreatedAssetZero(e);
    requireInvariant meUncreatedAssetsRemainingZero(e);
    requireInvariant meUncreatedAssetsTotalZero(e);
    requireInvariant meUncreatedMinFillZero(e);
    requireInvariant meUncreatedStartRateZero(e);
    requireInvariant meUncreatedEndRateZero(e);
    requireInvariant meUncreatedRampStartZero(e);
    requireInvariant meUncreatedRampEndZero(e);
    requireInvariant meUncreatedCreatedAtZero(e);
    requireInvariant meUncreatedDeadlineZero(e);
    requireInvariant meUncreatedMaxShareBurnZero(e);
    requireInvariant meUncreatedStatusNotCreated(e);
    requireInvariant meRemainingImpliesOpen(e);
    requireInvariant meOpenImpliesRemaining(e);
    requireInvariant meRemainingLeTotal(e);
    requireInvariant meCreatedAssetsTotalPositive(e);
    requireInvariant meStartRateLeEndRate(e);
    requireInvariant meEndRateCapped(e);
    requireInvariant meRampStartLeRampEnd(e);
    requireInvariant meRampEndsByDeadline(e);
    requireInvariant meDeadlineAfterCreation(e);
    requireInvariant meDeadlineWithinLifetime(e);
    requireInvariant meCreatedAtNotInFuture(e);
    requireInvariant meZeroOwnerNoIds(e);
    requireInvariant meOwnerIndexIssued(e);
    requireInvariant meOwnerIndexOwnership(e);
    requireInvariant meOwnerIndexStrictlyIncreasing(e);
    requireInvariant meZeroMarketIdNeverAllowed(e);
    requireInvariant meCreatedIffMarketBound(e);
    requireInvariant meAllowedMarketHasParamsRow(e);
    requireInvariant meBoundMarketHasParamsRow(e);
    requireInvariant meCreatedAssetIsMarketLoanToken(e);
    requireInvariant meParamsRowMarketExistsOnCore(e);
    requireInvariant meMinFillWithinTotal(e);
    requireInvariant meOwnerIndexLenLeNextId(e);
    requireInvariant meUncreatedReceiverZero(e);
    requireInvariant meCreatedReceiverSet(e);
}

function setupMorphoExitBookValidState(env e) {
    setupMorphoExitBook(e);
    requireMorphoExitBookInvariants(e);
}

function SETUP_ME(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupMorphoExitBook(e);
}

// ME-VS-01: The protocol's cut of a fill's priority fee never exceeds 25 percent of it.
invariant meServiceFeeCapped(env e)
    ghostMeServiceFee256 <= MAX_SERVICE_FEE_ME_CVL()
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-02: Whenever a service fee is charged, someone is named to receive it.
invariant meServiceFeeHasRecipient(env e)
    ghostMeServiceFee256 != 0 => ghostMeFeeRecipient != 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-03: Id zero never belongs to a request, so it cannot be mistaken for one.
invariant meZeroIdNeverCreated(env e)
    ghostMeReqOwner[0] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-04: No request exists beyond the last id the book has issued.
invariant meForwardIdsNeverCreated(env e)
    forall uint256 id. to_mathint(id) > ghostMeNextId256 => ghostMeReqOwner[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-05: Every id the book has issued resolves to a real request, with no gaps.
invariant meIssuedIdsDense(env e)
    forall uint256 id. (1 <= to_mathint(id) && to_mathint(id) <= ghostMeNextId256)
        => ghostMeReqOwner[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-06: An id the book never issued carries no payout token.
invariant meUncreatedAssetZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqAsset[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-07: An id the book never issued carries nothing left to fill.
invariant meUncreatedAssetsRemainingZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqAssetsRemaining128[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-08: An id the book never issued carries no requested amount.
invariant meUncreatedAssetsTotalZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqAssetsTotal128[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-09: An id the book never issued carries no minimum fill size.
invariant meUncreatedMinFillZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqMinFillAssets128[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-10: An id the book never issued carries no opening priority fee rate.
invariant meUncreatedStartRateZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqStartRate96[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-11: An id the book never issued carries no final priority fee rate.
invariant meUncreatedEndRateZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqEndRate96[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-12: An id the book never issued carries no fee ramp start time.
invariant meUncreatedRampStartZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqRampStart32[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-13: An id the book never issued carries no fee ramp end time.
invariant meUncreatedRampEndZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqRampEnd32[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-14: An id the book never issued carries no creation time.
invariant meUncreatedCreatedAtZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqCreatedAt40[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-15: An id the book never issued carries no deadline.
invariant meUncreatedDeadlineZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqDeadline40[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-16: An id the book never issued carries no share burn budget.
invariant meUncreatedMaxShareBurnZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqMaxShareBurn128[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-17: An id the book never issued reads as unknown, never as open, filled or cancelled.
invariant meUncreatedStatusNotCreated(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0
        => ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.NotCreated
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-18: Only an open request still has assets waiting to exit.
invariant meRemainingImpliesOpen(env e)
    forall uint256 id. ghostMeReqAssetsRemaining128[id] > 0
        => ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Open
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-19: An open request always has assets still waiting to be filled.
invariant meOpenImpliesRemaining(env e)
    forall uint256 id. (ghostMeReqOwner[id] != 0
            && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Open)
        => ghostMeReqAssetsRemaining128[id] > 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-20: A request never has more left to fill than the lender asked to exit.
invariant meRemainingLeTotal(env e)
    forall uint256 id. ghostMeReqAssetsRemaining128[id] <= ghostMeReqAssetsTotal128[id]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-21: Every request in the book asks to exit at least one unit of assets.
invariant meCreatedAssetsTotalPositive(env e)
    forall uint256 id. ghostMeReqOwner[id] != 0 => ghostMeReqAssetsTotal128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-22: A request's priority fee never starts above the rate its ramp ends at.
invariant meStartRateLeEndRate(env e)
    forall uint256 id. ghostMeReqStartRate96[id] <= ghostMeReqEndRate96[id]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-23: A request's peak priority fee never exceeds 10 percent of the amount filled.
invariant meEndRateCapped(env e)
    forall uint256 id. ghostMeReqEndRate96[id] <= MAX_PRIORITY_FEE_ME_CVL()
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-24: A request's fee ramp never ends before it begins.
invariant meRampStartLeRampEnd(env e)
    forall uint256 id. ghostMeReqRampStart32[id] <= ghostMeReqRampEnd32[id]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-25: A request's fee ramp finishes climbing by its deadline, while it can still be filled.
invariant meRampEndsByDeadline(env e)
    forall uint256 id. ghostMeReqOwner[id] != 0
        => ghostMeReqCreatedAt40[id] + ghostMeReqRampEnd32[id] <= ghostMeReqDeadline40[id]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-26: A request's deadline always falls after its creation, so none is born already expired.
invariant meDeadlineAfterCreation(env e)
    forall uint256 id. ghostMeReqOwner[id] != 0
        => ghostMeReqDeadline40[id] > ghostMeReqCreatedAt40[id]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-27: A request stays fillable for at most the book's configured maximum lifetime.
invariant meDeadlineWithinLifetime(env e)
    forall uint256 id. ghostMeReqOwner[id] != 0
        => ghostMeReqDeadline40[id] <= ghostMeReqCreatedAt40[id] + ghostMeMaxLifetime256
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-28: A request's creation time is never in the future.
invariant meCreatedAtNotInFuture(env e)
    forall uint256 id. ghostMeReqCreatedAt40[id] <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-29: The zero address never accumulates a request listing of its own.
invariant meZeroOwnerNoIds(env e)
    ghostMeOwnerReqIdsLen[0] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-30: An owner's listing only points at request ids the book actually issued.
invariant meOwnerIndexIssued(env e)
    forall address o. forall uint256 i. to_mathint(i) < ghostMeOwnerReqIdsLen[o]
        => (1 <= ghostMeOwnerReqIds[o][i] && ghostMeOwnerReqIds[o][i] <= ghostMeNextId256)
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-31: An owner's listing never shows anyone else's request.
invariant meOwnerIndexOwnership(env e)
    forall address o. forall uint256 i. forall uint256 rid.
        (to_mathint(i) < ghostMeOwnerReqIdsLen[o] && ghostMeOwnerReqIds[o][i] == to_mathint(rid))
        => ghostMeReqOwner[rid] == o
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) {
    SETUP_ME(e, eFunc);
    requireInvariant meForwardIdsNeverCreated(e);
    requireInvariant meZeroOwnerNoIds(e);
} }

// ME-VS-32: An owner's listing keeps placement order and never repeats a request.
invariant meOwnerIndexStrictlyIncreasing(env e)
    forall address o. forall uint256 i. forall uint256 j.
        (to_mathint(i) < to_mathint(j) && to_mathint(j) < ghostMeOwnerReqIdsLen[o])
        => ghostMeOwnerReqIds[o][i] < ghostMeOwnerReqIds[o][j]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) {
    SETUP_ME(e, eFunc);
    requireInvariant meOwnerIndexIssued(e);
} }

// ME-VS-33: The empty market id is never on the allow-list.
invariant meZeroMarketIdNeverAllowed(env e)
    forall MorphoExitBook.Id mid. mid == to_bytes32(0) => !ghostMeIsMarketAllowed[mid]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-34: A request exists exactly when it is bound to a market.
invariant meCreatedIffMarketBound(env e)
    forall uint256 id. ghostMeReqOwner[id] != 0 <=> ghostMeMarketIdOf[id] != to_bytes32(0)
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) {
    SETUP_ME(e, eFunc);
    requireInvariant meForwardIdsNeverCreated(e);
    requireInvariant meZeroMarketIdNeverAllowed(e);
} }

// ME-VS-35: A market is never allow-listed without its full description recorded.
invariant meAllowedMarketHasParamsRow(env e)
    forall MorphoExitBook.Id mid. ghostMeIsMarketAllowed[mid] => ghostMeParamsSet[mid]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-36: Every request still resolves to its market's description, even after that market is delisted.
invariant meBoundMarketHasParamsRow(env e)
    forall uint256 id. ghostMeReqOwner[id] != 0 => ghostMeParamsSet[ghostMeMarketIdOf[id]]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) {
    SETUP_ME(e, eFunc);
    requireInvariant meAllowedMarketHasParamsRow(e);
    requireInvariant meForwardIdsNeverCreated(e);
} }

// ME-VS-37: A request always pays out in the loan token of its own market.
invariant meCreatedAssetIsMarketLoanToken(env e)
    forall uint256 id. ghostMeReqOwner[id] != 0
        => ghostMeReqAsset[id] == ghostMeParamsLoanToken[ghostMeMarketIdOf[id]]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {
    preserved setMarketAllowed(MorphoExitBook.MarketParams params, bool allowed) with (env eFunc) {
        SETUP_ME(e, eFunc);
        requireInvariant meBoundMarketHasParamsRow(e);
        // ME-VS-41 is pinned at the id this call writes.
        MorphoExitBook.Id mid = marketParamsIdCVL(params.loanToken, params.collateralToken,
            params.oracle, params.irm, params.lltv);
        requireInvariant meParamsRowCanonical(e, mid);
    }
    preserved with (env eFunc) {
        SETUP_ME(e, eFunc);
        requireInvariant meBoundMarketHasParamsRow(e);
    }
}

// ME-VS-38: Every market the book registers really exists on the lending core.
invariant meParamsRowMarketExistsOnCore(env e)
    forall MorphoExitBook.Id mid. ghostMeParamsSet[mid] => ghostMeCoreLastUpdate128[mid] != 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-39: A request's minimum fill never exceeds the total amount it asks to exit.
invariant meMinFillWithinTotal(env e)
    forall uint256 id. ghostMeReqMinFillAssets128[id] <= ghostMeReqAssetsTotal128[id]
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-40: No owner's listing holds more requests than the book has ever issued.
invariant meOwnerIndexLenLeNextId(env e)
    forall address o. ghostMeOwnerReqIdsLen[o] <= ghostMeNextId256
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-41: A stored market description always matches the id it is filed under.
invariant meParamsRowCanonical(env e, MorphoExitBook.Id mid)
    ghostMeParamsSet[mid] => marketParamsIdCVL(ghostMeParamsLoanToken[mid],
        ghostMeParamsCollateralToken[mid], ghostMeParamsOracle[mid], ghostMeParamsIrm[mid],
        require_uint256(ghostMeParamsLltv256[mid])) == mid
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-42: An id the book never issued carries no payee.
invariant meUncreatedReceiverZero(env e)
    forall uint256 id. ghostMeReqOwner[id] == 0 => ghostMeReqReceiver[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }

// ME-VS-43: Every request names a payee, so a fill never pays into the zero address.
invariant meCreatedReceiverSet(env e)
    forall uint256 id. ghostMeReqOwner[id] != 0 => ghostMeReqReceiver[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_ME(f) } { preserved with (env eFunc) { SETUP_ME(e, eFunc); } }
