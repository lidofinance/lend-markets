// Every Erc4626ExitBook property outside valid state, in the tree's spec-type order.

import "Erc4626ExitBook_LinkedVaultCore_valid_state.spec";
import "../setup/math.spec";

// --- variable_transitions ---

// EE-VT-01: The request id counter never moves backward and issues at most one new id per call.
rule vtEeNextIdStepsByOne(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    mathint nextIdBefore = ghostEeNextId256;

    f(e, args);

    mathint nextIdAfter = ghostEeNextId256;
    assert(nextIdAfter == nextIdBefore || nextIdAfter == nextIdBefore + 1,
        "nextId stays or advances by exactly one");
}

// EE-VT-02: A request's owner is fixed at placement and never changes.
rule vtEeReqOwnerFrozenOnceSet(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    requireInvariant eeForwardIdsNeverCreated(e);
    address ownerBefore = ghostEeReqOwner[id];

    f(e, args);

    address ownerAfter = ghostEeReqOwner[id];
    assert(ownerBefore != 0 => ownerAfter == ownerBefore,
        "a created request's owner never changes");
}

// EE-VT-03: A request that has been filled or cancelled never changes status again.
rule vtEeClosedStatusTerminal(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    requireInvariant eeForwardIdsNeverCreated(e);
    address ownerBefore = ghostEeReqOwner[id];
    Erc4626ExitBook.ExitStatus statusBefore = ghostEeReqStatus[id];

    f(e, args);

    Erc4626ExitBook.ExitStatus statusAfter = ghostEeReqStatus[id];
    assert((ownerBefore != 0 && statusBefore != Erc4626ExitBook.ExitStatus.Open)
        => statusAfter == statusBefore,
        "a closed status is terminal");
}

// EE-VT-04: A request's outstanding amount never grows once the request is placed.
rule vtEeAssetsRemainingNeverGrows(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    requireInvariant eeForwardIdsNeverCreated(e);
    address ownerBefore = ghostEeReqOwner[id];
    mathint remainingBefore = ghostEeReqAssetsRemaining128[id];

    f(e, args);

    mathint remainingAfter = ghostEeReqAssetsRemaining128[id];
    assert(ownerBefore != 0 => remainingAfter <= remainingBefore,
        "a created request's remaining amount is non-increasing");
}

// EE-VT-05: A request's asset, size, minimum fill, share budget and fee rates are fixed at placement.
rule vtEeTermsFrozenOnceCreated(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    requireInvariant eeForwardIdsNeverCreated(e);
    address ownerBefore = ghostEeReqOwner[id];
    address assetBefore = ghostEeReqAsset[id];
    mathint totalBefore = ghostEeReqAssetsTotal128[id];
    mathint minFillBefore = ghostEeReqMinFillAssets128[id];
    mathint burnCapBefore = ghostEeReqMaxShareBurn128[id];
    mathint startRateBefore = ghostEeReqStartRate96[id];
    mathint endRateBefore = ghostEeReqEndRate96[id];

    f(e, args);

    address assetAfter = ghostEeReqAsset[id];
    mathint totalAfter = ghostEeReqAssetsTotal128[id];
    mathint minFillAfter = ghostEeReqMinFillAssets128[id];
    mathint burnCapAfter = ghostEeReqMaxShareBurn128[id];
    mathint startRateAfter = ghostEeReqStartRate96[id];
    mathint endRateAfter = ghostEeReqEndRate96[id];
    assert(ownerBefore != 0 => assetAfter == assetBefore,
        "a created request's asset never changes");
    assert(ownerBefore != 0 => totalAfter == totalBefore,
        "a created request's posted amount never changes");
    assert(ownerBefore != 0 => minFillAfter == minFillBefore,
        "a created request's minimum fill never changes");
    assert(ownerBefore != 0 => burnCapAfter == burnCapBefore,
        "a created request's share-burn budget never changes");
    assert(ownerBefore != 0 => startRateAfter == startRateBefore,
        "a created request's start rate never changes");
    assert(ownerBefore != 0 => endRateAfter == endRateBefore,
        "a created request's end rate never changes");
}

// EE-VT-06: A request's fee ramp timing, creation time, deadline and payee are fixed at placement.
rule vtEeScheduleFrozenOnceCreated(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    requireInvariant eeForwardIdsNeverCreated(e);
    address ownerBefore = ghostEeReqOwner[id];
    mathint rampStartBefore = ghostEeReqRampStart32[id];
    mathint rampEndBefore = ghostEeReqRampEnd32[id];
    mathint createdBefore = ghostEeReqCreatedAt40[id];
    mathint deadlineBefore = ghostEeReqDeadline40[id];
    address receiverBefore = ghostEeReqReceiver[id];

    f(e, args);

    mathint rampStartAfter = ghostEeReqRampStart32[id];
    mathint rampEndAfter = ghostEeReqRampEnd32[id];
    mathint createdAfter = ghostEeReqCreatedAt40[id];
    mathint deadlineAfter = ghostEeReqDeadline40[id];
    address receiverAfter = ghostEeReqReceiver[id];
    assert(ownerBefore != 0 => rampStartAfter == rampStartBefore,
        "a created request's ramp start never changes");
    assert(ownerBefore != 0 => rampEndAfter == rampEndBefore,
        "a created request's ramp end never changes");
    assert(ownerBefore != 0 => createdAfter == createdBefore,
        "a created request's creation time never changes");
    assert(ownerBefore != 0 => deadlineAfter == deadlineBefore,
        "a created request's deadline never changes");
    assert(ownerBefore != 0 => receiverAfter == receiverBefore,
        "a created request's payee never changes");
}

// EE-VT-07: The vault a request draws from is fixed at placement and never switches.
rule vtEeVaultFrozenOnceCreated(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    requireInvariant eeForwardIdsNeverCreated(e);
    address ownerBefore = ghostEeReqOwner[id];
    address vaultBefore = ghostEeVaultOf[id];

    f(e, args);

    address vaultAfter = ghostEeVaultOf[id];
    assert(ownerBefore != 0 => vaultAfter == vaultBefore,
        "a created request's bound vault never changes");
}

