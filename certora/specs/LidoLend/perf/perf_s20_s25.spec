// Perf lane for three high level rules, with LidoLend._hook cut to an empty body and _isHealthy NONDET.
// Both cuts only add executions; a counterexample here is re-checked in high_level.conf.

import "../LidoLend_high_level.spec";

methods {
    function LidoLend._isHealthy(LidoLend.MarketParams memory, LidoLend.Id, address)
        internal returns (bool) => NONDET;
    function LidoLend._isHealthy(LidoLend.MarketParams memory, LidoLend.Id, address, uint256)
        internal returns (bool) => NONDET;

    function LidoLend._hook(LidoLend.Id, ILidoLendMarketController.HookEvent, bytes memory)
        internal => perfLlHookNoopCvl();
}

function perfLlHookNoopCvl() { }

use rule hlLlBorrowRepayNoProfit;
use rule hlLlBorrowRepayAnyModeNoProfit;
use rule hlLlLiquidateSocializesAtMostBorrowerDebt;

// Non-vacuity witnesses for the rules above.

rule perfBorrowRepayNoProfitIsReachable(
    env e, LidoLend.MarketParams mp, uint256 borrowAssets, address onBehalf, address receiver, bytes data
) {
    setupLidoLendValidState(e);
    require(e.msg.sender == onBehalf, "SCOPE: a self-service round trip");
    require(receiver == onBehalf, "SCOPE: one address on both legs");

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = borrow(e, mp, borrowAssets, 0, onBehalf, receiver);
    repay(e, mp, 0, retShares, onBehalf, data);

    satisfy true;
}

rule perfBorrowRepayAnyModeNoProfitIsReachable(
    env e, LidoLend.MarketParams mp, uint256 borrowAssetsIn, uint256 borrowSharesIn, address onBehalf,
    address receiver, bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlBorrowShares128[onBehalf] == 0,
        "SCOPE: a debt opened by this round trip");

    uint256 borrowedAssets; uint256 borrowedShares;
    borrowedAssets, borrowedShares = borrow(e, mp, borrowAssetsIn, borrowSharesIn, onBehalf, receiver);
    repay(e, mp, 0, borrowedShares, onBehalf, data);

    satisfy true;
}

rule perfLiquidateSocializesAtMostBorrowerDebtIsReachable(
    env e, LidoLend.MarketParams mp, address borrower, uint256 seizedAssets, uint256 repaidShares,
    bytes data
) {
    setupLidoLendValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: frozen accrual");

    liquidate(e, mp, borrower, seizedAssets, repaidShares, data);

    satisfy true;
}
