// Each rule pins when a call must fail and when it must not

import "LidoLendMarketController_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_core_view.spec";
import "../setup/GuardianSignals/GuardianSignals_cvl.spec";

using LidoLendMarketControllerHookEncoder as _HookEncoder;

// MC-RV-01: Only the core lending contract can drive this market's policy hook.
rule rvMcOnRevertsWhenCallerNotCore(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    address core = _Controller.LIDO_LEND(e);
    bool notCore = e.msg.sender != core;

    on@withrevert(e, id, ev, data);
    bool reverted = lastReverted;

    assert(notCore => reverted, "a hook from any caller but the core reverts");
}

// MC-RV-02: A hook call for any market other than the bound one fails.
rule rvMcOnRevertsOnForeignMarketId(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    bool wrongId = id != ghostMcMarketId;

    on@withrevert(e, id, ev, data);
    bool reverted = lastReverted;

    assert(wrongId => reverted, "a hook for a foreign market id reverts");
}

// MC-RV-03: While the controller is paused, every core action on the market fails.
rule rvMcOnRevertsWhenPaused(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;

    on@withrevert(e, id, ev, data);
    bool reverted = lastReverted;

    assert(paused => reverted, "a paused controller reverts every hooked action");
}

// MC-RV-04: The controller blocks a lender withdrawal or interest accrual exactly when the caller, market or pause check rejects it.
rule rvMcOnPassiveEventRevertsIff(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.HookEvent ev, bytes data) {

    setupLidoLendMarketControllerValidState(e);

    require(ev == ILidoLendMarketController.HookEvent.Withdraw
        || ev == ILidoLendMarketController.HookEvent.AccrueInterest,
        "SCOPE: payload-free events only");
    address core = _Controller.LIDO_LEND(e);
    bool notCore = e.msg.sender != core;
    bool wrongId = id != ghostMcMarketId;
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;

    on@withrevert(e, id, ev, data);
    bool reverted = lastReverted;

    assert(reverted <=> (notCore || wrongId || paused),
        "a payload-free hook reverts iff the caller, id, or pause gate fails");
}

// MC-RV-05: While the market is frozen, every new borrow fails.
rule rvMcOnBorrowRevertsWhenFrozen(env e, LidoLendMarketController.Id id, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    bool frozen = ghostMcIsFrozen;

    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Borrow, data);
    bool reverted = lastReverted;

    assert(frozen => reverted, "a frozen market reverts every new borrow");
}

// MC-RV-06: No settlement proceeds while the riskiest queued borrower is underwater.
rule rvMcOnSettleRevertsOnRootBadDebt(env e, LidoLendMarketController.Id id, bytes data) {

    setupLidoLendMarketControllerValidState(e);
    bool rootBadDebt = hasBadDebt(e);

    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Settle, data);
    bool reverted = lastReverted;

    assert(rootBadDebt => reverted, "no settle may proceed while the queue root is bad debt");
}

// MC-RV-07: Installing an activation config fails exactly when any of its fields falls outside its allowed range.
rule rvMcSetActivationConfigRevertsIff(env e,
    LidoLendMarketController.CollateralActivationConfig cfg) {

    setupLidoLendMarketControllerValidState(e);
    bool invalidConfig = cfg.minActivationDelay == 0
        || cfg.minActivationDelay > cfg.maxActivationDelay
        || to_mathint(cfg.maxActivationDelay) > MAX_DELAY_DURATION_MC_CVL()
        || to_mathint(cfg.activatingLockDuration) > MAX_DELAY_DURATION_MC_CVL()
        || (cfg.maxGuardiansQuorumDelay != 0
            && cfg.maxGuardiansQuorumDelay <= cfg.maxActivationDelay)
        || to_mathint(cfg.maxGuardiansQuorumDelay) > MAX_DELAY_DURATION_MC_CVL()
        || cfg.minActivationAmount == 0
        || cfg.maxDelayInflow == 0
        || cfg.minDepositAmount > cfg.minActivationAmount
        || to_mathint(cfg.delayPerStrike) > MAX_DELAY_DURATION_MC_CVL()
        || to_mathint(cfg.delayPerSuspect) > MAX_DELAY_DURATION_MC_CVL();

    setCollateralActivationConfig@withrevert(e, cfg);
    bool reverted = lastReverted;

    assert(reverted <=> invalidConfig,
        "an activation config is rejected iff a validation guard fires");
}

// MC-RV-08: The manager can always grant instant activation to a caller, even a banned one.
rule rvMcSetInstantActivationEnableNeverReverts(env e, address caller) {

    setupLidoLendMarketControllerValidState(e);

    setInstantActivation@withrevert(e, caller, true);
    bool reverted = lastReverted;

    assert(!reverted, "granting instant activation has no revert path beyond the role gate");
}

