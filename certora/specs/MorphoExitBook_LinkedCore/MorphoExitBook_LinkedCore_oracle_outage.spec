// Oracle outage for the exit book over the real core: a fill never calls its market's oracle.
// price() is summarized: the rows show the oracle is never called, not how a reverting feed behaves.

import "MorphoExitBook_LinkedCore_valid_state.spec";

persistent ghost address ghostMeOoOracle;
persistent ghost bool ghostMeOoSawOracleRead;

hook STATICCALL(uint g, address addr, uint argsOffset, uint argsLength, uint retOffset, uint retLength)
    uint rc {
    if (addr == ghostMeOoOracle) {
        ghostMeOoSawOracleRead = true;
    }
}

// --- oracle_outage ---

// ME-OO-01: Filling an exit request never reads the oracle of its own market.
rule ooMeFillNeverReadsTheOracle(env e, uint256 id, uint256 fillAssets, address rewardRecipient) {

    setupMorphoExitBookValidState(e);
    MorphoExitBook.Id own = ghostMeMarketIdOf[id];
    requireInvariant meParamsRowCanonical(e, own);
    require(ghostMeOoOracle == ghostMeParamsOracle[own],
        "SAFE: the ledger key is the oracle of the request's market");
    require(ghostMeOoOracle != 0 && ghostMeOoOracle != _Core && ghostMeOoOracle != currentContract
            && ghostMeOoOracle != ghostMeParamsLoanToken[own]
            && ghostMeOoOracle != ghostMeParamsCollateralToken[own]
            && ghostMeOoOracle != ghostMeParamsIrm[own]
            && ghostMeOoOracle != ghostMeReqAsset[id],
        "TRUSTED: the oracle is no other scene contract");
    require(!ghostMeOoSawOracleRead,
        "SAFE: the ledger starts empty at the top of a call");

    fillExitRequest(e, id, fillAssets, rewardRecipient);

    assert(!ghostMeOoSawOracleRead,
        "a fill never reads the oracle of the request's market");
}
