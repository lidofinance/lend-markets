// Each rule walks a concrete scenario: one named external call, or a sequence of them, then asserts the end-to-end
// law (conservation, isolation, monotonicity, a round trip).

import "LidoLendMarketController_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_core_view.spec";
import "../setup/GuardianSignals/GuardianSignals_cvl.spec";
import "../setup/erc20.spec";

// Scene-only encoder: turns a typed hook payload into the bytes on() decodes.
using LidoLendMarketControllerHookEncoder as _HookEncoder;

// MC-HL-01: Market traffic never changes the activation wait floor.
rule hlMcOnLeavesMinDelay(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    mathint minBefore = ghostMcCfgMinActivationDelay40;

    on(e, id, ev, data);

    assert(ghostMcCfgMinActivationDelay40 == minBefore,
        "on() keeps the min activation delay");
}

// MC-HL-02: Market traffic never changes the activation wait ceiling.
rule hlMcOnLeavesMaxDelay(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    mathint maxBefore = ghostMcCfgMaxActivationDelay40;

    on(e, id, ev, data);

    assert(ghostMcCfgMaxActivationDelay40 == maxBefore,
        "on() keeps the max activation delay");
}

// MC-HL-03: Market traffic never changes the market's supply cap.
rule hlMcOnLeavesSupplyCap(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    mathint capBefore = ghostMcSupplyCap256;

    on(e, id, ev, data);

    assert(ghostMcSupplyCap256 == capBefore,
        "on() keeps the supply cap");
}

// MC-HL-04: Market traffic never changes a borrower's settle-down LTV target.
rule hlMcOnLeavesSettlementLtv(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, address b) {

    setupLidoLendMarketControllerValidState(e);
    mathint ltvBefore = ghostMcSettlementLtv256[b];

    on(e, id, ev, data);

    assert(ghostMcSettlementLtv256[b] == ltvBefore,
        "on() keeps every settlement ltv");
}

// MC-HL-05: Market traffic never grants or revokes a caller's instant activation.
rule hlMcOnLeavesInstantActivationList(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data, address c) {

    setupLidoLendMarketControllerValidState(e);
    bool memberBefore = ghostMcInstantActivationCallers[c];

    on(e, id, ev, data);

    assert(ghostMcInstantActivationCallers[c] == memberBefore,
        "on() keeps the instant activation list");
}

// MC-HL-06: A larger deposit is never quoted a shorter activation wait, and every quote stays between the configured floor and ceiling.
rule hlMcActivationDelayMonotoneBanded(env e, uint256 x, uint256 y) {

    setupLidoLendMarketControllerValidState(e);
    require(x <= y, "SCOPE: x names the smaller increment");

    mathint delayX = currentActivationDelay(e, x);
    mathint delayY = currentActivationDelay(e, y);

    assert(ghostMcCfgMinActivationDelay40 <= delayX && delayX <= delayY
        && delayY <= ghostMcCfgMaxActivationDelay40,
        "a larger deposit never matures faster and the delay stays in [min, max]");
}

// MC-HL-07: A collateral deposit changes the activation buckets and timer of at most one borrower.
rule hlMcSupplyCollateralTouchesOneBorrower(env e, LidoLendMarketController.Id id,
    bytes data, address b1, address b2) {

    setupLidoLendMarketControllerValidState(e);
    require(b1 != b2, "SCOPE: two distinct borrowers");
    mathint dust1 = ghostMcPosDust128[b1];
    mathint act1 = ghostMcPosActivating128[b1];
    mathint start1 = ghostMcPosActivatingStart40[b1];
    mathint delay1 = ghostMcPosActivatingDelay32[b1];
    mathint dust2 = ghostMcPosDust128[b2];
    mathint act2 = ghostMcPosActivating128[b2];
    mathint start2 = ghostMcPosActivatingStart40[b2];
    mathint delay2 = ghostMcPosActivatingDelay32[b2];

    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    assert((ghostMcPosDust128[b1] == dust1 && ghostMcPosActivating128[b1] == act1
            && ghostMcPosActivatingStart40[b1] == start1 && ghostMcPosActivatingDelay32[b1] == delay1)
        || (ghostMcPosDust128[b2] == dust2 && ghostMcPosActivating128[b2] == act2
            && ghostMcPosActivatingStart40[b2] == start2 && ghostMcPosActivatingDelay32[b2] == delay2),
        "a supply-collateral hook touches at most one borrower's buckets");
}

// MC-HL-08: Changing the activation policy never touches any borrower's pending collateral or its timer.
rule hlMcSetActivationConfigLeavesPositions(env e,
    LidoLendMarketController.CollateralActivationConfig cfg, address b) {

    setupLidoLendMarketControllerValidState(e);
    mathint dustBefore = ghostMcPosDust128[b];
    mathint actBefore = ghostMcPosActivating128[b];
    mathint startBefore = ghostMcPosActivatingStart40[b];
    mathint delayBefore = ghostMcPosActivatingDelay32[b];

    setCollateralActivationConfig(e, cfg);

    assert(ghostMcPosDust128[b] == dustBefore
        && ghostMcPosActivating128[b] == actBefore
        && ghostMcPosActivatingStart40[b] == startBefore
        && ghostMcPosActivatingDelay32[b] == delayBefore,
        "setCollateralActivationConfig keeps every stored activation position");
}

// MC-HL-09: Resuming ends the pause at once and leaves the supply cap and the activation delays untouched.
rule hlMcPauseResumeRoundTrip(env e, env e2, uint256 duration) {

    setupLidoLendMarketControllerValidState(e);
    require(e2.block.timestamp >= e.block.timestamp, "SCOPE: the resume reads a clock at or after the pause");
    bool frozenBefore = ghostMcIsFrozen;
    mathint capBefore = ghostMcSupplyCap256;
    mathint minBefore = ghostMcCfgMinActivationDelay40;
    mathint maxBefore = ghostMcCfgMaxActivationDelay40;

    pauseFor(e, duration);
    resume(e2);

    assert(ghostMcResumeSinceTimestamp256 == to_mathint(e2.block.timestamp)
        && ghostMcIsFrozen == frozenBefore
        && ghostMcSupplyCap256 == capBefore
        && ghostMcCfgMinActivationDelay40 == minBefore
        && ghostMcCfgMaxActivationDelay40 == maxBefore,
        "the round trip lands resumed at now and never bleeds into governance");
}