// EE-VT-08: An owner's request list only gains entries, and entries already in it are never rewritten.
rule vtEeOwnerIndexAppendOnly(env e, method f, calldataarg args, address o, uint256 i)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    requireInvariant eeOwnerIndexLenLeNextId(e);
    mathint lenBefore = ghostEeOwnerReqIdsLen[o];
    mathint entryBefore = ghostEeOwnerReqIds[o][i];

    f(e, args);

    mathint lenAfter = ghostEeOwnerReqIdsLen[o];
    mathint entryAfter = ghostEeOwnerReqIds[o][i];
    assert(lenAfter == lenBefore || lenAfter == lenBefore + 1,
        "an owner's index grows by at most one entry and never shrinks");
    assert(to_mathint(i) < lenBefore => entryAfter == entryBefore,
        "existing index entries are never rewritten");
}

// EE-VT-09: An owner's list only grows by appending a newly placed request, and every new request is listed under its owner.
rule vtEeOwnerIndexAppendsFreshId(env e, method f, calldataarg args, address o)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    requireInvariant eeOwnerIndexLenLeNextId(e);
    mathint lenBefore = ghostEeOwnerReqIdsLen[o];
    mathint nextIdBefore = ghostEeNextId256;

    f(e, args);

    mathint lenAfter = ghostEeOwnerReqIdsLen[o];
    mathint nextIdAfter = ghostEeNextId256;
    mathint appendedIdAfter = ghostEeOwnerReqIds[o][require_uint256(lenBefore)];
    address freshOwnerAfter = ghostEeReqOwner[require_uint256(nextIdAfter)];

    assert(lenAfter == lenBefore + 1
        => (nextIdAfter == nextIdBefore + 1 && appendedIdAfter == nextIdAfter),
        "an index grows only by appending the freshly issued id");
    assert((nextIdAfter == nextIdBefore + 1 && freshOwnerAfter == o)
        => lenAfter == lenBefore + 1,
        "a fresh request lands in its own owner's index");
}

// --- state_transitions ---

// EE-ST-01: A request is marked filled only when nothing is left to exit on it.
rule stEeFilledClosesAtZero(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBookValidState(e);
    mathint remainingBefore = ghostEeReqAssetsRemaining128[id];

    f(e, args);

    assert((ghostEeReqAssetsRemaining128[id] < remainingBefore
            && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Filled)
        => ghostEeReqAssetsRemaining128[id] == 0,
        "a fill closes only at zero remaining");
}

// EE-ST-02: Cancelling a request leaves nothing outstanding on it.
rule stEeCancelZeroesRemaining(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBookValidState(e);
    Erc4626ExitBook.ExitStatus stBefore = ghostEeReqStatus[id];

    f(e, args);

    assert((ghostEeReqStatus[id] != stBefore
            && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Cancelled)
        => ghostEeReqAssetsRemaining128[id] == 0,
        "a cancel zeroes the remaining amount");
}

// EE-ST-03: A newly placed request belongs to the caller who placed it.
rule stEeMintOwnsNewId(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBookValidState(e);
    mathint nextBefore = ghostEeNextId256;

    f(e, args);

    assert(ghostEeNextId256 != nextBefore
        => ghostEeReqOwner[require_uint256(ghostEeNextId256)] == e.msg.sender,
        "the fresh id belongs to the caller");
}

// --- high_level ---

// EE-HL-01: Filling one request leaves every other request's outstanding amount untouched.
rule hlEeFillLeavesOtherRequests(env e, uint256 id, uint256 fillAssets, address rewardRecipient,
    uint256 id2) {

    setupErc4626ExitBookValidState(e);
    require(id2 != id,
        "SCOPE: a bystander request, not the one being filled");
    mathint remainingBefore = ghostEeReqAssetsRemaining128[id2];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    assert(ghostEeReqAssetsRemaining128[id2] == remainingBefore,
        "a fill moves only its own request's remaining amount");
}

// EE-HL-02: Placing a request leaves every already issued request's outstanding amount untouched.
rule hlEePlaceLeavesExistingRequests(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline,
    uint256 oldId) {

    setupErc4626ExitBookValidState(e);
    require(to_mathint(oldId) <= ghostEeNextId256,
        "SCOPE: an id already issued before this placement");
    mathint remainingBefore = ghostEeReqAssetsRemaining128[oldId];

    placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    assert(ghostEeReqAssetsRemaining128[oldId] == remainingBefore,
        "a place moves no already-issued request's remaining amount");
}

// EE-HL-03: Cancelling a request leaves every other request's status untouched.
rule hlEeCancelLeavesOtherRequests(env e, uint256 id, uint256 id2) {

    setupErc4626ExitBookValidState(e);
    require(id2 != id,
        "SCOPE: a bystander request, not the one being cancelled");
    Erc4626ExitBook.ExitStatus stBefore = ghostEeReqStatus[id2];

    cancelExitRequest(e, id);

    assert(ghostEeReqStatus[id2] == stBefore,
        "a cancel closes only its own request");
}

// EE-HL-04: The fee rate a fill charges stays inside the request's own band and under the 10 percent cap.
rule hlEeRampRateWithinBand(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);

    uint256 rate = priorityFeeRateExt(e, id);

    assert(ghostEeReqStartRate96[id] <= to_mathint(rate) && to_mathint(rate) <= ghostEeReqEndRate96[id],
        "the charged rate stays inside the request's [startRate, endRate] band");
    assert(to_mathint(rate) <= MAX_PRIORITY_FEE_EE_CVL(),
        "the charged rate never exceeds the priority-fee cap");
}

// EE-HL-05: A request's priority fee rate never falls as the request ages.
rule hlEeRampRateMonotoneInTime(env e1, env e2, uint256 id) {

    setupErc4626ExitBookValidState(e1);
    setupEnv(e2);
    require(e1.block.timestamp <= e2.block.timestamp,
        "SCOPE: e1 is the earlier of the two rate reads");

    uint256 rateEarly = priorityFeeRateExt(e1, id);
    uint256 rateLate = priorityFeeRateExt(e2, id);

    assert(to_mathint(rateEarly) <= to_mathint(rateLate),
        "the charged rate never falls as the request ages");
}

// EE-HL-06: A fill pays out everything it withdrew and leaves no assets stuck in the exit book.
rule hlEeFillKeepsNoRemainder(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    address asset = ghostEeReqAsset[id];
    require(ghostEeReqReceiver[id] != currentContract && rewardRecipient != currentContract,
        "SCOPE: neither payout leg lands back on the book");
    mathint bookBefore = ghostERC20Balances128[asset][currentContract];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    assert(ghostERC20Balances128[asset][currentContract] == bookBefore,
        "a fill splits the withdrawn assets with no remainder");
}

