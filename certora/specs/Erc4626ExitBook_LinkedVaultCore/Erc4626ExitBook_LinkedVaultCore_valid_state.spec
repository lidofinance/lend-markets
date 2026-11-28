// Each invariant is proven inductively: assumed in the pre-state, re-asserted after any external method call.
// Once proven, other spec files assume them via setupErc4626ExitBookValidState, which narrows the Prover's arbitrary
// storage havoc down to reachable states and so cuts down on the false counterexamples those files hit.

import "../LidoLendERC4626/LidoLendERC4626_valid_state.spec";
import "../setup/Erc4626ExitBook_LinkedVaultCore/Erc4626ExitBook_LinkedVaultCore.spec";

function requireErc4626ExitBookInvariants(env e) {
    requireInvariant eeServiceFeeCapped(e);
    requireInvariant eeServiceFeeHasRecipient(e);
    requireInvariant eeZeroIdNeverCreated(e);
    requireInvariant eeForwardIdsNeverCreated(e);
    requireInvariant eeIssuedIdsDense(e);
    requireInvariant eeUncreatedAssetZero(e);
    require(forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqAssetsRemaining128[id] == 0,
        "PROVED: an id with no owner has nothing left to fill");
    requireInvariant eeUncreatedAssetsTotalZero(e);
    requireInvariant eeUncreatedMinFillAssetsZero(e);
    requireInvariant eeUncreatedStartRateZero(e);
    requireInvariant eeUncreatedEndRateZero(e);
    requireInvariant eeUncreatedRampStartZero(e);
    requireInvariant eeUncreatedRampEndZero(e);
    requireInvariant eeUncreatedCreatedAtZero(e);
    requireInvariant eeUncreatedDeadlineZero(e);
    requireInvariant eeUncreatedMaxShareBurnZero(e);
    requireInvariant eeUncreatedStatusNotCreated(e);
    requireInvariant eeRemainingImpliesOpen(e);
    requireInvariant eeOpenImpliesRemaining(e);
    requireInvariant eeRemainingLeTotal(e);
    requireInvariant eeCreatedAssetsTotalPositive(e);
    requireInvariant eeUncreatedReceiverZero(e);
    requireInvariant eeStartRateLeEndRate(e);
    requireInvariant eeEndRateCapped(e);
    requireInvariant eeRampStartLeRampEnd(e);
    requireInvariant eeRampEndsByDeadline(e);
    requireInvariant eeDeadlineAfterCreation(e);
    requireInvariant eeDeadlineWithinLifetime(e);
    requireInvariant eeCreatedAtNotInFuture(e);
    requireInvariant eeZeroOwnerNoIds(e);
    requireInvariant eeOwnerIndexIssued(e);
    requireInvariant eeOwnerIndexOwnership(e);
    requireInvariant eeOwnerIndexStrictlyIncreasing(e);
    requireInvariant eeZeroVaultNeverAllowed(e);
    requireInvariant eeCreatedIffVaultBound(e);
    require(forall uint256 id. (ghostEeReqOwner[id] != 0 && ghostEeVaultOf[id] == _Vault)
            => ghostEeReqAsset[id] == ghostVaAsset,
        "PROVED: a request bound to the in-scene vault pays out in its asset");
    requireInvariant eeCreatedReceiverSet(e);
    requireInvariant eeOwnerIndexLenLeNextId(e);
}

function setupErc4626ExitBookValidState(env e) {
    setupErc4626ExitBook(e);
    requireErc4626ExitBookInvariants(e);
}

function SETUP_EE(env e, env eFunc) {
    requireSameEnv(e, eFunc);
    setupErc4626ExitBook(e);
}

// EE-VS-01: The protocol's cut of a fill's priority fee never exceeds 25 percent of it.
invariant eeServiceFeeCapped(env e)
    ghostEeServiceFee256 <= MAX_SERVICE_FEE_EE_CVL()
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-02: A nonzero service fee always has an address on file to collect it.
invariant eeServiceFeeHasRecipient(env e)
    ghostEeServiceFee256 != 0 => ghostEeFeeRecipient != 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-03: Id zero never belongs to a request, so it cannot be mistaken for one.