// MC-HL-10: Resuming a paused market never lifts a freeze.
rule hlMcResumeLeavesFrozen(env e) {

    setupLidoLendMarketControllerValidState(e);
    bool frozenBefore = ghostMcIsFrozen;

    resume(e);

    assert(ghostMcIsFrozen == frozenBefore, "resume() keeps the freeze flag");
}

// MC-HL-11: Pausing the market never sets or lifts a freeze.
rule hlMcPauseForLeavesFrozen(env e, uint256 duration) {

    setupLidoLendMarketControllerValidState(e);
    bool frozenBefore = ghostMcIsFrozen;

    pauseFor(e, duration);

    assert(ghostMcIsFrozen == frozenBefore, "pauseFor() keeps the freeze flag");
}

// MC-HL-12: Freezing the market never changes when a pause ends.
rule hlMcFreezeLeavesResumeTimestamp(env e) {

    setupLidoLendMarketControllerValidState(e);
    mathint resumeBefore = ghostMcResumeSinceTimestamp256;

    freeze(e);

    assert(ghostMcResumeSinceTimestamp256 == resumeBefore, "freeze() keeps the resume timestamp");
}

// MC-HL-13: Lifting a freeze never changes when a pause ends.
rule hlMcUnfreezeLeavesResumeTimestamp(env e) {

    setupLidoLendMarketControllerValidState(e);
    mathint resumeBefore = ghostMcResumeSinceTimestamp256;

    unfreeze(e);

    assert(ghostMcResumeSinceTimestamp256 == resumeBefore, "unfreeze() keeps the resume timestamp");
}

// MC-HL-14: When the oracle reports a zero price, no settlement quote cuts anything, and each slice reports the borrower's debt untouched.
rule hlMcZeroPriceSizesNoSettlement(env e, address borrower, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostOraclePrice256[ghostLlCvlOracle] == 0,
        "SCOPE: the market oracle reports a zero price");

    LidoLendMarketController.SettlementQuote quote = settlementFor(e, borrower, budgetSupplyShares);

    assert(quote.personal.supplyShares == 0 && quote.personal.borrowShares == 0
            && quote.queueRoot.supplyShares == 0 && quote.queueRoot.borrowShares == 0,
        "a zero-price market cuts nothing");
    assert(to_mathint(quote.personal.remainingBorrowShares) == ghostLlCvlPosBorrowShares[borrower]
            && to_mathint(quote.queueRoot.remainingBorrowShares) == ghostLlCvlPosBorrowShares[borrower],
        "and each slice hands back the whole debt as its remainder");
}

// MC-HL-15: The remaining deposit room does not move when the oracle price moves.
rule hlMcMaxDepositOracleIndependent(env e) {

    setupLidoLendMarketControllerValidState(e);
    uint256 before_ = maxDeposit(e);
    havoc ghostOraclePrice256;

    uint256 after_ = maxDeposit(e);

    assert(before_ == after_, "the deposit cap survives an oracle outage");
}

// MC-HL-16: A lender's withdrawable amount does not move when the oracle price moves.
rule hlMcMaxWithdrawableOracleIndependent(env e, address supplier) {

    setupLidoLendMarketControllerValidState(e);
    uint256 before_ = maxWithdrawableAssets(e, supplier);
    havoc ghostOraclePrice256;

    uint256 after_ = maxWithdrawableAssets(e, supplier);

    assert(before_ == after_, "the withdrawable limit survives an oracle outage");
}

// MC-HL-17: The next-to-settle view reports the lender shares from whichever of the borrower's two settlement quotes is larger.
rule hlMcSettlementViewsAgreeSupply(env e, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    address b; LidoLendMarketController.SettlementSlice slice;
    b, slice = nextSettlementBorrower(e, budgetSupplyShares);
    requireBucketsWithinCollateral(b);

    LidoLendMarketController.SettlementQuote quote = settlementFor(e, b, budgetSupplyShares);
    ILidoLendMarketController.BorrowerPosition dash = positionOf(e, b);

    assert(slice.supplyShares == (dash.personalSliceAssets >= dash.queueRootSliceAssets
            ? quote.personal.supplyShares : quote.queueRoot.supplyShares),
        "the next-to-settle supply slice is the one quoted for the larger allowance");
}

// MC-HL-18: The next-to-settle view reports the debt shares from whichever of the borrower's two settlement quotes is larger.
rule hlMcSettlementViewsAgreeBorrow(env e, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    address b; LidoLendMarketController.SettlementSlice slice;
    b, slice = nextSettlementBorrower(e, budgetSupplyShares);
    requireBucketsWithinCollateral(b);

    LidoLendMarketController.SettlementQuote quote = settlementFor(e, b, budgetSupplyShares);
    ILidoLendMarketController.BorrowerPosition dash = positionOf(e, b);

    assert(slice.borrowShares == (dash.personalSliceAssets >= dash.queueRootSliceAssets
            ? quote.personal.borrowShares : quote.queueRoot.borrowShares),
        "the next-to-settle borrow slice is the one quoted for the larger allowance");
}

// MC-HL-19: The next-to-settle view reports the debt left over by whichever of the two settlement quotes is larger.
rule hlMcSettlementViewsAgreeRemainder(env e, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    address b; LidoLendMarketController.SettlementSlice slice;
    b, slice = nextSettlementBorrower(e, budgetSupplyShares);
    requireBucketsWithinCollateral(b);

    LidoLendMarketController.SettlementQuote quote = settlementFor(e, b, budgetSupplyShares);
    ILidoLendMarketController.BorrowerPosition dash = positionOf(e, b);

    assert(slice.remainingBorrowShares == (dash.personalSliceAssets >= dash.queueRootSliceAssets
            ? quote.personal.remainingBorrowShares : quote.queueRoot.remainingBorrowShares),
        "the next-to-settle remainder is the one quoted for the larger allowance");
}

// MC-HL-20: Only a governance policy change can leave the inflow throttle above its ceiling.
rule hlMcInflowCapBreaksOnlyViaConfig(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketControllerValidState(e);
    bool capBefore = ghostMcActInflow128 <= ghostMcCfgMaxDelayInflow128;

    f(e, args);

    bool capAfter = ghostMcActInflow128 <= ghostMcCfgMaxDelayInflow128;

    assert((capBefore && !capAfter) => f.selector ==
        sig:setCollateralActivationConfig(LidoLendMarketController.CollateralActivationConfig).selector,
        "only a config lowering can push the inflow accumulator over its ceiling");
}