// EE-HL-07: A fill draws the assets it pays out from the vault the request named.
rule hlEeFillTakesAssetsOutOfItsVault(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    address asset = ghostEeReqAsset[id];
    address vault = ghostEeVaultOf[id];

    require(ghostEeReqReceiver[id] != vault && rewardRecipient != vault && ghostEeFeeRecipient != vault,
        "SCOPE: no payout leg lands back on the source vault");

    mathint sourceBefore = ghostERC20Balances128[asset][vault];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    assert(ghostERC20Balances128[asset][vault] < sourceBefore,
        "a fill takes a strictly positive amount out of the vault");
}

// EE-HL-08: A placement books the full amount asked for against exactly the vault the lender named.
rule hlEePlaceBindsItsNamedVault(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    assert(ghostEeVaultOf[id] == vault,
        "a placement binds the request to exactly the vault it named");
    assert(ghostEeReqAssetsTotal128[id] == to_mathint(assets)
            && ghostEeReqAssetsRemaining128[id] == to_mathint(assets),
        "a placement books the whole amount it was asked for, none of it pre-filled");
}

// --- unit_tests ---

// EE-UT-01: Before a request's fee ramp begins, its priority fee rate stays at the starting rate.
rule utEeRampRateHoldsAtStartRate(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);
    require(to_mathint(e.block.timestamp) - ghostEeReqCreatedAt40[id] < ghostEeReqRampStart32[id],
        "SCOPE: the read falls in the hold before the ramp starts");

    uint256 rate = priorityFeeRateExt(e, id);

    assert(to_mathint(rate) == ghostEeReqStartRate96[id],
        "the fee rate holds at startRate through the opening hold");
}

// EE-UT-02: Once the ramp begins, a request's priority fee rate rises in a straight line to its end rate.
rule utEeRampRateInterpolatesLinearly(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);
    mathint elapsed = to_mathint(e.block.timestamp) - ghostEeReqCreatedAt40[id];
    require(elapsed >= ghostEeReqRampStart32[id] && elapsed < ghostEeReqRampEnd32[id],
        "SCOPE: the read falls inside the ramp's climb");

    uint256 rate = priorityFeeRateExt(e, id);

    assert(to_mathint(rate) == ghostEeReqStartRate96[id]
            + (ghostEeReqEndRate96[id] - ghostEeReqStartRate96[id])
                * (elapsed - ghostEeReqRampStart32[id])
                / (ghostEeReqRampEnd32[id] - ghostEeReqRampStart32[id]),
        "the fee rate climbs linearly from startRate to endRate across the ramp");
}

// EE-UT-03: Once the ramp is over, a request's priority fee rate stays at its end rate.
rule utEeRampRatePlateausAtEndRate(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);
    require(to_mathint(e.block.timestamp) - ghostEeReqCreatedAt40[id] >= ghostEeReqRampEnd32[id],
        "SCOPE: the read falls on the plateau past the ramp's end");

    uint256 rate = priorityFeeRateExt(e, id);

    assert(to_mathint(rate) == ghostEeReqEndRate96[id],
        "the fee rate plateaus at endRate and never climbs past it");
}

// EE-UT-04: A fill pays the receiver the amount filled minus the current priority fee.
rule utEeFillPaysReceiverFillAssetsMinusPriorityFee(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    address asset = ghostEeReqAsset[id];
    address receiver = ghostEeReqReceiver[id];
    address recipient = ghostEeFeeRecipient;
    address vault = ghostEeVaultOf[id];

    require(receiver != rewardRecipient,
        "SCOPE: the receiver is not the filler's payee");
    require(receiver != recipient,
        "SCOPE: the receiver is not the fee recipient");
    require(receiver != vault && receiver != currentContract,
        "SCOPE: the receiver is neither the source vault nor the book");

    mathint receiverBefore = ghostERC20Balances128[asset][receiver];
    uint256 rate = priorityFeeRateExt(e, id);

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    assert(ghostERC20Balances128[asset][receiver] - receiverBefore
            == to_mathint(fillAssets) - to_mathint(fillAssets) * to_mathint(rate) / WAD_EE_CVL(),
        "a fill pays the receiver the filled amount less the ramp's fee");
}

// EE-UT-05: A fill pays the filler the priority fee less the service cut, and the fee recipient exactly that cut.
rule utEeFillSplitsFillerRewardAndServiceCut(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    address asset = ghostEeReqAsset[id];
    address receiver = ghostEeReqReceiver[id];
    address recipient = ghostEeFeeRecipient;
    address vault = ghostEeVaultOf[id];

    require(receiver != rewardRecipient && receiver != recipient && rewardRecipient != recipient,
        "SCOPE: receiver, filler payee and fee recipient are distinct");
    require(rewardRecipient != vault && recipient != vault,
        "SCOPE: neither reward leg lands on the source vault");
    require(rewardRecipient != currentContract,
        "SCOPE: the filler's payee is not the book itself");

    mathint svcFee = ghostEeServiceFee256;
    mathint fillerBefore = ghostERC20Balances128[asset][rewardRecipient];
    mathint recipientBefore = ghostERC20Balances128[asset][recipient];
    uint256 rate = priorityFeeRateExt(e, id);

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    mathint priorityFee = to_mathint(fillAssets) * to_mathint(rate) / WAD_EE_CVL();
    mathint serviceCut = priorityFee * svcFee / WAD_EE_CVL();

    assert(ghostERC20Balances128[asset][rewardRecipient] - fillerBefore == priorityFee - serviceCut,
        "a fill pays the filler's payee the priority fee net of the service cut");
    assert(ghostERC20Balances128[asset][recipient] - recipientBefore == serviceCut,
        "a fill pays the fee recipient exactly the service cut of the priority fee");
}

