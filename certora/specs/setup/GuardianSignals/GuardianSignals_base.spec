// Storage mirrors, hooks, the role model and the base setup for scenes that run the guardian registry's own
// bytecode. The committee and the per-signal flagger and suspect sets are narrowed to three against a real
// cap of thirty two, with their layout coherence assumed.

import "../env.spec";

using GuardianSignals as _Signals;

methods {
    function AccessControlUpgradeable._checkRole(bytes32 role) internal with (env e)
        => checkRoleGsCVL(role, e.msg.sender);
    function AccessControlUpgradeable._checkRole(bytes32 role, address account) internal
        => checkRoleGsCVL(role, account);

    function GuardianSignals.hasRole(bytes32 role, address account) internal returns (bool)
        => ghostGsHasRole[role][account];
    function GuardianSignals.getRoleAdmin(bytes32 role) internal returns (bytes32)
        => ghostGsRoleAdmin[role];

    function AccessControlEnumerableUpgradeable._grantRole(bytes32 role, address account) internal returns (bool)
        => grantRoleGsCVL(role, account);
    function AccessControlEnumerableUpgradeable._revokeRole(bytes32 role, address account) internal returns (bool)
        => revokeRoleGsCVL(role, account);

    function GuardianSignals.getRoleMember(bytes32 role, uint256 index) internal returns (address)
        => NONDET;
    function GuardianSignals.getRoleMemberCount(bytes32 role) internal returns (uint256)
        => NONDET;

    // Scene cleanup: initialize is one-shot.
    function _Signals.initialize(address, address[], uint256) external => NONDET DELETE;

    function _Signals.MAX_SUSPECT_WINDOW() external returns (uint256) envfree;
    function _Signals.MANAGER_ROLE() external returns (bytes32) envfree;
    function _Signals.ACCESS_LIMITER_ROLE() external returns (bytes32) envfree;
    function _Signals.ACCESS_RESTORER_ROLE() external returns (bytes32) envfree;
}

