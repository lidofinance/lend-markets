// Every MorphoExitBook property outside valid state, in the tree's spec-type order.

import "MorphoExitBook_LinkedCore_valid_state.spec";
import "../setup/math.spec";

// --- variable_transitions ---

// ME-VT-01: The request id counter never moves backward and issues at most one new id per call.
rule vtMeNextIdIncrementsByOne(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    mathint nextIdBefore = ghostMeNextId256;

    f(e, args);

    mathint nextIdAfter = ghostMeNextId256;

    assert(nextIdAfter == nextIdBefore || nextIdAfter == nextIdBefore + 1,
        "nextId stays or advances by exactly one");
}

// ME-VT-02: A request's owner is fixed at placement and never changes.
rule vtMeRequestOwnerImmutable(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meForwardIdsNeverCreated(e);
    address ownerBefore = ghostMeReqOwner[id];

    f(e, args);

    address ownerAfter = ghostMeReqOwner[id];

    assert(ownerBefore != 0 => ownerAfter == ownerBefore,
        "a created request's owner never changes");
}

// ME-VT-03: A request that has been filled or cancelled never changes status again.
rule vtMeClosedStatusTerminal(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meForwardIdsNeverCreated(e);
    address ownerBefore = ghostMeReqOwner[id];
    MorphoExitBook.ExitStatus statusBefore = ghostMeReqStatus[id];

    f(e, args);

    MorphoExitBook.ExitStatus statusAfter = ghostMeReqStatus[id];

    assert((ownerBefore != 0 && statusBefore != MorphoExitBook.ExitStatus.Open)
        => statusAfter == statusBefore,
        "a request that left Open never changes status again");
}

// ME-VT-04: A request's outstanding amount never grows once the request is placed.
rule vtMeAssetsRemainingNonIncreasing(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meForwardIdsNeverCreated(e);
    address ownerBefore = ghostMeReqOwner[id];
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];

    f(e, args);

    mathint remainingAfter = ghostMeReqAssetsRemaining128[id];

    assert(ownerBefore != 0 => remainingAfter <= remainingBefore,
        "a created request's outstanding amount never grows");
}

// ME-VT-05: A request's asset, size, minimum fill, share budget and fee rates are fixed at placement.
rule vtMeRequestTermsFrozen(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meForwardIdsNeverCreated(e);
    address ownerBefore = ghostMeReqOwner[id];
    address assetBefore = ghostMeReqAsset[id];
    mathint assetsTotalBefore = ghostMeReqAssetsTotal128[id];
    mathint minFillBefore = ghostMeReqMinFillAssets128[id];
    mathint maxShareBurnBefore = ghostMeReqMaxShareBurn128[id];
    mathint startRateBefore = ghostMeReqStartRate96[id];
    mathint endRateBefore = ghostMeReqEndRate96[id];

    f(e, args);

    address assetAfter = ghostMeReqAsset[id];
    mathint assetsTotalAfter = ghostMeReqAssetsTotal128[id];
    mathint minFillAfter = ghostMeReqMinFillAssets128[id];
    mathint maxShareBurnAfter = ghostMeReqMaxShareBurn128[id];
    mathint startRateAfter = ghostMeReqStartRate96[id];
    mathint endRateAfter = ghostMeReqEndRate96[id];

    assert(ownerBefore != 0 => assetAfter == assetBefore,
        "a created request's asset is frozen");
    assert(ownerBefore != 0 => assetsTotalAfter == assetsTotalBefore,
        "a created request's total is frozen");
    assert(ownerBefore != 0 => minFillAfter == minFillBefore,
        "a created request's per-fill floor is frozen");
    assert(ownerBefore != 0 => maxShareBurnAfter == maxShareBurnBefore,
        "a created request's share budget is frozen");
    assert(ownerBefore != 0 => startRateAfter == startRateBefore,
        "a created request's start rate is frozen");
    assert(ownerBefore != 0 => endRateAfter == endRateBefore,
        "a created request's end rate is frozen");
}

// ME-VT-06: A request's schedule, payee and backing market are fixed at placement.
rule vtMeRequestScheduleFrozen(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meForwardIdsNeverCreated(e);
    address ownerBefore = ghostMeReqOwner[id];
    mathint rampStartBefore = ghostMeReqRampStart32[id];
    mathint rampEndBefore = ghostMeReqRampEnd32[id];
    mathint createdAtBefore = ghostMeReqCreatedAt40[id];
    mathint deadlineBefore = ghostMeReqDeadline40[id];
    address receiverBefore = ghostMeReqReceiver[id];
    MorphoExitBook.Id marketIdOfBefore = ghostMeMarketIdOf[id];

    f(e, args);

    mathint rampStartAfter = ghostMeReqRampStart32[id];
    mathint rampEndAfter = ghostMeReqRampEnd32[id];
    mathint createdAtAfter = ghostMeReqCreatedAt40[id];
    mathint deadlineAfter = ghostMeReqDeadline40[id];
    address receiverAfter = ghostMeReqReceiver[id];
    MorphoExitBook.Id marketIdOfAfter = ghostMeMarketIdOf[id];

    assert(ownerBefore != 0 => rampStartAfter == rampStartBefore,
        "a created request's ramp start is frozen");
    assert(ownerBefore != 0 => rampEndAfter == rampEndBefore,
        "a created request's ramp end is frozen");
    assert(ownerBefore != 0 => createdAtAfter == createdAtBefore,
        "a created request's creation time is frozen");
    assert(ownerBefore != 0 => deadlineAfter == deadlineBefore,
        "a created request's deadline is frozen");
    assert(ownerBefore != 0 => receiverAfter == receiverBefore,
        "a created request's payee is frozen");
    assert(ownerBefore != 0 => marketIdOfAfter == marketIdOfBefore,
        "a created request's bound market is frozen");
}

// ME-VT-07: An owner's request list only grows by one entry at a time and never rewrites earlier entries.
rule vtMeOwnerIndexAppendOnly(env e, method f, calldataarg args, address o, uint256 j)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meOwnerIndexLenLeNextId(e);
    mathint lenBefore = ghostMeOwnerReqIdsLen[o];
    mathint entryJBefore = ghostMeOwnerReqIds[o][j];

    f(e, args);

    mathint lenAfter = ghostMeOwnerReqIdsLen[o];
    mathint entryJAfter = ghostMeOwnerReqIds[o][j];

    assert(lenAfter == lenBefore || lenAfter == lenBefore + 1,
        "an owner index grows by at most one entry and never shrinks");
    assert(to_mathint(j) < lenBefore => entryJAfter == entryJBefore,
        "an owner index prefix is never overwritten");
}

// ME-VT-08: An owner's list grows only by appending a freshly placed id, and every new request is listed under its owner.
rule vtMeOwnerIndexAppendsFreshId(env e, method f, calldataarg args, address o)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meOwnerIndexLenLeNextId(e);
    mathint lenBefore = ghostMeOwnerReqIdsLen[o];
    mathint nextIdBefore = ghostMeNextId256;

    f(e, args);

    mathint lenAfter = ghostMeOwnerReqIdsLen[o];
    mathint nextIdAfter = ghostMeNextId256;
    mathint appendedIdAfter = ghostMeOwnerReqIds[o][require_uint256(lenBefore)];
    address freshOwnerAfter = ghostMeReqOwner[require_uint256(nextIdAfter)];

    assert(lenAfter == lenBefore + 1
        => (nextIdAfter == nextIdBefore + 1 && appendedIdAfter == nextIdAfter),
        "an index grows only by appending the freshly issued id");
    assert((nextIdAfter == nextIdBefore + 1 && freshOwnerAfter == o)
        => lenAfter == lenBefore + 1,
        "a fresh request lands in its own owner's index");
}

// ME-VT-09: A market registered with the exit book keeps its record forever, even after it is de-listed.
rule vtMeParamsRowLatches(env e, method f, calldataarg args, MorphoExitBook.Id mid)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meParamsRowCanonical(e, mid);
    bool setBefore = ghostMeParamsSet[mid];
    address loanTokenBefore = ghostMeParamsLoanToken[mid];

    f(e, args);

    bool setAfter = ghostMeParamsSet[mid];

    assert(setBefore => setAfter,
        "a written params row is never unwritten");
    assert((setBefore && loanTokenBefore != 0) => ghostMeParamsLoanToken[mid] != 0,
        "a written params row is never blanked");
}