// EE-UT-06: Reading an owner's request ids returns the window asked for, starting at the offset given.
rule utEeOwnerRequestIdsReadsTheRequestedWindow(env e, address o, uint256 offset, uint256 count,
    uint256 j) {

    setupErc4626ExitBookValidState(e);
    require(count >= 1 && count <= 3,
        "SCOPE: a page of at most three ids, the conf's loop_iter");
    mathint len = ghostEeOwnerReqIdsLen[o];
    require(to_mathint(offset) < len,
        "SCOPE: an offset inside the owner's listing");

    uint256[] page = getOwnerRequestIds(e, o, offset, count);

    mathint room = len - to_mathint(offset);
    assert(to_mathint(page.length) == (to_mathint(count) < room ? to_mathint(count) : room),
        "a page holds the smaller of the count asked for and the ids left past the offset");
    assert(to_mathint(page[0]) == ghostEeOwnerReqIds[o][offset],
        "a page starts at the entry the offset names");

    require(to_mathint(j) < to_mathint(page.length),
        "SCOPE: a position inside the page just returned");

    assert(to_mathint(page[j]) == ghostEeOwnerReqIds[o][require_uint256(to_mathint(offset) + to_mathint(j))],
        "every entry of a page reads the listing at its own position in the window, in order");
}

// --- reachability ---

// EE-RC-01: A lender can open a new exit request that belongs to them and awaits filling.
rule rcEePlaceExitRequestIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeReqOwner[id] == e.msg.sender && ghostEeReqAssetsRemaining128[id] > 0,
        "a lender can open a fresh caller-owned exit request with assets to fill");
}

// EE-RC-02: A lender can require their request be filled in one go, all or nothing.
rule rcEePlaceMinFillAtFullSizeIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeReqMinFillAssets128[id] == ghostEeReqAssetsTotal128[id]
        && ghostEeReqAssetsRemaining128[id] > 0,
        "an all-or-nothing exit request can be placed");
}

// EE-RC-03: A lender can place an exit request backed by the protocol's own lending vault.
rule rcEePlaceOnLinkedVaultIsReachable(env e, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, _Vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeVaultOf[id] == _Vault && ghostEeReqAssetsRemaining128[id] > 0,
        "a request can be placed against the in-scene vault address");
}

// EE-RC-04: A lender can place an exit request backed by another allow-listed vault.
rule rcEePlaceOnUnlinkedVaultIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);
    require(vault != _Vault,
        "SCOPE: a vault address other than the in-scene one");

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeVaultOf[id] == vault && ghostEeReqAssetsRemaining128[id] > 0,
        "a request can be placed against a vault address other than the in-scene one");
}

// EE-RC-05: A lender can place an exit request for a single unit of the asset.
rule rcEePlaceOneAssetIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeReqAssetsTotal128[id] == 1, "a one-unit exit request can be placed");
}

// EE-RC-06: A lender can place a request for the largest amount a request record can hold.
rule rcEePlaceMaxAssetsIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeReqAssetsTotal128[id] == max_uint128,
        "a request at the uint128 packed-field boundary can be placed");
}

// EE-RC-07: A lender can place a request that offers fillers no priority fee at all.
rule rcEePlaceZeroRampIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeReqStartRate96[id] == 0 && ghostEeReqEndRate96[id] == 0
        && ghostEeReqAssetsRemaining128[id] > 0,
        "a request with no priority-fee ramp can be placed");
}

// EE-RC-08: A lender can set a request's deadline exactly at the maximum allowed lifetime.
rule rcEePlaceDeadlineAtLifetimeCapIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeReqDeadline40[id] == ghostEeReqCreatedAt40[id] + ghostEeMaxLifetime256
        && ghostEeReqAssetsRemaining128[id] > 0,
        "a request whose deadline sits exactly at the lifetime cap can be placed");
}

// EE-RC-09: A filler can partly fill an open request and leave the rest outstanding.
rule rcEeFillExitRequestIsReachable(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    mathint before = ghostEeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(ghostEeReqAssetsRemaining128[id] < before && ghostEeReqAssetsRemaining128[id] > 0,
        "a filler can partially fill an open request, leaving it open");
}

// EE-RC-10: An all-or-nothing request can be closed by one fill covering its whole size.
rule rcEeFillMinFillAtFullSizeIsReachable(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    mathint before = ghostEeReqAssetsRemaining128[id];
    mathint minFillBefore = ghostEeReqMinFillAssets128[id];
    mathint totalBefore = ghostEeReqAssetsTotal128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(minFillBefore == totalBefore && before > 0 && ghostEeReqAssetsRemaining128[id] == 0
        && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Filled,
        "an all-or-nothing request can be closed by a single full fill");
}

// EE-RC-11: A fill can take a single unit and leave the request open.
rule rcEeFillOneAssetStepIsReachable(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    require(ghostEeReqAssetsRemaining128[id] > 1,
        "SCOPE: more than one unit is still outstanding");
    mathint before = ghostEeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(ghostEeReqAssetsRemaining128[id] == before - 1
        && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Open,
        "a fill can consume exactly one unit and leave the request open");
}

// EE-RC-12: Someone other than the owner can fill a request and pay its named receiver.
rule rcEeFillPaysRequestReceiverIsReachable(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    mathint before = ghostEeReqAssetsRemaining128[id];
    address owner_ = ghostEeReqOwner[id];
    address receiver_ = ghostEeReqReceiver[id];
    address asset_ = ghostEeReqAsset[id];
    address recip = ghostEeFeeRecipient;
    address vault_ = ghostEeVaultOf[id];
    mathint receiverBalBefore = ghostERC20Balances128[asset_][receiver_];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(ghostEeReqAssetsRemaining128[id] < before
        && owner_ != e.msg.sender && receiver_ != e.msg.sender
        && receiver_ != rewardRecipient && receiver_ != recip && receiver_ != vault_
        && ghostERC20Balances128[asset_][receiver_] > receiverBalBefore,
        "a fill by a third party, who is neither the request owner nor its receiver, pays the receiver in the request asset");
}

// EE-RC-13: A fill under a positive service fee credits the fee recipient.
rule rcEeFillPaysServiceFeeIsReachable(env e, uint256 id, uint256 fillAssets,
    address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    mathint before = ghostEeReqAssetsRemaining128[id];
    mathint feeBefore = ghostEeServiceFee256;
    address recip = ghostEeFeeRecipient;
    address receiver_ = ghostEeReqReceiver[id];
    address asset_ = ghostEeReqAsset[id];
    address vault_ = ghostEeVaultOf[id];
    mathint recipBalBefore = ghostERC20Balances128[asset_][recip];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(feeBefore > 0 && ghostEeReqAssetsRemaining128[id] < before
        && recip != receiver_ && recip != rewardRecipient && recip != vault_
        && ghostERC20Balances128[asset_][recip] > recipBalBefore,
        "a fill under a positive service fee pays the fee recipient");
}