// MC-HL-21: A borrow matures collateral only after the full wait, guardian surcharges included, and an open quorum gate.
rule hlMcBorrowMaturationGateExact(env e, LidoLendMarketController.Id id, bytes data, address b) {

    setupLidoLendMarketControllerValidState(e);
    mathint act0 = ghostMcPosActivating128[b];
    mathint start0 = ghostMcPosActivatingStart40[b];
    mathint delay0 = ghostMcPosActivatingDelay32[b];
    mathint surcharge = ghostGsCvlStrikeCount[ghostMcMarketId][b] * ghostMcCfgDelayPerStrike40
        + (start0 < ghostGsCvlSuspectExpiry256[ghostMcMarketId][b]
            ? ghostGsCvlSuspectCount[ghostMcMarketId][b] * ghostMcCfgDelayPerSuspect40 : 0);
    mathint unlock = start0 + delay0 + surcharge;

    on(e, id, ILidoLendMarketController.HookEvent.Borrow, data);

    assert(ghostMcPosActivating128[b] != act0 => ghostMcPosActivating128[b] == 0,
        "a moved lot is a matured lot");
    assert(ghostMcPosActivating128[b] != act0
        => (to_mathint(e.block.timestamp) >= unlock
            && (unlock <= ghostGsCvlQuorumFrontier40
                || to_mathint(e.block.timestamp) >= start0 + ghostMcCfgMaxGuardiansQuorumDelay40)),
        "maturation needs the unlock passed and the quorum gate open");
    assert(ghostMcPosActivating128[b] != act0 => to_mathint(e.block.timestamp) >= start0 + delay0,
        "maturation never beats the base delay");
}

// MC-HL-22: While the market is frozen or the borrower is banned, a deposit never matures the waiting collateral.
rule hlMcFrozenOrBannedDefersMaturation(env e, LidoLendMarketController.Id id, bytes data, address b) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcIsFrozen || ghostGsCvlBanned[ghostMcMarketId][b],
        "SCOPE: the frozen or banned deferral legs");
    mathint act0 = ghostMcPosActivating128[b];
    mathint start0 = ghostMcPosActivatingStart40[b];

    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    assert(ghostMcPosActivating128[b] >= act0, "a deferred lot never shrinks");
    assert(start0 != 0 => ghostMcPosActivatingStart40[b] != 0, "a deferred timer keeps running");
}

// MC-HL-23: An ordinary caller's deposit that lifts the borrower's dust over the activation threshold enters the timer with it.
rule hlMcNonGrantedDepositEntersActivating(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcPosActivatingStart40[d.onBehalf] == 0, "SCOPE: no standing activation timer");
    require(!ghostMcInstantActivationCallers[d.caller], "SCOPE: an ungranted caller");
    mathint dustBefore = ghostMcPosDust128[d.onBehalf];
    require(to_mathint(d.assets) + dustBefore >= ghostMcCfgMinActivationAmount128,
        "SCOPE: supra-threshold");
    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);

    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    assert(ghostMcPosActivating128[d.onBehalf] == to_mathint(d.assets) + dustBefore
        && ghostMcPosDust128[d.onBehalf] == 0,
        "the deposit and the released dust enter the timer as one lot");
}

// MC-HL-24: Without new deposits the inflow throttle only decays, and the wait it quotes never grows.
rule hlMcInflowDecayLaws(env e1, env e2, uint256 inc) {

    setupLidoLendMarketControllerValidState(e1);
    require(e2.block.timestamp >= e1.block.timestamp
        && to_mathint(e2.block.timestamp) < MAX_BLOCK_TIMESTAMP(),
        "SCOPE: e2 is the later reading, inside the setup's timestamp band");

    mathint i1 = currentInflow(e1);
    mathint i2 = currentInflow(e2);
    mathint d1 = currentActivationDelay(e1, inc);
    mathint d2 = currentActivationDelay(e2, inc);

    assert(i1 <= ghostMcActInflow128, "the decayed inflow never exceeds its snapshot");
    assert(i2 <= i1, "the inflow only decays");
    assert((to_mathint(e2.block.timestamp) - ghostMcActInflowUpdatedAt40 >= ghostMcCfgMaxActivationDelay40
            && ghostMcActInflow128 <= ghostMcCfgMaxDelayInflow128)
        => i2 == 0,
        "a full delay window drains the accumulator to zero");
    assert(d2 <= d1, "a later quote is never longer");
}

// MC-HL-25: A top-up unlocks at the later of the standing deadline and the one its own size earns.
rule hlMcTopUpDeadlineIsMaxOfOldAndQuote(env e, LidoLendMarketController.Id id, bytes data,
    address b, uint256 inc) {

    setupLidoLendMarketControllerValidState(e);
    mathint act0 = ghostMcPosActivating128[b];
    mathint start0 = ghostMcPosActivatingStart40[b];
    mathint delay0 = ghostMcPosActivatingDelay32[b];
    require(start0 == 0 || to_mathint(e.block.timestamp) < start0 + delay0,
        "SCOPE: the standing lot is not yet due");
    mathint quote = currentActivationDelay(e, inc);

    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    require(ghostMcPosActivating128[b] > act0, "SCOPE: the deposit landed in b's timer leg");

    require(to_mathint(inc) == ghostMcPosActivating128[b] - act0,
        "SCOPE: the quote prices the increment the deposit books");
    mathint newDeadline = ghostMcPosActivatingStart40[b] + ghostMcPosActivatingDelay32[b];

    assert(newDeadline == (start0 + delay0 >= to_mathint(e.block.timestamp) + quote
        ? start0 + delay0 : to_mathint(e.block.timestamp) + quote),
        "the deadline is the max of the standing one and the fresh quote");
}

// MC-HL-26: While the lock holds, a withdrawal that completes leaves both inactive buckets exactly as they were.
rule hlMcWithdrawUnderLockKeepsFloor(env e, LidoLendMarketController.Id id, bytes data, address b) {

    setupLidoLendMarketControllerValidState(e);
    mathint act0 = ghostMcPosActivating128[b];
    mathint dust0 = ghostMcPosDust128[b];
    mathint start0 = ghostMcPosActivatingStart40[b];
    require(act0 != 0
        && to_mathint(e.block.timestamp) < start0 + ghostMcCfgActivatingLockDuration40,
        "SCOPE: the lock is in force");
    require(to_mathint(e.block.timestamp) < start0 + ghostMcPosActivatingDelay32[b],
        "SCOPE: the lot is not yet due");

    on(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);

    assert(ghostMcPosActivating128[b] == act0, "the locked lot survives the withdrawal whole");
    assert(ghostMcPosDust128[b] == dust0, "a locked withdrawal moves no dust either");
}