// ME-VT-10: A registered market's recorded parameters never change, so one market id always means one market.
rule vtMeParamsRowValuesFrozen(env e, method f, calldataarg args, MorphoExitBook.Id mid)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    requireInvariant meParamsRowCanonical(e, mid);
    bool setBefore = ghostMeParamsSet[mid];
    address loanTokenBefore = ghostMeParamsLoanToken[mid];
    address collateralTokenBefore = ghostMeParamsCollateralToken[mid];
    address oracleBefore = ghostMeParamsOracle[mid];
    address irmBefore = ghostMeParamsIrm[mid];
    mathint lltvBefore = ghostMeParamsLltv256[mid];

    f(e, args);

    address loanTokenAfter = ghostMeParamsLoanToken[mid];
    address collateralTokenAfter = ghostMeParamsCollateralToken[mid];
    address oracleAfter = ghostMeParamsOracle[mid];
    address irmAfter = ghostMeParamsIrm[mid];
    mathint lltvAfter = ghostMeParamsLltv256[mid];

    assert(setBefore => loanTokenAfter == loanTokenBefore,
        "a written row's loan token is frozen");
    assert(setBefore => collateralTokenAfter == collateralTokenBefore,
        "a written row's collateral token is frozen");
    assert(setBefore => oracleAfter == oracleBefore,
        "a written row's oracle is frozen");
    assert(setBefore => irmAfter == irmBefore,
        "a written row's irm is frozen");
    assert(setBefore => lltvAfter == lltvBefore,
        "a written row's lltv is frozen");
}

// ME-VT-11: No exit book call makes the lending core forget that a market was created.
rule vtMeCoreMarketStaysCreated(env e, method f, calldataarg args, MorphoExitBook.Id mid)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    mathint lastUpdateBefore = ghostMeCoreLastUpdate128[mid];

    f(e, args);

    mathint lastUpdateAfter = ghostMeCoreLastUpdate128[mid];

    assert(lastUpdateBefore != 0 => lastUpdateAfter != 0,
        "a created core market never loses its creation stamp");
}

// --- state_transitions ---

// ME-ST-01: Only an open request can have its outstanding amount move.
rule stMeRemainingMovesOnlyOpen(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBookValidState(e);
    address ownerBefore = ghostMeReqOwner[id];
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];
    MorphoExitBook.ExitStatus stBefore = ghostMeReqStatus[id];

    f(e, args);

    assert((ownerBefore != 0 && ghostMeReqAssetsRemaining128[id] != remainingBefore)
        => stBefore == MorphoExitBook.ExitStatus.Open,
        "only an open request moves its outstanding amount");
}

// ME-ST-02: A newly placed request belongs to the caller who placed it.
rule stMeMintOwnsNewId(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBookValidState(e);
    mathint nextBefore = ghostMeNextId256;

    f(e, args);

    assert(ghostMeNextId256 != nextBefore
        => ghostMeReqOwner[require_uint256(ghostMeNextId256)] == e.msg.sender,
        "the fresh id belongs to the caller");
}

// ME-ST-03: Placing a request adds exactly one entry to the caller's own request list.
rule stMeMintIndexesOwner(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBookValidState(e);
    mathint nextBefore = ghostMeNextId256;
    mathint ownerIdsBefore = ghostMeOwnerReqIdsLen[e.msg.sender];

    f(e, args);

    assert(ghostMeNextId256 != nextBefore
        => ghostMeOwnerReqIdsLen[e.msg.sender] == ownerIdsBefore + 1,
        "the caller's index grows by one");
}

// --- high_level ---

// ME-HL-01: Filling one request leaves every other request's outstanding amount untouched.
rule hlMeFillLeavesOtherRequests(env e, uint256 id, uint256 fillAssets, address rewardRecipient,
    uint256 id2) {

    setupMorphoExitBookValidState(e);
    require(id2 != id,
        "SCOPE: a bystander request");
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id2];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    assert(ghostMeReqAssetsRemaining128[id2] == remainingBefore,
        "a fill moves only its own request's outstanding amount");
}

// ME-HL-02: Placing a request leaves every already issued request's outstanding amount untouched.
rule hlMePlaceLeavesExistingRequests(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline, uint256 oldId) {

    setupMorphoExitBookValidState(e);
    require(to_mathint(oldId) <= ghostMeNextId256,
        "SCOPE: a pre-existing id");
    mathint remainingBefore = ghostMeReqAssetsRemaining128[oldId];

    placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    assert(ghostMeReqAssetsRemaining128[oldId] == remainingBefore,
        "a place moves no pre-existing request's outstanding amount");
}

// ME-HL-03: Cancelling a request leaves every other request's status untouched.
rule hlMeCancelLeavesOtherRequests(env e, uint256 id, uint256 id2) {

    setupMorphoExitBookValidState(e);
    require(id2 != id,
        "SCOPE: a bystander request");
    MorphoExitBook.ExitStatus stBefore = ghostMeReqStatus[id2];

    cancelExitRequest(e, id);

    assert(ghostMeReqStatus[id2] == stBefore,
        "a cancel closes only its own request");
}

// ME-HL-04: The fee rate a fill charges stays inside the request's own band and under the 10 percent cap.
rule hlMeRampRateWithinBand(env e, uint256 id) {

    setupMorphoExitBookValidState(e);

    uint256 rate = priorityFeeRateExt(e, id);

    assert(ghostMeReqStartRate96[id] <= to_mathint(rate) && to_mathint(rate) <= ghostMeReqEndRate96[id],
        "the charged rate stays inside the request's [startRate, endRate] band");
    assert(to_mathint(rate) <= MAX_PRIORITY_FEE_ME_CVL(),
        "the charged rate never exceeds the priority-fee cap");
}

// ME-HL-05: A request's priority fee rate never falls as the request ages.
rule hlMeRampRateMonotoneInTime(env e1, env e2, uint256 id) {

    setupMorphoExitBookValidState(e1);
    setupEnv(e2);
    require(e1.block.timestamp <= e2.block.timestamp,
        "SCOPE: e1 is the earlier of the two rate reads");

    uint256 rateEarly = priorityFeeRateExt(e1, id);
    uint256 rateLate = priorityFeeRateExt(e2, id);

    assert(to_mathint(rateEarly) <= to_mathint(rateLate),
        "the charged rate never falls as the request ages");
}

// ME-HL-06: A fill pays out everything it withdrew and leaves no assets stuck in the exit book.
rule hlMeFillKeepsNoRemainder(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address asset = ghostMeReqAsset[id];
    require(ghostMeReqReceiver[id] != currentContract && rewardRecipient != currentContract,
        "SCOPE: no payout leg lands on the book");
    mathint bookBefore = ghostERC20Balances128[asset][currentContract];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    assert(ghostERC20Balances128[asset][currentContract] == bookBefore,
        "a fill splits the withdrawn assets with no remainder");
}

// ME-HL-07: A fill touches only the market its request was placed against, leaving other markets and their positions alone.
rule hlMeFillTouchesOnlyItsOwnMarket(env e, uint256 id, uint256 fillAssets, address rewardRecipient,
    MorphoExitBook.Id other, address who) {

    setupMorphoExitBookValidState(e);
    MorphoExitBook.Id own = ghostMeMarketIdOf[id];
    requireInvariant meParamsRowCanonical(e, own);
    require(other != own,
        "SCOPE: a bystander market");

    uint128 tsa0; uint128 tss0; uint128 tba0; uint128 tbs0; uint128 lu0; uint128 fe0;
    tsa0, tss0, tba0, tbs0, lu0, fe0 = _Core.market(e, other);
    uint256 shares0; uint128 borrow0; uint128 coll0;
    shares0, borrow0, coll0 = _Core.position(e, other, who);

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    uint128 tsa1; uint128 tss1; uint128 tba1; uint128 tbs1; uint128 lu1; uint128 fe1;
    tsa1, tss1, tba1, tbs1, lu1, fe1 = _Core.market(e, other);
    uint256 shares1; uint128 borrow1; uint128 coll1;
    shares1, borrow1, coll1 = _Core.position(e, other, who);

    assert(tsa1 == tsa0 && tss1 == tss0 && tba1 == tba0 && tbs1 == tbs0 && fe1 == fe0,
        "a fill moves no other market's supply or borrow totals");
    assert(lu1 == lu0,
        "a fill accrues no other market");
    assert(shares1 == shares0 && borrow1 == borrow0 && coll1 == coll0,
        "a fill touches no holder's position in another market");
}