// EE-RC-14: An owner can cancel an open request, leaving nothing outstanding on it.
rule rcEeCancelExitRequestIsReachable(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);
    mathint before = ghostEeReqAssetsRemaining128[id];

    cancelExitRequest(e, id);

    satisfy(before > 0 && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Cancelled
        && ghostEeReqAssetsRemaining128[id] == 0,
        "an owner can cancel an open request, zeroing its remaining amount");
}

// EE-RC-15: An owner can still cancel a request a filler has already partly consumed.
rule rcEeCancelPartiallyFilledIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline,
    uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);
    mathint totalAfterPlace = ghostEeReqAssetsTotal128[id];
    fillExitRequest(e, id, fillAssets, rewardRecipient);
    mathint leftAfterFill = ghostEeReqAssetsRemaining128[id];
    cancelExitRequest(e, id);

    satisfy(leftAfterFill > 0 && leftAfterFill < totalAfterPlace
        && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Cancelled
        && ghostEeReqAssetsRemaining128[id] == 0,
        "a request a fill has partly consumed can still be cancelled, and the cancel clears what was left");
}

// EE-RC-16: The fee manager can set the service fee to its 25 percent cap, naming a live recipient.
rule rcEeSetServiceFeeAtCapIsReachable(env e, address recipient, uint256 fee) {

    setupErc4626ExitBookValidState(e);

    setServiceFee(e, recipient, fee);

    satisfy(to_mathint(fee) == MAX_SERVICE_FEE_EE_CVL() && ghostEeServiceFee256 == to_mathint(fee)
        && ghostEeFeeRecipient == recipient && recipient != 0,
        "the fee manager can set the service fee at its cap with a live recipient");
}

// EE-RC-17: The fee manager can switch a positive service fee back off.
rule rcEeSetServiceFeeDisableIsReachable(env e, address recipient) {

    setupErc4626ExitBookValidState(e);
    mathint feeBefore = ghostEeServiceFee256;

    setServiceFee(e, recipient, 0);

    satisfy(feeBefore > 0 && ghostEeServiceFee256 == 0,
        "the fee manager can disable a previously positive service fee");
}

// EE-RC-18: The allow-list manager can add a vault that was not allowed before.
rule rcEeSetVaultAllowedIsReachable(env e, address vault) {

    setupErc4626ExitBookValidState(e);
    bool allowedBefore = ghostEeIsVaultAllowed[vault];

    setVaultAllowed(e, vault, true);

    satisfy(!allowedBefore && ghostEeIsVaultAllowed[vault],
        "the allow-list manager can allow-list a previously de-listed vault");
}

// EE-RC-19: The allow-list manager can take a vault off the allowed list.
rule rcEeSetVaultDelistIsReachable(env e, address vault) {

    setupErc4626ExitBookValidState(e);
    bool allowedBefore = ghostEeIsVaultAllowed[vault];

    setVaultAllowed(e, vault, false);

    satisfy(allowedBefore && !ghostEeIsVaultAllowed[vault],
        "the allow-list manager can de-list a previously allowed vault");
}

// EE-RC-20: A lender can place an exit request and immediately cancel it, leaving nothing to fill.
rule rcEePlaceThenCancelIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);
    cancelExitRequest(e, id);

    satisfy(ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Cancelled
        && ghostEeReqAssetsRemaining128[id] == 0,
        "a lender can place a request and immediately cancel it");
}

// EE-RC-21: A request can be filled immediately after a lender places it.
rule rcEePlaceThenFillIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline,
    uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);
    mathint totalAfterPlace = ghostEeReqAssetsTotal128[id];
    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(ghostEeReqAssetsRemaining128[id] < totalAfterPlace,
        "a freshly placed request can immediately be filled");
}

// EE-RC-22: A vault allowed a moment ago can immediately back a new exit request.
rule rcEeAllowThenPlaceIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);
    bool allowedBefore = ghostEeIsVaultAllowed[vault];

    setVaultAllowed(e, vault, true);
    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(!allowedBefore && ghostEeVaultOf[id] == vault && ghostEeReqAssetsRemaining128[id] > 0,
        "a newly allow-listed vault can immediately back a fresh request");
}

// EE-RC-23: The recoverer can move stray tokens out of the book to a recipient.
rule rcEeRecoverErc20IsReachable(env e, address token, address recipient, uint256 amount) {

    setupErc4626ExitBookValidState(e);
    mathint balBefore = ghostERC20Balances128[token][recipient];

    recoverERC20(e, token, recipient, amount);

    satisfy(amount > 0 && ghostERC20Balances128[token][recipient] == balBefore + amount,
        "the recoverer can recover stray erc20 tokens to a recipient");
}

// EE-RC-24: The recoverer can sweep the book's whole ether balance to a recipient.
rule rcEeRecoverEtherIsReachable(env e, address recipient) {

    setupErc4626ExitBookValidState(e);
    mathint bookBalBefore = nativeBalances[_Erc4626ExitBook];

    recoverEther(e, recipient);

    satisfy(bookBalBefore > 0 && nativeBalances[_Erc4626ExitBook] == 0,
        "the recoverer can sweep the book's full ether balance");
}

// EE-RC-25: A lender can still cancel an open request while the book is paused.
rule rcEeCancelWhilePausedIsReachable(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);
    bool pausedBefore = paused(e);
    Erc4626ExitBook.ExitStatus statusBefore = ghostEeReqStatus[id];

    cancelExitRequest(e, id);

    satisfy(pausedBefore && statusBefore == Erc4626ExitBook.ExitStatus.Open
        && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Cancelled
        && ghostEeReqAssetsRemaining128[id] == 0,
        "an owner can cancel an open request while the book is stopped");
}

// EE-RC-26: A lender's placement can raise the last issued request id by one.
rule rcEeLastRequestIdPositiveIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 lastBefore = lastRequestId(e);

    placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    uint256 last = lastRequestId(e);

    satisfy(to_mathint(last) > 0 && to_mathint(last) == to_mathint(lastBefore) + 1,
        "the request counter reads one higher after a placement");
}

// EE-RC-27: A lender can read a freshly placed request back as the last entry of their own list.
rule rcEeOwnerRequestIndexViewsIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    uint256 count = getOwnerRequestCount(e, e.msg.sender);
    require(to_mathint(count) >= 1,
        "SCOPE: the caller's listing is not empty");
    uint256[] page = getOwnerRequestIds(e, e.msg.sender, require_uint256(to_mathint(count) - 1), 1);

    satisfy(to_mathint(count) > 0 && page.length == 1 && to_mathint(page[0]) == to_mathint(id),
        "the request a lender just placed reads back as the last entry of their own index");
}