// MC-HL-27: A quoted settlement cut never exceeds the borrower's debt, and any nonzero cut plus the remainder equals it.
rule hlMcSettlementSliceConservesDebt(env e, address borrower, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    mathint posShares = ghostLlCvlPosBorrowShares[borrower];
    mathint posCollateral = ghostLlCvlPosCollateral[borrower];

    LidoLendMarketController.SettlementQuote quote = settlementFor(e, borrower, budgetSupplyShares);
    uint256 s = quote.queueRoot.supplyShares;
    uint256 bs = quote.queueRoot.borrowShares;
    uint256 r = quote.queueRoot.remainingBorrowShares;

    assert(bs == 0 => (s == 0 && to_mathint(r) == posShares), "a zero cut spends nothing and keeps the debt whole");
    assert(to_mathint(bs) <= posShares, "the cut never exceeds the position");
    assert(bs != 0 => to_mathint(bs) + to_mathint(r) == posShares, "the cut and the remainder split the debt");
    assert((bs != 0 && r == 0) => to_mathint(bs) == posShares, "a zero remainder is a full close");
    assert(posCollateral == 0 => bs == 0, "an uncollateralized position is never sliced");
}

// MC-HL-28: A timed pause stays in force for its whole window.
rule hlMcTimedPauseHoldsThroughWindow(env e, env e2, uint256 duration) {

    setupLidoLendMarketControllerValidState(e);
    require(to_mathint(duration) != max_uint256
        || to_mathint(e2.block.timestamp) < MAX_BLOCK_TIMESTAMP(),
        "SAFE: the excluded read sits at a max-clock singularity no chain reaches");

    pauseFor(e, duration);

    require(to_mathint(e2.block.timestamp) >= to_mathint(e.block.timestamp)
        && to_mathint(e2.block.timestamp) < to_mathint(e.block.timestamp) + duration,
        "SCOPE: the clock is inside the pause window");
    assert(isPaused(e2), "a timed pause holds until its window elapses");
}

// MC-HL-29: A timed pause ends by itself when its window elapses, with no resume call.
rule hlMcTimedPauseExpiresWithoutResume(env e, env e2, uint256 duration) {

    setupLidoLendMarketControllerValidState(e);

    pauseFor(e, duration);

    require(to_mathint(e2.block.timestamp) >= to_mathint(e.block.timestamp) + duration,
        "SCOPE: the clock has passed the pause window");
    assert(!isPaused(e2), "a timed pause ends when its window elapses, with no resume call");
}

// MC-HL-30: Once the lock has elapsed, a covering withdrawal clears the borrower's whole pending collateral.
rule hlMcLockLiftsAfterDeadline(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    mathint act0 = ghostMcPosActivating128[d.onBehalf];
    mathint dust0 = ghostMcPosDust128[d.onBehalf];
    mathint start0 = ghostMcPosActivatingStart40[d.onBehalf];
    require(to_mathint(e.block.timestamp) >= start0 + ghostMcCfgActivatingLockDuration40,
        "SCOPE: the lock window has elapsed");
    require(to_mathint(d.assets) >= act0 + dust0,
        "SCOPE: the withdrawal covers the whole un-matured balance");

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);

    assert(ghostMcPosActivating128[d.onBehalf] == 0 && ghostMcPosDust128[d.onBehalf] == 0,
        "an elapsed lock holds nothing back");
}

// MC-HL-31: A debt-free borrower's withdrawal either leaves the inactive buckets whole under a live lock, or clears them both.
rule hlMcVoluntaryDrainIsAllOrNothing(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostLlCvlPosBorrowShares[d.onBehalf] == 0,
        "SCOPE: a debt-free exit");
    mathint dust0 = ghostMcPosDust128[d.onBehalf];
    mathint act0 = ghostMcPosActivating128[d.onBehalf];
    mathint start0 = ghostMcPosActivatingStart40[d.onBehalf];
    mathint delay0 = ghostMcPosActivatingDelay32[d.onBehalf];
    require(start0 == 0 || to_mathint(e.block.timestamp) < start0 + delay0,
        "SCOPE: the lot is not yet due");
    require(dust0 + act0 != 0, "SCOPE: the position carries inactive collateral");
    bool locked = act0 != 0
        && to_mathint(e.block.timestamp) < start0 + ghostMcCfgActivatingLockDuration40;
    requireBucketsWithinCollateral(d.onBehalf);

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);

    assert(locked => (ghostMcPosDust128[d.onBehalf] == dust0
            && ghostMcPosActivating128[d.onBehalf] == act0),
        "a withdrawal under the lock moves neither bucket");
    assert(!locked => (ghostMcPosDust128[d.onBehalf] == 0
            && ghostMcPosActivating128[d.onBehalf] == 0),
        "an unlocked withdrawal that completes clears the whole inactive holding");
    assert(!locked => (ghostMcPosActivatingStart40[d.onBehalf] == 0
            && ghostMcPosActivatingDelay32[d.onBehalf] == 0),
        "an emptied lot leaves no timer behind");
}

// MC-HL-32: The queue-root policy quote honors both settlement floors and never exceeds the borrower's debt.
rule hlMcRootSliceHonorsPolicyFloors(env e, address b) {

    setupLidoLendMarketControllerValidState(e);
    require(b != 0, "SCOPE: a nonzero borrower row");
    requireBucketsWithinCollateral(b);

    ILidoLendMarketController.BorrowerPosition dash = positionOf(e, b);

    // Both fields come off one snapshot, so debt is what the slice ladder itself sizes against.
    mathint debt = to_mathint(dash.debtAssets);
    mathint slice = to_mathint(dash.queueRootSliceAssets);
    mathint byBps = debt * ghostMcSetSliceFloorBps16 / BPS_MC_CVL();
    mathint floorAssets = ghostMcSetSliceFloorAssets96;
    mathint collValue = to_mathint(ghostLlCvlPosCollateral[b])
        * to_mathint(ghostOraclePrice256[ghostLlCvlOracle]) / ORACLE_PRICE_SCALE_MC_CVL();
    bool sizeable = debt != 0 && collValue != 0;

    assert(slice <= debt, "the advertised cut never exceeds the debt");
    assert(sizeable => slice >= (byBps < debt ? byBps : debt),
        "the debt-fraction floor is honored, capped at the debt");
    assert(sizeable => slice >= (floorAssets < debt ? floorAssets : debt),
        "the asset floor is honored, capped at the debt");
    assert((ghostMcSetSliceFloorBps16 == 0 && floorAssets == 0 && ghostMcSetLtvStepBps16 == 0)
            => slice == 0,
        "an all-zero policy quotes no root cut; the quote is a prospective allowance, and root status gates its execution rather than its size");
}

