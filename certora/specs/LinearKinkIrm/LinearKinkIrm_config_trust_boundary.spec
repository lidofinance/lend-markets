// Two witnesses that LinearKinkIrm accepts a config its constructor would reject: a zero kink deconfigures a
// live market and its rate query then reverts, a peak rate above the cap is storable. Both run with config
// validity switched off and claim nothing about the contract.

import "../setup/Irm/LinearKinkIrm/LinearKinkIrm.spec";

// LKI-TB-01: Applying a curve whose kink is zero can strip a live market of its rate and stop its interest.
rule rcLkiZeroKinkConfigDeconfiguresALiveMarket(env e, LinearKinkIrm.MarketParams marketParams, address config,
    LinearKinkIrm.Market market) {

    setupLinearKinkIrmUntrustedConfig(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(e.msg.sender == ghostLkiOwner || e.msg.sender == ghostLkiManager,
        "SCOPE: the owner or the manager as the caller");
    require(ghostLkiOptimalUtilization64[id] != 0, "SCOPE: a market that is priced before the call");
    require(ghostLkiCfgOptimalUtilization64[config] == 0,
        "SCOPE: a config reporting the zero kink its constructor would reject");

    applyIrmConfig(e, marketParams, config);
    borrowRate@withrevert(e, marketParams, market);

    satisfy(lastReverted && ghostLkiOptimalUtilization64[id] == 0,
        "a config reporting a zero kink deconfigures a live market and its rate query then reverts");
}

// LKI-TB-02: Applying a curve can give a market a peak rate above the 800 percent per year cap.
rule rcLkiOverCapPeakRateIsStorable(env e, LinearKinkIrm.MarketParams marketParams, address config) {

    setupLinearKinkIrmUntrustedConfig(e);
    LinearKinkIrm.Id id = summaryMarketParamsId(marketParams);
    require(e.msg.sender == ghostLkiOwner || e.msg.sender == ghostLkiManager,
        "SCOPE: the owner or the manager as the caller");
    require(ghostLkiCfgOptimalUtilization64[config] > 0
        && ghostLkiCfgOptimalUtilization64[config] < WAD_MATH(),
        "SCOPE: a config whose kink is in band");
    require(ghostLkiCfgBaseRate64[config] + ghostLkiCfgSlope1_64[config] + ghostLkiCfgSlope2_64[config]
            > MAX_BORROW_RATE_LKI_CVL(),
        "SCOPE: a config reporting the over cap peak its constructor would reject");

    applyIrmConfig(e, marketParams, config);

    satisfy(ghostLkiBaseRate64[id] + ghostLkiSlope1_64[id] + ghostLkiSlope2_64[id]
            > MAX_BORROW_RATE_LKI_CVL(),
        "a peak rate above the cap is storable, because the IRM copies the config's answer unchecked");
}