// ME-HL-08: A fill debits the request by exactly the amount filled and burns no more of the lender's supply than budgeted.
rule hlMeFillDebitsExactlyWithinShareBudget(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address owner = ghostMeReqOwner[id];
    MorphoExitBook.Id own = ghostMeMarketIdOf[id];
    requireInvariant meParamsRowCanonical(e, own);
    uint128 tsa; uint128 tss; uint128 tba; uint128 tbs; uint128 lu; uint128 fe;
    tsa, tss, tba, tbs, lu, fe = _Core.market(e, own);
    uint256 ownerShares0; uint128 ownerBorrow0; uint128 ownerColl0;
    ownerShares0, ownerBorrow0, ownerColl0 = _Core.position(e, own, owner);
    mathint remBefore = ghostMeReqAssetsRemaining128[id];
    mathint total = ghostMeReqAssetsTotal128[id];
    mathint budget = ghostMeReqMaxShareBurn128[id];

    require(to_mathint(lu) == to_mathint(e.block.timestamp),
        "SCOPE: a market accrued this block");
    fillExitRequest(e, id, fillAssets, rewardRecipient);

    uint256 ownerShares1; uint128 ownerBorrow1; uint128 ownerColl1;
    ownerShares1, ownerBorrow1, ownerColl1 = _Core.position(e, own, owner);

    assert(remBefore - ghostMeReqAssetsRemaining128[id] == to_mathint(fillAssets),
        "a fill debits the request by exactly the amount it was asked for");
    assert(budget != 0 => to_mathint(ownerShares0) - to_mathint(ownerShares1)
            <= (budget * fillAssets + total - 1) / total,
        "a fill burns no more of the owner's supply than the pro-rata share budget allows");
}

// ME-HL-09: Placing a request binds it to the market named, in that market's loan token, for the full amount asked.
rule hlMePlaceBindsItsOwnMarket(env e, MorphoExitBook.Id marketId, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    requireInvariant meParamsRowCanonical(e, marketId);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    assert(ghostMeMarketIdOf[id] == marketId,
        "a placement binds the request to exactly the market id it named");
    assert(ghostMeReqAsset[id] == ghostMeParamsLoanToken[marketId],
        "a placement denominates the request in its own market's loan token");
    assert(ghostMeReqAssetsTotal128[id] == to_mathint(assets)
        && ghostMeReqAssetsRemaining128[id] == to_mathint(assets),
        "a placement books the whole amount asked for as outstanding");
}

// ME-HL-10: A fill draws the assets it pays out from the market the request was placed against.
rule hlMeFillTakesAssetsOutOfItsMarket(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address asset = ghostMeReqAsset[id];
    address receiver = ghostMeReqReceiver[id];
    address recipient = ghostMeFeeRecipient;

    require(receiver != _Core && rewardRecipient != _Core && recipient != _Core,
        "SCOPE: no payout leg lands on the market itself");

    mathint sourceBefore = ghostERC20Balances128[asset][_Core];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    assert(ghostERC20Balances128[asset][_Core] < sourceBefore,
        "a fill takes a strictly positive amount out of the market");
}

// --- unit_tests ---

// ME-UT-01: Before a request's fee ramp begins, its priority fee rate stays at the starting rate.
rule utMeRampRateHoldsAtStartRate(env e, uint256 id) {

    setupMorphoExitBookValidState(e);
    require(to_mathint(e.block.timestamp) - ghostMeReqCreatedAt40[id] < ghostMeReqRampStart32[id],
        "SCOPE: the opening hold, before the ramp begins");

    uint256 rate = priorityFeeRateExt(e, id);

    assert(to_mathint(rate) == ghostMeReqStartRate96[id],
        "the fee rate holds at startRate through the opening hold");
}

// ME-UT-02: Once the ramp begins, a request's priority fee rate rises in a straight line to its end rate.
rule utMeRampRateInterpolatesLinearly(env e, uint256 id) {

    setupMorphoExitBookValidState(e);
    mathint elapsed = to_mathint(e.block.timestamp) - ghostMeReqCreatedAt40[id];
    require(elapsed >= ghostMeReqRampStart32[id] && elapsed < ghostMeReqRampEnd32[id],
        "SCOPE: the climb, between ramp start and ramp end");

    uint256 rate = priorityFeeRateExt(e, id);

    assert(to_mathint(rate) == ghostMeReqStartRate96[id]
            + (ghostMeReqEndRate96[id] - ghostMeReqStartRate96[id])
                * (elapsed - ghostMeReqRampStart32[id])
                / (ghostMeReqRampEnd32[id] - ghostMeReqRampStart32[id]),
        "the fee rate climbs linearly from startRate to endRate across the ramp");
}

// ME-UT-03: Once the ramp is over, a request's priority fee rate stays at its end rate.
rule utMeRampRatePlateausAtEndRate(env e, uint256 id) {

    setupMorphoExitBookValidState(e);
    require(to_mathint(e.block.timestamp) - ghostMeReqCreatedAt40[id] >= ghostMeReqRampEnd32[id],
        "SCOPE: the plateau, past the ramp end");

    uint256 rate = priorityFeeRateExt(e, id);

    assert(to_mathint(rate) == ghostMeReqEndRate96[id],
        "the fee rate plateaus at endRate and never climbs past it");
}

// ME-UT-04: A fill pays the receiver the amount filled minus the current priority fee.
rule utMeFillPaysReceiverFillLessPriorityFee(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address asset = ghostMeReqAsset[id];
    address receiver = ghostMeReqReceiver[id];
    address recipient = ghostMeFeeRecipient;

    require(receiver != rewardRecipient && receiver != recipient,
        "SCOPE: the receiver is neither the filler nor the fee recipient");
    require(receiver != _Core && receiver != currentContract,
        "SCOPE: the payout lands on neither the market nor the book");

    mathint receiverBefore = ghostERC20Balances128[asset][receiver];
    uint256 rate = priorityFeeRateExt(e, id);

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    mathint priorityFee = to_mathint(fillAssets) * to_mathint(rate) / WAD_ME_CVL();

    assert(ghostERC20Balances128[asset][receiver] - receiverBefore
            == to_mathint(fillAssets) - priorityFee,
        "a fill pays the receiver the amount filled less the ramp's priority fee");
}

// ME-UT-05: A fill pays the filler the priority fee less the service cut, and the fee recipient exactly that cut.
rule utMeFillSplitsFillerRewardAndServiceCut(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address asset = ghostMeReqAsset[id];
    address receiver = ghostMeReqReceiver[id];
    address recipient = ghostMeFeeRecipient;

    require(receiver != rewardRecipient && receiver != recipient && rewardRecipient != recipient,
        "SCOPE: the receiver, the filler and the fee recipient are pairwise distinct");
    require(rewardRecipient != _Core && recipient != _Core && rewardRecipient != currentContract,
        "SCOPE: no payout leg lands on the market or the book");

    mathint svcFee = ghostMeServiceFee256;
    mathint fillerBefore = ghostERC20Balances128[asset][rewardRecipient];
    mathint recipientBefore = ghostERC20Balances128[asset][recipient];
    uint256 rate = priorityFeeRateExt(e, id);

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    mathint priorityFee = to_mathint(fillAssets) * to_mathint(rate) / WAD_ME_CVL();
    mathint serviceCut = priorityFee * svcFee / WAD_ME_CVL();

    assert(ghostERC20Balances128[asset][rewardRecipient] - fillerBefore
            == priorityFee - serviceCut,
        "a fill pays the filler the priority fee net of the service cut");
    assert(ghostERC20Balances128[asset][recipient] - recipientBefore == serviceCut,
        "a fill pays the fee recipient exactly the service cut of the priority fee");
}

// ME-UT-06: A fill never changes the exit book's own supply position in the lending market.
rule utMeFillLeavesTheBookWithoutACorePosition(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    MorphoExitBook.Id own = ghostMeMarketIdOf[id];
    requireInvariant meParamsRowCanonical(e, own);
    address coreFeeRecipient = _Core.feeRecipient(e);
    require(coreFeeRecipient != currentContract,
        "TRUSTED: the core's fee recipient is not the book");
    uint256 bookShares0; uint128 bookBorrow0; uint128 bookColl0;
    bookShares0, bookBorrow0, bookColl0 = _Core.position(e, own, currentContract);

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    uint256 bookShares1; uint128 bookBorrow1; uint128 bookColl1;
    bookShares1, bookBorrow1, bookColl1 = _Core.position(e, own, currentContract);

    assert(bookShares1 == bookShares0,
        "a fill leaves the book without a supply position of its own");
}