// MC-HL-33: A borrower's personal quote is its settle-down target capped at its debt, and zero without an opt-in.
rule hlMcSlicePartitionsByEligibility(env e, address b) {

    setupLidoLendMarketControllerValidState(e);
    require(b != 0, "SCOPE: a nonzero borrower row");
    requireBucketsWithinCollateral(b);

    ILidoLendMarketController.BorrowerPosition dash = positionOf(e, b);
    uint256 ltv; uint256 ltvSlice;
    ltv, ltvSlice = settlementLtv(e, b);

    mathint debt = to_mathint(dash.debtAssets);
    mathint slice = to_mathint(dash.personalSliceAssets);
    mathint capped = to_mathint(ltvSlice) < debt ? to_mathint(ltvSlice) : debt;

    assert(slice == capped,
        "the personal quote is the opt-in slice capped at the debt, whatever the queue holds");
    assert(ltv == 0 => slice == 0, "a borrower that set no target is never quoted a personal cut");
}

// MC-HL-34: A deposit fully withdrawn in the same transaction leaves the inflow throttle exactly where it stood.
rule hlMcSameTxSupplyWithdrawUndoesInflow(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData ds,
    ILidoLendMarketController.WithdrawCollateralHookData dw) {

    setupLidoLendMarketControllerValidState(e);
    require(ds.onBehalf == dw.onBehalf, "SCOPE: one borrower supplies and withdraws");
    require(to_mathint(dw.assets) == to_mathint(ds.assets),
        "SCOPE: the withdrawal takes back exactly the deposit");
    require(!ghostMcInstantActivationCallers[ds.caller],
        "SCOPE: an ungranted caller");
    require(ghostMcPosActivatingStart40[ds.onBehalf] == 0 && ghostMcPosDust128[ds.onBehalf] == 0,
        "SCOPE: a borrower with no standing lot and no dust");
    require(to_mathint(ds.assets) >= ghostMcCfgMinActivationAmount128,
        "SCOPE: a supra-threshold deposit");
    require(ghostMcCfgActivatingLockDuration40 == 0,
        "SCOPE: no lock in force");
    require(ghostMcActInflow128 <= ghostMcCfgMaxDelayInflow128,
        "SCOPE: the inflow meter within its cap");
    require(ghostLlCvlPosBorrowShares[ds.onBehalf] == 0,
        "SCOPE: a debt-free borrower");

    mathint inflowStart = currentInflow(e);

    bytes supplyData = _HookEncoder.encodeSupplyCollateral(e, ds);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, supplyData);
    bytes withdrawData = _HookEncoder.encodeWithdrawCollateral(e, dw);
    on(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, withdrawData);

    assert(ghostMcActInflow128 == inflowStart,
        "the flash deposit leaves the tracked inflow where it stood");
    assert(ghostMcTransientSlot[borrowerSlotMcCVL(ds.onBehalf)] == 0, "and its same-tx counter nets back to zero");
}

// MC-HL-42: A deposit withdrawn in a later transaction leaves the inflow throttle charged.
rule hlMcCrossTxWithdrawLeavesInflowCharged(env e1, env e2, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData ds,
    ILidoLendMarketController.WithdrawCollateralHookData dw) {

    setupLidoLendMarketControllerValidState(e1);
    setupEnv(e2);
    require(e1.msg.sender == e2.msg.sender, "SCOPE: one hook caller across both transactions");
    require(e2.block.timestamp >= e1.block.timestamp,
        "SCOPE: the withdrawal comes at or after the deposit's block");
    require(ds.onBehalf == dw.onBehalf, "SCOPE: one borrower supplies and withdraws");
    require(to_mathint(dw.assets) == to_mathint(ds.assets),
        "SCOPE: the withdrawal takes back exactly the deposit");
    require(!ghostMcInstantActivationCallers[ds.caller],
        "SCOPE: an ungranted caller");
    require(ghostMcPosActivatingStart40[ds.onBehalf] == 0 && ghostMcPosDust128[ds.onBehalf] == 0,
        "SCOPE: a borrower with no standing lot and no dust");
    require(to_mathint(ds.assets) >= ghostMcCfgMinActivationAmount128,
        "SCOPE: a supra-threshold deposit");
    require(ghostMcCfgActivatingLockDuration40 == 0,
        "SCOPE: no lock in force");
    require(ghostMcActInflow128 <= ghostMcCfgMaxDelayInflow128,
        "SCOPE: the inflow meter within its governance cap");
    require(ghostLlCvlPosBorrowShares[ds.onBehalf] == 0,
        "SCOPE: a debt-free borrower");

    bytes supplyData = _HookEncoder.encodeSupplyCollateral(e1, ds);
    on(e1, id, ILidoLendMarketController.HookEvent.SupplyCollateral, supplyData);

    mathint inflowAfterDeposit = ghostMcActInflow128;
    mathint clockAfterDeposit = ghostMcActInflowUpdatedAt40;

    // Transaction boundary: the EVM clears both transient slots between the calls.
    ghostMcTransientSlot[borrowerSlotMcCVL(ds.onBehalf)] = 0;
    ghostMcTransientSlot[MC_TX_INFLOW_SLOT()] = 0;

    bytes withdrawData = _HookEncoder.encodeWithdrawCollateral(e2, dw);
    on(e2, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, withdrawData);

    assert(ghostMcActInflow128 == inflowAfterDeposit,
        "the cross-transaction withdrawal leaves the inflow meter charged");
    assert(ghostMcActInflowUpdatedAt40 == clockAfterDeposit,
        "and does not restamp the meter clock");
}

