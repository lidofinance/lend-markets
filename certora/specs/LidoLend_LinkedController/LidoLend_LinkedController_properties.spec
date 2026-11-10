// Properties of the linked pair: both contracts run their real bytecode, neither is a stub of the other.

import "LidoLend_LinkedController_valid_state.spec";

// --- high_level ---

// CL-HL-01: A collateral deposit is credited in full and stays inactive unless the depositor is trusted.
rule hlLwcSupplyCollateralCreditMatchesCoreDelta(env e, LidoLend.MarketParams p, uint256 assets, address b,
    bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(data.length == 0, "SCOPE: no supply-collateral callback");

    mathint buckets0 = ghostMcPosActivating128[b] + ghostMcPosDust128[b];
    mathint coll0 = ghostLlCollateral128[b];
    bool instant = ghostMcInstantActivationCallers[e.msg.sender];
    bool noMaturation = ghostMcIsFrozen || ghostMcPosActivatingStart40[b] == 0
        || to_mathint(e.block.timestamp) < ghostMcPosActivatingStart40[b] + ghostMcPosActivatingDelay32[b];

    _Core.supplyCollateral(e, p, assets, b, data);

    mathint collDelta = ghostLlCollateral128[b] - coll0;
    mathint bucketsDelta = ghostMcPosActivating128[b] + ghostMcPosDust128[b] - buckets0;

    assert(collDelta == to_mathint(assets),
        "core credits the deposit to the borrower's raw collateral");
    assert(bucketsDelta <= collDelta,
        "a deposit never inflates the inactive buckets past the raw credit");
    assert((!instant && noMaturation) => bucketsDelta == collDelta,
        "a throttled deposit lands wholly inactive");
    assert((instant && noMaturation) => bucketsDelta == 0,
        "a trusted caller's deposit lands active at any size, and the dust already held stays dormant");
}

// CL-HL-02: A liquidation spends a borrower's active collateral first, and drains the inactive buckets only by what the active balance could not cover.
rule hlLwcLiquidateSeizureDrainsBucketsExactly(env e, LidoLend.MarketParams p, address borrower,
    uint256 seizedAssets, uint256 repaidShares, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(data.length == 0, "SCOPE: no liquidate callback");

    mathint buckets0 = ghostMcPosActivating128[borrower] + ghostMcPosDust128[borrower];
    mathint coll0 = ghostLlCollateral128[borrower];

    _Core.liquidate(e, p, borrower, seizedAssets, repaidShares, data);

    mathint seized = coll0 - ghostLlCollateral128[borrower];
    mathint buckets1 = ghostMcPosActivating128[borrower] + ghostMcPosDust128[borrower];
    mathint active0 = coll0 - buckets0;
    mathint uncovered = seized > active0 ? seized - active0 : 0;

    assert(buckets1 == buckets0 - uncovered,
        "a seizure drains the buckets by exactly the uncovered amount");
}

// CL-HL-03: A settlement spends a borrower's active collateral first, and drains the inactive buckets only by what the active balance could not cover.
rule hlLwcSettleSeizureDrainsBucketsExactly(env e, LidoLend.MarketParams p,
    uint256 borrowShares, address onBehalf, address borrower, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);

    mathint buckets0 = ghostMcPosActivating128[borrower] + ghostMcPosDust128[borrower];
    mathint coll0 = ghostLlCollateral128[borrower];

    _Core.settle(e, p, borrowShares, onBehalf, borrower, receiver);

    mathint seized = coll0 - ghostLlCollateral128[borrower];
    mathint buckets1 = ghostMcPosActivating128[borrower] + ghostMcPosDust128[borrower];
    mathint active0 = coll0 - buckets0;
    mathint uncovered = seized > active0 ? seized - active0 : 0;

    assert(buckets1 == buckets0 - uncovered,
        "a settlement drains the buckets by exactly the uncovered amount");
}

