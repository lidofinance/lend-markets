// A light CVL implementation of the contract, for consumer scenes that do not carry its bytecode:
// ghosts and CVL bodies behind the reads the consumer makes. Never co-imported with LidoLendMarketController.spec.

// Declared by both attachment modes: co-import fails as a duplicate declaration.
persistent ghost bool ghostMcModeMarker;

methods {
    function _.marketId() external
        => ghostMcCvlMarketId[calledContract] expect bytes32 UNRESOLVED;
    function _.on(bytes32 id, uint8 hookEvent, bytes data) external
        => onMcCVL() expect void UNRESOLVED;
    function _.maxDeposit() external
        => ghostMcCvlMaxDeposit[calledContract] expect uint256 UNRESOLVED;
    function _.maxWithdrawableAssets(address supplier) external
        => ghostMcCvlMaxWithdrawable[calledContract][supplier] expect uint256 UNRESOLVED;
    // UNSAFE: unconstrained quotes; the policy sizing them is proven on the controller's own scene.
    function _.settlementFor(address borrower, uint256 budgetSupplyShares) external => NONDET UNRESOLVED;
    function _.nextSettlementBorrower(uint256 budgetSupplyShares) external => NONDET UNRESOLVED;
}

persistent ghost mapping(address => bytes32) ghostMcCvlMarketId {
    init_state axiom forall address c. ghostMcCvlMarketId[c] == to_bytes32(0);
}

persistent ghost mapping(address => uint256) ghostMcCvlMaxDeposit {
    // TRUSTED: governance caps inside uint128, or leaves the cap unset as the uint256.max sentinel
    axiom forall address c.
        ghostMcCvlMaxDeposit[c] <= max_uint128 || ghostMcCvlMaxDeposit[c] == max_uint256;
}

persistent ghost mapping(address => mapping(address => uint256)) ghostMcCvlMaxWithdrawable {
    // SAFE: the quote is bounded by the core's uint128 totalSupplyAssets by construction
    axiom forall address c. forall address s. ghostMcCvlMaxWithdrawable[c][s] <= max_uint128;
}

// SCOPE: non-blocking hook stub; the gates it stands for are proven on the controller's own scene
function onMcCVL() { }