// MC-HL-35: A deposit that leaves the borrower's total under the activation threshold never feeds the inflow throttle or restarts its decay.
rule hlMcDustDepositLeavesThrottle(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(to_mathint(d.assets) + ghostMcPosDust128[d.onBehalf] < ghostMcCfgMinActivationAmount128,
        "SCOPE: the deposit and the dust it joins stay under the activation threshold");
    mathint inflowBefore = ghostMcActInflow128;
    mathint clockBefore = ghostMcActInflowUpdatedAt40;

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    assert(ghostMcActInflow128 == inflowBefore && ghostMcActInflowUpdatedAt40 == clockBefore,
        "a dust deposit neither feeds the inflow meter nor restamps its clock");
    assert(ghostMcTransientSlot[borrowerSlotMcCVL(d.onBehalf)] == 0, "and books no same-tx inflow at all");
}

// MC-HL-36: Outside a pause, a lender's deposit fares the same at any time and starts no activation timer.
rule hlMcSupplyGateIgnoresTheClock(env e1, env e2, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyHookData d, address b) {

    setupLidoLendMarketControllerValidState(e1);
    setupEnv(e2);
    require(e1.msg.sender == e2.msg.sender,
        "SCOPE: one caller across both readings");
    require(to_mathint(e1.block.timestamp) >= ghostMcResumeSinceTimestamp256
        && to_mathint(e2.block.timestamp) >= ghostMcResumeSinceTimestamp256,
        "SCOPE: both readings sit outside a pause window");
    mathint dustBefore = ghostMcPosDust128[b];
    mathint actBefore = ghostMcPosActivating128[b];

    bytes data = _HookEncoder.encodeSupply(e1, d);
    on@withrevert(e1, id, ILidoLendMarketController.HookEvent.Supply, data);
    bool revertedEarly = lastReverted;
    on@withrevert(e2, id, ILidoLendMarketController.HookEvent.Supply, data);
    bool revertedLate = lastReverted;

    assert(revertedEarly == revertedLate, "the supply gate admits the same deposit at any time");
    assert(ghostMcPosDust128[b] == dustBefore && ghostMcPosActivating128[b] == actBefore,
        "and parks nothing in the activation pipeline on the way");
}

// MC-HL-37: An unfreeze followed by a resume always reopens the market, whatever call came before.
rule hlMcNoRestrictionIsTerminal(env e, env e2, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_MC(f) } {

    setupLidoLendMarketControllerValidState(e);

    f(e, args);
    unfreeze(e2);
    // Reverts exactly when there is nothing to resume, which is the state the assert asks for.
    resume@withrevert(e2);

    assert(!ghostMcIsFrozen && to_mathint(e2.block.timestamp) >= ghostMcResumeSinceTimestamp256,
        "an unfreeze and a resume always return the market to borrowable");
}

// MC-HL-38: A deposit whose surcharged wait outlasts the quorum window still matures without a quorum scan.
rule hlMcFallbackAloneMaturesSurchargedLot(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.BorrowHookData d) {

    setupLidoLendMarketControllerValidState(e);
    mathint start0 = ghostMcPosActivatingStart40[d.onBehalf];
    mathint delay0 = ghostMcPosActivatingDelay32[d.onBehalf];
    mathint surcharge = ghostGsCvlStrikeCount[ghostMcMarketId][d.onBehalf] * ghostMcCfgDelayPerStrike40
        + (start0 < ghostGsCvlSuspectExpiry256[ghostMcMarketId][d.onBehalf]
            ? ghostGsCvlSuspectCount[ghostMcMarketId][d.onBehalf] * ghostMcCfgDelayPerSuspect40 : 0);
    mathint unlock = start0 + delay0 + surcharge;
    require(start0 > 0, "SCOPE: a running activation timer");
    require(ghostMcCfgMaxGuardiansQuorumDelay40 != 0,
        "SCOPE: a live fallback window");
    require(unlock >= start0 + ghostMcCfgMaxGuardiansQuorumDelay40,
        "SCOPE: the surcharge consumes the quorum window");
    require(ghostGsCvlQuorumFrontier40 < unlock,
        "SCOPE: the frontier behind the unlock");
    require(to_mathint(e.block.timestamp) >= unlock,
        "SCOPE: the unlock has passed");

    bytes data = _HookEncoder.encodeBorrow(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Borrow, data);

    mathint actAfter = ghostMcPosActivating128[d.onBehalf];
    mathint startAfter = ghostMcPosActivatingStart40[d.onBehalf];

    assert(actAfter == 0 && startAfter == 0,
        "the start-anchored fallback matures the lot with no quorum scan");
}

// MC-HL-39: An ordinary caller's deposit that keeps the borrower's dust under the activation threshold joins it and starts no timer.
rule hlMcSubThresholdDepositStaysDust(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcPosActivatingStart40[d.onBehalf] == 0, "SCOPE: no standing activation timer");
    require(!ghostMcInstantActivationCallers[d.caller],
        "SCOPE: an ungranted caller");
    mathint dustBefore = ghostMcPosDust128[d.onBehalf];
    require(to_mathint(d.assets) + dustBefore < ghostMcCfgMinActivationAmount128,
        "SCOPE: sub-threshold");

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    mathint dustAfter = ghostMcPosDust128[d.onBehalf];
    mathint actAfter = ghostMcPosActivating128[d.onBehalf];
    mathint startAfter = ghostMcPosActivatingStart40[d.onBehalf];

    assert(dustAfter == to_mathint(d.assets) + dustBefore && actAfter == 0 && startAfter == 0,
        "the deposit joins the dust it aggregates with and starts no timer");
}

// MC-HL-40: The riskiest borrower counts as bad debt exactly when its debt, priced up, exceeds its collateral, priced down.
rule hlMcBadDebtVerdictMatchesTheRoundedPredicate(env e) {

    setupLidoLendMarketControllerValidState(e);
    address root = ghostMcHeapNodeAccount[1];
    mathint shares = to_mathint(ghostLlCvlPosBorrowShares[root]);
    mathint collateral = to_mathint(ghostLlCvlPosCollateral[root]);
    mathint price = to_mathint(ghostOraclePrice256[ghostLlCvlOracle]);

    // The two roundings written out over the stored fields, ceil against floor.
    mathint debtUp = (shares * (to_mathint(ghostLlCvlTotalBorrowAssets) + VIRTUAL_ASSETS_MC_CVL())
            + to_mathint(ghostLlCvlTotalBorrowShares) + VIRTUAL_SHARES_MC_CVL() - 1)
        / (to_mathint(ghostLlCvlTotalBorrowShares) + VIRTUAL_SHARES_MC_CVL());
    mathint valueDown = collateral * price / ORACLE_PRICE_SCALE_MC_CVL();

    bool bad = hasBadDebt(e);

    assert(bad <=> (shares != 0 && debtUp > valueDown),
        "the verdict is the rounded predicate itself, in both directions");
    assert((shares != 0 && collateral * price < ORACLE_PRICE_SCALE_MC_CVL()) => bad,
        "and a root the price floors to no value at all is bad debt while it owes anything");
}

