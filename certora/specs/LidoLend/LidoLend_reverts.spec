// Most rules state one direction: when a call must fail. The rules phrased "exactly when" are full
// iffs, LL-RV-05 is the one success-side rule, and success witnesses for every mutator live in the
// reachability suite.

import "LidoLend_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// LL-RV-01: Handing over ownership fails exactly when the caller is not the owner or names the current owner.
rule rvLlSetOwnerRevertsIff(env e, address newOwner) {
    setupLidoLendValidState(e);
    bool notOwner = e.msg.sender != ghostLlOwner;
    bool unchanged = newOwner == ghostLlOwner;

    setOwner@withrevert(e, newOwner);
    bool reverted = lastReverted;

    assert(reverted <=> (notOwner || unchanged),
        "setOwner reverts iff the caller is not the owner or the owner is unchanged");
}

// LL-RV-02: Only the owner can change a market's fee.
rule rvLlSetFeeRevertsWhenNotOwner(env e, LidoLend.MarketParams mp, uint256 newFee) {
    setupLidoLendValidState(e);
    bool notOwner = e.msg.sender != ghostLlOwner;

    setFee@withrevert(e, mp, newFee);
    bool reverted = lastReverted;

    assert(notOwner => reverted, "setFee must revert when the caller is not the owner");
}

// LL-RV-03: Setting a market fee to the value it already holds is rejected.
rule rvLlSetFeeRevertsWhenFeeUnchanged(env e, LidoLend.MarketParams mp, uint256 newFee) {
    setupLidoLendValidState(e);
    bool unchanged = to_mathint(newFee) == ghostLlFee128;

    setFee@withrevert(e, mp, newFee);
    bool reverted = lastReverted;

    assert(unchanged => reverted, "setFee must revert when the fee is unchanged");
}

// LL-RV-04: A market fee can never be set above the protocol's hard cap.
rule rvLlSetFeeRevertsWhenAboveMaxFee(env e, LidoLend.MarketParams mp, uint256 newFee) {
    setupLidoLendValidState(e);
    bool aboveCap = to_mathint(newFee) > MAX_FEE_LL_CVL();

    setFee@withrevert(e, mp, newFee);
    bool reverted = lastReverted;

    assert(aboveCap => reverted, "setFee must revert when the new fee exceeds MAX_FEE");
}

// LL-RV-05: The owner can always set a different market fee within the cap.
rule rvLlSetFeeSucceedsOnValidInput(env e, LidoLend.MarketParams mp, uint256 newFee) {
    setupLidoLendValidState(e);
    require(e.msg.sender == ghostLlOwner, "SCOPE: the caller is the owner");
    require(to_mathint(newFee) != ghostLlFee128, "SCOPE: the fee actually changes");
    require(to_mathint(newFee) <= MAX_FEE_LL_CVL(), "SCOPE: the new fee is within the cap");
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: interest already up to date");

    setFee@withrevert(e, mp, newFee);
    bool reverted = lastReverted;

    assert(!reverted, "an owner setFee of a changed capped fee with no-op accrual must succeed");
}

// LL-RV-06: Changing the fee recipient fails exactly when the caller is not the owner or names the current recipient.
rule rvLlSetFeeRecipientRevertsIff(env e, address newFeeRecipient) {
    setupLidoLendValidState(e);
    bool notOwner = e.msg.sender != ghostLlOwner;
    bool unchanged = newFeeRecipient == ghostLlFeeRecipient;

    setFeeRecipient@withrevert(e, newFeeRecipient);
    bool reverted = lastReverted;

    assert(reverted <=> (notOwner || unchanged),
        "setFeeRecipient reverts iff caller is not the owner or recipient is unchanged");
}

// LL-RV-07: A supply must name either an asset amount or a share amount, never both or neither.
rule rvLlSupplyRevertsWhenInconsistentInput(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    bool inconsistent = (assets == 0) == (shares == 0);

    supply@withrevert(e, mp, assets, shares, onBehalf, data);
    bool reverted = lastReverted;

    assert(inconsistent => reverted, "supply must revert unless exactly one input is zero");
}