// MC-RV-09: The manager can always revoke instant activation, even from a caller that never had it.
rule rvMcSetInstantActivationDisableNeverReverts(env e, address caller) {

    setupLidoLendMarketControllerValidState(e);

    setInstantActivation@withrevert(e, caller, false);
    bool reverted = lastReverted;

    assert(!reverted, "revoking instant activation has no revert path beyond the role gate");
}

// MC-RV-10: The manager can always set the supply cap, including below the assets already supplied.
rule rvMcSetSupplyCapNeverReverts(env e, uint256 cap) {

    setupLidoLendMarketControllerValidState(e);

    setSupplyCap@withrevert(e, cap);
    bool reverted = lastReverted;

    assert(!reverted, "setting the supply cap has no revert path beyond the role gate");
}

// MC-RV-11: Installing a settlement policy fails exactly when either of its percentages exceeds 100 percent.
rule rvMcSetSettlementConfigRevertsIff(env e, LidoLendMarketController.SettlementConfig config) {

    setupLidoLendMarketControllerValidState(e);
    bool outOfRange = to_mathint(config.sliceFloorBps) > BPS_MC_CVL()
        || to_mathint(config.ltvStepBps) > BPS_MC_CVL();

    setSettlementConfig@withrevert(e, config);
    bool reverted = lastReverted;

    assert(reverted <=> outOfRange,
        "a settlement config is rejected iff a bps knob exceeds one hundred percent");
}

// MC-RV-12: Setting a borrower's own settlement target fails exactly when it reaches 100 percent.
rule rvMcSetSettlementLtvRevertsIff(env e, uint256 ltv) {

    setupLidoLendMarketControllerValidState(e);
    bool outOfRange = to_mathint(ltv) >= WAD_MC_CVL();

    setSettlementLtv@withrevert(e, ltv);
    bool reverted = lastReverted;

    assert(reverted <=> outOfRange, "a settlement ltv is rejected iff it reaches WAD");
}

// MC-RV-13: The freezer can always freeze the market, even when it is already frozen.
rule rvMcFreezeNeverReverts(env e) {

    setupLidoLendMarketControllerValidState(e);

    freeze@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "freezing has no revert path beyond the role gate");
}

// MC-RV-14: The unfreezer can always lift a freeze, even while the controller is paused.
rule rvMcUnfreezeNeverReverts(env e) {

    setupLidoLendMarketControllerValidState(e);

    unfreeze@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "unfreezing has no revert path beyond the role gate");
}

// MC-RV-15: Pausing the market fails exactly when it is already paused, the duration is zero, or the clock overflows.
rule rvMcPauseForRevertsIff(env e, uint256 duration) {

    setupLidoLendMarketControllerValidState(e);
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    bool zeroDuration = duration == 0;
    bool overflows = to_mathint(duration) != max_uint256
        && e.block.timestamp + duration > max_uint256;

    pauseFor@withrevert(e, duration);
    bool reverted = lastReverted;

    assert(reverted <=> (paused || zeroDuration || overflows),
        "pausing reverts iff already paused, zero duration, or the resume stamp overflows");
}

// MC-RV-16: Resuming fails exactly when no pause is in force.
rule rvMcResumeRevertsIff(env e) {

    setupLidoLendMarketControllerValidState(e);
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;

    resume@withrevert(e);
    bool reverted = lastReverted;

    assert(reverted <=> !paused, "resuming reverts iff there is nothing to resume");
}

// MC-RV-17: Reading whether the market is paused never fails.
rule rvMcIsPausedNeverReverts(env e) {

    setupLidoLendMarketControllerValidState(e);

    isPaused@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "the pause probe is total");
}

// MC-RV-18: Reading the current level of the collateral inflow throttle never fails.
rule rvMcCurrentInflowNeverReverts(env e) {

    setupLidoLendMarketControllerValidState(e);

    currentInflow@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "the decayed inflow read is total");
}

// MC-RV-19: Quoting the base activation wait for a collateral inflow of any size never fails.
rule rvMcCurrentActivationDelayNeverReverts(env e, uint256 inflowIncrement) {

    setupLidoLendMarketControllerValidState(e);

    currentActivationDelay@withrevert(e, inflowIncrement);
    bool reverted = lastReverted;

    assert(!reverted, "the delay quote is total");
}

// MC-RV-20: Reading how much room is left under the supply cap never fails.
rule rvMcMaxDepositNeverReverts(env e) {

    setupLidoLendMarketControllerValidState(e);

    maxDeposit@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "the deposit cap view is total");
}

// MC-RV-21: Reading how much a lender can withdraw right now never fails.
rule rvMcMaxWithdrawableAssetsNeverReverts(env e, address supplier) {

    setupLidoLendMarketControllerValidState(e);

    maxWithdrawableAssets@withrevert(e, supplier);
    bool reverted = lastReverted;

    assert(!reverted, "the withdrawable limit view is total");
}