// ME-UT-07: Reading an owner's request ids returns the window asked for, starting at the offset given.
rule utMeOwnerRequestIdsReadsTheRequestedWindow(env e, address o, uint256 offset, uint256 count) {

    setupMorphoExitBookValidState(e);
    require(count >= 1 && count <= 3, "SCOPE: a page of at most three ids");
    mathint len = ghostMeOwnerReqIdsLen[o];
    require(to_mathint(offset) < len,
        "SCOPE: an offset inside the listing");

    uint256[] page = getOwnerRequestIds(e, o, offset, count);

    mathint room = len - to_mathint(offset);
    assert(to_mathint(page.length) == (to_mathint(count) < room ? to_mathint(count) : room),
        "a page holds the smaller of the count asked for and the ids left past the offset");
    assert(to_mathint(page[0]) == ghostMeOwnerReqIds[o][offset],
        "a page starts at the entry the offset names");
}

// ME-UT-08: The backing a placement demands is the amount asked for, converted to shares at the live price and rounded up.
rule utMeSupplyQuoteRoundsUpAtTheLivePrice(env e, MorphoExitBook.Id marketId, uint256 assets) {

    setupMorphoExitBookValidState(e);
    require(ghostMeParamsSet[marketId],
        "SCOPE: a registered market");
    requireInvariant meParamsRowCanonical(e, marketId);

    uint128 tsa; uint128 tss; uint128 tba; uint128 tbs; uint128 lu; uint128 fe;
    tsa, tss, tba, tbs, lu, fe = _Core.market(e, marketId);
    require(to_mathint(lu) == to_mathint(e.block.timestamp)
        || tba == 0 || ghostMeParamsIrm[marketId] == 0,
        "SCOPE: no interest pending");

    uint256 quote = supplyAssetsToSharesExt(e, marketId, assets);

    assert(to_mathint(quote) == (assets * (tss + 1000000) + tsa) / (tsa + 1),
        "the quote converts the requested assets to shares at the live supply price, rounded up");
}

// --- reachability ---

// ME-RC-01: A lender can open a request on an allow-listed market and own it.
rule rcMePlaceExitRequestIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeReqOwner[id] == e.msg.sender && ghostMeReqAssetsRemaining128[id] > 0
        && ghostMeMarketIdOf[id] == marketId && ghostMeIsMarketAllowed[marketId],
        "a lender can open a caller-owned request on the allow-listed market it names");
}

// ME-RC-02: A lender can place a request that sets a floor under every partial fill.
rule rcMePlaceWithMinFillIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeReqMinFillAssets128[id] > 0
        && ghostMeReqMinFillAssets128[id] <= ghostMeReqAssetsTotal128[id]
        && ghostMeReqAssetsRemaining128[id] > 0,
        "a request with a per-fill floor can be placed");
}

// ME-RC-03: A lender can place a request for a single unit of assets.
rule rcMePlaceOneWeiAssetIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeReqAssetsTotal128[id] == 1 && ghostMeReqOwner[id] == e.msg.sender,
        "a one-wei exit request can be placed");
}

// ME-RC-04: A lender can place a request as large as the request record can hold.
rule rcMePlaceMaxUint128AssetsIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeReqAssetsTotal128[id] == max_uint128,
        "a request at the uint128 record boundary can be placed");
}

// ME-RC-05: A lender can place a request whose priority fee rate climbs strictly over time.
rule rcMePlaceRampedRatesIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeReqStartRate96[id] < ghostMeReqEndRate96[id]
        && ghostMeReqRampStart32[id] < ghostMeReqRampEnd32[id]
        && ghostMeReqAssetsRemaining128[id] > 0,
        "a strictly ramped priority-fee request can be placed");
}

// ME-RC-06: A lender can place a request that offers fillers no priority fee at all.
rule rcMePlaceZeroRampIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeReqEndRate96[id] == 0 && ghostMeReqAssetsRemaining128[id] > 0,
        "a zero-incentive request with no priority-fee ramp can be placed");
}

// ME-RC-07: A lender can set a deadline exactly at the maximum request lifetime.
rule rcMePlaceDeadlineAtLifetimeCapIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeReqDeadline40[id] == ghostMeReqCreatedAt40[id] + ghostMeMaxLifetime256,
        "a deadline at the exact max-lifetime cap is admitted");
}

// ME-RC-08: A filler can fill part of a request and leave it open for more.
rule rcMeFillPartialIsReachable(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(ghostMeReqAssetsRemaining128[id] > 0
        && ghostMeReqAssetsRemaining128[id] < remainingBefore
        && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Open,
        "a partial fill can shrink an open request and leave it open");
}

// ME-RC-09: A filler can take the whole remaining amount and close the request as filled.
rule rcMeFillFullCloseIsReachable(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    require(ghostMeReqAssetsRemaining128[id] == 1,
        "SCOPE: a one-wei request");
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(remainingBefore > 0 && ghostMeReqAssetsRemaining128[id] == 0
        && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Filled,
        "a fill can close a live request to filled at zero remaining");
}

// ME-RC-10: A fill can credit the exit proceeds to the receiver the lender named.
rule rcMeFillPaysReceiverIsReachable(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address receiver = ghostMeReqReceiver[id];
    address reqAsset = ghostMeReqAsset[id];
    mathint receiverBalBefore = ghostERC20Balances128[reqAsset][receiver];
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    // Alias disjointness anchors the witness: the payout leg is the only credit to the receiver.
    satisfy(ghostMeReqAssetsRemaining128[id] < remainingBefore
        && ghostERC20Balances128[reqAsset][receiver] > receiverBalBefore
        && receiver != rewardRecipient && receiver != ghostMeFeeRecipient && receiver != _Core
        && receiver != currentContract,
        "a fill can pay exit proceeds to the request's receiver");
}

// ME-RC-11: A fill under a positive service fee can credit the fee recipient its cut.
rule rcMeFillPaysServiceFeeIsReachable(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    require(ghostMeServiceFee256 > 0, "SCOPE: a positive service fee is configured");
    address feeRecip = ghostMeFeeRecipient;
    address receiver = ghostMeReqReceiver[id];
    address reqAsset = ghostMeReqAsset[id];
    mathint feeBalBefore = ghostERC20Balances128[reqAsset][feeRecip];
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    // Alias disjointness anchors the witness: the service cut is the only credit to the recipient.
    satisfy(ghostMeReqAssetsRemaining128[id] < remainingBefore
        && ghostERC20Balances128[reqAsset][feeRecip] > feeBalBefore
        && feeRecip != rewardRecipient && feeRecip != receiver && feeRecip != _Core
        && feeRecip != currentContract,
        "a fill under a positive service fee can pay the fee recipient");
}

// ME-RC-12: An owner can cancel an open request, leaving nothing outstanding on it.
rule rcMeCancelExitRequestIsReachable(env e, uint256 id) {

    setupMorphoExitBookValidState(e);
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];

    cancelExitRequest(e, id);

    satisfy(remainingBefore > 0 && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Cancelled
        && ghostMeReqAssetsRemaining128[id] == 0,
        "an owner can cancel a live request, zeroing its outstanding amount");
}

// ME-RC-13: An owner can still cancel a partly filled request with one unit left.
rule rcMeCancelLastWeiIsReachable(env e, uint256 id) {

    setupMorphoExitBookValidState(e);
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];

    cancelExitRequest(e, id);

    satisfy(remainingBefore == 1 && ghostMeReqAssetsTotal128[id] > 1
        && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Cancelled,
        "a nearly-exhausted partially-filled request can still be cancelled");
}

// ME-RC-14: The fee manager can set a positive service fee and its recipient.
rule rcMeSetServiceFeeIsReachable(env e, address recipient, uint256 fee) {

    setupMorphoExitBookValidState(e);

    setServiceFee(e, recipient, fee);

    satisfy(fee > 0 && recipient != 0 && ghostMeServiceFee256 == to_mathint(fee)
        && ghostMeFeeRecipient == recipient,
        "the fee manager can configure a positive service fee with a recipient");
}

// ME-RC-15: The fee manager can set the service fee to its 25 percent cap.
rule rcMeSetServiceFeeAtCapIsReachable(env e, address recipient, uint256 fee) {

    setupMorphoExitBookValidState(e);

    setServiceFee(e, recipient, fee);

    satisfy(ghostMeServiceFee256 == MAX_SERVICE_FEE_ME_CVL(),
        "the service fee can be set exactly at its cap");
}

// ME-RC-16: The fee manager can switch a positive service fee back off.
rule rcMeSetServiceFeeDisableIsReachable(env e, address recipient, uint256 fee) {

    setupMorphoExitBookValidState(e);
    mathint feeBefore = ghostMeServiceFee256;

    setServiceFee(e, recipient, fee);

    satisfy(feeBefore > 0 && ghostMeServiceFee256 == 0,
        "a positive service fee can be switched off");
}