definition EXCLUDED_FUNCTION_GS(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

// Mirrors _isSenderAuthorized: g sits on the committee and sender is g or the delegate g appointed.
definition ACTS_FOR_GS(address sender, address g) returns bool =
    ghostGsGuardianPositions[to_bytes32(g)] != 0
        && (sender == g || ghostGsDelegates[g] == sender);

// The entries that name the seat they act for, so a guardian's delegate may call them on its behalf.
definition DELEGATABLE_ENTRY_GS(method f) returns bool =
    f.selector == sig:heartbeat(address, GuardianSignals.BlockInfoWithHash).selector
        || f.selector == sig:flag(GuardianSignals.Id, address, address[]).selector
        || f.selector == sig:unflag(GuardianSignals.Id, address, address[]).selector
        || f.selector == sig:suspect(GuardianSignals.Id, address, address[]).selector
        || f.selector == sig:unsuspect(GuardianSignals.Id, address, address[]).selector
    ;

persistent ghost mapping(bytes32 => mapping(address => bool)) ghostGsHasRole;
persistent ghost mapping(bytes32 => bytes32) ghostGsRoleAdmin;

// Declared by both attachment modes: co-import fails as a duplicate declaration.
persistent ghost bool ghostGsModeMarker;

function checkRoleGsCVL(bytes32 role, address account) {
    require(ghostGsHasRole[role][account], "ASSERT: AccessControlUnauthorizedAccount");
}

function grantRoleGsCVL(bytes32 role, address account) returns bool {
    bool wasGranted = !ghostGsHasRole[role][account];
    ghostGsHasRole[role][account] = true;
    return wasGranted;
}

function revokeRoleGsCVL(bytes32 role, address account) returns bool {
    bool wasRevoked = ghostGsHasRole[role][account];
    ghostGsHasRole[role][account] = false;
    return wasRevoked;
}

// UNSAFE: mirrored set lengths narrowed to loop_iter = 3 (real cap 32); committees of 4..32 are unanalyzed
definition MAX_COMMITTEE_GS_CVL() returns mathint = 3;

// The setup without the PROVED frontier pin, which the quorum invariant must not assume.
function setupGuardianSignalsCore(env e) {

    setupEnv(e);

    require(ghostGsInitialized64 == 1,
        "TRUSTED: the proxy is initialized");
}

function setupGuardianSignals(env e) {

    setupGuardianSignalsCore(e);

    require(ghostGsQuorumFrontierTimestamp40 <= to_mathint(e.block.timestamp),
        "PROVED: the scan frontier never runs ahead of the chain");
}

// --- _guardians ---

persistent ghost mathint ghostGsGuardiansLen {
    init_state axiom ghostGsGuardiansLen == 0;
    // UNSAFE: committee length narrowed to 3 (real cap 32)
    axiom ghostGsGuardiansLen >= 0 && ghostGsGuardiansLen <= MAX_COMMITTEE_GS_CVL();
}
persistent ghost mapping(uint256 => bytes32) ghostGsGuardianValues {
    init_state axiom forall uint256 i. ghostGsGuardianValues[i] == to_bytes32(0);
}
persistent ghost mapping(bytes32 => mathint) ghostGsGuardianPositions {
    init_state axiom forall bytes32 v. ghostGsGuardianPositions[v] == 0;
    axiom forall bytes32 v.
        ghostGsGuardianPositions[v] >= 0 && ghostGsGuardianPositions[v] <= max_uint256;
}

hook Sload uint256 val _Signals._guardians._inner._values.length {
    require(require_uint256(ghostGsGuardiansLen) == val, "SAFE: ghostGsGuardiansLen sync");
}
hook Sstore _Signals._guardians._inner._values.length uint256 val {
    ghostGsGuardiansLen = val;
}
hook Sload bytes32 val _Signals._guardians._inner._values[INDEX uint256 i] {
    require(ghostGsGuardianValues[i] == val, "SAFE: ghostGsGuardianValues sync");
}
hook Sstore _Signals._guardians._inner._values[INDEX uint256 i] bytes32 val {
    ghostGsGuardianValues[i] = val;
}
hook Sload uint256 val _Signals._guardians._inner._positions[KEY bytes32 v] {
    require(require_uint256(ghostGsGuardianPositions[v]) == val, "SAFE: ghostGsGuardianPositions sync");
}
hook Sstore _Signals._guardians._inner._positions[KEY bytes32 v] uint256 val {
    ghostGsGuardianPositions[v] = val;
}

// --- Packed slot B+0 { _quorum, _suspectWindow, _quorumFrontierTimestamp } ---

persistent ghost mathint ghostGsQuorum8 {
    init_state axiom ghostGsQuorum8 == 0;
    axiom ghostGsQuorum8 >= 0 && ghostGsQuorum8 <= max_uint8;
}
persistent ghost mathint ghostGsSuspectWindow40 {
    init_state axiom ghostGsSuspectWindow40 == 0;
    axiom ghostGsSuspectWindow40 >= 0 && ghostGsSuspectWindow40 <= max_uint40;
}
persistent ghost mathint ghostGsQuorumFrontierTimestamp40 {
    init_state axiom ghostGsQuorumFrontierTimestamp40 == 0;
    axiom ghostGsQuorumFrontierTimestamp40 >= 0 && ghostGsQuorumFrontierTimestamp40 <= max_uint40;
}

hook Sload uint8 val _Signals._quorum {
    require(require_uint8(ghostGsQuorum8) == val, "SAFE: ghostGsQuorum8 sync");
}
hook Sstore _Signals._quorum uint8 val {
    ghostGsQuorum8 = val;
}
hook Sload uint40 val _Signals._suspectWindow {
    require(ghostGsSuspectWindow40 == to_mathint(val), "SAFE: ghostGsSuspectWindow40 sync");
}
hook Sstore _Signals._suspectWindow uint40 val {
    ghostGsSuspectWindow40 = to_mathint(val);
}
hook Sload uint40 val _Signals._quorumFrontierTimestamp {
    require(ghostGsQuorumFrontierTimestamp40 == to_mathint(val), "SAFE: ghostGsQuorumFrontierTimestamp40 sync");
}
hook Sstore _Signals._quorumFrontierTimestamp uint40 val {
    ghostGsQuorumFrontierTimestamp40 = to_mathint(val);
}

// --- Initializable (OZ v5): _initialized, the uint64 head of erc7201 openzeppelin.storage.Initializable ---

persistent ghost mathint ghostGsInitialized64 {
    init_state axiom ghostGsInitialized64 == 0;
    axiom ghostGsInitialized64 >= 0 && ghostGsInitialized64 <= max_uint64;
}
hook Sload uint64 val _Signals.(slot 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00, offset 0) {
    require(ghostGsInitialized64 == to_mathint(val), "SAFE: ghostGsInitialized64 sync");
}
hook Sstore _Signals.(slot 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00, offset 0) uint64 val {
    ghostGsInitialized64 = to_mathint(val);
}

// --- _delegates: the hot key each guardian may act through, zero when it appointed none ---

persistent ghost mapping(address => address) ghostGsDelegates {
    init_state axiom forall address g. ghostGsDelegates[g] == 0;
}

hook Sload address val _Signals._delegates[KEY address g] {
    require(ghostGsDelegates[g] == val, "SAFE: ghostGsDelegates sync");
}
hook Sstore _Signals._delegates[KEY address g] address val {
    ghostGsDelegates[g] = val;
}

// --- _heartbeats: guardian key left unbounded (read only through the capped committee) ---

persistent ghost mapping(address => mathint) ghostGsHeartbeats40 {
    init_state axiom forall address g. ghostGsHeartbeats40[g] == 0;
    axiom forall address g. ghostGsHeartbeats40[g] >= 0 && ghostGsHeartbeats40[g] <= max_uint40;
}

hook Sload uint40 val _Signals._heartbeats[KEY address g] {
    require(ghostGsHeartbeats40[g] == to_mathint(val), "SAFE: ghostGsHeartbeats40 sync");
}
hook Sstore _Signals._heartbeats[KEY address g] uint40 val {
    ghostGsHeartbeats40[g] = to_mathint(val);
}

// --- _signals[id][account] packed head { banned, suspectReportedAt, suspectCount } ---

persistent ghost mapping(GuardianSignals.Id => mapping(address => bool)) ghostGsSigBanned {
    init_state axiom forall GuardianSignals.Id id. forall address a. ghostGsSigBanned[id][a] == false;
}
persistent ghost mapping(GuardianSignals.Id => mapping(address => mathint)) ghostGsSigSuspectReportedAt40 {
    init_state axiom forall GuardianSignals.Id id. forall address a. ghostGsSigSuspectReportedAt40[id][a] == 0;
    axiom forall GuardianSignals.Id id. forall address a.
        ghostGsSigSuspectReportedAt40[id][a] >= 0 && ghostGsSigSuspectReportedAt40[id][a] <= max_uint40;
}
persistent ghost mapping(GuardianSignals.Id => mapping(address => mathint)) ghostGsSigSuspectCount16 {
    init_state axiom forall GuardianSignals.Id id. forall address a. ghostGsSigSuspectCount16[id][a] == 0;
    axiom forall GuardianSignals.Id id. forall address a.
        ghostGsSigSuspectCount16[id][a] >= 0 && ghostGsSigSuspectCount16[id][a] <= max_uint16;
}
persistent ghost mapping(GuardianSignals.Id => mapping(address => mapping(address => mathint))) ghostGsSigSuspectedAt40 {
    init_state axiom forall GuardianSignals.Id id. forall address a. forall address g.
        ghostGsSigSuspectedAt40[id][a][g] == 0;
    axiom forall GuardianSignals.Id id. forall address a. forall address g.
        ghostGsSigSuspectedAt40[id][a][g] >= 0 && ghostGsSigSuspectedAt40[id][a][g] <= max_uint40;
}

hook Sload bool val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].banned {
    require(ghostGsSigBanned[id][a] == val, "SAFE: ghostGsSigBanned sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].banned bool val {
    ghostGsSigBanned[id][a] = val;
}
hook Sload uint40 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectReportedAt {
    require(ghostGsSigSuspectReportedAt40[id][a] == to_mathint(val), "SAFE: ghostGsSigSuspectReportedAt40 sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectReportedAt uint40 val {
    ghostGsSigSuspectReportedAt40[id][a] = to_mathint(val);
}
hook Sload uint16 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectCount {
    require(require_uint16(ghostGsSigSuspectCount16[id][a]) == val, "SAFE: ghostGsSigSuspectCount16 sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectCount uint16 val {
    ghostGsSigSuspectCount16[id][a] = val;
}
hook Sload uint40 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectedAt[KEY address g] {
    require(ghostGsSigSuspectedAt40[id][a][g] == to_mathint(val), "SAFE: ghostGsSigSuspectedAt40 sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectedAt[KEY address g] uint40 val {
    ghostGsSigSuspectedAt40[id][a][g] = to_mathint(val);
}

// --- per-signal flaggedBy / suspectedBy triples ---

persistent ghost mapping(GuardianSignals.Id => mapping(address => mathint)) ghostGsFlaggedByLen {
    init_state axiom forall GuardianSignals.Id id. forall address a. ghostGsFlaggedByLen[id][a] == 0;
    // UNSAFE: per-signal flagger set narrowed to 3 (real cap 32)
    axiom forall GuardianSignals.Id id. forall address a.
        ghostGsFlaggedByLen[id][a] >= 0 && ghostGsFlaggedByLen[id][a] <= MAX_COMMITTEE_GS_CVL();
}
persistent ghost mapping(GuardianSignals.Id => mapping(address => mapping(uint256 => bytes32))) ghostGsFlaggedByValues {
    init_state axiom forall GuardianSignals.Id id. forall address a. forall uint256 i.
        ghostGsFlaggedByValues[id][a][i] == to_bytes32(0);
}
persistent ghost mapping(GuardianSignals.Id => mapping(address => mapping(bytes32 => mathint))) ghostGsFlaggedByPositions {
    init_state axiom forall GuardianSignals.Id id. forall address a. forall bytes32 v.
        ghostGsFlaggedByPositions[id][a][v] == 0;
    axiom forall GuardianSignals.Id id. forall address a. forall bytes32 v.
        ghostGsFlaggedByPositions[id][a][v] >= 0 && ghostGsFlaggedByPositions[id][a][v] <= max_uint256;
}

persistent ghost mapping(GuardianSignals.Id => mapping(address => mathint)) ghostGsSuspectedByLen {
    init_state axiom forall GuardianSignals.Id id. forall address a. ghostGsSuspectedByLen[id][a] == 0;
    // UNSAFE: per-signal suspect set narrowed to 3 (real cap 32)
    axiom forall GuardianSignals.Id id. forall address a.
        ghostGsSuspectedByLen[id][a] >= 0 && ghostGsSuspectedByLen[id][a] <= MAX_COMMITTEE_GS_CVL();
}
persistent ghost mapping(GuardianSignals.Id => mapping(address => mapping(uint256 => bytes32))) ghostGsSuspectedByValues {
    init_state axiom forall GuardianSignals.Id id. forall address a. forall uint256 i.
        ghostGsSuspectedByValues[id][a][i] == to_bytes32(0);
    // SAFE: suspect set value is uint160-clean, since only add() writes the slot values() reads unmasked
    axiom forall GuardianSignals.Id id. forall address a. forall uint256 i.
        ghostGsSuspectedByValues[id][a][i] & to_bytes32(max_uint160) == ghostGsSuspectedByValues[id][a][i];
}
persistent ghost mapping(GuardianSignals.Id => mapping(address => mapping(bytes32 => mathint))) ghostGsSuspectedByPositions {
    init_state axiom forall GuardianSignals.Id id. forall address a. forall bytes32 v.
        ghostGsSuspectedByPositions[id][a][v] == 0;
    axiom forall GuardianSignals.Id id. forall address a. forall bytes32 v.
        ghostGsSuspectedByPositions[id][a][v] >= 0 && ghostGsSuspectedByPositions[id][a][v] <= max_uint256;
}

hook Sload uint256 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].flaggedBy._inner._values.length {
    require(require_uint256(ghostGsFlaggedByLen[id][a]) == val, "SAFE: ghostGsFlaggedByLen sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].flaggedBy._inner._values.length uint256 val {
    ghostGsFlaggedByLen[id][a] = val;
}
hook Sload bytes32 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].flaggedBy._inner._values[INDEX uint256 i] {
    require(ghostGsFlaggedByValues[id][a][i] == val, "SAFE: ghostGsFlaggedByValues sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].flaggedBy._inner._values[INDEX uint256 i] bytes32 val {
    ghostGsFlaggedByValues[id][a][i] = val;
}
hook Sload uint256 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].flaggedBy._inner._positions[KEY bytes32 v] {
    require(require_uint256(ghostGsFlaggedByPositions[id][a][v]) == val, "SAFE: ghostGsFlaggedByPositions sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].flaggedBy._inner._positions[KEY bytes32 v] uint256 val {
    ghostGsFlaggedByPositions[id][a][v] = val;
}

hook Sload uint256 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectedBy._inner._values.length {
    require(require_uint256(ghostGsSuspectedByLen[id][a]) == val, "SAFE: ghostGsSuspectedByLen sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectedBy._inner._values.length uint256 val {
    ghostGsSuspectedByLen[id][a] = val;
}
hook Sload bytes32 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectedBy._inner._values[INDEX uint256 i] {
    require(ghostGsSuspectedByValues[id][a][i] == val, "SAFE: ghostGsSuspectedByValues sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectedBy._inner._values[INDEX uint256 i] bytes32 val {
    ghostGsSuspectedByValues[id][a][i] = val;
}
hook Sload uint256 val _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectedBy._inner._positions[KEY bytes32 v] {
    require(require_uint256(ghostGsSuspectedByPositions[id][a][v]) == val, "SAFE: ghostGsSuspectedByPositions sync");
}
hook Sstore _Signals._signals[KEY GuardianSignals.Id id][KEY address a].suspectedBy._inner._positions[KEY bytes32 v] uint256 val {
    ghostGsSuspectedByPositions[id][a][v] = val;
}

// SAFE: OZ EnumerableSet layout coherence, a library fact assumed on the pre-state only.
function requireGsFlaggerSetBijection() {

    require(forall GuardianSignals.Id id. forall address a. forall uint256 i.
            i < ghostGsFlaggedByLen[id][a]
                => ghostGsFlaggedByPositions[id][a][ghostGsFlaggedByValues[id][a][i]] == i + 1,
        "SAFE: flag-list slot registers the flagger it holds");
    require(forall GuardianSignals.Id id. forall address a. forall uint256 i. forall bytes32 v.
            (i < ghostGsFlaggedByLen[id][a] && ghostGsFlaggedByPositions[id][a][v] == i + 1)
                => ghostGsFlaggedByValues[id][a][i] == v,
        "SAFE: a flagger registration names the flagger in its slot");
}

function requireGsSuspectSetBijection() {

    require(forall GuardianSignals.Id id. forall address a. forall uint256 i.
            i < ghostGsSuspectedByLen[id][a]
                => ghostGsSuspectedByPositions[id][a][ghostGsSuspectedByValues[id][a][i]] == i + 1,
        "SAFE: suspect-list slot registers the reporter it holds");
    require(forall GuardianSignals.Id id. forall address a. forall uint256 i. forall bytes32 v.
            (i < ghostGsSuspectedByLen[id][a] && ghostGsSuspectedByPositions[id][a][v] == i + 1)
                => ghostGsSuspectedByValues[id][a][i] == v,
        "SAFE: a reporter registration names the reporter in its slot");
}

function requireGsEnumerableSetCoherence() {

    requireGsFlaggerSetBijection();
    requireGsSuspectSetBijection();

    require(forall uint256 i. i < ghostGsGuardiansLen
            => ghostGsGuardianPositions[ghostGsGuardianValues[i]] == i + 1,
        "SAFE: committee roster slot registers the guardian it holds");
    require(forall uint256 i. forall bytes32 v.
            (i < ghostGsGuardiansLen && ghostGsGuardianPositions[v] == i + 1)
                => ghostGsGuardianValues[i] == v,
        "SAFE: a committee registration names the guardian in its slot");
    require(forall bytes32 v. ghostGsGuardianPositions[v] <= ghostGsGuardiansLen,
        "SAFE: no committee registration past the end of the roster");
    require(forall uint256 i. i < ghostGsGuardiansLen
            => ghostGsGuardianValues[i] != to_bytes32(0),
        "SAFE: the committee roster lists no zero address");
    require(ghostGsGuardianPositions[to_bytes32(0)] == 0,
        "SAFE: the zero address is no committee member");
    require(forall uint256 i. i >= ghostGsGuardiansLen
            => ghostGsGuardianValues[i] == to_bytes32(0),
        "SAFE: committee slots past the end are cleared");
    require(forall uint256 i. i < ghostGsGuardiansLen
            => (exists address a. ghostGsGuardianValues[i] == to_bytes32(a)),
        "SAFE: a committee slot holds an address, never a dirty word");
    require(ghostGsDelegates[0] == 0,
        "SAFE: the zero address appoints no delegate");

    require(forall GuardianSignals.Id id. forall address a. forall bytes32 v.
            ghostGsFlaggedByPositions[id][a][v] <= ghostGsFlaggedByLen[id][a],
        "SAFE: no flagger registration past the end of the flag list");
    require(forall GuardianSignals.Id id. forall address a. forall uint256 i.
            i < ghostGsFlaggedByLen[id][a]
                => ghostGsFlaggedByValues[id][a][i] != to_bytes32(0),
        "SAFE: a flag list lists no zero address");
    require(forall GuardianSignals.Id id. forall address a.
            ghostGsFlaggedByPositions[id][a][to_bytes32(0)] == 0,
        "SAFE: the zero address is no flagger");

    require(forall GuardianSignals.Id id. forall address a. forall bytes32 v.
            ghostGsSuspectedByPositions[id][a][v] <= ghostGsSuspectedByLen[id][a],
        "SAFE: no reporter registration past the end of the suspect list");
    require(forall GuardianSignals.Id id. forall address a. forall uint256 i.
            i < ghostGsSuspectedByLen[id][a]
                => ghostGsSuspectedByValues[id][a][i] != to_bytes32(0),
        "SAFE: a suspect list lists no zero address");
    require(forall GuardianSignals.Id id. forall address a.
            ghostGsSuspectedByPositions[id][a][to_bytes32(0)] == 0,
        "SAFE: the zero address is no suspect reporter");
    require(forall GuardianSignals.Id id. forall address a. forall uint256 i.
            i >= ghostGsSuspectedByLen[id][a]
                => ghostGsSuspectedByValues[id][a][i] == to_bytes32(0),
        "SAFE: suspect-list slots past the end are cleared");
}