// MC-RV-22: Reading a borrower's settlement target and the debt slice it allows never fails while the market oracle answers.
rule rvMcSettlementLtvViewNeverReverts(env e, address borrower) {

    setupLidoLendMarketControllerValidState(e);

    settlementLtv@withrevert(e, borrower);
    bool reverted = lastReverted;

    assert(!reverted, "the settlement ltv view is total");
}

// MC-RV-23: Reading whether the market carries bad debt never fails while the market oracle answers.
rule rvMcHasBadDebtNeverReverts(env e) {

    setupLidoLendMarketControllerValidState(e);

    hasBadDebt@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "the bad debt probe is total");
}

// MC-RV-24: Reading which borrower settles next, and what a given budget could cut, never fails.
rule rvMcNextSettlementBorrowerNeverReverts(env e, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    require(to_mathint(budgetSupplyShares) <= to_mathint(ghostLlCvlTotalSupplyShares),
        "SCOPE: a budget within the market's total supply shares");

    nextSettlementBorrower@withrevert(e, budgetSupplyShares);
    bool reverted = lastReverted;

    assert(!reverted, "the next settlement sizing view is total");
}

// MC-RV-25: Pricing a settlement cut against a borrower within a spendable supply budget never fails.
rule rvMcSettlementForNeverReverts(env e, address borrower, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    require(to_mathint(budgetSupplyShares) <= to_mathint(ghostLlCvlTotalSupplyShares),
        "SCOPE: a budget within the market's total supply shares");

    settlementFor@withrevert(e, borrower, budgetSupplyShares);
    bool reverted = lastReverted;

    assert(!reverted, "the per-borrower settlement sizing view is total");
}

// MC-RV-26: Paging through the settlement queue never fails, even past its end.
rule rvMcSettlementBorrowersNeverReverts(env e, uint256 offset, uint256 maxCount) {

    setupLidoLendMarketControllerValidState(e);
    require(maxCount <= 3,
        "SCOPE: a window within the loop_iter bound");

    settlementBorrowers@withrevert(e, offset, maxCount);
    bool reverted = lastReverted;

    assert(!reverted, "the queue window view is total");
}

// MC-RV-27: Reading a borrower's full position summary never fails while the market oracle answers.
rule rvMcPositionOfNeverReverts(env e, address borrower) {

    setupLidoLendMarketControllerValidState(e);

    requireBucketsWithinCollateral(borrower);

    positionOf@withrevert(e, borrower);
    bool reverted = lastReverted;

    assert(!reverted, "the borrower dashboard view is total");
}

// Typed-payload hook gates: the encoder binds each revert to the decoded payload fields.

// MC-RV-28: A frozen market refuses a collateral withdrawal while the position still carries debt.
rule rvMcOnWithdrawRevertsWhenFrozenWithDebt(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    bool frozenWithDebt = ghostMcIsFrozen
        && ghostLlCvlPosBorrowShares[d.onBehalf] != 0;

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);
    bool reverted = lastReverted;

    assert(frozenWithDebt => reverted, "a freeze blocks a collateral withdraw under open debt");
}

// MC-RV-29: A borrow fails when the guardian has banned its caller, its receiver, or the borrower.
rule rvMcOnBorrowRevertsWhenActorBanned(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.BorrowHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    bool anyBanned = ghostGsCvlBanned[id][d.caller]
        || ghostGsCvlBanned[id][d.receiver]
        || ghostGsCvlBanned[id][d.onBehalf];

    bytes data = _HookEncoder.encodeBorrow(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Borrow, data);
    bool reverted = lastReverted;

    assert(anyBanned => reverted, "a banned actor on any leg blocks the borrow");
}

// MC-RV-30: A borrow fails when it would push the market's borrow shares past the rate ceiling or draw zero assets.
rule rvMcOnBorrowRevertsAboveShareRateCeiling(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.BorrowHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    mathint postAssets = to_mathint(ghostLlCvlTotalBorrowAssets) + to_mathint(d.assets);
    mathint postShares = to_mathint(ghostLlCvlTotalBorrowShares) + to_mathint(d.shares);
    bool rateExceeded = postShares + VIRTUAL_SHARES_MC_CVL()
        > MAX_BORROW_SHARE_RATE_MC_CVL() * (postAssets + VIRTUAL_ASSETS_MC_CVL());

    bytes data = _HookEncoder.encodeBorrow(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Borrow, data);
    bool reverted = lastReverted;

    assert(rateExceeded => reverted, "a borrow past the share-rate ceiling reverts");
    assert(d.assets == 0 => reverted, "a zero-asset borrow reverts in any regime");
}