// ME-RC-17: The allow-list manager can open a market for exits and record its parameters.
rule rcMeSetMarketAllowedIsReachable(env e, MorphoExitBook.MarketParams params) {

    setupMorphoExitBookValidState(e);
    MorphoExitBook.Id mid = marketParamsIdCVL(params.loanToken, params.collateralToken,
        params.oracle, params.irm, params.lltv);
    bool allowedBefore = ghostMeIsMarketAllowed[mid];

    setMarketAllowed(e, params, true);

    satisfy(!allowedBefore && ghostMeIsMarketAllowed[mid]
        && ghostMeParamsLoanToken[mid] == params.loanToken,
        "the allow-list manager can allow-list a market and register its params row");
}

// ME-RC-18: The allow-list manager can remove a market from the allow list.
rule rcMeSetMarketDelistIsReachable(env e, MorphoExitBook.MarketParams params) {

    setupMorphoExitBookValidState(e);
    MorphoExitBook.Id mid = marketParamsIdCVL(params.loanToken, params.collateralToken,
        params.oracle, params.irm, params.lltv);
    bool allowedBefore = ghostMeIsMarketAllowed[mid];

    setMarketAllowed(e, params, false);

    satisfy(allowedBefore && !ghostMeIsMarketAllowed[mid],
        "the allow-list manager can de-list a previously allowed market");
}

// ME-RC-19: The recoverer can send stray tokens held by the book to a recipient.
rule rcMeRecoverERC20IsReachable(env e, address token, address recipient, uint256 amount) {

    setupMorphoExitBookValidState(e);
    mathint recipBefore = ghostERC20Balances128[token][recipient];

    recoverERC20(e, token, recipient, amount);

    satisfy(amount > 0 && recipient != currentContract
        && ghostERC20Balances128[token][recipient] == recipBefore + amount,
        "the recoverer can recover stray erc20 tokens to a recipient");
}

// ME-RC-20: The recoverer can empty the book's entire ether balance in one sweep.
rule rcMeRecoverEtherIsReachable(env e, address recipient) {

    setupMorphoExitBookValidState(e);
    mathint bookEthBefore = nativeBalances[currentContract];

    recoverEther(e, recipient);

    satisfy(bookEthBefore > 0 && nativeBalances[currentContract] == 0,
        "the recoverer can drain the book's full ether balance");
}

// ME-RC-21: A lender can cancel a request in the same block it was placed.
rule rcMePlaceThenCancelIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    cancelExitRequest(e, id);

    satisfy(ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Cancelled
        && ghostMeReqAssetsRemaining128[id] == 0 && ghostMeReqAssetsTotal128[id] > 0,
        "a freshly placed request can be cancelled in the same block");
}

// ME-RC-22: A market just added to the allow list can immediately back a new request.
rule rcMeAllowThenPlaceIsReachable(env e, MorphoExitBook.MarketParams params, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    MorphoExitBook.Id mid = marketParamsIdCVL(params.loanToken, params.collateralToken,
        params.oracle, params.irm, params.lltv);

    setMarketAllowed(e, params, true);
    uint256 id = placeExitRequest(e, mid, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeMarketIdOf[id] == mid && ghostMeReqAssetsRemaining128[id] > 0,
        "a newly allow-listed market can immediately back a fresh request");
}

// ME-RC-23: Requests from two different owners can stand in the book at the same time.
rule rcMeTwoOwnersCoexistIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline, uint256 otherId) {

    setupMorphoExitBookValidState(e);

    uint256 id = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);

    satisfy(ghostMeReqOwner[id] == e.msg.sender && ghostMeReqOwner[otherId] != 0
        && ghostMeReqOwner[otherId] != e.msg.sender,
        "requests of two distinct owners can coexist in the book");
}

// ME-RC-24: The book can report a positive last request id, taken from its own id counter.
rule rcMeLastRequestIdPositiveIsReachable(env e) {

    setupMorphoExitBookValidState(e);

    uint256 last = lastRequestId(e);

    satisfy(to_mathint(last) == ghostMeNextId256 && last > 0,
        "the request counter can be positive and reports the minted high-water mark");
}

// ME-RC-25: The book can report a positive request count for an owner, matching that owner's stored list.
rule rcMeOwnerRequestCountPositiveIsReachable(env e, address owner) {

    setupMorphoExitBookValidState(e);

    uint256 c = getOwnerRequestCount(e, owner);

    satisfy(c > 0 && to_mathint(c) == ghostMeOwnerReqIdsLen[owner],
        "an active owner's request count is positive and matches the index length");
}

// ME-RC-26: A newly placed request can resolve to the parameters of the market it named.
rule rcMeMarketParamsOfResolvesIsReachable(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);

    uint256 requestId = placeExitRequest(e, marketId, assets, receiver, minFillAssets, maxShareBurn,
        ramp, deadline);
    MorphoExitBook.MarketParams p = marketParamsOf(e, requestId);

    satisfy(ghostMeReqOwner[requestId] != 0 && p.loanToken == ghostMeReqAsset[requestId]
        && p.loanToken != 0 && ghostMeMarketIdOf[requestId] == marketId,
        "a fresh request resolves to the registered params of the market it named");
}

// ME-RC-27: A lender can still cancel an open request while the book is paused.
rule rcMeCancelWhilePausedIsReachable(env e, uint256 id) {

    setupMorphoExitBookValidState(e);
    bool pausedBefore = paused();
    MorphoExitBook.ExitStatus statusBefore = ghostMeReqStatus[id];

    cancelExitRequest(e, id);

    satisfy(pausedBefore && statusBefore == MorphoExitBook.ExitStatus.Open
        && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Cancelled
        && ghostMeReqAssetsRemaining128[id] == 0,
        "an owner can cancel an open request while the book is stopped");
}

// ME-RC-28: A fill below the request's minimum can still go through when it closes the whole remainder.
rule rcMeFillBelowMinFillClosesRequestIsReachable(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    mathint minFill = ghostMeReqMinFillAssets128[id];
    mathint remainingBefore = ghostMeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(to_mathint(fillAssets) < minFill && to_mathint(fillAssets) == remainingBefore
        && ghostMeReqAssetsRemaining128[id] == 0
        && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Filled,
        "a fill under the request's floor still closes the whole remainder");
}

// ME-RC-29: A fill can go through while a second funded market stands untouched.
rule rcMeFillLeavesTheOtherMarketIsReachable(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient, MorphoExitBook.Id other) {

    setupMorphoExitBookValidState(e);
    MorphoExitBook.Id own = ghostMeMarketIdOf[id];
    requireInvariant meParamsRowCanonical(e, own);
    require(other != own && ghostMeParamsSet[other],
        "SCOPE: a second registered market, distinct from the filled request's own");

    uint128 tsa0; uint128 tss0; uint128 tba0; uint128 tbs0; uint128 lu0; uint128 fe0;
    tsa0, tss0, tba0, tbs0, lu0, fe0 = _Core.market(e, other);
    mathint remBefore = ghostMeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    uint128 tsa1; uint128 tss1; uint128 tba1; uint128 tbs1; uint128 lu1; uint128 fe1;
    tsa1, tss1, tba1, tbs1, lu1, fe1 = _Core.market(e, other);

    satisfy(ghostMeReqAssetsRemaining128[id] < remBefore
        && lu0 != 0 && tss0 > 0
        && tsa1 == tsa0 && tss1 == tss0 && lu1 == lu0,
        "a fill shrinks its request while a second created, funded market is untouched");
}

// ME-RC-30: The fee manager can clear the fee recipient and leave the fee at zero.
rule rcMeSetServiceFeeClearsRecipientIsReachable(env e, address recipient, uint256 fee) {

    setupMorphoExitBookValidState(e);
    address recipientBefore = ghostMeFeeRecipient;

    setServiceFee(e, recipient, fee);

    satisfy(recipientBefore != 0 && ghostMeFeeRecipient == 0 && ghostMeServiceFee256 == 0,
        "the fee manager can retire the fee recipient and leave the fee at zero");
}

