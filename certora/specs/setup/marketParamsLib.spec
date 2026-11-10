// MarketParamsLib.id as a shared keccak ghost: every scene derives the same market id from the same params.

function summaryMarketParamsId(MarketParamsLib.MarketParams marketParams)
    returns MarketParamsLib.Id {
    return marketParamsIdCVL(
        marketParams.loanToken,
        marketParams.collateralToken,
        marketParams.oracle,
        marketParams.irm,
        marketParams.lltv
    );
}

function marketParamsIdCVL(
    address loanToken,
    address collateralToken,
    address oracle,
    address irm,
    uint256 lltv
) returns MarketParamsLib.Id {
    return ghostMktMarketParamsId[loanToken][collateralToken][oracle][irm][lltv];
}

persistent ghost mapping(address => mapping(address => mapping(address =>
    mapping(address => mapping(uint256 => MarketParamsLib.Id))))) ghostMktMarketParamsId {
    // SAFE: zero has no keccak preimage; id 0 stays the not-configured sentinel.
    axiom forall address lt. forall address ct. forall address o. forall address i.
        forall uint256 l. ghostMktMarketParamsId[lt][ct][o][i][l] != to_bytes32(0);
    // SAFE: collision resistance over the 5-tuple.
    axiom forall address lt1. forall address ct1. forall address o1. forall address i1. forall uint256 l1.
        forall address lt2. forall address ct2. forall address o2. forall address i2. forall uint256 l2.
            (ghostMktMarketParamsId[lt1][ct1][o1][i1][l1] == ghostMktMarketParamsId[lt2][ct2][o2][i2][l2])
            => (lt1 == lt2 && ct1 == ct2 && o1 == o2 && i1 == i2 && l1 == l2);
}