// EE-RC-28: A lender can place a request whose priority fee rate climbs over time.
rule rcEePlaceRampedRatesIsReachable(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    uint256 id = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    satisfy(ghostEeReqStartRate96[id] < ghostEeReqEndRate96[id]
        && ghostEeReqRampStart32[id] < ghostEeReqRampEnd32[id]
        && ghostEeReqAssetsRemaining128[id] > 0,
        "a strictly ramped priority-fee request can be placed, so the climb EE-UT-02 describes has instances");
}

// EE-RC-29: A single fill can take the whole remainder and close the request as filled.
rule rcEeFillFullCloseIsReachable(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    require(ghostEeReqAssetsRemaining128[id] == 1,
        "SCOPE: a one-unit request");
    mathint remainingBefore = ghostEeReqAssetsRemaining128[id];

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    satisfy(remainingBefore > 0 && ghostEeReqAssetsRemaining128[id] == 0
        && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Filled,
        "a fill can close a live request to filled at zero remaining");
}

// EE-RC-30: The fee manager can clear the fee recipient and leave the fee at zero.
rule rcEeSetServiceFeeClearsRecipientIsReachable(env e, address recipient, uint256 fee) {

    setupErc4626ExitBookValidState(e);
    address recipientBefore = ghostEeFeeRecipient;

    setServiceFee(e, recipient, fee);

    satisfy(recipientBefore != 0 && ghostEeFeeRecipient == 0 && ghostEeServiceFee256 == 0,
        "the fee manager can retire the fee recipient and leave the fee at zero");
}

// EE-RC-31: A paused book can be started again, and its record reads answer while paused.
rule rcEePauseResumeIsReachable(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);
    bool pausedBefore = paused(e);
    uint256 lastBefore = lastRequestId(e);

    pause(e);

    bool pausedWhileStopped = paused(e);
    getExitRequest(e, id);
    uint256 lastWhileStopped = lastRequestId(e);

    resume(e);

    bool pausedAfterResume = paused(e);

    satisfy(!pausedBefore && pausedWhileStopped && !pausedAfterResume
        && to_mathint(lastWhileStopped) == to_mathint(lastBefore),
        "the pauser can stop the book and the resumer can start it again, and the reads answer throughout");
}

// --- reverts ---

// EE-RV-01: Setting a vault's allow-list flag fails exactly when the caller lacks the role or the vault is zero.
rule rvEeSetVaultAllowedRevertsIff(env e, address vault, bool allowed) {

    setupErc4626ExitBookValidState(e);
    bool notManager = !ghostEeHasRole[_Erc4626ExitBook.ALLOWLIST_MANAGER_ROLE()][e.msg.sender];
    bool zeroVault = vault == 0;

    setVaultAllowed@withrevert(e, vault, allowed);
    bool reverted = lastReverted;

    assert(reverted <=> (notManager || zeroVault),
        "setVaultAllowed reverts exactly for an unauthorized caller or the zero vault");
}

// EE-RV-02: Setting the service fee fails exactly for an unauthorized caller, a fee above its cap, or a nonzero fee with no recipient.
rule rvEeSetServiceFeeRevertsIff(env e, address recipient, uint256 fee) {

    setupErc4626ExitBookValidState(e);
    bool notManager = !ghostEeHasRole[_Erc4626ExitBook.FEE_MANAGER_ROLE()][e.msg.sender];
    bool feeAboveCap = to_mathint(fee) > MAX_SERVICE_FEE_EE_CVL();
    bool missingRecipient = recipient == 0 && fee != 0;

    setServiceFee@withrevert(e, recipient, fee);
    bool reverted = lastReverted;

    assert(reverted <=> (notManager || feeAboveCap || missingRecipient),
        "reverts iff unauthorized, over the cap, or a nonzero fee without recipient");
}

// EE-RV-03: Placing an exit request fails exactly when a pause, allow-list, backing, deadline or size check rejects it.
rule rvEePlaceExitRequestRevertsIff(env e, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);
    mathint ts = to_mathint(e.block.timestamp);
    mathint maxLifetime = ghostEeMaxLifetime256;
    // The place-time share quote: previewWithdraw resolves to the vault model's per-callee frozen draw.
    mathint requiredShares = to_mathint(ghostErc4626PreviewWithdraw[vault][assets]);
    bool bookPaused = ghostEePaused;
    bool vaultNotAllowed = !ghostEeIsVaultAllowed[vault];
    bool zeroAssets = assets == 0;
    bool insufficientAllowance =
        ghostERC20Allowances256[vault][e.msg.sender][currentContract] < requiredShares;
    bool insufficientShares = ghostERC20Balances128[vault][e.msg.sender] < requiredShares;
    bool zeroReceiver = receiver == 0;
    bool burnCapBelowQuote = maxShareBurn != 0 && to_mathint(maxShareBurn) < requiredShares;
    bool endRateAboveCap = to_mathint(ramp.endRate) > MAX_PRIORITY_FEE_EE_CVL();
    bool startAboveEnd = ramp.startRate > ramp.endRate;
    bool rampInverted = ramp.rampStart > ramp.rampEnd;
    bool deadlineInPast = to_mathint(deadline) <= ts;
    bool lifetimeAddOverflows = ts + maxLifetime > max_uint256;
    bool deadlineTooFar = to_mathint(deadline) > ts + maxLifetime;
    bool rampPastDeadline = ts + to_mathint(ramp.rampEnd) > to_mathint(deadline);
    bool assetsAboveWidth = to_mathint(assets) > max_uint128;
    bool burnCapAboveWidth = to_mathint(maxShareBurn) > max_uint128;
    bool rampStartAboveWidth = to_mathint(ramp.rampStart) > max_uint32;
    bool rampEndAboveWidth = to_mathint(ramp.rampEnd) > max_uint32;
    bool deadlineAboveWidth = to_mathint(deadline) > max_uint40;
    bool idCounterSaturated = ghostEeNextId256 == max_uint256;

    placeExitRequest@withrevert(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);
    bool reverted = lastReverted;

    // The width causes are the record's SafeCast downcasts and the checked lifetime add.
    assert(reverted <=> (
            bookPaused || vaultNotAllowed || zeroAssets || zeroReceiver
            || insufficientAllowance || insufficientShares || burnCapBelowQuote
            || endRateAboveCap || startAboveEnd || rampInverted
            || deadlineInPast || lifetimeAddOverflows || deadlineTooFar || rampPastDeadline
            || assetsAboveWidth || burnCapAboveWidth || rampStartAboveWidth
            || rampEndAboveWidth || deadlineAboveWidth || idCounterSaturated),
        "a placement reverts exactly when a guard or a record width cap trips");
}