// ME-RC-31: A fill can go through when its share burn exactly meets the request's own limit.
rule rcMeFillAtExactShareBudgetIsReachable(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address owner = ghostMeReqOwner[id];
    MorphoExitBook.Id own = ghostMeMarketIdOf[id];
    requireInvariant meParamsRowCanonical(e, own);
    uint128 tsa; uint128 tss; uint128 tba; uint128 tbs; uint128 lu; uint128 fe;
    tsa, tss, tba, tbs, lu, fe = _Core.market(e, own);
    uint256 ownerShares0; uint128 ownerBorrow0; uint128 ownerColl0;
    ownerShares0, ownerBorrow0, ownerColl0 = _Core.position(e, own, owner);
    mathint total = ghostMeReqAssetsTotal128[id];
    mathint budget = ghostMeReqMaxShareBurn128[id];

    require(to_mathint(lu) == to_mathint(e.block.timestamp),
        "SCOPE: a market accrued this block");
    fillExitRequest(e, id, fillAssets, rewardRecipient);

    uint256 ownerShares1; uint128 ownerBorrow1; uint128 ownerColl1;
    ownerShares1, ownerBorrow1, ownerColl1 = _Core.position(e, own, owner);

    satisfy(budget != 0 && to_mathint(ownerShares0) - to_mathint(ownerShares1)
            == (budget * fillAssets + total - 1) / total,
        "a fill whose burn exactly meets its pro-rata share budget is admitted");
}

// ME-RC-32: The book can be stopped and started again, and its reads answer while stopped.
rule rcMePauseResumeIsReachable(env e, uint256 id) {

    setupMorphoExitBookValidState(e);
    bool pausedBefore = paused();
    uint256 lastBefore = lastRequestId(e);

    pause(e);

    bool pausedWhileStopped = paused();
    getExitRequest(e, id);
    uint256 lastWhileStopped = lastRequestId(e);

    resume(e);

    bool pausedAfterResume = paused();

    satisfy(!pausedBefore && pausedWhileStopped && !pausedAfterResume
        && to_mathint(lastWhileStopped) == to_mathint(lastBefore),
        "the pauser can stop the book and the resumer can start it again, and the reads answer throughout");
}

// --- reverts ---

// ME-RV-01: Changing a market's allow-list status fails exactly when the caller lacks the role or the market does not exist.
rule rvMeSetMarketAllowedRevertsIff(env e, MorphoExitBook.MarketParams params, bool allowed) {

    setupMorphoExitBookValidState(e);
    bool notManager = !hasRole(ALLOWLIST_MANAGER_ROLE(), e.msg.sender);
    MorphoExitBook.Id mid = marketParamsIdCVL(params.loanToken, params.collateralToken,
        params.oracle, params.irm, params.lltv);
    bool marketNotCreated = ghostMeCoreLastUpdate128[mid] == 0;

    setMarketAllowed@withrevert(e, params, allowed);
    bool reverted = lastReverted;

    assert(reverted <=> (notManager || marketNotCreated),
        "setMarketAllowed rejects exactly an unauthorized caller or an uncreated core market");
}

// ME-RV-02: Setting the service fee fails exactly when the caller lacks the role, the fee exceeds its cap, or no recipient is named.
rule rvMeSetServiceFeeRevertsIff(env e, address recipient, uint256 fee) {

    setupMorphoExitBookValidState(e);
    bool notManager = !hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    bool feeTooHigh = to_mathint(fee) > MAX_SERVICE_FEE_ME_CVL();
    bool recipientMissing = recipient == 0 && fee != 0;

    setServiceFee@withrevert(e, recipient, fee);
    bool reverted = lastReverted;

    assert(reverted <=> (notManager || feeTooHigh || recipientMissing),
        "setServiceFee rejects exactly an unauthorized caller, an over-cap or recipientless fee");
}

// ME-RV-03: Placing an exit request against a market off the allow list fails.
rule rvMePlaceExitRequestRevertsWhenMarketNotAllowed(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool notAllowed = !ghostMeIsMarketAllowed[marketId];

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(notAllowed => reverted, "placeExitRequest rejects a market off the allow-list");
}

// ME-RV-04: Placing an exit request fails when the lender has not authorized the book over their position.
rule rvMePlaceExitRequestRevertsWhenNotAuthorizedOnCore(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool authorized = _Core.isAuthorized(e, e.msg.sender, currentContract);

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(!authorized => reverted,
        "placeExitRequest rejects a caller who has not authorized the book on the core");
}

// ME-RV-05: Placing an exit request fails when the lender's supply position does not cover the amount.
rule rvMePlaceExitRequestRevertsOnInsufficientBacking(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    uint256 callerShares; uint128 callerBorrow; uint128 callerColl;
    callerShares, callerBorrow, callerColl = _Core.position(e, marketId, e.msg.sender);
    uint256 quote = supplyAssetsToSharesExt(e, marketId, assets);
    bool insufficientBacking = to_mathint(callerShares) < to_mathint(quote);

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(insufficientBacking => reverted,
        "placeExitRequest rejects an amount the caller's supply position does not back");
}

// ME-RV-06: Placing an exit request for a zero amount always fails.
rule rvMePlaceExitRequestRevertsOnZeroAssets(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool zeroAssets = assets == 0;

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(zeroAssets => reverted, "placeExitRequest rejects a zero-asset request");
}

// ME-RV-07: Placing a request whose end fee rate exceeds the 10 percent cap fails.
rule rvMePlaceExitRequestRevertsOnHighPriorityFee(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool feeTooHigh = to_mathint(ramp.endRate) > MAX_PRIORITY_FEE_ME_CVL();

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(feeTooHigh => reverted,
        "placeExitRequest rejects an end priority-fee rate above the cap");
}

// ME-RV-08: Placing a request whose fee ramp starts above where it ends fails.
rule rvMePlaceExitRequestRevertsOnStartAboveEnd(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool startAboveEnd = ramp.startRate > ramp.endRate;

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(startAboveEnd => reverted,
        "placeExitRequest rejects a start rate above the end rate");
}

// ME-RV-09: Placing a request whose ramp start time is after its ramp end fails.
rule rvMePlaceExitRequestRevertsOnRampStartAfterEnd(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool rampInverted = ramp.rampStart > ramp.rampEnd;

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(rampInverted => reverted,
        "placeExitRequest rejects a ramp start after the ramp end");
}

// ME-RV-10: Placing a request with a deadline not in the future fails.
rule rvMePlaceExitRequestRevertsOnDeadlineInPast(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool deadlinePast = to_mathint(deadline) <= to_mathint(e.block.timestamp);

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(deadlinePast => reverted, "placeExitRequest rejects a deadline not in the future");
}

// ME-RV-11: Placing a request with a deadline past the maximum request lifetime fails.
rule rvMePlaceExitRequestRevertsOnDeadlineTooFar(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool deadlineTooFar =
        to_mathint(deadline) > to_mathint(e.block.timestamp) + ghostMeMaxLifetime256;

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(deadlineTooFar => reverted,
        "placeExitRequest rejects a deadline beyond the lifetime cap");
}

// ME-RV-12: Placing a request whose fee ramp ends after its deadline fails.
rule rvMePlaceExitRequestRevertsOnRampPastDeadline(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool rampPastDeadline =
        to_mathint(e.block.timestamp) + to_mathint(ramp.rampEnd) > to_mathint(deadline);

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(rampPastDeadline => reverted,
        "placeExitRequest rejects a ramp that ends after the deadline");
}

// ME-RV-13: Placing a request bigger than the stored amount field can hold fails.
rule rvMePlaceExitRequestRevertsOnAssetsCastOverflow(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool assetsOverflow = to_mathint(assets) > max_uint128;

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(assetsOverflow => reverted,
        "placeExitRequest rejects an amount above the uint128 record width");
}

// ME-RV-14: Placing a request with a deadline beyond the stored deadline field's range fails.
rule rvMePlaceExitRequestRevertsOnDeadlineCastOverflow(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool deadlineOverflow = to_mathint(deadline) > max_uint40;

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(deadlineOverflow => reverted,
        "placeExitRequest rejects a deadline above the uint40 record width");
}

// ME-RV-15: Placing a request with ramp offsets beyond their stored fields' range fails.
rule rvMePlaceExitRequestRevertsOnRampCastOverflow(env e, MorphoExitBook.Id marketId,
    uint256 assets, address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool rampOverflow = to_mathint(ramp.rampStart) > max_uint32
        || to_mathint(ramp.rampEnd) > max_uint32;

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(rampOverflow => reverted,
        "placeExitRequest rejects ramp offsets above the uint32 record width");
}