// CL-HL-04: A borrow leaves the debt covered by matured collateral at the market's liquidation threshold.
rule hlLwcBorrowLeavesDebtCoveredByActiveCollateral(env e, LidoLend.MarketParams p, uint256 assets,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL()
            <= ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL(),
        "SCOPE: at most one loan asset per borrow share");

    mathint sharesPre = ghostLlBorrowShares128[onBehalf];
    mathint totalBorrowAssetsPre = ghostLlTotalBorrowAssets128;
    mathint totalBorrowSharesPre = ghostLlTotalBorrowShares128;

    _Core.borrow(e, p, assets, 0, onBehalf, receiver);

    mathint active = clActiveCollateralCVL(onBehalf);

    assert(clDebtAssetsCVL(sharesPre, totalBorrowAssetsPre, totalBorrowSharesPre) + to_mathint(assets)
            <= clMaxBorrowCVL(active),
        "standing debt plus the new draw fits the ACTIVE collateral at LLTV");
    assert(clDebtAssetsCVL(ghostLlBorrowShares128[onBehalf], ghostLlTotalBorrowAssets128,
                ghostLlTotalBorrowShares128)
            <= clMaxBorrowCVL(active) + 1,
        "the settled debt stays covered by ACTIVE collateral at LLTV, up to round-up");
}

// CL-HL-05: The quoted deposit headroom is the real room left under the supply cap, zero while paused.
rule hlLwcMaxDepositQuoteMatchesCoreHeadroom(env e) {

    setupLidoLend_LinkedControllerValidState(e);

    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp)
        || ghostLlTotalBorrowAssets128 == 0 || ghostLlIrm == 0,
        "SCOPE: no interest pending");

    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    mathint cap = ghostMcSupplyCap256;
    mathint supplied = ghostLlTotalSupplyAssets128;

    uint256 quote = _Controller.maxDeposit(e);

    assert(paused => quote == 0, "a paused market quotes no headroom at all");
    assert((!paused && cap == 0) => to_mathint(quote) == max_uint256,
        "an unset cap quotes unbounded headroom");
    assert((!paused && cap != 0) => to_mathint(quote) == (cap > supplied ? cap - supplied : 0),
        "a live cap quotes the core's supplied-assets headroom, saturating at zero");
}

// CL-HL-06: The market never refuses a deposit of exactly the headroom it quotes.
rule hlLwcMaxDepositIsSuppliableEndToEnd(env e, LidoLend.MarketParams p, address onBehalf, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(!_Core._hookInProgress,
        "SCOPE: no controller hook in progress");
    require(data.length == 0, "SCOPE: no supply callback");
    require(ghostMcSupplyCap256 <= max_uint128,
        "SCOPE: a supply cap the core's uint128 counter can hold");

    uint256 q = _Controller.maxDeposit(e);
    require(q != 0 && to_mathint(q) != max_uint256,
        "SCOPE: a live, finite quote");

    mathint sharesQ = to_mathint(q) * (ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL())
        / (ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL());
    require(ghostLlTotalSupplyShares128 + sharesQ <= max_uint128,
        "SCOPE: uint128 share-counter headroom");

    address token = ghostLlLoanToken;
    require(ERC20_ACCOUNT_BOUNDS(token, e.msg.sender) && ERC20_ACCOUNT_BOUNDS(token, _Core)
            && ERC20_ACCOUNT_BOUNDS(token, onBehalf),
        "SCOPE: depositor, core and credited holder in the bounded account set");
    require(ghostERC20Balances128[token][_Core] + to_mathint(q) <= max_uint128,
        "SCOPE: uint128 balance headroom on the core's custody account");

    _Core.supply@withrevert(e, p, q, 0, onBehalf, data);

    assert(!lastReverted, "the deposit the controller quotes is one the core accepts");
}

// CL-HL-07: The quoted withdrawable amount is the lender's own assets capped by idle liquidity, zero while paused.
rule hlLwcMaxWithdrawableQuoteMatchesCoreFormula(env e, address supplier) {

    setupLidoLend_LinkedControllerValidState(e);

    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp)
        || ghostLlTotalBorrowAssets128 == 0 || ghostLlIrm == 0,
        "SCOPE: no interest pending");

    bool paused = to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256;
    mathint own = clSupplyAssetsCVL(ghostLlSupplyShares256[supplier], ghostLlTotalSupplyAssets128,
        ghostLlTotalSupplyShares128);
    mathint free = ghostLlTotalSupplyAssets128 > ghostLlTotalBorrowAssets128
        ? ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128
        : 0;

    uint256 quote = _Controller.maxWithdrawableAssets(e, supplier);

    assert(paused => quote == 0, "a paused market quotes no withdrawable assets at all");
    assert(!paused => to_mathint(quote) == (own < free ? own : free),
        "the quote is the supplier's own assets capped by idle liquidity");
}

