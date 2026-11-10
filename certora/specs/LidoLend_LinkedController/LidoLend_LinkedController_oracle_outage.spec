// Oracle outage, both contracts real: withdraw, plain repay, debt free collateral exit and quotes read no oracle.
// price() is summarized: the rows show the oracle is never called, not how a reverting feed behaves.

import "LidoLend_LinkedController_valid_state.spec";

persistent ghost mathint ghostOoLwcOracleReads;

hook STATICCALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength)
    uint rc {

    if (addr == ghostLlOracle) {
        ghostOoLwcOracleReads = ghostOoLwcOracleReads + 1;
    }
}

function setupOoLwcOracleLedger(env e) {
    setupLidoLend_LinkedControllerValidState(e);
    require(ghostOoLwcOracleReads == 0, "SAFE: the ledger starts empty at the top of a call");
    require(ghostLlOracle != 0 && ghostLlOracle != _Core && ghostLlOracle != _Controller
            && ghostLlOracle != ghostMcGuardianSignals && ghostLlOracle != ghostLlIrm
            && ghostLlOracle != ghostLlLoanToken && ghostLlOracle != ghostLlCollateralToken,
        "TRUSTED: the oracle is no other scene contract");
}

// --- oracle_outage ---

// CL-OO-01: A lender withdrawal through the real controller never reads the market oracle.
rule ooLwcWithdrawReadsNoOracle(env e, LidoLend.MarketParams p, uint256 assets, uint256 shares,
    address onBehalf, address receiver) {

    setupOoLwcOracleLedger(e);

    _Core.withdraw(e, p, assets, shares, onBehalf, receiver);

    assert(ghostOoLwcOracleReads == 0,
        "a lender's withdrawal never reads the market oracle");
}

// CL-OO-02: A repay with no callback through the real controller never reads the market oracle.
rule ooLwcRepayReadsNoOracle(env e, LidoLend.MarketParams p, uint256 assets, uint256 shares,
    address onBehalf, bytes data) {

    setupOoLwcOracleLedger(e);
    require(data.length == 0, "SCOPE: no repay callback");

    _Core.repay(e, p, assets, shares, onBehalf, data);

    assert(ghostOoLwcOracleReads == 0,
        "a repay with no callback never reads the market oracle");
}

// CL-OO-03: A debt free collateral exit through the real controller reads no oracle.
rule ooLwcDebtFreeCollateralExitReadsNoOracle(env e, LidoLend.MarketParams p, uint256 assets,
    address onBehalf, address receiver) {

    setupOoLwcOracleLedger(e);
    require(ghostLlBorrowShares128[onBehalf] == 0, "SCOPE: the borrower carries no debt");

    _Core.withdrawCollateral(e, p, assets, onBehalf, receiver);

    assert(ghostOoLwcOracleReads == 0,
        "a collateral exit with no debt never reads the market oracle");
}

// CL-OO-04: A collateral exit with debt can read the oracle in the controller and in the core.
rule ooLwcDebtBearingCollateralExitReadsTheOracleTwice(env e, LidoLend.MarketParams p, uint256 assets,
    address onBehalf, address receiver) {

    setupOoLwcOracleLedger(e);
    require(ghostLlBorrowShares128[onBehalf] != 0, "SCOPE: the borrower still carries debt");

    _Core.withdrawCollateral(e, p, assets, onBehalf, receiver);

    satisfy(ghostOoLwcOracleReads == 2,
        "an exit with open debt reads the oracle twice, once per contract");
}

// CL-OO-05: The quoted withdrawable amount is produced without reading the market oracle.
rule ooLwcMaxWithdrawableQuoteReadsNoOracle(env e, address supplier) {

    setupOoLwcOracleLedger(e);

    _Controller.maxWithdrawableAssets(e, supplier);

    assert(ghostOoLwcOracleReads == 0,
        "the withdrawable quote never reads the market oracle");
}

// CL-OO-06: The quoted deposit room is produced without reading the market oracle.
rule ooLwcMaxDepositQuoteReadsNoOracle(env e) {

    setupOoLwcOracleLedger(e);

    _Controller.maxDeposit(e);

    assert(ghostOoLwcOracleReads == 0,
        "the deposit room quote never reads the market oracle");
}