// LL-RV-08: Nobody can supply on behalf of the zero address.
rule rvLlSupplyRevertsWhenZeroOnBehalf(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    bool zeroOnBehalf = onBehalf == 0;

    supply@withrevert(e, mp, assets, shares, onBehalf, data);
    bool reverted = lastReverted;

    assert(zeroOnBehalf => reverted, "supply must revert when onBehalf is zero");
}

// LL-RV-09: A withdrawal must name either an asset amount or a share amount, never both or neither.
rule rvLlWithdrawRevertsWhenInconsistentInput(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf,
    address receiver
) {
    setupLidoLendValidState(e);
    bool inconsistent = (assets == 0) == (shares == 0);

    withdraw@withrevert(e, mp, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(inconsistent => reverted, "withdraw must revert unless exactly one input is zero");
}

// LL-RV-10: A withdrawal can never pay out to the zero address.
rule rvLlWithdrawRevertsWhenZeroReceiver(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf,
    address receiver
) {
    setupLidoLendValidState(e);
    bool zeroReceiver = receiver == 0;

    withdraw@withrevert(e, mp, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted, "withdraw must revert when the receiver is zero");
}

// LL-RV-11: Only the position holder or an account it authorized can withdraw its supply.
rule rvLlWithdrawRevertsWhenUnauthorized(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf,
    address receiver
) {
    setupLidoLendValidState(e);
    bool unauthorized = e.msg.sender != onBehalf && !ghostLlIsAuthorized[onBehalf][e.msg.sender];

    withdraw@withrevert(e, mp, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "withdraw must revert for an unauthorized caller");
}

// LL-RV-12: A borrow must name either an asset amount or a share amount, never both or neither.
rule rvLlBorrowRevertsWhenInconsistentInput(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf,
    address receiver
) {
    setupLidoLendValidState(e);
    bool inconsistent = (assets == 0) == (shares == 0);

    borrow@withrevert(e, mp, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(inconsistent => reverted, "borrow must revert unless exactly one input is zero");
}

// LL-RV-13: A borrow can never pay out to the zero address.
rule rvLlBorrowRevertsWhenZeroReceiver(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf,
    address receiver
) {
    setupLidoLendValidState(e);
    bool zeroReceiver = receiver == 0;

    borrow@withrevert(e, mp, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted, "borrow must revert when the receiver is zero");
}

// LL-RV-14: Only the position holder or an account it authorized can borrow against it.
rule rvLlBorrowRevertsWhenUnauthorized(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf,
    address receiver
) {
    setupLidoLendValidState(e);
    bool unauthorized = e.msg.sender != onBehalf && !ghostLlIsAuthorized[onBehalf][e.msg.sender];

    borrow@withrevert(e, mp, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "borrow must revert for an unauthorized caller");
}

// LL-RV-15: A repayment must name either an asset amount or a share amount, never both or neither.
rule rvLlRepayRevertsWhenInconsistentInput(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    bool inconsistent = (assets == 0) == (shares == 0);

    repay@withrevert(e, mp, assets, shares, onBehalf, data);
    bool reverted = lastReverted;

    assert(inconsistent => reverted, "repay must revert unless exactly one input is zero");
}

// LL-RV-16: Nobody can repay on behalf of the zero address.
rule rvLlRepayRevertsWhenZeroOnBehalf(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    bool zeroOnBehalf = onBehalf == 0;

    repay@withrevert(e, mp, assets, shares, onBehalf, data);
    bool reverted = lastReverted;

    assert(zeroOnBehalf => reverted, "repay must revert when onBehalf is zero");
}

// LL-RV-17: Posting collateral fails when the amount is zero.
rule rvLlSupplyCollateralRevertsWhenZeroAssets(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    bool zeroAssets = assets == 0;

    supplyCollateral@withrevert(e, mp, assets, onBehalf, data);
    bool reverted = lastReverted;

    assert(zeroAssets => reverted, "supplyCollateral must revert on zero assets");
}

// LL-RV-18: Nobody can post collateral on behalf of the zero address.
rule rvLlSupplyCollateralRevertsWhenZeroOnBehalf(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, bytes data
) {
    setupLidoLendValidState(e);
    bool zeroOnBehalf = onBehalf == 0;

    supplyCollateral@withrevert(e, mp, assets, onBehalf, data);
    bool reverted = lastReverted;

    assert(zeroOnBehalf => reverted, "supplyCollateral must revert when onBehalf is zero");
}

// LL-RV-19: Withdrawing collateral fails when the amount is zero.
rule rvLlWithdrawCollateralRevertsWhenZeroAssets(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    bool zeroAssets = assets == 0;

    withdrawCollateral@withrevert(e, mp, assets, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(zeroAssets => reverted, "withdrawCollateral must revert on zero assets");
}

// LL-RV-20: A collateral withdrawal can never send the collateral to the zero address.
rule rvLlWithdrawCollateralRevertsWhenZeroReceiver(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    bool zeroReceiver = receiver == 0;

    withdrawCollateral@withrevert(e, mp, assets, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted, "withdrawCollateral must revert when the receiver is zero");
}

// LL-RV-21: Only the position holder or an account it authorized can pull its collateral out.
rule rvLlWithdrawCollateralRevertsWhenUnauthorized(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupLidoLendValidState(e);
    bool unauthorized = e.msg.sender != onBehalf && !ghostLlIsAuthorized[onBehalf][e.msg.sender];

    withdrawCollateral@withrevert(e, mp, assets, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "withdrawCollateral must revert for an unauthorized caller");
}

// LL-RV-22: A market that has not enabled settlement can never be settled.
rule rvLlSettleRevertsWhenSettlementDisabled(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    bool settlementDisabled = !ghostLlIsSettlementEnabled;

    settle@withrevert(e, mp, borrowShares, onBehalf, borrower, receiver);
    bool reverted = lastReverted;

    assert(settlementDisabled => reverted, "settle must revert when settlement is disabled");
}

// LL-RV-23: A settlement can never send the seized collateral to the zero address.
rule rvLlSettleRevertsWhenZeroReceiver(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    bool zeroReceiver = receiver == 0;

    settle@withrevert(e, mp, borrowShares, onBehalf, borrower, receiver);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted, "settle must revert when the receiver is zero");
}

// LL-RV-24: Only the position holder or an account it authorized can settle on its behalf.
rule rvLlSettleRevertsWhenUnauthorized(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    bool unauthorized = e.msg.sender != onBehalf && !ghostLlIsAuthorized[onBehalf][e.msg.sender];

    settle@withrevert(e, mp, borrowShares, onBehalf, borrower, receiver);
    bool reverted = lastReverted;

    assert(unauthorized => reverted, "settle must revert for an unauthorized caller");
}

// LL-RV-25: Cancelling a borrower's debt fails when the account absorbing the loss holds no supply.
rule rvLlSettleRevertsOnBorrowAnchoredNoSupply(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    require(onBehalf != ghostLlFeeRecipient,
        "SCOPE: onBehalf is not the fee recipient");
    bool noSupplyPosition = ghostLlSupplyShares256[onBehalf] == 0;

    settle@withrevert(e, mp, borrowShares, onBehalf, borrower, receiver);
    bool reverted = lastReverted;

    assert(noSupplyPosition => reverted,
        "borrow-anchored settle must revert when onBehalf holds no supply shares");
}

// LL-RV-26: A settlement can never cancel more debt than the borrower actually owes.
rule rvLlSettleRevertsWhenBorrowAnchoredExceedsDebt(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);
    bool exceedsDebt = to_mathint(borrowShares) > ghostLlBorrowShares128[borrower];

    settle@withrevert(e, mp, borrowShares, onBehalf, borrower, receiver);
    bool reverted = lastReverted;

    assert(exceedsDebt => reverted,
        "borrow-anchored settle must revert when the cancel exceeds the borrower's debt");
}

// LL-RV-27: A liquidation must name either the collateral to seize or the debt shares to repay, never both or neither.
rule rvLlLiquidateRevertsWhenInconsistentInput(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets,
    uint256 repaidShares, bytes data
) {
    setupLidoLendValidState(e);
    bool inconsistent = (seizedAssets == 0) == (repaidShares == 0);

    liquidate@withrevert(e, mp, borrower, seizedAssets, repaidShares, data);
    bool reverted = lastReverted;

    assert(inconsistent => reverted, "liquidate must revert unless exactly one input is zero");
}

// LL-RV-28: A flash loan fails exactly when it asks for a zero amount.
rule rvLlFlashLoanRevertsIff(env e, address token, uint256 assets, bytes data) {
    setupLidoLendValidState(e);
    bool zeroAssets = assets == 0;

    flashLoan@withrevert(e, token, assets, data);
    bool reverted = lastReverted;

    assert(reverted <=> zeroAssets, "flashLoan reverts iff assets is zero");
}

// LL-RV-29: Granting or revoking an authorization fails exactly when it would not change the current permission.
rule rvLlSetAuthorizationRevertsIff(env e, address authorized, bool newIsAuthorized) {
    setupLidoLendValidState(e);
    bool unchanged = newIsAuthorized == ghostLlIsAuthorized[e.msg.sender][authorized];

    setAuthorization@withrevert(e, authorized, newIsAuthorized);
    bool reverted = lastReverted;

    assert(reverted <=> unchanged, "setAuthorization reverts iff the flag is unchanged");
}

// LL-RV-30: Accruing interest fails while one of the market's controller hooks is still running.
rule rvLlAccrueInterestRevertsWhenHookInProgress(env e, LidoLend.MarketParams mp) {
    setupLidoLendValidState(e);
    bool lockHeld = _Core._hookInProgress;

    accrueInterest@withrevert(e, mp);
    bool reverted = lastReverted;

    assert(lockHeld => reverted, "accrueInterest must revert while a hook is in flight");
}

// LL-RV-31: A settlement that cancels no debt shares is refused.
rule rvLlSettleRevertsOnZeroSlice(
    env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver
) {
    setupLidoLendValidState(e);

    settle@withrevert(e, mp, borrowShares, onBehalf, borrower, receiver);
    bool reverted = lastReverted;

    assert(borrowShares == 0 => reverted,
        "a settle that cancels no debt shares is refused");
}

definition HOOKED_CORE_MUTATOR_LL(method f) returns bool =
    f.selector == sig:supply(LidoLend.MarketParams,uint256,uint256,address,bytes).selector
    || f.selector == sig:withdraw(LidoLend.MarketParams,uint256,uint256,address,address).selector
    || f.selector == sig:borrow(LidoLend.MarketParams,uint256,uint256,address,address).selector
    || f.selector == sig:repay(LidoLend.MarketParams,uint256,uint256,address,bytes).selector
    || f.selector == sig:supplyCollateral(LidoLend.MarketParams,uint256,address,bytes).selector
    || f.selector
        == sig:withdrawCollateral(LidoLend.MarketParams,uint256,address,address).selector
    || f.selector == sig:settle(LidoLend.MarketParams,uint256,address,address,address).selector
    || f.selector == sig:liquidate(LidoLend.MarketParams,address,uint256,uint256,bytes).selector
    || f.selector == sig:accrueInterest(LidoLend.MarketParams).selector
    ;

// LL-RE-01: A controlled market refuses every hooked action while one of those hooks is running.
rule reLlHookedActionsRevertWhileHookInProgress(env e, method f, calldataarg args)
    filtered { f -> HOOKED_CORE_MUTATOR_LL(f) } {

    setupLidoLendValidState(e);
    require(ghostLlMarketController != 0,
        "SCOPE: the acting market has a controller");
    bool lockHeld = _Core._hookInProgress;

    f@withrevert(e, args);
    bool reverted = lastReverted;

    assert(lockHeld => reverted, "every hooked action must fail while a hook is in flight");
}

// LL-RE-02: The gate is read before the market's controller, so a market without one is refused too.
rule reLlHooklessMarketActionRevertsWhileHookInProgress(env e, method f, calldataarg args)
    filtered { f -> HOOKED_CORE_MUTATOR_LL(f) } {

    setupLidoLendValidState(e);
    require(ghostLlMarketController == 0,
        "SCOPE: a market with no controller");
    bool lockHeld = _Core._hookInProgress;

    f@withrevert(e, args);
    bool reverted = lastReverted;

    assert(lockHeld => reverted,
        "a market with no controller is refused while a hook is in flight");
}

// LL-RE-03: A call that begins with the hook latch down always returns with it down.
rule reLlHookLatchClearedByReturn(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLendValidState(e);
    require(!_Core._hookInProgress,
        "SCOPE: a top level call starts with the hook latch clear");

    f(e, args);

    assert(!_Core._hookInProgress,
        "a call that starts with the latch clear may not leave it held");
}