// MC-HL-41: Anyone can repay the whole debt of the riskiest borrower when its collateral prices to nothing, clearing it from the queue.
rule hlMcZeroValuedRootClearsByExactShareRepay(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.RepayHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(id == ghostMcMarketId,
        "SCOPE: the bound market");
    require(e.msg.sender == _Controller.LIDO_LEND(e),
        "SCOPE: the core drives every hook");
    require(to_mathint(e.block.timestamp) >= ghostMcResumeSinceTimestamp256,
        "SCOPE: a running market, outside a pause window");

    address root = ghostMcHeapNodeAccount[1];
    require(ghostMcHeapNodesLength > 1 && root != 0, "SCOPE: a queue with a root to clear");
    mathint collateral = to_mathint(ghostLlCvlPosCollateral[root]);
    mathint price = to_mathint(ghostOraclePrice256[ghostLlCvlOracle]);
    require(collateral != 0 && collateral * price < ORACLE_PRICE_SCALE_MC_CVL(),
        "SCOPE: a root whose collateral prices below one raw unit");

    require(price >= ORACLE_PRICE_SCALE_MC_CVL() / 10000000000000
            && price <= ORACLE_PRICE_SCALE_MC_CVL() * 10,
        "SCOPE: a price within the band deployed adapters report");

    require(to_mathint(ghostLlCvlTotalBorrowShares) >= to_mathint(ghostLlCvlTotalBorrowAssets)
            && to_mathint(ghostLlCvlTotalBorrowShares)
                <= to_mathint(ghostLlCvlTotalBorrowAssets) * VIRTUAL_SHARES_MC_CVL(),
        "SCOPE: a borrow index inside the band a market runs in");

    require(to_mathint(ghostLlCvlPosBorrowShares[root]) == 1,
        "SCOPE: a root owing one borrow share");
    require(d.onBehalf == root && to_mathint(d.shares) == 1,
        "SCOPE: the exact-share payload for the root's whole debt");
    require(to_mathint(d.assets) == debtAssetsUpMcCVL(root),
        "SCOPE: assets priced as toAssetsUp(shares)");

    // The gate is one-sided: a market already over the ceiling is exempt.
    mathint tBA = to_mathint(ghostLlCvlTotalBorrowAssets);
    mathint tBS = to_mathint(ghostLlCvlTotalBorrowShares);
    mathint postAssets = tBA > to_mathint(d.assets) ? tBA - to_mathint(d.assets) : 0;
    mathint postShares = tBS > to_mathint(d.shares) ? tBS - to_mathint(d.shares) : 0;
    bool preOver = tBS + VIRTUAL_SHARES_MC_CVL()
        > MAX_BORROW_SHARE_RATE_MC_CVL() * (tBA + VIRTUAL_ASSETS_MC_CVL());
    require(!(!preOver && postShares + VIRTUAL_SHARES_MC_CVL()
            > MAX_BORROW_SHARE_RATE_MC_CVL() * (postAssets + VIRTUAL_ASSETS_MC_CVL())),
        "SCOPE: the repay does not cross the borrow-share-rate ceiling");

    bool badBefore = hasBadDebt(e);

    bytes data = _HookEncoder.encodeRepay(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Repay, data);
    bool reverted = lastReverted;

    assert(badBefore, "the queue root is bad debt here, so the settle waterfall is shut on it");
    assert(!reverted, "the repay hook carries no verdict of its own, so the cleanup goes through");
    assert(ghostMcHeapSlot[root] == 0, "and it takes the cleared borrower out of the settlement queue");
    assert(to_mathint(d.assets) == 1, "one raw unit of the loan token is the whole price of that cleanup");
}

// MC-HL-43: A settlement quote never asks the caller for more supply shares than the budget it was given.
rule hlMcSettlementQuoteFitsBudget(env e, address borrower, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    require(budgetSupplyShares != 0,
        "SCOPE: a budgeted quote");
    require(to_mathint(budgetSupplyShares) <= max_uint128,
        "SCOPE: a budget a core supply position can hold");

    LidoLendMarketController.SettlementQuote quote = settlementFor(e, borrower, budgetSupplyShares);

    assert(to_mathint(quote.personal.supplyShares) <= to_mathint(budgetSupplyShares),
        "the personal quote is one the budget funds");
    assert(to_mathint(quote.queueRoot.supplyShares) <= to_mathint(budgetSupplyShares),
        "the root quote is one the budget funds");
}

// MC-HL-44: A trusted caller's deposit is active at once whatever its size, and leaves dust and the inflow throttle untouched.
rule hlMcInstantDepositLandsActiveAndLeavesDust(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcInstantActivationCallers[d.caller], "SCOPE: a granted caller");
    require(ghostMcPosActivatingStart40[d.onBehalf] == 0,
        "SCOPE: no standing activation timer");
    mathint dustBefore = ghostMcPosDust128[d.onBehalf];
    mathint activatingBefore = ghostMcPosActivating128[d.onBehalf];
    mathint inflowBefore = ghostMcActInflow128;
    mathint clockBefore = ghostMcActInflowUpdatedAt40;

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    assert(ghostMcPosDust128[d.onBehalf] == dustBefore
        && ghostMcPosActivating128[d.onBehalf] == activatingBefore
        && ghostMcPosActivatingStart40[d.onBehalf] == 0,
        "the granted deposit joins neither bucket and starts no timer, whatever its size");
    assert(ghostMcActInflow128 == inflowBefore && ghostMcActInflowUpdatedAt40 == clockBefore
        && ghostMcTransientSlot[borrowerSlotMcCVL(d.onBehalf)] == 0,
        "and the inflow throttle never meters it");
}