// ME-RV-16: A request that meets every placement condition is always accepted.
rule rvMePlaceValidRequestSucceeds(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    require(!paused(), "SCOPE: placement is not paused");
    require(ghostMeIsMarketAllowed[marketId], "SCOPE: an allow-listed market");
    requireInvariant meParamsRowCanonical(e, marketId);
    bool authorized = _Core.isAuthorized(e, e.msg.sender, currentContract);
    require(authorized, "SCOPE: the caller pre-authorized the book on the core");
    uint256 quote = supplyAssetsToSharesExt(e, marketId, assets);
    uint256 callerShares; uint128 callerBorrow; uint128 callerColl;
    callerShares, callerBorrow, callerColl = _Core.position(e, marketId, e.msg.sender);
    require(to_mathint(quote) <= to_mathint(callerShares),
        "SCOPE: the caller's supply position backs the quoted shares");
    require(assets != 0 && to_mathint(assets) <= max_uint128,
        "SCOPE: a nonzero amount within the record width");
    require(receiver != 0, "SCOPE: a real payee");
    require(to_mathint(maxShareBurn) <= max_uint128
        && (maxShareBurn == 0 || to_mathint(maxShareBurn) >= to_mathint(quote)),
        "SCOPE: a share budget within the record width that covers the placement quote");
    require(to_mathint(ramp.endRate) <= MAX_PRIORITY_FEE_ME_CVL()
        && ramp.startRate <= ramp.endRate
        && ramp.rampStart <= ramp.rampEnd
        && to_mathint(ramp.rampEnd) <= max_uint32,
        "SCOPE: a capped, non-inverted ramp inside the uint32 width");
    require(to_mathint(deadline) > to_mathint(e.block.timestamp)
        && to_mathint(deadline) <= to_mathint(e.block.timestamp) + ghostMeMaxLifetime256
        && to_mathint(e.block.timestamp) + to_mathint(ramp.rampEnd) <= to_mathint(deadline)
        && to_mathint(deadline) <= max_uint40,
        "SCOPE: a capped future deadline past the ramp end");
    require(to_mathint(e.block.timestamp) + ghostMeMaxLifetime256 <= max_uint256,
        "TRUSTED: the deployed lifetime cap leaves the checked deadline add in range");
    require(ghostMeNextId256 < max_uint256,
        "SCOPE: the id counter below its saturation corner");

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(!reverted, "a fully valid place succeeds");
}

// ME-RV-17: Filling an exit request after its deadline has passed always fails.
rule rvMeFillExitRequestRevertsWhenExpired(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    bool pastDeadline = to_mathint(e.block.timestamp) > ghostMeReqDeadline40[id];

    fillExitRequest@withrevert(e, id, fillAssets, rewardRecipient);
    bool reverted = lastReverted;

    assert(pastDeadline => reverted, "fillExitRequest rejects a request past its deadline");
}

// ME-RV-18: Filling fails once the request's owner revokes the book's permission over their position.
rule rvMeFillExitRequestRevertsWhenAuthorizationRevoked(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address requestOwner = ghostMeReqOwner[id];
    bool authorized = _Core.isAuthorized(e, requestOwner, currentContract);

    fillExitRequest@withrevert(e, id, fillAssets, rewardRecipient);
    bool reverted = lastReverted;

    assert(!authorized => reverted,
        "fillExitRequest rejects a request whose owner revoked the book's authorization");
}

// ME-RV-19: Filling a request fails when its owner, unless it is the market's fee recipient, holds no supply position left.
rule rvMeFillExitRequestRevertsOnZeroBacking(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address requestOwner = ghostMeReqOwner[id];
    MorphoExitBook.Id mid = ghostMeMarketIdOf[id];
    requireInvariant meParamsRowCanonical(e, mid);
    address coreFeeRecipient = _Core.feeRecipient(e);
    require(coreFeeRecipient != requestOwner,
        "SCOPE: the exiting lender is not the core's fee recipient");
    uint256 ownerShares; uint128 ownerBorrow; uint128 ownerColl;
    ownerShares, ownerBorrow, ownerColl = _Core.position(e, mid, requestOwner);
    bool zeroBacking = ownerShares == 0;

    fillExitRequest@withrevert(e, id, fillAssets, rewardRecipient);
    bool reverted = lastReverted;

    assert(zeroBacking => reverted,
        "fillExitRequest rejects a request with no live supply backing");
}

// ME-RV-20: A backed, unexpired fill of an open request succeeds while the market carries no debt.
rule rvMeFillValidRequestSucceeds(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    address requestOwner = ghostMeReqOwner[id];
    MorphoExitBook.Id mid = ghostMeMarketIdOf[id];
    mathint remaining = ghostMeReqAssetsRemaining128[id];
    require(!paused(), "SCOPE: filling is not paused");
    require(rewardRecipient != 0, "SCOPE: a real filler payee");
    require(requestOwner != 0 && ghostMeReqReceiver[id] != 0
        && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Open
        && to_mathint(e.block.timestamp) <= ghostMeReqDeadline40[id],
        "SCOPE: an open, unexpired request with a real payee");
    require(fillAssets != 0 && to_mathint(fillAssets) <= remaining
        && (to_mathint(fillAssets) >= ghostMeReqMinFillAssets128[id]
            || to_mathint(fillAssets) == remaining),
        "SCOPE: an amount inside the remainder that clears the request's own floor");
    require(ghostMeReqMaxShareBurn128[id] == 0,
        "SCOPE: share-burn protection disabled");
    requireInvariant meParamsRowCanonical(e, mid);
    uint128 tsa; uint128 tss; uint128 tba; uint128 tbs; uint128 lu; uint128 fe;
    tsa, tss, tba, tbs, lu, fe = _Core.market(e, mid);
    require(to_mathint(lu) == to_mathint(e.block.timestamp),
        "SCOPE: a market accrued this block");
    require(tba == 0,
        "SCOPE: a debt-free market");
    require(to_mathint(fillAssets) <= to_mathint(tsa),
        "SCOPE: the market's supply covers the withdrawal");
    require(to_mathint(tsa) <= ghostERC20Balances128[ghostMeReqAsset[id]][_Core],
        "PROVED: LL-VS-09 tokenBackingSolvency");
    bool authorized = _Core.isAuthorized(e, requestOwner, currentContract);
    require(authorized, "SCOPE: the request owner keeps the book authorized on the core");
    uint256 ownerShares; uint128 ownerBorrow; uint128 ownerColl;
    ownerShares, ownerBorrow, ownerColl = _Core.position(e, mid, requestOwner);
    require((fillAssets * (tss + 1000000) + tsa) / (tsa + 1) <= to_mathint(ownerShares),
        "SCOPE: the owner's live position covers the shares the withdrawal burns");
    require(to_mathint(ownerShares) <= to_mathint(tss),
        "PROVED: LL-VS-05 supplySharesSumCorrect");
    require(!_Core._hookInProgress,
        "SCOPE: a top-level fill, with no core hook in progress");

    fillExitRequest@withrevert(e, id, fillAssets, rewardRecipient);
    bool reverted = lastReverted;

    assert(!reverted,
        "a fully backed, unexpired, budget-free fill on a fresh, debt-free market succeeds");
}

// ME-RV-21: Cancelling an exit request fails exactly when the caller is not its owner or it is not open.
rule rvMeCancelExitRequestRevertsIff(env e, uint256 id) {

    setupMorphoExitBookValidState(e);
    bool notRequestOwner = ghostMeReqOwner[id] != e.msg.sender;
    bool notOpen = ghostMeReqStatus[id] != MorphoExitBook.ExitStatus.Open;

    cancelExitRequest@withrevert(e, id);
    bool reverted = lastReverted;

    assert(reverted <=> (notRequestOwner || notOpen),
        "cancel rejects exactly a non-owner caller or an already-closed request");
}

// ME-RV-22: Sweeping the book's ether fails when the caller is not the recoverer or the recipient is zero.
rule rvMeRecoverEtherRevertsOnNotRecovererOrZeroRecipient(env e, address recipient) {

    setupMorphoExitBookValidState(e);
    bool notRecoverer = !hasRole(RECOVERER_ROLE(), e.msg.sender);
    bool zeroRecipient = recipient == 0;

    recoverEther@withrevert(e, recipient);
    bool reverted = lastReverted;

    assert((notRecoverer || zeroRecipient) => reverted,
        "recoverEther rejects an unauthorized caller or a zero recipient");
}

// ME-RV-23: Recovering a stray ERC-20 balance fails exactly when the caller is not the recoverer or the recipient is zero.
rule rvMeRecoverTokenRevertsIff(env e, address token, address recipient, uint256 amount) {

    setupMorphoExitBookValidState(e);
    bool notRecoverer = !hasRole(RECOVERER_ROLE(), e.msg.sender);
    bool zeroRecipient = recipient == 0;

    recoverERC20@withrevert(e, token, recipient, amount);
    bool reverted = lastReverted;

    assert(reverted <=> (notRecoverer || zeroRecipient),
        "erc-20 recovery rejects exactly an unauthorized caller or a zero recipient");
}