// MC-RV-31: A borrow fails unless the borrower's borrowable collateral clears the activation minimum and covers the resulting debt.
rule rvMcOnBorrowRevertsAboveActiveCapacity(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.BorrowHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    require(!ghostMcIsFrozen, "SCOPE: an unfrozen market");

    // Dropping only dust bounds the active collateral from above however the timer lands.
    mathint shares = to_mathint(ghostLlCvlPosBorrowShares[d.onBehalf]);
    mathint debtAssets = debtAssetsUpMcCVL(d.onBehalf);
    mathint active = to_mathint(ghostLlCvlPosCollateral[d.onBehalf]) - ghostMcPosDust128[d.onBehalf];
    mathint maxBorrow = maxBorrowMcCVL(active);
    bool exceeds = debtAssets + to_mathint(d.assets) > maxBorrow;
    bool belowFloor = active < ghostMcCfgMinActivationAmount128 && d.assets > 0;

    bytes data = _HookEncoder.encodeBorrow(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Borrow, data);
    bool reverted = lastReverted;

    assert(exceeds => reverted, "a borrow beyond the active collateral capacity reverts");
    assert(belowFloor => reverted, "a sub-floor active position backs no borrow");
}

// MC-RV-32: A borrower cannot withdraw collateral their remaining debt still needs at the market's liquidation threshold.
rule rvMcOnWithdrawRevertsWhenRemainingActiveInsufficient(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    require(!ghostMcIsFrozen, "SCOPE: an unfrozen market");
    requireBucketsWithinCollateral(d.onBehalf);

    // The dust the withdrawal does not consume bounds the surviving active collateral from above.
    mathint w = to_mathint(d.assets);
    mathint dust0 = ghostMcPosDust128[d.onBehalf];
    mathint inactiveAfter = dust0 > w ? dust0 - w : 0;
    mathint activeAfter = to_mathint(ghostLlCvlPosCollateral[d.onBehalf]) - w - inactiveAfter;
    mathint shares = to_mathint(ghostLlCvlPosBorrowShares[d.onBehalf]);
    bool debtUncovered = shares != 0 && debtAssetsUpMcCVL(d.onBehalf) > maxBorrowMcCVL(activeAfter);

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);
    bool reverted = lastReverted;

    assert(debtUncovered => reverted, "a withdraw that strands the debt above capacity reverts");
}

// MC-RV-39: A borrower with no debt cannot withdraw their whole collateral while a fresh supply is still locked.
rule rvMcOnWithdrawCollateralDebtFreeFullExitRevertsUnderLock(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    require(to_mathint(e.block.timestamp) >= ghostMcResumeSinceTimestamp256,
        "SCOPE: the running controller");
    require(ghostLlCvlPosBorrowShares[d.onBehalf] == 0, "SCOPE: the debt-free exit");
    mathint start0 = ghostMcPosActivatingStart40[d.onBehalf];
    require(start0 != 0
            && to_mathint(e.block.timestamp) < start0 + ghostMcCfgActivatingLockDuration40
            && ghostMcPosActivating128[d.onBehalf] > 0,
        "SCOPE: the lock is in force");
    require(to_mathint(e.block.timestamp) < start0 + ghostMcPosActivatingDelay32[d.onBehalf],
        "SCOPE: the lot is not yet due");
    require(to_mathint(d.assets) == to_mathint(ghostLlCvlPosCollateral[d.onBehalf]),
        "SCOPE: the borrower asks for the whole collateral");

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);
    bool reverted = lastReverted;

    assert(reverted, "a full exit under a live lock has no completing path");
}

// MC-RV-33: A settlement can cut only the riskiest queued borrower or one who opted in.
rule rvMcOnSettleIneligibleBorrowerReverts(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SettleHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcSettlementLtv256[d.borrower] == 0, "SCOPE: no personal settlement ltv opt-in");
    require(ghostMcHeapNodesLength < 2 || ghostMcHeapNodeAccount[1] != d.borrower,
        "SCOPE: the borrower is not the queue root");
    require(d.borrowSharesCanceled > 0, "SCOPE: a nonzero cut");

    bytes data = _HookEncoder.encodeSettle(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Settle, data);
    bool reverted = lastReverted;

    assert(reverted, "an ineligible borrower admits no settle cut");
}

// MC-RV-34: A borrower who repays in full leaves the settlement queue.
rule rvMcOnFullRepayRemovesFromQueue(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.RepayHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(to_mathint(d.shares) == to_mathint(ghostLlCvlPosBorrowShares[d.onBehalf]),
        "SCOPE: the full-repay payload");

    bytes data = _HookEncoder.encodeRepay(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Repay, data);

    assert(ghostMcHeapSlot[d.onBehalf] == 0, "a fully repaid borrower leaves the settlement queue");
}

// MC-RV-37: After a partial repay the borrower stays queued exactly while collateral remains.
rule rvMcOnPartialRepayKeepsQueued(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.RepayHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(to_mathint(d.shares) < to_mathint(ghostLlCvlPosBorrowShares[d.onBehalf]),
        "SCOPE: the partial-repay payload");
    mathint collateral = to_mathint(ghostLlCvlPosCollateral[d.onBehalf]);

    bytes data = _HookEncoder.encodeRepay(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Repay, data);
    uint256 slotAfter = ghostMcHeapSlot[d.onBehalf];

    assert(slotAfter != 0 <=> collateral > 0,
        "a partially repaid borrower stays queued exactly while collateral remains");
}

