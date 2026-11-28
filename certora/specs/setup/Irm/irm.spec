// The IRM rate as a per-callee ghost: deterministic within a rule, so a quote and the accrual agree.

methods {
    function _.borrowRate(LidoLend.MarketParams, LidoLend.Market) external
        => ghostLlIrmBorrowRate[calledContract] expect uint256;
    function _.borrowRateView(LidoLend.MarketParams, LidoLend.Market) external
        => ghostLlIrmBorrowRate[calledContract] expect uint256;
}

persistent ghost mapping(address => uint256) ghostLlIrmBorrowRate {
    // TRUSTED: owner-gated IRM admission; an admitted model never quotes above WAD per second.
    axiom forall address irm. ghostLlIrmBorrowRate[irm] <= 10^18;
}
