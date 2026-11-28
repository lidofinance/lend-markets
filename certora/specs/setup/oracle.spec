// Shared oracle stub: per-callee frozen price, read-consistent within a rule.

methods {
    // TRUSTED: the summary is total, so a reverting oracle is outside the scene
    function _.price() external => ghostOraclePrice256[calledContract] expect uint256;
}

persistent ghost mapping(address => uint256) ghostOraclePrice256 {
    init_state axiom forall address o. ghostOraclePrice256[o] == 0;
    // TRUSTED: governance-wired oracle; a sane price keeps collateral valuation in range
    axiom forall address o. ghostOraclePrice256[o] <= max_uint128;
}