// Permitting direction: what the gates must still let through.

// MC-RV-38: A borrower who repays down to one share can still be the next in line for settlement.
rule rvMcOnRepayDustRootStaysNext(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.RepayHookData d, uint256 budgetSupplyShares) {

    setupLidoLendMarketControllerValidState(e);
    require(to_mathint(d.shares) + 1 == to_mathint(ghostLlCvlPosBorrowShares[d.onBehalf]),
        "SCOPE: the repay leaves a one-share residual");

    bytes data = _HookEncoder.encodeRepay(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.Repay, data);
    address rootAfter; LidoLendMarketController.SettlementSlice sliceAfter;
    rootAfter, sliceAfter = nextSettlementBorrower(e, budgetSupplyShares);

    satisfy(rootAfter == d.onBehalf, "a dust-debt borrower can stay the next settlement target");
}

// MC-RV-35: A banned caller with the instant activation grant can still deposit collateral that is active at once.
rule rvMcOnSupplyCollateralInstantSurvivesCallerBan(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostGsCvlBanned[id][d.caller], "SCOPE: the granted caller is banned");
    require(ghostMcInstantActivationCallers[d.caller], "SCOPE: the caller keeps its instant grant");
    require(!ghostGsCvlBanned[id][d.onBehalf], "SCOPE: a fresh unbanned borrower");
    require(ghostMcPosActivatingStart40[d.onBehalf] == 0, "SCOPE: no activation timer");
    mathint dustBefore = ghostMcPosDust128[d.onBehalf];
    require(dustBefore > 0,
        "SCOPE: standing dust");
    require(to_mathint(d.assets) + dustBefore >= ghostMcCfgMinActivationAmount128,
        "SCOPE: a deposit at or above the activation minimum");
    mathint activatingBefore = ghostMcPosActivating128[d.onBehalf];

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    satisfy(ghostMcPosDust128[d.onBehalf] == dustBefore
            && ghostMcPosActivating128[d.onBehalf] == activatingBefore
            && ghostMcPosActivatingStart40[d.onBehalf] == 0,
        "a banned granted caller's deposit lands active with no timer, leaving the held dust dormant");
}

// MC-RV-36: In a frozen market a caller with the instant activation grant can still deposit collateral that is active at once.
rule rvMcOnSupplyCollateralInstantSurvivesFreeze(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(ghostMcIsFrozen, "SCOPE: the frozen market");
    require(ghostMcInstantActivationCallers[d.caller], "SCOPE: a granted caller");
    require(ghostMcPosActivatingStart40[d.onBehalf] == 0, "SCOPE: no activation timer");
    mathint dustBefore = ghostMcPosDust128[d.onBehalf];
    require(dustBefore > 0,
        "SCOPE: standing dust");
    require(to_mathint(d.assets) + dustBefore >= ghostMcCfgMinActivationAmount128,
        "SCOPE: a deposit at or above the activation minimum");
    mathint activatingBefore = ghostMcPosActivating128[d.onBehalf];

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);

    satisfy(ghostMcPosDust128[d.onBehalf] == dustBefore
            && ghostMcPosActivating128[d.onBehalf] == activatingBefore
            && ghostMcPosActivatingStart40[d.onBehalf] == 0,
        "a frozen market still lands a granted caller's deposit active at once, leaving the held dust dormant");
}

// Typed-payload revert-iff: with a well-formed payload each event admits exactly its own gates.

// MC-RV-40: Only the caller, market and pause checks or the supply cap can stop a lender deposit.
rule rvMcOnSupplyRevertsIff(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyHookData d) {

    setupLidoLendMarketControllerValidState(e);
    bool notCore = e.msg.sender != _Controller.LIDO_LEND(e);
    bool wrongId = id != ghostMcMarketId;
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    bool exceedsCap = ghostMcSupplyCap256 != 0
        && to_mathint(ghostLlCvlTotalSupplyAssets) + to_mathint(d.assets) > ghostMcSupplyCap256;

    bytes data = _HookEncoder.encodeSupply(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Supply, data);
    bool reverted = lastReverted;

    assert(reverted <=> (notCore || wrongId || paused || exceedsCap),
        "a well-formed deposit reverts iff a gate or the cap says so");
}

