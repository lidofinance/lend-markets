// A light CVL implementation of the contract, for consumer scenes that do not carry its bytecode:
// keyed ghosts behind the reads the consumer makes. Never co-imported with GuardianSignals.spec.

// Declared by both attachment modes: co-import fails as a duplicate declaration.
persistent ghost bool ghostGsModeMarker;

methods {
    function _.getOpinion(LidoLendMarketController.Id id, address account) external with (env e)
        => guardianSignalsGetOpinionCVL(e, id, account) expect LidoLendMarketController.GuardiansOpinion;
    function _.isBanned(LidoLendMarketController.Id id, address account) external
        => guardianSignalsIsBannedCVL(id, account) expect bool;
}

definition MAX_SUSPECT_WINDOW_GS_CVL() returns mathint = 2592000;

persistent ghost mapping(LidoLendMarketController.Id => mapping(address => bool)) ghostGsCvlBanned {
    init_state axiom forall LidoLendMarketController.Id id. forall address a.
        ghostGsCvlBanned[id][a] == false;
}
persistent ghost mapping(LidoLendMarketController.Id => mapping(address => mathint)) ghostGsCvlStrikeCount {
    init_state axiom forall LidoLendMarketController.Id id. forall address a.
        ghostGsCvlStrikeCount[id][a] == 0;
    // SCOPE: strike count narrowed to uint16, a bound the source itself does not carry.
    axiom forall LidoLendMarketController.Id id. forall address a.
        ghostGsCvlStrikeCount[id][a] >= 0 && ghostGsCvlStrikeCount[id][a] <= max_uint16;
}
persistent ghost mapping(LidoLendMarketController.Id => mapping(address => mathint)) ghostGsCvlSuspectCount {
    init_state axiom forall LidoLendMarketController.Id id. forall address a.
        ghostGsCvlSuspectCount[id][a] == 0;
    // SAFE: stored uint16; keeps the surcharge multiply in range.
    axiom forall LidoLendMarketController.Id id. forall address a.
        ghostGsCvlSuspectCount[id][a] >= 0 && ghostGsCvlSuspectCount[id][a] <= max_uint16;
}
persistent ghost mapping(LidoLendMarketController.Id => mapping(address => mathint)) ghostGsCvlSuspectExpiry256 {
    init_state axiom forall LidoLendMarketController.Id id. forall address a.
        ghostGsCvlSuspectExpiry256[id][a] == 0;
    axiom forall LidoLendMarketController.Id id. forall address a.
        ghostGsCvlSuspectExpiry256[id][a] >= 0 && ghostGsCvlSuspectExpiry256[id][a] <= max_uint256;
}
persistent ghost mathint ghostGsCvlQuorumFrontier40 {
    init_state axiom ghostGsCvlQuorumFrontier40 == 0;
    axiom ghostGsCvlQuorumFrontier40 >= 0 && ghostGsCvlQuorumFrontier40 <= max_uint40;
}

function guardianSignalsIsBannedCVL(LidoLendMarketController.Id id, address account) returns bool {
    return ghostGsCvlBanned[id][account];
}

function guardianSignalsGetOpinionCVL(env e, LidoLendMarketController.Id id, address account)
    returns LidoLendMarketController.GuardiansOpinion {
    LidoLendMarketController.GuardiansOpinion opinion;
    require(opinion.banned == ghostGsCvlBanned[id][account]
        && to_mathint(opinion.strikeCount) == ghostGsCvlStrikeCount[id][account]
        && to_mathint(opinion.suspectCount) == ghostGsCvlSuspectCount[id][account]
        && to_mathint(opinion.suspectExpiryTimestamp) == ghostGsCvlSuspectExpiry256[id][account]
        && to_mathint(opinion.quorumFrontierTimestamp) == ghostGsCvlQuorumFrontier40,
        "SAFE: opinion pinned to read-consistent stub ghosts");
    require(ghostGsCvlQuorumFrontier40 <= to_mathint(e.block.timestamp),
        "PROVED: the frontier never runs ahead of the chain");
    require(ghostGsCvlSuspectExpiry256[id][account]
            <= to_mathint(e.block.timestamp) + MAX_SUSPECT_WINDOW_GS_CVL(),
        "PROVED: the suspect expiry stays within one window of now");
    require(ghostGsCvlSuspectCount[id][account] > 0
            => ghostGsCvlSuspectExpiry256[id][account] > 0,
        "PROVED: a nonzero suspect count carries an expiry");
    return opinion;
}
