// Storage mirrors, hooks, the role model, the transient inflow scratch and the base setup for scenes running
// the controller's own bytecode. The settlement heap is narrowed to seven live nodes, and the setup pins the
// nonzero configuration the initializer leaves behind.

import "../env.spec";
import "../oracle.spec";

using LidoLendMarketController as _Controller;

methods {
    // Role gating rides these summaries; the public getters read raw storage outside the role-admin scene.
    function AccessControlUpgradeable._checkRole(bytes32 role) internal with (env e)
        => checkRoleMcCVL(role, e.msg.sender);
    function AccessControlUpgradeable._checkRole(bytes32 role, address account) internal
        => checkRoleMcCVL(role, account);
    function AccessControlUpgradeable._grantRole(bytes32 role, address account) internal returns (bool)
        => grantRoleMcCVL(role, account);
    function AccessControlUpgradeable._revokeRole(bytes32 role, address account) internal returns (bool)
        => revokeRoleMcCVL(role, account);
    // The only writer of a role's admin, so the ghost mirror sees every change.
    function AccessControlUpgradeable._setRoleAdmin(bytes32 role, bytes32 adminRole) internal
        => setRoleAdminMcCVL(role, adminRole);

    // Scene cleanup: the one-shot initializer
    function _Controller.initialize(
        LidoLendMarketController.Id, address, uint256, address,
        LidoLendMarketController.CollateralActivationConfig,
        LidoLendMarketController.SettlementConfig
    ) external => NONDET DELETE;

    // Per-slot ghost: the assembly scratch slots sit outside the transient-storage model.
    function CollateralActivationLib._tload(bytes32 slot)
        internal returns (uint256) => tloadMcCVL(slot);
    function CollateralActivationLib._tstore(bytes32 slot, uint256 value)
        internal => tstoreMcCVL(slot, value);
    function CollateralActivationLib._borrowerContributionSlot(address borrower)
        internal returns (bytes32) => borrowerSlotMcCVL(borrower);

    function _Controller.DEFAULT_ADMIN_ROLE() external returns (bytes32) envfree;
    function _Controller.MANAGER_ROLE() external returns (bytes32) envfree;
    function _Controller.FREEZER_ROLE() external returns (bytes32) envfree;
    function _Controller.UNFREEZER_ROLE() external returns (bytes32) envfree;
    function _Controller.PAUSER_ROLE() external returns (bytes32) envfree;
    function _Controller.RESUMER_ROLE() external returns (bytes32) envfree;
}