// CL-HL-08: The market pays out a withdrawal of exactly the amount it quotes as withdrawable.
rule hlLwcMaxWithdrawableIsWithdrawableEndToEnd(env e, LidoLend.MarketParams p, address supplier,
    address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(!_Core._hookInProgress,
        "SCOPE: no controller hook in progress");
    require(supplier == e.msg.sender,
        "SCOPE: the supplier withdraws its own supply");

    require(ghostLlFee128 == 0,
        "SCOPE: no protocol fee");

    uint256 q = _Controller.maxWithdrawableAssets(e, supplier);
    require(q != 0,
        "SCOPE: a nonzero withdrawable quote");

    address token = ghostLlLoanToken;
    require(ERC20_ACCOUNT_BOUNDS(token, supplier) && ERC20_ACCOUNT_BOUNDS(token, _Core)
            && ERC20_ACCOUNT_BOUNDS(token, receiver),
        "SCOPE: supplier, core and payee in the bounded account set");

    _Core.withdraw@withrevert(e, p, q, 0, supplier, receiver);

    assert(!lastReverted,
        "the withdrawal the controller quotes is one the core pays out, pending interest included");
}

// CL-HL-09: A collateral withdrawal takes exactly the amount asked and keeps an indebted position at the activation minimum or above.
rule hlLwcWithdrawCollateralDebitsCoreAndHoldsActiveFloor(env e, LidoLend.MarketParams p, uint256 assets,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);

    mathint coll0 = ghostLlCollateral128[onBehalf];

    _Core.withdrawCollateral(e, p, assets, onBehalf, receiver);

    assert(coll0 - ghostLlCollateral128[onBehalf] == to_mathint(assets),
        "the core debits the borrower's raw collateral by exactly the amount asked");
    assert(ghostLlBorrowShares128[onBehalf] != 0
            => clActiveCollateralCVL(onBehalf) >= ghostMcCfgMinActivationAmount128,
        "a position left carrying debt keeps at least the activation minimum ACTIVE");
}

// CL-HL-10: A collateral withdrawal leaves the remaining debt covered by matured collateral at the liquidation threshold.
rule hlLwcWithdrawCollateralLeavesDebtCoveredByActiveCollateral(env e, LidoLend.MarketParams p,
    uint256 assets, address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);

    _Core.withdrawCollateral(e, p, assets, onBehalf, receiver);

    assert(clDebtAssetsCVL(ghostLlBorrowShares128[onBehalf], ghostLlTotalBorrowAssets128,
                ghostLlTotalBorrowShares128)
            <= clMaxBorrowCVL(clActiveCollateralCVL(onBehalf)),
        "the surviving debt stays covered by ACTIVE collateral at LLTV");
}

// CL-HL-11: A settlement that takes all the collateral leaves behind less than one loan asset of debt.
rule hlLwcSettleStrandsAtMostSubWeiDebt(env e, LidoLend.MarketParams p,
    uint256 borrowShares, address onBehalf, address borrower, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(borrower == ghostMcHeapNodeAccount[1],
        "SCOPE: the target is the queue root");
    require(ghostMcSetLtvStepBps16 == 0 && ghostMcSettlementLtv256[borrower] == 0,
        "SCOPE: no ltv step and no personal settlement ltv opt-in");

    mathint totalBorrowAssets0 = ghostLlTotalBorrowAssets128;
    mathint totalBorrowShares0 = ghostLlTotalBorrowShares128;

    _Core.settle(e, p, borrowShares, onBehalf, borrower, receiver);

    mathint left = ghostLlBorrowShares128[borrower];

    assert(ghostLlCollateral128[borrower] == 0
            => left * (totalBorrowAssets0 + VIRTUAL_ASSETS_LL_CVL())
                < totalBorrowShares0 + VIRTUAL_SHARES_LL_CVL(),
        "a fully seized position keeps fewer debt shares than one loan asset buys at the pre-cut index");
}