// MC-RV-41: Only the caller, market and pause checks, the share rate ceiling or repaying more than is owed can stop a repayment.
rule rvMcOnRepayRevertsIff(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.RepayHookData d) {

    setupLidoLendMarketControllerValidState(e);
    bool notCore = e.msg.sender != _Controller.LIDO_LEND(e);
    bool wrongId = id != ghostMcMarketId;
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    bool overRepay = to_mathint(d.shares) > to_mathint(ghostLlCvlPosBorrowShares[d.onBehalf]);

    // A market already over the ceiling is left alone; one still under it may not be carried across.
    mathint tBA = to_mathint(ghostLlCvlTotalBorrowAssets);
    mathint tBS = to_mathint(ghostLlCvlTotalBorrowShares);
    mathint postAssets = tBA > to_mathint(d.assets) ? tBA - to_mathint(d.assets) : 0;
    mathint postShares = tBS > to_mathint(d.shares) ? tBS - to_mathint(d.shares) : 0;
    bool preOver = tBS + VIRTUAL_SHARES_MC_CVL()
        > MAX_BORROW_SHARE_RATE_MC_CVL() * (tBA + VIRTUAL_ASSETS_MC_CVL());
    bool rateBreak = !preOver && postShares + VIRTUAL_SHARES_MC_CVL()
        > MAX_BORROW_SHARE_RATE_MC_CVL() * (postAssets + VIRTUAL_ASSETS_MC_CVL());

    bytes data = _HookEncoder.encodeRepay(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Repay, data);
    bool reverted = lastReverted;

    assert(reverted <=> (notCore || wrongId || paused || rateBreak || overRepay),
        "a well-formed repayment reverts iff a gate fails, it crosses the share-rate ceiling, or it repays more than is owed");
}

// MC-RV-42: Only the caller, market and pause checks or seizing or repaying more than the borrower holds can stop a liquidation.
rule rvMcOnLiquidateRevertsIff(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.LiquidateHookData d) {

    setupLidoLendMarketControllerValidState(e);
    requireBucketsWithinCollateral(d.borrower);
    bool notCore = e.msg.sender != _Controller.LIDO_LEND(e);
    bool wrongId = id != ghostMcMarketId;
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    bool pastPosition = to_mathint(d.repaidShares) > to_mathint(ghostLlCvlPosBorrowShares[d.borrower])
        || to_mathint(d.seizedAssets) > to_mathint(ghostLlCvlPosCollateral[d.borrower]);

    bytes data = _HookEncoder.encodeLiquidate(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Liquidate, data);
    bool reverted = lastReverted;

    assert(reverted <=> (notCore || wrongId || paused || pastPosition),
        "a well-formed liquidation reverts iff a gate fails or the payload outruns the position");
}

// MC-RV-43: Only the caller, market and pause checks, a freeze or ban, the rate ceiling or collateral capacity can stop a borrow.
rule rvMcOnBorrowRevertsIff(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.BorrowHookData d) {

    setupLidoLendMarketControllerValidState(e);
    requireBucketsWithinCollateral(d.onBehalf);
    require(to_mathint(d.shares) <= max_uint128,
        "SCOPE: a share count the core can store in uint128");

    bool notCore = e.msg.sender != _Controller.LIDO_LEND(e);
    bool wrongId = id != ghostMcMarketId;
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    bool zeroAssets = d.assets == 0;
    bool rateExceeded = to_mathint(ghostLlCvlTotalBorrowShares) + to_mathint(d.shares) + VIRTUAL_SHARES_MC_CVL()
        > MAX_BORROW_SHARE_RATE_MC_CVL()
            * (to_mathint(ghostLlCvlTotalBorrowAssets) + to_mathint(d.assets) + VIRTUAL_ASSETS_MC_CVL());
    bool anyBanned = ghostGsCvlBanned[id][d.caller] || ghostGsCvlBanned[id][d.receiver]
        || ghostGsCvlBanned[id][d.onBehalf];

    // The leading sync empties the activating bucket exactly when the lot matures.
    mathint inactive = ghostMcPosDust128[d.onBehalf]
        + (lotMaturesMcCVL(e, d.onBehalf) ? 0 : ghostMcPosActivating128[d.onBehalf]);
    mathint active = to_mathint(ghostLlCvlPosCollateral[d.onBehalf]) - inactive;
    bool overCapacity = debtAssetsUpMcCVL(d.onBehalf) + to_mathint(d.assets) > maxBorrowMcCVL(active);

    bytes data = _HookEncoder.encodeBorrow(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Borrow, data);
    bool reverted = lastReverted;

    assert(reverted <=> (notCore || wrongId || paused || ghostMcIsFrozen || zeroAssets
            || rateExceeded || anyBanned || overCapacity),
        "a well-formed borrow reverts iff a gate fails or the active collateral cannot carry it");
}