// EE-RV-04: Filling an exit request after its deadline has passed always fails.
rule rvEeFillRevertsWhenExpired(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    // The open conjunct pins the revert to the deadline guard.
    bool expired = ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Open
        && to_mathint(e.block.timestamp) > ghostEeReqDeadline40[id];

    fillExitRequest@withrevert(e, id, fillAssets, rewardRecipient);
    bool reverted = lastReverted;

    assert(expired => reverted,
        "a fill on an open request past its deadline reverts");
}

// EE-RV-05: A fill fails when the book is paused, the reward recipient is empty, or its size sits outside the request's window.
rule rvEeFillRevertsOnAmountGuards(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupErc4626ExitBookValidState(e);
    bool bookPaused = ghostEePaused;
    bool zeroRewardRecipient = rewardRecipient == 0;
    bool zeroFill = fillAssets == 0;
    bool aboveRemaining = to_mathint(fillAssets) > ghostEeReqAssetsRemaining128[id];
    bool belowMinimum = to_mathint(fillAssets) < ghostEeReqMinFillAssets128[id]
        && to_mathint(fillAssets) < ghostEeReqAssetsRemaining128[id];

    fillExitRequest@withrevert(e, id, fillAssets, rewardRecipient);
    bool reverted = lastReverted;

    assert((bookPaused || zeroRewardRecipient || zeroFill || aboveRemaining || belowMinimum)
            => reverted,
        "a fill reverts when the book is paused, its payee is empty, or its amount falls outside the request's window");
}

// EE-RV-06: Cancelling an exit request fails exactly when the caller is not its owner or it is not open.
rule rvEeCancelExitRequestRevertsIff(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);
    bool notReqOwner = ghostEeReqOwner[id] != e.msg.sender;
    bool notOpen = ghostEeReqStatus[id] != Erc4626ExitBook.ExitStatus.Open;

    cancelExitRequest@withrevert(e, id);
    bool reverted = lastReverted;

    assert(reverted <=> (notReqOwner || notOpen),
        "a cancel reverts exactly for a non-owner caller or a request that is not open");
}

// EE-RV-07: Sweeping the book's ether fails when the caller is not the recoverer or the recipient is zero.
rule rvEeRecoverEtherRevertsOnGuards(env e, address recipient) {

    setupErc4626ExitBookValidState(e);
    bool notRecoverer = !ghostEeHasRole[_Erc4626ExitBook.RECOVERER_ROLE()][e.msg.sender];
    bool zeroRecipient = recipient == 0;

    recoverEther@withrevert(e, recipient);
    bool reverted = lastReverted;

    assert((notRecoverer || zeroRecipient) => reverted,
        "ether recovery reverts for an unauthorized caller or a zero recipient");
}

// EE-RV-08: Recovering a stray ERC-20 balance fails exactly when the caller is not the recoverer or the recipient is zero.
rule rvEeRecoverErc20RevertsIff(env e, address token, address recipient, uint256 amount) {

    setupErc4626ExitBookValidState(e);
    bool notRecoverer = !ghostEeHasRole[_Erc4626ExitBook.RECOVERER_ROLE()][e.msg.sender];
    bool zeroRecipient = recipient == 0;

    recoverERC20@withrevert(e, token, recipient, amount);
    bool reverted = lastReverted;

    assert(reverted <=> (notRecoverer || zeroRecipient),
        "erc20 recovery reverts exactly for an unauthorized caller or a zero recipient");
}

// EE-RV-09: Recovering a stray NFT fails exactly when the caller is not the recoverer or the recipient is zero.
rule rvEeRecoverErc721RevertsIff(env e, address token, address recipient, uint256 tokenId) {

    setupErc4626ExitBookValidState(e);
    bool notRecoverer = !ghostEeHasRole[_Erc4626ExitBook.RECOVERER_ROLE()][e.msg.sender];
    bool zeroRecipient = recipient == 0;

    recoverERC721@withrevert(e, token, recipient, tokenId);
    bool reverted = lastReverted;

    assert(reverted <=> (notRecoverer || zeroRecipient),
        "erc721 recovery reverts exactly for an unauthorized caller or a zero recipient");
}

// EE-RV-10: Recovering a stray ERC-1155 balance fails exactly when the caller is not the recoverer or the recipient is zero.
rule rvEeRecoverErc1155RevertsIff(env e, address token, address recipient, uint256 tokenId) {

    setupErc4626ExitBookValidState(e);
    bool notRecoverer = !ghostEeHasRole[_Erc4626ExitBook.RECOVERER_ROLE()][e.msg.sender];
    bool zeroRecipient = recipient == 0;

    recoverERC1155@withrevert(e, token, recipient, tokenId);
    bool reverted = lastReverted;

    assert(reverted <=> (notRecoverer || zeroRecipient),
        "erc1155 recovery reverts exactly for an unauthorized caller or a zero recipient");
}

// EE-RV-11: Reading the fee recipient always answers, and reports the address the fee manager last set.
rule rvEeFeeRecipientNeverReverts(env e, address recipient, uint256 fee) {

    setupErc4626ExitBookValidState(e);

    feeRecipient@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "reading the fee recipient never reverts");

    setServiceFee(e, recipient, fee);

    address stored = feeRecipient@withrevert(e);
    bool rereadReverted = lastReverted;

    assert(!rereadReverted && stored == recipient,
        "the view reports the recipient the fee manager just set");
}

// EE-RV-12: Reading the service fee always answers, and reports the rate the fee manager last set.
rule rvEeServiceFeeNeverReverts(env e, address recipient, uint256 fee) {

    setupErc4626ExitBookValidState(e);

    serviceFee@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "reading the service fee never reverts");

    setServiceFee(e, recipient, fee);

    uint256 stored = serviceFee@withrevert(e);
    bool rereadReverted = lastReverted;

    assert(!rereadReverted && to_mathint(stored) == to_mathint(fee),
        "the view reports the fee the fee manager just set");
}