// MC-HL-45: A borrower who added nothing to the inflow throttle takes nothing back on exit, so another borrower's charge stands.
rule hlMcInflowUndoIsPerBorrower(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d2,
    ILidoLendMarketController.WithdrawCollateralHookData w1) {

    setupLidoLendMarketControllerValidState(e);
    require(w1.onBehalf != d2.onBehalf, "SCOPE: two distinct borrowers");
    require(!ghostMcInstantActivationCallers[d2.caller],
        "SCOPE: an ungranted caller");
    require(ghostMcPosActivatingStart40[d2.onBehalf] == 0 && ghostMcPosDust128[d2.onBehalf] == 0,
        "SCOPE: the depositing borrower has no standing lot and no dust");
    require(to_mathint(d2.assets) >= ghostMcCfgMinActivationAmount128,
        "SCOPE: a supra-threshold deposit");
    mathint start1 = ghostMcPosActivatingStart40[w1.onBehalf];
    require(start1 != 0 && ghostMcPosActivating128[w1.onBehalf] > 0
            && to_mathint(e.block.timestamp) < start1 + ghostMcPosActivatingDelay32[w1.onBehalf],
        "SCOPE: the exiting borrower holds a standing lot not yet due");
    require(ghostMcCfgActivatingLockDuration40 == 0,
        "SCOPE: no lock in force");
    require(ghostLlCvlPosBorrowShares[w1.onBehalf] == 0,
        "SCOPE: a debt-free exit");
    requireBucketsWithinCollateral(w1.onBehalf);
    mathint inflowStart = currentInflow(e);
    require(inflowStart + to_mathint(d2.assets) <= ghostMcCfgMaxDelayInflow128,
        "SCOPE: headroom under the inflow cap");

    bytes supplyData = _HookEncoder.encodeSupplyCollateral(e, d2);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, supplyData);

    mathint afterDeposit = ghostMcActInflow128;
    mathint clockAfterDeposit = ghostMcActInflowUpdatedAt40;

    bytes withdrawData = _HookEncoder.encodeWithdrawCollateral(e, w1);
    on(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, withdrawData);

    assert(ghostMcActInflow128 == afterDeposit,
        "the exit gives back nothing it never booked, so the other borrower's charge stands");
    assert(ghostMcActInflowUpdatedAt40 == clockAfterDeposit,
        "and it does not restamp the meter clock");
}

// MC-HL-46: A deposit seized back in the same transaction leaves the inflow throttle exactly where it stood.
rule hlMcSameTxSeizureUndoesInflow(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData ds,
    ILidoLendMarketController.LiquidateHookData dl) {

    setupLidoLendMarketControllerValidState(e);
    require(dl.borrower == ds.onBehalf, "SCOPE: the seizure lands on the depositing borrower");
    require(to_mathint(dl.seizedAssets) == to_mathint(ds.assets),
        "SCOPE: the seizure takes back exactly the deposit");
    require(!ghostMcInstantActivationCallers[ds.caller],
        "SCOPE: an ungranted caller");
    require(ghostMcPosActivatingStart40[ds.onBehalf] == 0 && ghostMcPosDust128[ds.onBehalf] == 0,
        "SCOPE: a borrower with no standing lot and no dust");
    require(to_mathint(ds.assets) >= ghostMcCfgMinActivationAmount128,
        "SCOPE: a supra-threshold deposit");
    require(ghostMcActInflow128 <= ghostMcCfgMaxDelayInflow128,
        "SCOPE: the inflow meter within its governance cap");
    requireBucketsWithinCollateral(ds.onBehalf);
    require(to_mathint(ghostLlCvlPosCollateral[ds.onBehalf]) == to_mathint(ds.assets),
        "SCOPE: the depositor holds no collateral beyond the fresh deposit");

    mathint inflowStart = currentInflow(e);

    bytes supplyData = _HookEncoder.encodeSupplyCollateral(e, ds);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, supplyData);
    bytes liquidateData = _HookEncoder.encodeLiquidate(e, dl);
    on(e, id, ILidoLendMarketController.HookEvent.Liquidate, liquidateData);

    assert(ghostMcActInflow128 == inflowStart,
        "the seized deposit leaves the tracked inflow where it stood");
    assert(ghostMcTransientSlot[borrowerSlotMcCVL(ds.onBehalf)] == 0,
        "and its same-transaction contribution nets back to zero");
}

// MC-HL-47: A seizure takes active collateral first, then dust, then the activating lot, and leaves any surviving lot on its own timer.
rule hlMcSeizeTakesActiveThenDustThenActivating(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.LiquidateHookData d) {

    setupLidoLendMarketControllerValidState(e);
    requireBucketsWithinCollateral(d.borrower);
    require(d.seizedAssets != 0, "SCOPE: a seizure that reaches the position");

    mathint dust0 = ghostMcPosDust128[d.borrower];
    mathint act0 = ghostMcPosActivating128[d.borrower];
    mathint start0 = ghostMcPosActivatingStart40[d.borrower];
    mathint delay0 = ghostMcPosActivatingDelay32[d.borrower];
    mathint collateral = to_mathint(ghostLlCvlPosCollateral[d.borrower]);

    mathint active = collateral - dust0 - act0;
    mathint seized = to_mathint(d.seizedAssets);
    mathint uncovered = seized > active ? seized - active : 0;
    mathint fromDust = dust0 < uncovered ? dust0 : uncovered;
    mathint rest = uncovered - fromDust;
    mathint fromAct = rest < act0 ? rest : act0;

    bytes data = _HookEncoder.encodeLiquidate(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Liquidate, data);

    mathint dustAfter = ghostMcPosDust128[d.borrower];
    mathint actAfter = ghostMcPosActivating128[d.borrower];

    assert(uncovered == 0 => (dustAfter == dust0 && actAfter == act0
            && ghostMcPosActivatingStart40[d.borrower] == start0
            && ghostMcPosActivatingDelay32[d.borrower] == delay0),
        "a covered seizure leaves both buckets and the timer alone");
    assert(uncovered != 0 => (dustAfter == dust0 - fromDust && actAfter == act0 - fromAct),
        "the uncovered part comes from dust first, then from the lot");
    assert((uncovered != 0 && actAfter != 0)
        => (ghostMcPosActivatingStart40[d.borrower] == start0
            && ghostMcPosActivatingDelay32[d.borrower] == delay0),
        "a remainder of any size stays on the timer it already had");
    assert((uncovered != 0 && actAfter == 0)
        => (ghostMcPosActivatingStart40[d.borrower] == 0
            && ghostMcPosActivatingDelay32[d.borrower] == 0),
        "an emptied lot leaves no timer behind");
}