// MC-RV-44: Only the usual checks, the deposit floor, unresolved dust or an overfull activating lot can stop a collateral deposit.
rule rvMcOnSupplyCollateralRevertsIff(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SupplyCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    requireBucketsWithinCollateral(d.onBehalf);
    require(to_mathint(d.assets) <= max_uint128,
        "SCOPE: a deposit the core can hold in uint128");

    bool notCore = e.msg.sender != _Controller.LIDO_LEND(e);
    bool wrongId = id != ghostMcMarketId;
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;

    bool instant = ghostMcInstantActivationCallers[d.caller];
    mathint dust = ghostMcPosDust128[d.onBehalf];
    mathint booked = to_mathint(d.assets) + dust;
    bool belowDepositFloor = !instant && to_mathint(d.assets) < ghostMcCfgMinDepositAmount128;
    bool dustUnresolved = !instant && !belowDepositFloor
        && booked < ghostMcCfgMinActivationAmount128 && dust != 0;
    mathint activatingAfterSync = lotMaturesMcCVL(e, d.onBehalf) ? 0 : ghostMcPosActivating128[d.onBehalf];
    bool bucketOverflows = !instant && !belowDepositFloor
        && booked >= ghostMcCfgMinActivationAmount128
        && activatingAfterSync + booked > max_uint128;

    bytes data = _HookEncoder.encodeSupplyCollateral(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.SupplyCollateral, data);
    bool reverted = lastReverted;

    assert(reverted <=> (notCore || wrongId || paused
            || belowDepositFloor || dustUnresolved || bucketOverflows),
        "a deposit reverts iff a gate, the floor, the dust or the lot check fails");
}

// MC-RV-45: Only the usual checks, a freeze with open debt, the position size, the lock or uncovered debt can stop a collateral withdrawal.
rule rvMcOnWithdrawCollateralRevertsIff(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    requireBucketsWithinCollateral(d.onBehalf);

    bool notCore = e.msg.sender != _Controller.LIDO_LEND(e);
    bool wrongId = id != ghostMcMarketId;
    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    mathint shares = to_mathint(ghostLlCvlPosBorrowShares[d.onBehalf]);
    bool frozenWithDebt = ghostMcIsFrozen && shares != 0;

    bool matured = lotMaturesMcCVL(e, d.onBehalf);
    mathint start = matured ? 0 : ghostMcPosActivatingStart40[d.onBehalf];
    mathint activating = matured ? 0 : ghostMcPosActivating128[d.onBehalf];
    mathint w = to_mathint(d.assets);
    mathint dust = ghostMcPosDust128[d.onBehalf];
    mathint held = dust + activating;

    mathint collateral = to_mathint(ghostLlCvlPosCollateral[d.onBehalf]);
    bool pastPosition = w > collateral;
    mathint active = collateral - held;
    bool locked = held != 0 && activating != 0
        && to_mathint(e.block.timestamp) < start + ghostMcCfgActivatingLockDuration40;
    bool lockBlocks = !pastPosition && locked && w > active;
    bool notCleared = !pastPosition && !locked && held != 0 && w < held;
    mathint inactive = locked ? held : 0;
    bool debtUncovered = !pastPosition && !lockBlocks && !notCleared && shares != 0
        && debtAssetsUpMcCVL(d.onBehalf) > maxBorrowMcCVL(collateral - w - inactive);

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);
    bool reverted = lastReverted;

    assert(reverted <=> (notCore || wrongId || paused || frozenWithDebt
            || pastPosition || lockBlocks || notCleared || debtUncovered),
        "a well-formed withdrawal reverts iff a gate, the position bound, the lock or the debt cover says so");
}

// MC-RV-46: Settling the riskiest borrower past their allowed slice fails unless the lender's illiquid supply funds it.
rule rvMcOnSettleRevertsAboveSettleableSupply(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SettleHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    requireBucketsWithinCollateral(d.borrower);

    ILidoLendMarketController.BorrowerPosition dash = positionOf(e, d.borrower);
    mathint tBA = to_mathint(ghostLlCvlTotalBorrowAssets);
    mathint tBS = to_mathint(ghostLlCvlTotalBorrowShares);
    mathint tSA = to_mathint(ghostLlCvlTotalSupplyAssets);
    mathint tSS = to_mathint(ghostLlCvlTotalSupplyShares);
    mathint personalShares = (to_mathint(dash.personalSliceAssets) * (tBS + VIRTUAL_SHARES_MC_CVL()) + tBA)
        / (tBA + VIRTUAL_ASSETS_MC_CVL());
    bool isRoot = ghostMcHeapNodesLength > 1 && ghostMcHeapNodeAccount[1] == d.borrower;

    // The settling lender's supply left over once every idle loan asset in the market is already spoken for.
    mathint ownSupply = to_mathint(ghostLlCvlPosSupplyShares[d.onBehalf]) * (tSA + VIRTUAL_ASSETS_MC_CVL())
        / (tSS + VIRTUAL_SHARES_MC_CVL());
    mathint freeLiquidity = tSA > tBA ? tSA - tBA : 0;
    mathint settleable = ownSupply > freeLiquidity ? ownSupply - freeLiquidity : 0;

    bool aboveTail = isRoot && to_mathint(d.borrowSharesCanceled) > personalShares
        && to_mathint(d.borrowAssetsCanceled) > settleable;

    bytes data = _HookEncoder.encodeSettle(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Settle, data);
    bool reverted = lastReverted;

    assert(aboveTail => reverted,
        "a root cut past the personal allowance must fit the settling lender's illiquid supply tail");
}