// CL-HL-12: Booking interest does not move a lender's withdrawable quote, which already prices the pending interest.
rule hlLwcMaxWithdrawableQuoteAccrualInvariant(env e, LidoLend.MarketParams p, address supplier) {

    setupLidoLend_LinkedControllerValidState(e);
    require(supplier != ghostLlFeeRecipient,
        "SCOPE: a supplier other than the fee recipient");
    require(ghostLlFee128 == 0 || ERC20_ACCOUNT_BOUNDS(ghostLlLoanToken, ghostLlFeeRecipient),
        "SCOPE: no fee, or a fee recipient in the bounded account set");

    uint256 quoteBefore = _Controller.maxWithdrawableAssets(e, supplier);

    _Core.accrueInterest(e, p);

    assert(_Controller.maxWithdrawableAssets(e, supplier) == quoteBefore,
        "the projection the quote prices by is the accrual the core books");
}

// --- reachability ---

// CL-RC-01: A collateral deposit can land in the activation pipeline that holds it before it counts.
rule rcLwcSupplyCollateralReachesActivation(env e, LidoLend.MarketParams params, uint256 assets,
    address onBehalf, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(data.length == 0, "SCOPE: no supply-collateral callback");

    mathint pipelineBefore = ghostMcPosActivating128[onBehalf] + ghostMcPosDust128[onBehalf];

    _Core.supplyCollateral(e, params, assets, onBehalf, data);

    satisfy(ghostMcPosActivating128[onBehalf] + ghostMcPosDust128[onBehalf] > pipelineBefore,
        "a core collateral deposit books into the controller's activation pipeline");
}

// CL-RC-02: A borrow can enroll the borrower in the settlement queue.
rule rcLwcBorrowInsertsBorrowerIntoHeap(env e, LidoLend.MarketParams params, uint256 assets, uint256 shares,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcHeapNodesLength == 1,
        "SCOPE: an empty queue");
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(shares == 0, "SCOPE: an assets-anchored draw");
    require(to_mathint(ghostOraclePrice256[ghostLlOracle]) == ORACLE_PRICE_SCALE_MC_CVL(),
        "SCOPE: a par oracle price, one collateral unit per loan unit");

    _Core.borrow(e, params, assets, shares, onBehalf, receiver);

    satisfy(ghostMcHeapSlot[onBehalf] != 0,
        "a core borrow inserts the borrower into the controller's settlement queue");
}

// CL-RC-03: A borrower who repays in full can drop out of the settlement queue.
rule rcLwcFullRepayRemovesBorrowerFromHeap(env e, LidoLend.MarketParams params, uint256 assets, uint256 shares,
    address onBehalf, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcHeapSlot[onBehalf] != 0, "SCOPE: the borrower is tracked");
    require(data.length == 0, "SCOPE: no repay callback");

    _Core.repay(e, params, assets, shares, onBehalf, data);

    satisfy(ghostMcHeapSlot[onBehalf] == 0 && ghostLlBorrowShares128[onBehalf] == 0,
        "clearing the debt in core drops the borrower out of the controller's queue");
}

// CL-RC-04: A liquidation can clear a borrower's collateral, debt and queue entry in one call.
rule rcLwcFullSeizureLiquidationClearsHeapAndDebt(env e, LidoLend.MarketParams params, address borrower,
    uint256 seizedAssets, uint256 repaidShares, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcHeapSlot[borrower] != 0, "SCOPE: the borrower is tracked");
    require(data.length == 0, "SCOPE: no liquidate callback");

    _Core.liquidate(e, params, borrower, seizedAssets, repaidShares, data);

    satisfy(ghostLlCollateral128[borrower] == 0 && ghostLlBorrowShares128[borrower] == 0
            && ghostMcHeapSlot[borrower] == 0,
        "a full seizure clears the position and its queue entry");
}

// CL-RC-05: A settlement aimed at the riskiest queued borrower can pass the policy gates and cut debt.
rule rcLwcSettleAtRootCutsDebt(env e, LidoLend.MarketParams params, uint256 borrowShares,
    address onBehalf, address borrower, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(borrower == ghostMcHeapNodeAccount[1], "SCOPE: the target is the queue root");

    mathint debtBefore = ghostLlBorrowShares128[borrower];

    _Core.settle(e, params, borrowShares, onBehalf, borrower, receiver);

    satisfy(ghostLlBorrowShares128[borrower] < debtBefore,
        "a settle at the queue root clears the policy gate and cuts debt");
}

