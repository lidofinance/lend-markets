// Oracle outage in the core: a ledger of oracle STATICCALLs, and a reverting oracle mock.
// No core invariant is assumed, and the rate model and hook are NONDET: claims cover core code only.

import "../setup/marketParamsLib.spec";

using LidoLend as _Core;
using RevertingOracleMock as _Oracle;

methods {
    // SAFE: injective id ghost; pure, so no call opcode is lost.
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    function _.price() external => DISPATCHER(true);

    // TRUSTED: NONDET, so no havoc clears `down` before a price read.
    function _.borrowRate(LidoLend.MarketParams, LidoLend.Market) external => NONDET;
    function _.on(bytes32, uint8, bytes) external => NONDET;

    function _Core.position(MarketParamsLib.Id, address) external
        returns (uint256, uint128, uint128) envfree;
    function _Oracle.down() external returns (bool) envfree;
}

persistent ghost address ghostOoOracle;
persistent ghost mathint ghostOoReads;

hook STATICCALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength)
    uint rc {
    if (addr == ghostOoOracle) {
        ghostOoReads = ghostOoReads + 1;
    }
}

function setupOracleOutageLedger(LidoLend.MarketParams mp) {
    require(ghostOoReads == 0,
        "SAFE: the ledger starts empty at the top of a call");
    ghostOoOracle = mp.oracle;
    require(mp.oracle != 0 && mp.oracle != currentContract && mp.oracle != mp.loanToken
        && mp.oracle != mp.collateralToken && mp.oracle != mp.irm,
        "TRUSTED: the oracle is not the core, a token or the rate model");
}

function requireOracleIsDown(LidoLend.MarketParams mp) {
    require(mp.oracle == _Oracle,
        "SCOPE: the market's oracle is the scene's reverting mock");
    require(_Oracle.down(),
        "SCOPE: the oracle is down and reverts on every call");
}

function borrowSharesOf(LidoLend.MarketParams mp, address who) returns uint128 {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
    supplyShares, borrowShares, collateral = _Core.position(summaryMarketParamsId(mp), who);
    return borrowShares;
}

// LL-OO-01: A lender withdrawal never reaches the market oracle on any of the core's own paths.
rule ooLlWithdrawNeverReadsTheOracle(env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares,
    address onBehalf, address receiver) {

    setupOracleOutageLedger(mp);

    withdraw(e, mp, assets, shares, onBehalf, receiver);

    assert(ghostOoReads == 0, "a lender withdrawal never reads the market oracle");
}

// LL-OO-02: A debt repayment never reaches the market oracle on any of the core's own paths.
rule ooLlRepayNeverReadsTheOracle(env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares,
    address onBehalf, bytes data) {

    setupOracleOutageLedger(mp);

    repay(e, mp, assets, shares, onBehalf, data);

    assert(ghostOoReads == 0, "a repayment never reads the market oracle");
}

// LL-OO-03: A debt free collateral withdrawal never reaches the market oracle.
rule ooLlDebtFreeWithdrawCollateralNeverReadsTheOracle(env e, LidoLend.MarketParams mp, uint256 assets,
    address onBehalf, address receiver) {

    setupOracleOutageLedger(mp);
    require(borrowSharesOf(mp, onBehalf) == 0, "SCOPE: a position with no debt");

    withdrawCollateral(e, mp, assets, onBehalf, receiver);

    assert(ghostOoReads == 0, "a debt free collateral withdrawal never reads the market oracle");
}

// LL-OO-04: A supply of loan assets never reaches the market oracle on any of the core's own paths.
rule ooLlSupplyNeverReadsTheOracle(env e, LidoLend.MarketParams mp, uint256 assets, uint256 shares,
    address onBehalf, bytes data) {

    setupOracleOutageLedger(mp);

    supply(e, mp, assets, shares, onBehalf, data);

    assert(ghostOoReads == 0, "a supply of loan assets never reads the market oracle");
}

// LL-OO-05: A collateral supply never reaches the market oracle on any of the core's own paths.
rule ooLlSupplyCollateralNeverReadsTheOracle(env e, LidoLend.MarketParams mp, uint256 assets,
    address onBehalf, bytes data) {

    setupOracleOutageLedger(mp);

    supplyCollateral(e, mp, assets, onBehalf, data);

    assert(ghostOoReads == 0, "a collateral supply never reads the market oracle");
}