// ME-RV-24: Recovering a stray NFT fails exactly when the caller is not the recoverer or the recipient is zero.
rule rvMeRecoverNftRevertsIff(env e, address token, address recipient, uint256 tokenId) {

    setupMorphoExitBookValidState(e);
    bool notRecoverer = !hasRole(RECOVERER_ROLE(), e.msg.sender);
    bool zeroRecipient = recipient == 0;

    recoverERC721@withrevert(e, token, recipient, tokenId);
    bool reverted = lastReverted;

    assert(reverted <=> (notRecoverer || zeroRecipient),
        "erc-721 recovery rejects exactly an unauthorized caller or a zero recipient");
}

// ME-RV-25: Recovering a stray ERC-1155 balance fails exactly when the caller is not the recoverer or the recipient is zero.
rule rvMeRecoverMultiTokenRevertsIff(env e, address token, address recipient, uint256 tokenId) {

    setupMorphoExitBookValidState(e);
    bool notRecoverer = !hasRole(RECOVERER_ROLE(), e.msg.sender);
    bool zeroRecipient = recipient == 0;

    recoverERC1155@withrevert(e, token, recipient, tokenId);
    bool reverted = lastReverted;

    assert(reverted <=> (notRecoverer || zeroRecipient),
        "erc-1155 recovery rejects exactly an unauthorized caller or a zero recipient");
}

// ME-RV-26: Reading several exit requests in one call never fails.
rule rvMeGetRequestsNeverReverts(env e, uint256[] ids) {

    setupMorphoExitBookValidState(e);
    require(ids.length <= 3,
        "SCOPE: a batch of at most three ids");

    getRequests@withrevert(e, ids);
    bool reverted = lastReverted;

    assert(!reverted, "getRequests never reverts under valid state");
}

// ME-RV-27: Reading a page of an owner's request ids never fails, an out-of-range start included.
rule rvMeGetOwnerRequestIdsNeverReverts(env e, address owner, uint256 offset, uint256 count) {

    setupMorphoExitBookValidState(e);
    require(count <= 3,
        "SCOPE: a page of at most three ids");

    getOwnerRequestIds@withrevert(e, owner, offset, count);
    bool reverted = lastReverted;

    assert(!reverted, "getOwnerRequestIds never reverts under valid state");
}

// ME-RV-28: A lender cannot place a new exit request while the book is stopped.
rule rvMePlaceExitRequestRevertsWhenPaused(env e, MorphoExitBook.Id marketId, uint256 assets,
    address receiver, uint256 minFillAssets, uint256 maxShareBurn,
    MorphoExitBook.PriorityRamp ramp, uint256 deadline) {

    setupMorphoExitBookValidState(e);
    bool bookPaused = paused();

    placeExitRequest@withrevert(e, marketId, assets, receiver, minFillAssets, maxShareBurn, ramp,
        deadline);
    bool reverted = lastReverted;

    assert(bookPaused => reverted,
        "placeExitRequest rejects a placement while the book is stopped");
}

// ME-RV-29: No one can fill an exit request while the book is stopped.
rule rvMeFillExitRequestRevertsWhenPaused(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    bool bookPaused = paused();

    fillExitRequest@withrevert(e, id, fillAssets, rewardRecipient);
    bool reverted = lastReverted;

    assert(bookPaused => reverted,
        "fillExitRequest rejects a fill while the book is stopped");
}

// ME-RV-30: A request whose floor is its whole amount takes only a fill of the whole remainder.
rule rvMeFillExitRequestRevertsOnPartialAtWholeTotalFloor(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    bool wholeTotalFloor = ghostMeReqMinFillAssets128[id] == ghostMeReqAssetsTotal128[id];
    bool notWholeRemainder = to_mathint(fillAssets) != ghostMeReqAssetsRemaining128[id];

    fillExitRequest@withrevert(e, id, fillAssets, rewardRecipient);
    bool reverted = lastReverted;

    assert((wholeTotalFloor && notWholeRemainder) => reverted,
        "a floor at the whole posted amount rejects every fill but the whole remainder");
}

// --- access_control ---

// ME-AC-01: An exit request is cancelled only by the lender who owns it.
rule acMeOnlyRequestOwnerCancels(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    address ownerBefore = ghostMeReqOwner[id];
    MorphoExitBook.ExitStatus statusBefore = ghostMeReqStatus[id];

    f(e, args);

    assert((statusBefore != MorphoExitBook.ExitStatus.Cancelled
            && ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.Cancelled)
        => e.msg.sender == ownerBefore,
        "a request becomes cancelled only when its owner cancels it");
}

// ME-AC-02: An owner's list of request ids changes only when that owner is the caller.
rule acMeOwnerIndexMovesOnlyForCaller(env e, method f, calldataarg args, address o)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    mathint lenBefore = ghostMeOwnerReqIdsLen[o];

    f(e, args);

    assert(ghostMeOwnerReqIdsLen[o] != lenBefore => o == e.msg.sender,
        "an owner's request-id index moves only when that owner places a request");
}

// ME-AC-03: Only the fee manager can change the service fee or its recipient.
rule acMeOnlyFeeManagerSetsFeeConfig(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    bool callerIsFeeManager = hasRole(FEE_MANAGER_ROLE(), e.msg.sender);
    address feeRecipientBefore = ghostMeFeeRecipient;
    mathint serviceFeeBefore = ghostMeServiceFee256;

    f(e, args);

    assert((ghostMeFeeRecipient != feeRecipientBefore || ghostMeServiceFee256 != serviceFeeBefore)
        => callerIsFeeManager,
        "the service-fee configuration moves only for the fee manager");
}

// ME-AC-04: Only the allow-list manager can add or remove a market from the allow-list.
rule acMeOnlyManagerMovesMarketAllowlist(env e, method f, calldataarg args, MorphoExitBook.Id mid)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    bool callerIsManager = hasRole(ALLOWLIST_MANAGER_ROLE(), e.msg.sender);
    bool allowedBefore = ghostMeIsMarketAllowed[mid];

    f(e, args);

    assert(ghostMeIsMarketAllowed[mid] != allowedBefore => callerIsManager,
        "the market allow-list moves only for the allow-list manager");
}

// ME-AC-05: Only the allow-list manager can write a market's registered parameters.
rule acMeOnlyManagerWritesParamsRow(env e, method f, calldataarg args, MorphoExitBook.Id mid)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    bool callerIsManager = hasRole(ALLOWLIST_MANAGER_ROLE(), e.msg.sender);
    address loanTokenBefore = ghostMeParamsLoanToken[mid];
    address collateralTokenBefore = ghostMeParamsCollateralToken[mid];
    address oracleBefore = ghostMeParamsOracle[mid];
    address irmBefore = ghostMeParamsIrm[mid];
    mathint lltvBefore = ghostMeParamsLltv256[mid];
    bool setBefore = ghostMeParamsSet[mid];

    f(e, args);

    assert((ghostMeParamsLoanToken[mid] != loanTokenBefore
            || ghostMeParamsCollateralToken[mid] != collateralTokenBefore
            || ghostMeParamsOracle[mid] != oracleBefore
            || ghostMeParamsIrm[mid] != irmBefore
            || ghostMeParamsLltv256[mid] != lltvBefore
            || ghostMeParamsSet[mid] != setBefore)
        => callerIsManager,
        "a market-params registry row moves only for the allow-list manager");
}

// ME-AC-06: Only a role's admin can grant or revoke it, apart from a holder giving up their own.
rule acMeOnlyRoleAdminMovesRoles(env e, method f, calldataarg args, bytes32 role, address account)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    bool hadRole = hasRole(role, account);
    bool callerIsRoleAdmin = hasRole(getRoleAdmin(role), e.msg.sender);

    f(e, args);

    assert(hasRole(role, account) != hadRole
        => (callerIsRoleAdmin
            || (account == e.msg.sender && hadRole && !hasRole(role, account))),
        "role membership moves only for the role's admin, or for a holder giving up their own");
}

// ME-AC-07: The book's ether balance falls only when the recoverer sweeps it.
rule acMeOnlyRecovererSweepsEther(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_ME(f) } {

    setupMorphoExitBook(e);
    bool callerIsRecoverer = hasRole(RECOVERER_ROLE(), e.msg.sender);
    mathint etherBefore = nativeBalances[_MorphoExitBook];

    f(e, args);

    assert(nativeBalances[_MorphoExitBook] < etherBefore => callerIsRecoverer,
        "the book's ether balance decreases only for the recoverer");
}