// CL-RC-06: Pulling collateral can change the borrower's risk score without dropping it from the settlement queue.
rule rcLwcWithdrawCollateralReKeysHeap(env e, LidoLend.MarketParams params, uint256 assets, address onBehalf,
    address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcHeapSlot[onBehalf] != 0,
        "SCOPE: a tracked borrower");

    mathint keyBefore = ghostMcHeapNodeKey256[ghostMcHeapSlot[onBehalf]];

    _Core.withdrawCollateral(e, params, assets, onBehalf, receiver);

    satisfy(ghostMcHeapSlot[onBehalf] != 0
            && ghostMcHeapNodeKey256[ghostMcHeapSlot[onBehalf]] != keyBefore,
        "a collateral withdrawal re-keys the queue entry without removing it");
}

// CL-RC-07: A deposit that fits under a live supply cap can go through.
rule rcLwcSupplyUnderCapSucceeds(env e, LidoLend.MarketParams params, uint256 assets, uint256 shares,
    address onBehalf, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcSupplyCap256 != 0, "SCOPE: a live supply cap is configured");
    require(data.length == 0, "SCOPE: no supply callback");

    _Core.supply(e, params, assets, shares, onBehalf, data);

    satisfy(true, "a deposit under a live supply cap clears the controller's cap check");
}

// CL-RC-08: A borrower can sit in the settlement queue with a live risk score against real collateral.
rule rcLwcLiveQueueMemberFeasible(env e, LidoLend.MarketParams params, uint256 assets, uint256 shares,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);

    _Core.borrow(e, params, assets, shares, onBehalf, receiver);

    satisfy(ghostMcHeapSlot[onBehalf] != 0
            && ghostMcHeapNodeKey256[ghostMcHeapSlot[onBehalf]] > 0
            && ghostLlCollateral128[onBehalf] != 0,
        "a live queue member carries a positive key against collateral it still holds");
}

// CL-RC-09: A borrower already queued can still borrow when the settlement queue holds the scene's seven live nodes.
rule rcLwcBorrowAtHeapCap(env e, LidoLend.MarketParams params, uint256 assets, uint256 shares,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcHeapNodesLength == MAX_HEAP_NODES_MC_CVL() + 1,
        "SCOPE: the queue sits at the narrowed cap");
    require(ghostMcHeapSlot[onBehalf] != 0,
        "SCOPE: an already-tracked borrower");

    _Core.borrow(e, params, assets, shares, onBehalf, receiver);

    satisfy(true, "a tracked borrower can still borrow with the queue at the narrowed cap");
}

// CL-RC-10: A borrower can take on new debt in this market.
rule rcLwcBorrowMintsDebtFeasible(env e, LidoLend.MarketParams params, uint256 assets,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp), "SCOPE: fresh accrual");
    require(ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL()
            <= ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL(),
        "SCOPE: at most one loan asset per borrow share");

    mathint sharesBefore = ghostLlBorrowShares128[onBehalf];

    _Core.borrow(e, params, assets, 0, onBehalf, receiver);

    satisfy(assets > 0 && ghostLlBorrowShares128[onBehalf] > sharesBefore,
        "CL-HL-04's pin stack admits a real assets-mode borrow that mints debt");
}