// LL-OO-06: A lender can withdraw assets while the market oracle reverts on every call.
rule ooLlWithdrawCanLandWhileTheOracleReverts(env e, LidoLend.MarketParams mp, uint256 assets,
    address onBehalf, address receiver) {

    requireOracleIsDown(mp);

    withdraw@withrevert(e, mp, assets, 0, onBehalf, receiver);

    satisfy(!lastReverted && assets > 0,
        "a nonzero lender withdrawal completes with the oracle down");
}

// LL-OO-07: A borrower can repay debt while the market oracle reverts on every call.
rule ooLlRepayCanLandWhileTheOracleReverts(env e, LidoLend.MarketParams mp, uint256 assets,
    address onBehalf, bytes data) {

    requireOracleIsDown(mp);

    repay@withrevert(e, mp, assets, 0, onBehalf, data);

    satisfy(!lastReverted && assets > 0,
        "a nonzero repayment completes with the oracle down");
}

// LL-OO-08: A debt free borrower can withdraw collateral while the oracle reverts.
rule ooLlDebtFreeWithdrawCollateralCanLandWhileTheOracleReverts(env e, LidoLend.MarketParams mp,
    uint256 assets, address onBehalf, address receiver) {

    requireOracleIsDown(mp);
    require(borrowSharesOf(mp, onBehalf) == 0, "SCOPE: a position with no debt");

    withdrawCollateral@withrevert(e, mp, assets, onBehalf, receiver);

    satisfy(!lastReverted && assets > 0,
        "a nonzero debt free collateral exit completes with the oracle down");
}

// LL-OO-09: A borrow always fails while the market oracle reverts on every call.
rule ooLlBorrowAlwaysFailsWhileTheOracleReverts(env e, LidoLend.MarketParams mp, uint256 assets,
    uint256 shares, address onBehalf, address receiver) {

    requireOracleIsDown(mp);

    borrow@withrevert(e, mp, assets, shares, onBehalf, receiver);

    assert(lastReverted, "a borrow never completes with the oracle down");
}

// LL-OO-10: A collateral withdrawal that leaves debt fails while the oracle reverts.
rule ooLlIndebtedWithdrawCollateralAlwaysFailsWhileTheOracleReverts(env e, LidoLend.MarketParams mp,
    uint256 assets, address onBehalf, address receiver) {

    requireOracleIsDown(mp);
    require(borrowSharesOf(mp, onBehalf) != 0, "SCOPE: a position with debt outstanding");

    withdrawCollateral@withrevert(e, mp, assets, onBehalf, receiver);

    assert(lastReverted, "an indebted collateral withdrawal never completes with the oracle down");
}

// LL-OO-11: A liquidation always fails while the market oracle reverts on every call.
rule ooLlLiquidateAlwaysFailsWhileTheOracleReverts(env e, LidoLend.MarketParams mp, address borrower,
    uint256 seizedAssets, uint256 repaidShares, bytes data) {

    requireOracleIsDown(mp);

    liquidate@withrevert(e, mp, borrower, seizedAssets, repaidShares, data);

    assert(lastReverted, "a liquidation never completes with the oracle down");
}

// LL-OO-12: A settlement always fails while the market oracle reverts on every call.
rule ooLlSettleAlwaysFailsWhileTheOracleReverts(env e, LidoLend.MarketParams mp, uint256 borrowShares,
    address onBehalf, address borrower, address receiver) {

    requireOracleIsDown(mp);

    settle@withrevert(e, mp, borrowShares, onBehalf, borrower, receiver);

    assert(lastReverted, "a settlement never completes with the oracle down");
}

// LL-OO-13: A borrow can complete while the oracle answers, with the read recorded.
rule ooLlBorrowCanCompleteAndReadTheOracleWhileItAnswers(env e, LidoLend.MarketParams mp, uint256 assets,
    address onBehalf, address receiver) {

    setupOracleOutageLedger(mp);
    require(mp.oracle == _Oracle,
        "SCOPE: the market's oracle is the scene's reverting mock");
    require(!_Oracle.down(), "SCOPE: the oracle is up and answers every call");

    borrow@withrevert(e, mp, assets, 0, onBehalf, receiver);

    satisfy(!lastReverted && ghostOoReads >= 1,
        "a borrow completes with the oracle answering and the read recorded");
}
