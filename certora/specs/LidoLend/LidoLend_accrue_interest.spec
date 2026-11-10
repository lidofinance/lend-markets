// Each rule runs an operation with and without an explicit accrueInterest before it, from one
// snapshot, and compares storage.

import "../setup/LidoLend/LidoLend_accrual.spec";

// LL-AI-01: Supplying already brings interest current first, so accruing beforehand changes nothing.
rule aiLlSupplyAccrualIdempotent(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    supply(e, mp, assets, shares, onBehalf, data);
    storage afterBoth = lastStorage;

    supply(e, mp, assets, shares, onBehalf, data) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne, "supply after explicit accrual must end in the same storage");
}

// LL-AI-02: Withdrawing already brings interest current first, so accruing beforehand changes nothing.
rule aiLlWithdrawAccrualIdempotent(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    withdraw(e, mp, assets, shares, onBehalf, receiver);
    storage afterBoth = lastStorage;

    withdraw(e, mp, assets, shares, onBehalf, receiver) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne, "withdraw after explicit accrual must end in the same storage");
}

// LL-AI-03: Borrowing already brings interest current first, so accruing beforehand changes nothing.
rule aiLlBorrowAccrualIdempotent(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, address receiver
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    borrow(e, mp, assets, shares, onBehalf, receiver);
    storage afterBoth = lastStorage;

    borrow(e, mp, assets, shares, onBehalf, receiver) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne, "borrow after explicit accrual must end in the same storage");
}

// LL-AI-04: Repaying already brings interest current first, so accruing beforehand changes nothing.
rule aiLlRepayAccrualIdempotent(
    env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares, address onBehalf, bytes data
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    repay(e, mp, assets, shares, onBehalf, data);
    storage afterBoth = lastStorage;

    repay(e, mp, assets, shares, onBehalf, data) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne, "repay after explicit accrual must end in the same storage");
}

// LL-AI-05: Changing a market fee brings interest current at the old fee first, so accruing beforehand changes nothing.
rule aiLlSetFeeAccrualIdempotent(env e, LidoLend.MarketParams mp, uint256 newFee) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    setFee(e, mp, newFee);
    storage afterBoth = lastStorage;

    setFee(e, mp, newFee) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne, "setFee after explicit accrual must end in the same storage");
}

// LL-AI-06: Withdrawing collateral brings interest current first, so accruing beforehand changes nothing.
rule aiLlWithdrawCollateralAccrualIdempotent(
    env e, LidoLend.MarketParams mp, uint256 assets, address onBehalf, address receiver
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    withdrawCollateral(e, mp, assets, onBehalf, receiver);
    storage afterBoth = lastStorage;

    withdrawCollateral(e, mp, assets, onBehalf, receiver) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne, "withdrawCollateral after explicit accrual must end in the same storage");
}

// LL-AI-07: Settling a position already brings interest current first, so accruing beforehand changes nothing.
rule aiLlSettleAccrualIdempotent(
    env e, LidoLend.MarketParams mp, uint256 borrowShares, address onBehalf,
    address borrower, address receiver
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    settle(e, mp, borrowShares, onBehalf, borrower, receiver);
    storage afterBoth = lastStorage;

    settle(e, mp, borrowShares, onBehalf, borrower, receiver) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne, "settle after explicit accrual must end in the same storage");
}

// LL-AI-08: Liquidating already brings interest current first, so accruing beforehand changes nothing.
rule aiLlLiquidateAccrualIdempotent(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares,
    bytes data
) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    liquidate(e, mp, borrower, seizedAssets, repaidShares, data);
    storage afterBoth = lastStorage;

    liquidate(e, mp, borrower, seizedAssets, repaidShares, data) at init;
    storage afterOne = lastStorage;

    assert(afterBoth == afterOne, "liquidate after explicit accrual must end in the same storage");
}

// LL-AI-09: Interest accrues at most once per block, so a second accrual changes nothing.
rule aiLlAccrueTwiceIdempotent(env e, LidoLend.MarketParams mp) {
    setupEnv(e);

    storage init = lastStorage;

    accrueInterest(e, mp);
    accrueInterest(e, mp);
    storage afterTwice = lastStorage;

    accrueInterest(e, mp) at init;
    storage afterOnce = lastStorage;

    assert(afterTwice == afterOnce, "a second accrual in the same block must end in the same storage");
}