// CL-RC-11: A lender can deposit exactly the headroom the market quotes.
rule rcLwcSupplyMaxDepositFeasible(env e, LidoLend.MarketParams p, address onBehalf, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(data.length == 0, "SCOPE: no supply callback");
    require(ghostMcSupplyCap256 <= max_uint128,
        "SCOPE: a supply cap the core's uint128 counter can hold");

    uint256 q = _Controller.maxDeposit(e);
    require(q != 0 && to_mathint(q) != max_uint256,
        "SCOPE: a live, finite quote");

    mathint sharesQ = to_mathint(q) * (ghostLlTotalSupplyShares128 + VIRTUAL_SHARES_LL_CVL())
        / (ghostLlTotalSupplyAssets128 + VIRTUAL_ASSETS_LL_CVL());
    require(ghostLlTotalSupplyShares128 + sharesQ <= max_uint128,
        "SCOPE: uint128 share-counter headroom");

    address token = ghostLlLoanToken;
    require(ERC20_ACCOUNT_BOUNDS(token, e.msg.sender) && ERC20_ACCOUNT_BOUNDS(token, _Core),
        "SCOPE: depositor and core custody account drawn from the bounded account set");
    require(ghostERC20Balances128[token][_Core] + to_mathint(q) <= max_uint128,
        "SCOPE: uint128 balance headroom on the core's custody account");

    _Core.supply(e, p, q, 0, onBehalf, data);

    satisfy(true, "the full CL-HL-06 pin stack admits a real deposit of the quoted amount");
}

// CL-RC-12: A lender can be quoted a positive withdrawable amount while interest is still pending.
rule rcLwcMaxWithdrawableQuoteLiveUnderProjection(env e, address supplier) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 < to_mathint(e.block.timestamp)
        && ghostLlTotalBorrowAssets128 != 0 && ghostLlIrm != 0,
        "SCOPE: elapsed time with standing borrows and a live irm");

    uint256 quote = _Controller.maxWithdrawableAssets(e, supplier);

    satisfy(quote > 0, "the regime the two quote laws leave uncovered is reachable and still quotes a live amount");
}

// CL-RC-13: A lender can withdraw and be paid out while the market is running.
rule rcLwcWithdrawPaysOutThroughNoOpHook(env e, LidoLend.MarketParams params, uint256 assets,
    uint256 shares, address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");

    mathint sharesBefore = ghostLlSupplyShares256[onBehalf];

    uint256 retAssets; uint256 retShares;
    retAssets, retShares = _Core.withdraw(e, params, assets, shares, onBehalf, receiver);

    satisfy(retAssets > 0 && ghostLlSupplyShares256[onBehalf] < sharesBefore
            && to_mathint(e.block.timestamp) >= ghostMcResumeSinceTimestamp256,
        "a withdrawal burns shares and pays out with the controller resumed, the leg CL-RV-01 blocks while paused");
}

// CL-RC-14: Interest can be booked on the market while it is running.
rule rcLwcAccrueInterestStampsClockThroughNoOpHook(env e, LidoLend.MarketParams params) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 < to_mathint(e.block.timestamp),
        "SCOPE: real elapsed time");

    _Core.accrueInterest(e, params);

    satisfy(ghostLlLastUpdate128 == to_mathint(e.block.timestamp)
            && to_mathint(e.block.timestamp) >= ghostMcResumeSinceTimestamp256,
        "an accrual moves the core clock with the controller resumed, the leg CL-RV-01 blocks while paused");
}

// CL-RC-15: Once its waiting period ends, freshly matured collateral can back a new borrow.
rule rcLwcMaturationUnblocksCoreBorrow(env e, LidoLend.MarketParams params, uint256 assets,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(to_mathint(ghostOraclePrice256[ghostLlOracle]) == ORACLE_PRICE_SCALE_MC_CVL(),
        "SCOPE: a par oracle price");
    require(ghostMcPosActivatingStart40[onBehalf] != 0
            && ghostMcPosActivatingStart40[onBehalf] + ghostMcPosActivatingDelay32[onBehalf]
                <= ghostGsCvlQuorumFrontier40,
        "SCOPE: a live timer whose unlock the guardian scan has passed");
    require(ghostGsCvlStrikeCount[ghostMcMarketId][onBehalf] == 0
            && ghostGsCvlSuspectCount[ghostMcMarketId][onBehalf] == 0,
        "SCOPE: an unflagged borrower");
    require(clActiveCollateralCVL(onBehalf) < ghostMcCfgMinActivationAmount128,
        "SCOPE: active collateral below the activation floor");

    mathint activatingBefore = ghostMcPosActivating128[onBehalf];
    mathint sharesBefore = ghostLlBorrowShares128[onBehalf];

    _Core.borrow(e, params, assets, 0, onBehalf, receiver);

    satisfy(activatingBefore > 0 && ghostMcPosActivating128[onBehalf] == 0
            && ghostLlBorrowShares128[onBehalf] > sharesBefore,
        "the lot matures inside the borrow and the freed collateral carries the new debt");
}