// MC-RV-47: Settling fails when the cut would carry a market from under the borrow share rate ceiling to over it.
rule rvMcOnSettleRevertsAcrossShareRateCeiling(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.SettleHookData d) {

    setupLidoLendMarketControllerValidState(e);
    require(id == ghostMcMarketId, "SCOPE: the bound market");

    mathint tBA = to_mathint(ghostLlCvlTotalBorrowAssets);
    mathint tBS = to_mathint(ghostLlCvlTotalBorrowShares);
    // The reduction saturates on both legs: a cut may price one loan asset above the market total.
    mathint postAssets = tBA > to_mathint(d.borrowAssetsCanceled)
        ? tBA - to_mathint(d.borrowAssetsCanceled) : 0;
    mathint postShares = tBS > to_mathint(d.borrowSharesCanceled)
        ? tBS - to_mathint(d.borrowSharesCanceled) : 0;
    bool preOver = tBS + VIRTUAL_SHARES_MC_CVL()
        > MAX_BORROW_SHARE_RATE_MC_CVL() * (tBA + VIRTUAL_ASSETS_MC_CVL());
    bool postOver = postShares + VIRTUAL_SHARES_MC_CVL()
        > MAX_BORROW_SHARE_RATE_MC_CVL() * (postAssets + VIRTUAL_ASSETS_MC_CVL());

    bytes data = _HookEncoder.encodeSettle(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.Settle, data);
    bool reverted = lastReverted;

    assert((!preOver && postOver) => reverted,
        "a settlement cut may not carry the market across the share-rate ceiling");
}

// MC-RV-48: While the activating lock stands, a withdrawal that reaches past the active collateral is refused.
rule rvMcOnWithdrawCollateralRevertsUnderActivatingLock(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    requireBucketsWithinCollateral(d.onBehalf);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    require(to_mathint(e.block.timestamp) >= ghostMcResumeSinceTimestamp256,
        "SCOPE: the running controller");
    require(!ghostMcIsFrozen || ghostLlCvlPosBorrowShares[d.onBehalf] == 0,
        "SCOPE: the freeze gate does not decide this call");
    require(!lotMaturesMcCVL(e, d.onBehalf), "SCOPE: the leading sync leaves the lot standing");

    mathint act0 = ghostMcPosActivating128[d.onBehalf];
    require(act0 != 0
            && to_mathint(e.block.timestamp)
                < ghostMcPosActivatingStart40[d.onBehalf] + ghostMcCfgActivatingLockDuration40,
        "SCOPE: the lock is in force");

    mathint collateral = to_mathint(ghostLlCvlPosCollateral[d.onBehalf]);
    mathint active = collateral - ghostMcPosDust128[d.onBehalf] - act0;
    require(to_mathint(d.assets) <= collateral, "SCOPE: a withdrawal within the position");
    require(to_mathint(d.assets) > active, "SCOPE: the draw reaches past the active collateral");

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);

    assert(lastReverted, "the lock refuses any draw that would touch the inactive holding");
}

// MC-RV-49: Once the lock has elapsed, a withdrawal that leaves any of the inactive holding behind is refused.
rule rvMcOnWithdrawCollateralRevertsWhenInactiveNotCleared(env e, LidoLendMarketController.Id id,
    ILidoLendMarketController.WithdrawCollateralHookData d) {

    setupLidoLendMarketControllerValidState(e);
    requireBucketsWithinCollateral(d.onBehalf);
    require(e.msg.sender == _Controller.LIDO_LEND(e), "SCOPE: the authorized core path");
    require(id == ghostMcMarketId, "SCOPE: the bound market");
    require(to_mathint(e.block.timestamp) >= ghostMcResumeSinceTimestamp256,
        "SCOPE: the running controller");
    require(!ghostMcIsFrozen || ghostLlCvlPosBorrowShares[d.onBehalf] == 0,
        "SCOPE: the freeze gate does not decide this call");
    require(!lotMaturesMcCVL(e, d.onBehalf), "SCOPE: the leading sync leaves the lot standing");

    mathint act0 = ghostMcPosActivating128[d.onBehalf];
    mathint held = ghostMcPosDust128[d.onBehalf] + act0;
    require(act0 == 0
            || to_mathint(e.block.timestamp)
                >= ghostMcPosActivatingStart40[d.onBehalf] + ghostMcCfgActivatingLockDuration40,
        "SCOPE: no lock stands in the way");
    require(held != 0, "SCOPE: the position carries inactive collateral");
    require(to_mathint(d.assets) < held, "SCOPE: the draw falls short of the whole holding");

    bytes data = _HookEncoder.encodeWithdrawCollateral(e, d);
    on@withrevert(e, id, ILidoLendMarketController.HookEvent.WithdrawCollateral, data);

    assert(lastReverted, "an unlocked partial drain of the inactive holding reverts");
}
