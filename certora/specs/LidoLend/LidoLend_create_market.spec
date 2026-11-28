// Market creation, in a scene that pins no market.

import "../setup/LidoLend/LidoLend_create.spec";

// LL-UT-24: Creating a controlled market binds its parameters, controller and settlement switch.
rule utLlCreateControlledMarketBindsItsWiring(
    env e, LidoLend.MarketParams mp, address controller, bool enableSettlement
) {
    setupEnv(e);
    LidoLend.Id id = marketIdCmCVL(mp);
    requireBlankRowCmCVL(id);

    createMarket(e, mp, controller, enableSettlement);

    address loanToken; address collateralToken; address oracle; address irm; uint256 lltv;
    loanToken, collateralToken, oracle, irm, lltv = idToMarketParams(id);

    assert(marketLastUpdateCmCVL(id) == to_mathint(e.block.timestamp),
        "creation stamps the accrual clock with the block time");
    assert(loanToken == mp.loanToken && collateralToken == mp.collateralToken
        && oracle == mp.oracle && irm == mp.irm && lltv == mp.lltv,
        "creation stores the parameters the id is hashed from");
    assert(marketController(id) == controller && controller != 0,
        "creation binds the named, nonzero controller");
    assert(isSettlementEnabled(id) == enableSettlement,
        "creation sets the settlement switch as asked");
    assert(isIrmEnabled(mp.irm) && isLltvEnabled(mp.lltv) && to_mathint(mp.lltv) < WAD_CM_CVL(),
        "the bound irm and lltv are enabled, and lltv is below WAD");
}

// LL-UT-25: Creating a market without a controller leaves it with no controller and no settlement.
rule utLlCreateUncontrolledMarketBindsNoController(env e, LidoLend.MarketParams mp) {
    setupEnv(e);
    LidoLend.Id id = marketIdCmCVL(mp);
    requireBlankRowCmCVL(id);

    createMarket(e, mp);

    address loanToken; address collateralToken; address oracle; address irm; uint256 lltv;
    loanToken, collateralToken, oracle, irm, lltv = idToMarketParams(id);

    assert(marketLastUpdateCmCVL(id) == to_mathint(e.block.timestamp),
        "creation stamps the accrual clock with the block time");
    assert(loanToken == mp.loanToken && collateralToken == mp.collateralToken
        && oracle == mp.oracle && irm == mp.irm && lltv == mp.lltv,
        "creation stores the parameters the id is hashed from");
    assert(marketController(id) == 0 && !isSettlementEnabled(id),
        "without a controller, settlement stays off");
    assert(isIrmEnabled(mp.irm) && isLltvEnabled(mp.lltv) && to_mathint(mp.lltv) < WAD_CM_CVL(),
        "the bound irm and lltv are enabled, and lltv is below WAD");
}

// LL-RV-32: Controlled creation fails exactly when the caller, controller, threshold or id is wrong.
rule rvLlCreateControlledMarketRevertsIff(
    env e, LidoLend.MarketParams mp, address controller, bool enableSettlement
) {
    setupEnv(e);
    LidoLend.Id id = marketIdCmCVL(mp);
    bool notOwner = e.msg.sender != owner();
    bool noController = controller == 0;
    bool thresholdTooHigh = to_mathint(mp.lltv) >= WAD_CM_CVL();
    bool alreadyCreated = marketLastUpdateCmCVL(id) != 0;
    bool claimsAnotherMarket = ghostCmMarketId(controller) != id;

    createMarket@withrevert(e, mp, controller, enableSettlement);
    bool reverted = lastReverted;

    assert(reverted <=> (notOwner || noController || thresholdTooHigh || alreadyCreated
            || claimsAnotherMarket),
        "createMarket reverts iff a caller, controller, lltv or id check fails");
}

// LL-RC-29: The owner can create a market bound to a controller with settlement switched on.
rule rcLlCreateSettleableMarketIsReachable(env e, LidoLend.MarketParams mp, address controller) {
    setupEnv(e);
    LidoLend.Id id = marketIdCmCVL(mp);

    createMarket(e, mp, controller, true);

    satisfy(marketController(id) == controller && controller != 0 && isSettlementEnabled(id)
        && marketLastUpdateCmCVL(id) == to_mathint(e.block.timestamp),
        "the owner opens a market under a controller with settlement on");
}