// CL-RC-16: A settlement can cut debt even while the market still holds idle liquidity.
rule rcLwcSettleCutsDebtWithIdleLiquidityPresent(env e, LidoLend.MarketParams p,
    uint256 borrowShares, address onBehalf, address borrower, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(borrower == ghostMcHeapNodeAccount[1], "SCOPE: the target is the queue root");
    require(borrower != 0,
        "SCOPE: a nonzero borrower");
    require(to_mathint(ghostOraclePrice256[ghostLlOracle]) == ORACLE_PRICE_SCALE_MC_CVL(),
        "SCOPE: a par oracle price, one collateral unit per loan unit");

    mathint idle0 = ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128;
    mathint tba0 = ghostLlTotalBorrowAssets128;
    mathint debtBefore = ghostLlBorrowShares128[borrower];

    _Core.settle(e, p, borrowShares, onBehalf, borrower, receiver);

    satisfy(idle0 > 0 && tba0 - ghostLlTotalBorrowAssets128 <= idle0
            && ghostLlBorrowShares128[borrower] < debtBefore,
        "a cut idle liquidity could have covered lands anyway");
}

// CL-RC-17: Booking interest can raise the withdrawable quote of the account that collects the protocol fee.
rule rcLwcAccrualLiftsFeeRecipientQuote(env e, LidoLend.MarketParams p, address supplier) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 < to_mathint(e.block.timestamp),
        "SCOPE: real elapsed time");
    require(supplier == ghostLlFeeRecipient,
        "SCOPE: the supplier holds the fee row");
    require(ERC20_ACCOUNT_BOUNDS(ghostLlLoanToken, ghostLlFeeRecipient),
        "SCOPE: the fee recipient in the bounded account set");

    uint256 quoteBefore = _Controller.maxWithdrawableAssets(e, supplier);

    _Core.accrueInterest(e, p);

    satisfy(_Controller.maxWithdrawableAssets(e, supplier) > quoteBefore,
        "the fee credit the accrual books lifts the quote the projection missed");
}

// --- reverts ---

// CL-RV-01: A paused market blocks every deposit, withdrawal, borrow, repay, collateral move, liquidation, settlement and interest accrual.
rule rvLwcPausedBlocksAllHookedCoreMutators(env e, method f, calldataarg args)
    filtered {
        f -> f.contract == _Core
            && (f.selector
                    == sig:LidoLend.supply(LidoLend.MarketParams,uint256,uint256,address,bytes).selector
                || f.selector
                    == sig:LidoLend.withdraw(LidoLend.MarketParams,uint256,uint256,address,address).selector
                || f.selector
                    == sig:LidoLend.borrow(LidoLend.MarketParams,uint256,uint256,address,address).selector
                || f.selector
                    == sig:LidoLend.repay(LidoLend.MarketParams,uint256,uint256,address,bytes).selector
                || f.selector
                    == sig:LidoLend.supplyCollateral(LidoLend.MarketParams,uint256,address,bytes).selector
                || f.selector
                    == sig:LidoLend.withdrawCollateral(LidoLend.MarketParams,uint256,address,address).selector
                || f.selector
                    == sig:LidoLend.settle(LidoLend.MarketParams,uint256,address,address,address)
                        .selector
                || f.selector
                    == sig:LidoLend.liquidate(LidoLend.MarketParams,address,uint256,uint256,bytes).selector
                || f.selector == sig:LidoLend.accrueInterest(LidoLend.MarketParams).selector)
    } {

    setupLidoLend_LinkedControllerValidState(e);
    require(to_mathint(e.block.timestamp) < ghostMcResumeSinceTimestamp256,
        "SCOPE: the paused regime only");

    f@withrevert(e, args);
    bool reverted = lastReverted;

    assert(reverted, "a paused controller blocks every hooked core action");
}

// CL-RV-02: A frozen market lets nobody take on new debt.
rule rvLwcFrozenBlocksCoreBorrow(env e, LidoLend.MarketParams p, uint256 assets, uint256 shares,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcIsFrozen,
        "SCOPE: the frozen regime only");

    _Core.borrow@withrevert(e, p, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(reverted, "a frozen market admits no new core borrow");
}