definition EXCLUDED_FUNCTION_MC(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

// SAFE: contract hard caps (CollateralActivationLib.sol, Constants.sol); none of the three is exported.
definition MAX_DELAY_DURATION_MC_CVL() returns mathint = 604800;
definition WAD_MC_CVL() returns mathint = 1000000000000000000;
definition BPS_MC_CVL() returns mathint = 10000;
// SAFE: the value the controller's public MAX_BORROW_SHARE_RATE getter reports.
definition MAX_BORROW_SHARE_RATE_MC_CVL() returns mathint = 10^7;
// SAFE: core constants the sizing math is built on (ConstantsLib.ORACLE_PRICE_SCALE, SharesMathLib virtuals).
definition ORACLE_PRICE_SCALE_MC_CVL() returns mathint = 10^36;
definition VIRTUAL_SHARES_MC_CVL() returns mathint = 1000000;
definition VIRTUAL_ASSETS_MC_CVL() returns mathint = 1;
// UNSAFE: heap narrowed to 7 live nodes; the confs' loop_iter moves with this bound.
definition MAX_HEAP_NODES_MC_CVL() returns mathint = 7;

persistent ghost mapping(bytes32 => mapping(address => bool)) ghostMcHasRole;
persistent ghost mapping(bytes32 => bytes32) ghostMcRoleAdmin;

// Declared by both attachment modes: co-import fails as a duplicate declaration.
persistent ghost bool ghostMcModeMarker;

function checkRoleMcCVL(bytes32 role, address account) {
    require(ghostMcHasRole[role][account], "ASSERT: AccessControlUnauthorizedAccount");
}

function grantRoleMcCVL(bytes32 role, address account) returns bool {
    bool wasGranted = !ghostMcHasRole[role][account];
    ghostMcHasRole[role][account] = true;
    return wasGranted;
}

function revokeRoleMcCVL(bytes32 role, address account) returns bool {
    bool wasRevoked = ghostMcHasRole[role][account];
    ghostMcHasRole[role][account] = false;
    return wasRevoked;
}

function setRoleAdminMcCVL(bytes32 role, bytes32 adminRole) {
    ghostMcRoleAdmin[role] = adminRole;
}

function setupLidoLendMarketController(env e) {

    setupEnv(e);

    require(forall bytes32 slot. ghostMcTransientSlot[slot] == 0,
        "UNSAFE: no same-tx inflow credit is pending at entry");

    require(forall uint256 i. to_mathint(i) >= ghostMcHeapNodesLength => ghostMcHeapNodeAccount[i] == 0,
        "SAFE: a heap slot reads zero past its length");

    require(forall bytes32 role. ghostMcRoleAdmin[role] == to_bytes32(0),
        "SAFE: every role admin is the zero DEFAULT_ADMIN_ROLE");

    require(ghostMcCfgMinActivationDelay40 != 0, "TRUSTED: nonzero min activation delay from initialize");
    require(ghostMcCfgMinActivationAmount128 != 0, "TRUSTED: nonzero min activation amount from initialize");
    require(ghostMcCfgMaxDelayInflow128 != 0, "TRUSTED: nonzero max delay inflow from initialize");
    require(ghostMcMarketId != to_bytes32(0), "TRUSTED: deployer-wired nonzero market id from initialize");
    require(ghostMcGuardianSignals != 0, "TRUSTED: deployer-wired nonzero registry from initialize");
    require(ghostMcHeapNodesLength >= 1, "TRUSTED: heap sentinel from initialize");

}

// keccak256("lido.lend.CollateralActivationLib.TxUncappedInflow")
definition MC_TX_INFLOW_SLOT() returns bytes32 =
    to_bytes32(0x58db533cb9f1ed0c0af5bc6a8fd33d3e86d3bf9283bbb0d193a4a59d5e14202e);

persistent ghost mapping(bytes32 => uint256) ghostMcTransientSlot {
    init_state axiom forall bytes32 slot. ghostMcTransientSlot[slot] == 0;
}

persistent ghost mapping(address => bytes32) ghostMcBorrowerSlot {
    axiom forall address a. ghostMcBorrowerSlot[a] != MC_TX_INFLOW_SLOT();
    axiom forall address a. forall address b. a != b => ghostMcBorrowerSlot[a] != ghostMcBorrowerSlot[b];
}

function borrowerSlotMcCVL(address borrower) returns bytes32 {
    return ghostMcBorrowerSlot[borrower];
}

function tloadMcCVL(bytes32 slot) returns uint256 {
    return ghostMcTransientSlot[slot];
}

function tstoreMcCVL(bytes32 slot, uint256 value) {
    ghostMcTransientSlot[slot] = value;
}

// --- Scalars: marketId (B+0), supplyCap (B+1) ---

persistent ghost LidoLendMarketController.Id ghostMcMarketId {
    init_state axiom ghostMcMarketId == to_bytes32(0);
}

persistent ghost mathint ghostMcSupplyCap256 {
    init_state axiom ghostMcSupplyCap256 == 0;
    axiom ghostMcSupplyCap256 >= 0 && ghostMcSupplyCap256 <= max_uint256;
}

hook Sload LidoLendMarketController.Id val _Controller.marketId {
    require(ghostMcMarketId == val, "SAFE: ghostMcMarketId sync");
}
hook Sstore _Controller.marketId LidoLendMarketController.Id val {
    ghostMcMarketId = val;
}
hook Sload uint256 val _Controller.supplyCap {
    require(require_uint256(ghostMcSupplyCap256) == val, "SAFE: ghostMcSupplyCap256 sync");
}
hook Sstore _Controller.supplyCap uint256 val {
    ghostMcSupplyCap256 = val;
}

// --- PausableUntil: fixed keccak StorageSlot ---

persistent ghost mathint ghostMcResumeSinceTimestamp256 {
    init_state axiom ghostMcResumeSinceTimestamp256 == 0;
    axiom ghostMcResumeSinceTimestamp256 >= 0 && ghostMcResumeSinceTimestamp256 <= max_uint256;
}

hook Sload uint256 val _Controller.(slot 0xe8b012900cb200ee5dfc3b895a32791b67d12891b09f117814f167a237783a02) {
    require(require_uint256(ghostMcResumeSinceTimestamp256) == val,
        "SAFE: ghostMcResumeSinceTimestamp256 sync");
}
hook Sstore _Controller.(slot 0xe8b012900cb200ee5dfc3b895a32791b67d12891b09f117814f167a237783a02) uint256 val {
    ghostMcResumeSinceTimestamp256 = val;
}

// --- Packed slot B+2: { isFrozen, _guardianSignals } ---

persistent ghost bool ghostMcIsFrozen {
    init_state axiom ghostMcIsFrozen == false;
}
persistent ghost address ghostMcGuardianSignals {
    init_state axiom ghostMcGuardianSignals == 0;
}

hook Sload bool val _Controller.isFrozen {
    require(ghostMcIsFrozen == val, "SAFE: ghostMcIsFrozen sync");
}
hook Sstore _Controller.isFrozen bool val {
    ghostMcIsFrozen = val;
}
hook Sload address val _Controller._guardianSignals {
    require(ghostMcGuardianSignals == val, "SAFE: ghostMcGuardianSignals sync");
}
hook Sstore _Controller._guardianSignals address val {
    ghostMcGuardianSignals = val;
}

// --- _activation: { inflow, inflowUpdatedAt } ---

persistent ghost mathint ghostMcActInflow128 {
    init_state axiom ghostMcActInflow128 == 0;
    axiom ghostMcActInflow128 >= 0 && ghostMcActInflow128 <= max_uint128;
}
persistent ghost mathint ghostMcActInflowUpdatedAt40 {
    init_state axiom ghostMcActInflowUpdatedAt40 == 0;
    axiom ghostMcActInflowUpdatedAt40 >= 0 && ghostMcActInflowUpdatedAt40 <= max_uint40;
}

hook Sload uint128 val _Controller._activation.inflow {
    require(require_uint128(ghostMcActInflow128) == val, "SAFE: ghostMcActInflow128 sync");
}
hook Sstore _Controller._activation.inflow uint128 val {
    ghostMcActInflow128 = val;
}
hook Sload uint40 val _Controller._activation.inflowUpdatedAt {
    require(ghostMcActInflowUpdatedAt40 == to_mathint(val), "SAFE: ghostMcActInflowUpdatedAt40 sync");
}
hook Sstore _Controller._activation.inflowUpdatedAt uint40 val {
    ghostMcActInflowUpdatedAt40 = to_mathint(val);
}

// --- _activation.config (whole-struct writer) ---

persistent ghost mathint ghostMcCfgMinActivationDelay40 {
    init_state axiom ghostMcCfgMinActivationDelay40 == 0;
    axiom ghostMcCfgMinActivationDelay40 >= 0 && ghostMcCfgMinActivationDelay40 <= max_uint40;
}
persistent ghost mathint ghostMcCfgMaxActivationDelay40 {
    init_state axiom ghostMcCfgMaxActivationDelay40 == 0;
    axiom ghostMcCfgMaxActivationDelay40 >= 0 && ghostMcCfgMaxActivationDelay40 <= max_uint40;
}
persistent ghost mathint ghostMcCfgMaxDelayInflow128 {
    init_state axiom ghostMcCfgMaxDelayInflow128 == 0;
    axiom ghostMcCfgMaxDelayInflow128 >= 0 && ghostMcCfgMaxDelayInflow128 <= max_uint128;
}
persistent ghost mathint ghostMcCfgMinDepositAmount128 {
    init_state axiom ghostMcCfgMinDepositAmount128 == 0;
    axiom ghostMcCfgMinDepositAmount128 >= 0 && ghostMcCfgMinDepositAmount128 <= max_uint128;
}
persistent ghost mathint ghostMcCfgActivatingLockDuration40 {
    init_state axiom ghostMcCfgActivatingLockDuration40 == 0;
    axiom ghostMcCfgActivatingLockDuration40 >= 0 && ghostMcCfgActivatingLockDuration40 <= max_uint40;
}
persistent ghost mathint ghostMcCfgMinActivationAmount128 {
    init_state axiom ghostMcCfgMinActivationAmount128 == 0;
    axiom ghostMcCfgMinActivationAmount128 >= 0 && ghostMcCfgMinActivationAmount128 <= max_uint128;
}
persistent ghost mathint ghostMcCfgMaxGuardiansQuorumDelay40 {
    init_state axiom ghostMcCfgMaxGuardiansQuorumDelay40 == 0;
    axiom ghostMcCfgMaxGuardiansQuorumDelay40 >= 0 && ghostMcCfgMaxGuardiansQuorumDelay40 <= max_uint40;
}
persistent ghost mathint ghostMcCfgDelayPerStrike40 {
    init_state axiom ghostMcCfgDelayPerStrike40 == 0;
    axiom ghostMcCfgDelayPerStrike40 >= 0 && ghostMcCfgDelayPerStrike40 <= max_uint40;
}
persistent ghost mathint ghostMcCfgDelayPerSuspect40 {
    init_state axiom ghostMcCfgDelayPerSuspect40 == 0;
    axiom ghostMcCfgDelayPerSuspect40 >= 0 && ghostMcCfgDelayPerSuspect40 <= max_uint40;
}

hook Sload uint40 val _Controller._activation.config.minActivationDelay {
    require(ghostMcCfgMinActivationDelay40 == to_mathint(val), "SAFE: ghostMcCfgMinActivationDelay40 sync");
}
hook Sstore _Controller._activation.config.minActivationDelay uint40 val {
    ghostMcCfgMinActivationDelay40 = to_mathint(val);
}
hook Sload uint40 val _Controller._activation.config.maxActivationDelay {
    require(ghostMcCfgMaxActivationDelay40 == to_mathint(val), "SAFE: ghostMcCfgMaxActivationDelay40 sync");
}
hook Sstore _Controller._activation.config.maxActivationDelay uint40 val {
    ghostMcCfgMaxActivationDelay40 = to_mathint(val);
}
hook Sload uint128 val _Controller._activation.config.maxDelayInflow {
    require(require_uint128(ghostMcCfgMaxDelayInflow128) == val, "SAFE: ghostMcCfgMaxDelayInflow128 sync");
}
hook Sstore _Controller._activation.config.maxDelayInflow uint128 val {
    ghostMcCfgMaxDelayInflow128 = val;
}
hook Sload uint128 val _Controller._activation.config.minDepositAmount {
    require(require_uint128(ghostMcCfgMinDepositAmount128) == val, "SAFE: ghostMcCfgMinDepositAmount128 sync");
}
hook Sstore _Controller._activation.config.minDepositAmount uint128 val {
    ghostMcCfgMinDepositAmount128 = val;
}
hook Sload uint40 val _Controller._activation.config.activatingLockDuration {
    require(ghostMcCfgActivatingLockDuration40 == to_mathint(val), "SAFE: ghostMcCfgActivatingLockDuration40 sync");
}
hook Sstore _Controller._activation.config.activatingLockDuration uint40 val {
    ghostMcCfgActivatingLockDuration40 = to_mathint(val);
}
hook Sload uint128 val _Controller._activation.config.minActivationAmount {
    require(require_uint128(ghostMcCfgMinActivationAmount128) == val, "SAFE: ghostMcCfgMinActivationAmount128 sync");
}
hook Sstore _Controller._activation.config.minActivationAmount uint128 val {
    ghostMcCfgMinActivationAmount128 = val;
}
hook Sload uint40 val _Controller._activation.config.maxGuardiansQuorumDelay {
    require(ghostMcCfgMaxGuardiansQuorumDelay40 == to_mathint(val), "SAFE: ghostMcCfgMaxGuardiansQuorumDelay40 sync");
}
hook Sstore _Controller._activation.config.maxGuardiansQuorumDelay uint40 val {
    ghostMcCfgMaxGuardiansQuorumDelay40 = to_mathint(val);
}
hook Sload uint40 val _Controller._activation.config.delayPerStrike {
    require(ghostMcCfgDelayPerStrike40 == to_mathint(val), "SAFE: ghostMcCfgDelayPerStrike40 sync");
}
hook Sstore _Controller._activation.config.delayPerStrike uint40 val {
    ghostMcCfgDelayPerStrike40 = to_mathint(val);
}
hook Sload uint40 val _Controller._activation.config.delayPerSuspect {
    require(ghostMcCfgDelayPerSuspect40 == to_mathint(val), "SAFE: ghostMcCfgDelayPerSuspect40 sync");
}
hook Sstore _Controller._activation.config.delayPerSuspect uint40 val {
    ghostMcCfgDelayPerSuspect40 = to_mathint(val);
}

// --- _activation.positions[borrower] (borrower key unbounded: never iterated) ---

persistent ghost mapping(address => mathint) ghostMcPosDust128 {
    init_state axiom forall address a. ghostMcPosDust128[a] == 0;
    axiom forall address a. ghostMcPosDust128[a] >= 0 && ghostMcPosDust128[a] <= max_uint128;
}
persistent ghost mapping(address => mathint) ghostMcPosActivating128 {
    init_state axiom forall address a. ghostMcPosActivating128[a] == 0;
    axiom forall address a. ghostMcPosActivating128[a] >= 0 && ghostMcPosActivating128[a] <= max_uint128;
}
persistent ghost mapping(address => mathint) ghostMcPosActivatingStart40 {
    init_state axiom forall address a. ghostMcPosActivatingStart40[a] == 0;
    axiom forall address a. ghostMcPosActivatingStart40[a] >= 0 && ghostMcPosActivatingStart40[a] <= max_uint40;
}
persistent ghost mapping(address => mathint) ghostMcPosActivatingDelay32 {
    init_state axiom forall address a. ghostMcPosActivatingDelay32[a] == 0;
    axiom forall address a. ghostMcPosActivatingDelay32[a] >= 0 && ghostMcPosActivatingDelay32[a] <= max_uint32;
}

hook Sload uint128 val _Controller._activation.positions[KEY address a].dust {
    require(require_uint128(ghostMcPosDust128[a]) == val, "SAFE: ghostMcPosDust128 sync");
}
hook Sstore _Controller._activation.positions[KEY address a].dust uint128 val {
    ghostMcPosDust128[a] = val;
}
hook Sload uint128 val _Controller._activation.positions[KEY address a].activating {
    require(require_uint128(ghostMcPosActivating128[a]) == val, "SAFE: ghostMcPosActivating128 sync");
}
hook Sstore _Controller._activation.positions[KEY address a].activating uint128 val {
    ghostMcPosActivating128[a] = val;
}
hook Sload uint40 val _Controller._activation.positions[KEY address a].activatingStart {
    require(ghostMcPosActivatingStart40[a] == to_mathint(val), "SAFE: ghostMcPosActivatingStart40 sync");
}
hook Sstore _Controller._activation.positions[KEY address a].activatingStart uint40 val {
    ghostMcPosActivatingStart40[a] = to_mathint(val);
}
hook Sload uint32 val _Controller._activation.positions[KEY address a].activatingDelay {
    require(require_uint32(ghostMcPosActivatingDelay32[a]) == val, "SAFE: ghostMcPosActivatingDelay32 sync");
}
hook Sstore _Controller._activation.positions[KEY address a].activatingDelay uint32 val {
    ghostMcPosActivatingDelay32[a] = val;
}

// --- _settlementQueue.heap: 1-indexed Node[] + slot map ---

persistent ghost mapping(uint256 => address) ghostMcHeapNodeAccount {
    init_state axiom forall uint256 i. ghostMcHeapNodeAccount[i] == 0;
}
persistent ghost mapping(uint256 => mathint) ghostMcHeapNodeKey256 {
    init_state axiom forall uint256 i. ghostMcHeapNodeKey256[i] == 0;
    axiom forall uint256 i. ghostMcHeapNodeKey256[i] >= 0 && ghostMcHeapNodeKey256[i] <= max_uint256;
}
persistent ghost mathint ghostMcHeapNodesLength {
    init_state axiom ghostMcHeapNodesLength == 0;
    // UNSAFE: 7 live nodes plus the sentinel; deeper queues are unanalyzed
    axiom ghostMcHeapNodesLength >= 0 && ghostMcHeapNodesLength <= MAX_HEAP_NODES_MC_CVL() + 1;
}
persistent ghost mapping(address => uint256) ghostMcHeapSlot {
    init_state axiom forall address a. ghostMcHeapSlot[a] == 0;
}

hook Sload uint256 val _Controller._settlementQueue.heap.nodes.length {
    require(require_uint256(ghostMcHeapNodesLength) == val,
        "SAFE: ghostMcHeapNodesLength sync, bounded heap size");
}
hook Sstore _Controller._settlementQueue.heap.nodes.length uint256 val {
    ghostMcHeapNodesLength = val;
}
hook Sload address val _Controller._settlementQueue.heap.nodes[INDEX uint256 i].account {
    require(ghostMcHeapNodeAccount[i] == val, "SAFE: ghostMcHeapNodeAccount sync");
}
hook Sstore _Controller._settlementQueue.heap.nodes[INDEX uint256 i].account address val {
    ghostMcHeapNodeAccount[i] = val;
}
hook Sload uint256 val _Controller._settlementQueue.heap.nodes[INDEX uint256 i].key {
    require(ghostMcHeapNodeKey256[i] == to_mathint(val), "SAFE: ghostMcHeapNodeKey256 sync");
}
hook Sstore _Controller._settlementQueue.heap.nodes[INDEX uint256 i].key uint256 val {
    ghostMcHeapNodeKey256[i] = to_mathint(val);
}
hook Sload uint256 val _Controller._settlementQueue.heap.slot[KEY address a] {
    require(ghostMcHeapSlot[a] == val, "SAFE: ghostMcHeapSlot sync");
}
hook Sstore _Controller._settlementQueue.heap.slot[KEY address a] uint256 val {
    ghostMcHeapSlot[a] = val;
}

// --- _settlementQueue.config (whole-struct writer) ---

persistent ghost mathint ghostMcSetSliceFloorBps16 {
    init_state axiom ghostMcSetSliceFloorBps16 == 0;
    axiom ghostMcSetSliceFloorBps16 >= 0 && ghostMcSetSliceFloorBps16 <= max_uint16;
}
persistent ghost mathint ghostMcSetSliceFloorAssets96 {
    init_state axiom ghostMcSetSliceFloorAssets96 == 0;
    axiom ghostMcSetSliceFloorAssets96 >= 0 && ghostMcSetSliceFloorAssets96 <= max_uint96;
}
persistent ghost mathint ghostMcSetFullCutBelowCollateral96 {
    init_state axiom ghostMcSetFullCutBelowCollateral96 == 0;
    axiom ghostMcSetFullCutBelowCollateral96 >= 0 && ghostMcSetFullCutBelowCollateral96 <= max_uint96;
}
persistent ghost mathint ghostMcSetLtvStepBps16 {
    init_state axiom ghostMcSetLtvStepBps16 == 0;
    axiom ghostMcSetLtvStepBps16 >= 0 && ghostMcSetLtvStepBps16 <= max_uint16;
}

hook Sload uint16 val _Controller._settlementQueue.config.sliceFloorBps {
    require(require_uint16(ghostMcSetSliceFloorBps16) == val, "SAFE: ghostMcSetSliceFloorBps16 sync");
}
hook Sstore _Controller._settlementQueue.config.sliceFloorBps uint16 val {
    ghostMcSetSliceFloorBps16 = val;
}
hook Sload uint96 val _Controller._settlementQueue.config.sliceFloorAssets {
    require(ghostMcSetSliceFloorAssets96 == to_mathint(val), "SAFE: ghostMcSetSliceFloorAssets96 sync");
}
hook Sstore _Controller._settlementQueue.config.sliceFloorAssets uint96 val {
    ghostMcSetSliceFloorAssets96 = to_mathint(val);
}
hook Sload uint96 val _Controller._settlementQueue.config.fullCutBelowCollateral {
    require(ghostMcSetFullCutBelowCollateral96 == to_mathint(val), "SAFE: ghostMcSetFullCutBelowCollateral96 sync");
}
hook Sstore _Controller._settlementQueue.config.fullCutBelowCollateral uint96 val {
    ghostMcSetFullCutBelowCollateral96 = to_mathint(val);
}
hook Sload uint16 val _Controller._settlementQueue.config.ltvStepBps {
    require(require_uint16(ghostMcSetLtvStepBps16) == val, "SAFE: ghostMcSetLtvStepBps16 sync");
}
hook Sstore _Controller._settlementQueue.config.ltvStepBps uint16 val {
    ghostMcSetLtvStepBps16 = val;
}

// --- settlementLtv[borrower] + _instantActivationCallers[caller] (keys unbounded) ---

persistent ghost mapping(address => mathint) ghostMcSettlementLtv256 {
    init_state axiom forall address a. ghostMcSettlementLtv256[a] == 0;
    axiom forall address a. ghostMcSettlementLtv256[a] >= 0 && ghostMcSettlementLtv256[a] <= max_uint256;
}
persistent ghost mapping(address => bool) ghostMcInstantActivationCallers {
    init_state axiom forall address a. ghostMcInstantActivationCallers[a] == false;
}

hook Sload uint256 val _Controller._settlementQueue.settlementLtv[KEY address a] {
    require(require_uint256(ghostMcSettlementLtv256[a]) == val, "SAFE: ghostMcSettlementLtv256 sync");
}
hook Sstore _Controller._settlementQueue.settlementLtv[KEY address a] uint256 val {
    ghostMcSettlementLtv256[a] = val;
}
hook Sload bool val _Controller._instantActivationCallers[KEY address a] {
    require(ghostMcInstantActivationCallers[a] == val, "SAFE: ghostMcInstantActivationCallers sync");
}
hook Sstore _Controller._instantActivationCallers[KEY address a] bool val {
    ghostMcInstantActivationCallers[a] = val;
}