invariant eeZeroIdNeverCreated(env e)
    ghostEeReqOwner[0] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-04: No request is stored past the last id the book has issued.
invariant eeForwardIdsNeverCreated(env e)
    forall uint256 id. to_mathint(id) > ghostEeNextId256 => ghostEeReqOwner[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-05: Every id the book has issued still resolves to a request, with no gaps.
invariant eeIssuedIdsDense(env e)
    forall uint256 id. (1 <= to_mathint(id) && to_mathint(id) <= ghostEeNextId256)
        => ghostEeReqOwner[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-06: An id the book never issued carries no payout token.
invariant eeUncreatedAssetZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqAsset[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-07: An id the book never issued carries no requested amount.
invariant eeUncreatedAssetsTotalZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqAssetsTotal128[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-08: An id the book never issued carries no minimum fill size.
invariant eeUncreatedMinFillAssetsZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqMinFillAssets128[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-09: An id the book never issued carries no opening priority fee rate.
invariant eeUncreatedStartRateZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqStartRate96[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-10: An id the book never issued carries no final priority fee rate.
invariant eeUncreatedEndRateZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqEndRate96[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-11: An id the book never issued carries no fee ramp start time.
invariant eeUncreatedRampStartZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqRampStart32[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-12: An id the book never issued carries no fee ramp end time.
invariant eeUncreatedRampEndZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqRampEnd32[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-13: An id the book never issued carries no creation time.
invariant eeUncreatedCreatedAtZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqCreatedAt40[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-14: An id the book never issued carries no deadline.
invariant eeUncreatedDeadlineZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqDeadline40[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-15: An id the book never issued carries no share burn budget.
invariant eeUncreatedMaxShareBurnZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqMaxShareBurn128[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-16: An id the book never issued reads as unknown, never as open, filled or cancelled.
invariant eeUncreatedStatusNotCreated(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0
        => ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.NotCreated
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-17: Only an open request still has assets waiting to exit.
invariant eeRemainingImpliesOpen(env e)
    forall uint256 id. ghostEeReqAssetsRemaining128[id] > 0
        => ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Open
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-18: An open request always has assets still waiting to be filled.
invariant eeOpenImpliesRemaining(env e)
    forall uint256 id. (ghostEeReqOwner[id] != 0
            && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Open)
        => ghostEeReqAssetsRemaining128[id] > 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-19: A request never has more left to fill than the lender asked to exit.
invariant eeRemainingLeTotal(env e)
    forall uint256 id. ghostEeReqAssetsRemaining128[id] <= ghostEeReqAssetsTotal128[id]
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-20: Every request in the book asks to exit at least one unit of assets.
invariant eeCreatedAssetsTotalPositive(env e)
    forall uint256 id. ghostEeReqOwner[id] != 0 => ghostEeReqAssetsTotal128[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-21: An id the book never issued carries no payee.
invariant eeUncreatedReceiverZero(env e)
    forall uint256 id. ghostEeReqOwner[id] == 0 => ghostEeReqReceiver[id] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-22: A request's priority fee starts no higher than the ceiling it climbs to.
invariant eeStartRateLeEndRate(env e)
    forall uint256 id. ghostEeReqStartRate96[id] <= ghostEeReqEndRate96[id]
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-23: A request's peak priority fee never exceeds 10 percent of the amount filled.
invariant eeEndRateCapped(env e)
    forall uint256 id. ghostEeReqEndRate96[id] <= MAX_PRIORITY_FEE_EE_CVL()
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-24: A request's fee ramp never ends before it begins.
invariant eeRampStartLeRampEnd(env e)
    forall uint256 id. ghostEeReqRampStart32[id] <= ghostEeReqRampEnd32[id]
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-25: A request's fee ramp finishes climbing by its deadline, while it can still be filled.
invariant eeRampEndsByDeadline(env e)
    forall uint256 id. ghostEeReqOwner[id] != 0
        => ghostEeReqCreatedAt40[id] + ghostEeReqRampEnd32[id] <= ghostEeReqDeadline40[id]
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-26: A request's deadline always falls after its creation, so none is born already expired.
invariant eeDeadlineAfterCreation(env e)
    forall uint256 id. ghostEeReqOwner[id] != 0
        => ghostEeReqDeadline40[id] > ghostEeReqCreatedAt40[id]
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-27: A request never stays fillable longer than the maximum lifetime allowed from its creation.
invariant eeDeadlineWithinLifetime(env e)
    forall uint256 id. ghostEeReqOwner[id] != 0
        => ghostEeReqDeadline40[id] <= ghostEeReqCreatedAt40[id] + ghostEeMaxLifetime256
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-28: A request's creation time is never in the future.
invariant eeCreatedAtNotInFuture(env e)
    forall uint256 id. ghostEeReqCreatedAt40[id] <= e.block.timestamp
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-29: The empty address never accumulates a request history of its own.
invariant eeZeroOwnerNoIds(env e)
    ghostEeOwnerReqIdsLen[0] == 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-30: A lender's request history names only ids the book actually issued.
invariant eeOwnerIndexIssued(env e)
    forall address o. forall uint256 i. to_mathint(i) < ghostEeOwnerReqIdsLen[o]
        => (1 <= ghostEeOwnerReqIds[o][i] && ghostEeOwnerReqIds[o][i] <= ghostEeNextId256)
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-31: A lender's request history lists only requests they own.
invariant eeOwnerIndexOwnership(env e)
    forall address o. forall uint256 i. forall uint256 rid.
        (to_mathint(i) < ghostEeOwnerReqIdsLen[o] && ghostEeOwnerReqIds[o][i] == to_mathint(rid))
        => ghostEeReqOwner[rid] == o
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) {
    SETUP_EE(e, eFunc);
    requireInvariant eeForwardIdsNeverCreated(e);
    requireInvariant eeZeroOwnerNoIds(e);
} }

// EE-VS-32: A lender's request history reads in placement order and never repeats an id.
invariant eeOwnerIndexStrictlyIncreasing(env e)
    forall address o. forall uint256 i. forall uint256 j.
        (to_mathint(i) < to_mathint(j) && to_mathint(j) < ghostEeOwnerReqIdsLen[o])
        => ghostEeOwnerReqIds[o][i] < ghostEeOwnerReqIds[o][j]
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) {
    SETUP_EE(e, eFunc);
    requireInvariant eeOwnerIndexIssued(e);
} }

// EE-VS-33: The empty address is never allow-listed as a vault.
invariant eeZeroVaultNeverAllowed(env e)
    !ghostEeIsVaultAllowed[0]
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-34: A request exists exactly when a vault is bound to redeem it.
invariant eeCreatedIffVaultBound(env e)
    forall uint256 id. ghostEeReqOwner[id] != 0 <=> ghostEeVaultOf[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) {
    SETUP_EE(e, eFunc);
    requireInvariant eeZeroVaultNeverAllowed(e);
} }

// EE-VS-35: A request pays out in the underlying asset of the vault backing it.
invariant eeVaultAssetBinding(env e)
    forall uint256 id. ghostEeReqOwner[id] != 0
        => ghostEeReqAsset[id] == ghostErc4626Asset[ghostEeVaultOf[id]]
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) {
    SETUP_EE(e, eFunc);
} }

// EE-VS-36: Every request names a payee, so a fill never pays into the void.
invariant eeCreatedReceiverSet(env e)
    forall uint256 id. ghostEeReqOwner[id] != 0 => ghostEeReqReceiver[id] != 0
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }

// EE-VS-37: A lender's history never lists more requests than the book has issued.
invariant eeOwnerIndexLenLeNextId(env e)
    forall address o. ghostEeOwnerReqIdsLen[o] <= ghostEeNextId256
filtered { f -> !EXCLUDED_FUNCTION_EE(f) } { preserved with (env eFunc) { SETUP_EE(e, eFunc); } }