// EE-RV-13: Reading a vault's allow flag always answers, and reports what the allow-list manager last set.
rule rvEeIsVaultAllowedNeverReverts(env e, address vault, bool allowed) {

    setupErc4626ExitBookValidState(e);

    isVaultAllowed@withrevert(e, vault);
    bool reverted = lastReverted;

    assert(!reverted, "reading a vault's allow flag never reverts");

    setVaultAllowed(e, vault, allowed);

    bool flag = isVaultAllowed@withrevert(e, vault);
    bool rereadReverted = lastReverted;

    assert(!rereadReverted && flag == allowed,
        "the view reports the flag the allow-list manager just set");
}

// EE-RV-14: Reading a request's vault always answers, and reports the vault the placement named.
rule rvEeVaultOfNeverReverts(env e, uint256 id, address vault, uint256 assets, address receiver,
    uint256 minFillAssets, uint256 maxShareBurn, Erc4626ExitBook.PriorityRamp ramp, uint256 deadline) {

    setupErc4626ExitBookValidState(e);

    vaultOf@withrevert(e, id);
    bool reverted = lastReverted;

    assert(!reverted, "reading a request's bound vault never reverts");

    uint256 fresh = placeExitRequest(e, vault, assets, receiver, minFillAssets, maxShareBurn, ramp, deadline);

    address bound = vaultOf@withrevert(e, fresh);
    bool rereadReverted = lastReverted;

    assert(!rereadReverted && bound == vault,
        "the view reports the vault the placement bound");
}

// EE-RV-15: Reading a single request record by id never fails.
rule rvEeGetExitRequestNeverReverts(env e, uint256 id) {

    setupErc4626ExitBookValidState(e);

    getExitRequest@withrevert(e, id);
    bool reverted = lastReverted;

    assert(!reverted, "reading a request record never reverts");
}

// EE-RV-16: Reading a batch of request records never fails.
rule rvEeGetRequestsNeverReverts(env e, uint256[] ids) {

    setupErc4626ExitBookValidState(e);
    require(ids.length <= 3, "SCOPE: a batch of at most three ids, the conf's loop_iter");

    getRequests@withrevert(e, ids);
    bool reverted = lastReverted;

    assert(!reverted, "a bounded batch read of requests never reverts");
}

// EE-RV-17: Reading a page of one lender's request ids never fails.
rule rvEeGetOwnerRequestIdsNeverReverts(env e, address account, uint256 offset, uint256 count) {

    setupErc4626ExitBookValidState(e);
    require(count <= 3, "SCOPE: a page of at most three ids, the conf's loop_iter");

    getOwnerRequestIds@withrevert(e, account, offset, count);
    bool reverted = lastReverted;

    assert(!reverted, "a bounded page of an owner's request ids never reverts");
}

// --- access_control ---

// The three token-recovery gates are covered in the revert direction, by EE-RV-08, EE-RV-09 and EE-RV-10.

// EE-AC-01: An exit request is cancelled only by the lender who owns it.
rule acEeOnlyRequestOwnerCancels(env e, method f, calldataarg args, uint256 id)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    address ownerBefore = ghostEeReqOwner[id];
    Erc4626ExitBook.ExitStatus statusBefore = ghostEeReqStatus[id];

    f(e, args);

    assert((statusBefore != Erc4626ExitBook.ExitStatus.Cancelled
            && ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.Cancelled)
        => e.msg.sender == ownerBefore,
        "a request is cancelled only by its owner");
}

// EE-AC-02: An owner's list of request ids changes only when that owner is the caller.
rule acEeOwnerIndexMovesOnlyBySelf(env e, method f, calldataarg args, address o)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    mathint lenBefore = ghostEeOwnerReqIdsLen[o];

    f(e, args);

    assert(ghostEeOwnerReqIdsLen[o] != lenBefore => o == e.msg.sender,
        "an owner's request-id index moves only on that owner's own call");
}

// EE-AC-03: Only the fee manager can change the service fee or its recipient.
rule acEeOnlyFeeManagerSetsFeeConfig(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    bool senderIsFeeManager = ghostEeHasRole[_Erc4626ExitBook.FEE_MANAGER_ROLE()][e.msg.sender];
    mathint feeBefore = ghostEeServiceFee256;
    address recipientBefore = ghostEeFeeRecipient;

    f(e, args);

    assert((ghostEeServiceFee256 != feeBefore || ghostEeFeeRecipient != recipientBefore)
        => senderIsFeeManager,
        "only the fee manager changes the service-fee configuration");
}

// EE-AC-04: Only the allow-list manager can change which vaults may back exit requests.
rule acEeOnlyAllowlistManagerSetsVaultAllowlist(env e, method f, calldataarg args, address v)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    bool senderIsAllowlistManager =
        ghostEeHasRole[_Erc4626ExitBook.ALLOWLIST_MANAGER_ROLE()][e.msg.sender];
    bool allowedBefore = ghostEeIsVaultAllowed[v];

    f(e, args);

    assert(ghostEeIsVaultAllowed[v] != allowedBefore => senderIsAllowlistManager,
        "only the allow-list manager toggles the vault allow-list");
}

// EE-AC-05: Only a role's admin can grant or revoke it, apart from a holder giving up their own.
rule acEeOnlyRoleAdminMovesRoles(env e, method f, calldataarg args, bytes32 role, address account)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    bool heldBefore = ghostEeHasRole[role][account];
    bool senderIsAdmin = ghostEeHasRole[ghostEeRoleAdmin[role]][e.msg.sender];

    f(e, args);

    assert(ghostEeHasRole[role][account] != heldBefore
        => (senderIsAdmin || (account == e.msg.sender && heldBefore)),
        "a role is granted only by its admin, and given up only by its admin or its own holder");
}

// EE-AC-06: The book's ether balance falls only when the recoverer sweeps it.
rule acEeOnlyRecovererSweepsEther(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_EE(f) } {

    setupErc4626ExitBook(e);
    bool senderIsRecoverer = ghostEeHasRole[_Erc4626ExitBook.RECOVERER_ROLE()][e.msg.sender];
    mathint etherBefore = nativeBalances[_Erc4626ExitBook];

    f(e, args);

    assert(nativeBalances[_Erc4626ExitBook] < etherBefore => senderIsRecoverer,
        "the book's ether balance decreases only for the recoverer");
}