// CL-RV-03: A frozen market blocks a borrower carrying debt from pulling collateral out.
rule rvLwcFrozenBlocksDebtBearingCoreWithdrawCollateral(env e, LidoLend.MarketParams p, uint256 assets,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcIsFrozen,
        "SCOPE: the frozen regime only");
    require(ghostLlBorrowShares128[onBehalf] != 0,
        "SCOPE: open debt only");

    _Core.withdrawCollateral@withrevert(e, p, assets, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(reverted, "a freeze blocks a core collateral withdrawal");
}

// CL-RV-04: A deposit that would push supplied assets past the cap fails.
rule rvLwcCoreSupplyRevertsOverCap(env e, LidoLend.MarketParams p, uint256 assets, uint256 shares,
    address onBehalf, bytes data) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostMcSupplyCap256 != 0,
        "SCOPE: a live cap only");
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(ghostLlTotalSupplyAssets128 + to_mathint(assets) > ghostMcSupplyCap256,
        "SCOPE: the deposit breaches the supply cap");

    _Core.supply@withrevert(e, p, assets, shares, onBehalf, data);
    bool reverted = lastReverted;

    assert(reverted, "a core deposit breaching the supply cap reverts");
}

// CL-RV-05: No settlement goes through while the riskiest queued borrower carries bad debt.
rule rvLwcCoreSettleRevertsWhileRootBadDebt(env e, LidoLend.MarketParams p,
    uint256 borrowShares, address onBehalf, address borrower, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");

    bool rootBadDebt = _Controller.hasBadDebt(e);
    require(rootBadDebt,
        "SCOPE: a bad-debt root only");

    _Core.settle@withrevert(e, p, borrowShares, onBehalf, borrower, receiver);
    bool reverted = lastReverted;

    assert(reverted, "no core settle proceeds while the queue root is bad debt");
}

// CL-RV-06: A ban on the caller, the borrower or the receiver blocks the borrow.
rule rvLwcBannedCannotBorrowEndToEnd(env e, LidoLend.MarketParams p, uint256 assets, uint256 shares,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostGsCvlBanned[ghostMcMarketId][e.msg.sender]
        || ghostGsCvlBanned[ghostMcMarketId][receiver]
        || ghostGsCvlBanned[ghostMcMarketId][onBehalf],
        "SCOPE: a ban on one of the three legs");

    _Core.borrow@withrevert(e, p, assets, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(reverted, "a banned actor on any leg blocks the core borrow");
}

// CL-RV-07: A borrow priced in shares that rounds down to zero assets is refused.
rule rvLwcShareAnchoredBorrowRoundingToZeroReverts(env e, LidoLend.MarketParams p, uint256 shares,
    address onBehalf, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(shares != 0,
        "SCOPE: a nonzero share count");
    require(to_mathint(shares) * (ghostLlTotalBorrowAssets128 + VIRTUAL_ASSETS_LL_CVL())
            < ghostLlTotalBorrowShares128 + VIRTUAL_SHARES_LL_CVL(),
        "SCOPE: the draw rounds down to zero assets");

    _Core.borrow@withrevert(e, p, 0, shares, onBehalf, receiver);
    bool reverted = lastReverted;

    assert(reverted, "a share-anchored borrow the core rounds to zero assets is refused");
}

// CL-RV-08: A settlement of a borrower the controller bars unwinds the core call entirely.
rule rvLwcCoreSettleRevertsForIneligibleBorrower(env e, LidoLend.MarketParams p,
    uint256 borrowShares, address onBehalf, address borrower, address receiver) {

    setupLidoLend_LinkedControllerValidState(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual");
    require(ghostMcSettlementLtv256[borrower] == 0,
        "SCOPE: no personal settlement ltv opt-in");
    require(ghostMcHeapNodesLength < 2 || ghostMcHeapNodeAccount[1] != borrower,
        "SCOPE: the borrower is not the queue root");
    require(borrower != 0,
        "SCOPE: a nonzero borrower");

    _Core.settle@withrevert(e, p, borrowShares, onBehalf, borrower, receiver);
    bool reverted = lastReverted;

    assert(reverted, "a core settle of a borrower the controller bars reverts");
}
