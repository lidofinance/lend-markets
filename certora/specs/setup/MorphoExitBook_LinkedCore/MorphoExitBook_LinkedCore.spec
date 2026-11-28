// Attached when the scene runs the contract's real bytecode: storage mirrors, hooks and the base setup.

import "../env.spec";
import "../safeTransferLib.spec";
import "../safeErc20.spec";
import "../erc721.spec";
import "../erc1155.spec";
import "../marketParamsLib.spec";
import "../oracle.spec";
import "../Irm/irm.spec";
import "../LidoLendMarketController/LidoLendMarketController_cvl.spec";

using MorphoExitBookHarness as _MorphoExitBook;
using LidoLend as _Core;

methods {
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    // Scene cleanup: assembly sload loop; its failed memory partitioning degrades the whole scene.
    function _Core.extSloads(bytes32[]) external returns (bytes32[]) => NONDET DELETE;

    function _MorphoExitBook.MAX_REQUEST_LIFETIME() external returns (uint256) envfree;
    function _MorphoExitBook.MAX_PRIORITY_FEE() external returns (uint256) envfree;
    function _MorphoExitBook.MAX_SERVICE_FEE() external returns (uint256) envfree;
    function _MorphoExitBook.ALLOWLIST_MANAGER_ROLE() external returns (bytes32) envfree;
    function _MorphoExitBook.FEE_MANAGER_ROLE() external returns (bytes32) envfree;
    function _MorphoExitBook.RECOVERER_ROLE() external returns (bytes32) envfree;
    function _MorphoExitBook.hasRole(bytes32, address) external returns (bool) envfree;
    function _MorphoExitBook.getRoleAdmin(bytes32) external returns (bytes32) envfree;
    function _MorphoExitBook.paused() external returns (bool) envfree;
}

definition EXCLUDED_FUNCTION_ME(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

definition MAX_PRIORITY_FEE_ME_CVL() returns mathint = ghostMeMaxPriorityFee256;
definition MAX_SERVICE_FEE_ME_CVL() returns mathint = ghostMeMaxServiceFee256;

// SAFE: contract constant (src/libs/Constants.sol).
definition WAD_ME_CVL() returns mathint = 1000000000000000000;

function setupMorphoExitBook(env e) {
    setupEnv(e);
    setupERC20();
    require(forall uint256 i. ghostMeReqOwner[i] != currentContract,
        "SAFE: no exit request is owned by the book itself");
    require(ghostMeMaxLifetime256 == to_mathint(_MorphoExitBook.MAX_REQUEST_LIFETIME()),
        "SAFE: mirrors the MAX_REQUEST_LIFETIME immutable");
    require(ghostMeMaxPriorityFee256 == to_mathint(_MorphoExitBook.MAX_PRIORITY_FEE()),
        "SAFE: mirrors the MAX_PRIORITY_FEE constant");
    require(ghostMeMaxServiceFee256 == to_mathint(_MorphoExitBook.MAX_SERVICE_FEE()),
        "SAFE: mirrors the MAX_SERVICE_FEE constant");
    require(forall address o. forall uint256 i. to_mathint(i) >= ghostMeOwnerReqIdsLen[o]
         => ghostMeOwnerReqIds[o][i] == 0,
         "SAFE: an owner listing reads zero past its length");
    require(ghostMeFeeRecipient != currentContract,
        "TRUSTED: the fee recipient is not the book itself");
}

// --- fee config ---

persistent ghost address ghostMeFeeRecipient {
    init_state axiom ghostMeFeeRecipient == 0;
}
persistent ghost mathint ghostMeServiceFee256 {
    init_state axiom ghostMeServiceFee256 == 0;
    axiom ghostMeServiceFee256 >= 0 && ghostMeServiceFee256 <= max_uint256;
}
persistent ghost mathint ghostMeMaxLifetime256 {
    axiom ghostMeMaxLifetime256 >= 0 && ghostMeMaxLifetime256 <= max_uint256;
}
// Pinned to the getters in the setup: quantified formulas cannot call them directly.
persistent ghost mathint ghostMeMaxPriorityFee256 {
    axiom ghostMeMaxPriorityFee256 >= 0 && ghostMeMaxPriorityFee256 <= max_uint256;
}
persistent ghost mathint ghostMeMaxServiceFee256 {
    axiom ghostMeMaxServiceFee256 >= 0 && ghostMeMaxServiceFee256 <= max_uint256;
}

hook Sload address val _MorphoExitBook.feeRecipient {
    require(ghostMeFeeRecipient == val, "SAFE: ghostMeFeeRecipient sync");
}
hook Sstore _MorphoExitBook.feeRecipient address val {
    ghostMeFeeRecipient = val;
}
hook Sload uint256 val _MorphoExitBook.serviceFee {
    require(require_uint256(ghostMeServiceFee256) == val, "SAFE: ghostMeServiceFee256 sync");
}
hook Sstore _MorphoExitBook.serviceFee uint256 val {
    ghostMeServiceFee256 = val;
}

// --- _book.nextId + requests[id] ---

persistent ghost mathint ghostMeNextId256 {
    init_state axiom ghostMeNextId256 == 0;
    axiom ghostMeNextId256 >= 0 && ghostMeNextId256 <= max_uint256;
}
persistent ghost mapping(uint256 => address) ghostMeReqOwner {
    init_state axiom forall uint256 id. ghostMeReqOwner[id] == 0;
}
persistent ghost mapping(uint256 => address) ghostMeReqReceiver {
    init_state axiom forall uint256 id. ghostMeReqReceiver[id] == 0;
}
persistent ghost mapping(uint256 => address) ghostMeReqAsset {
    init_state axiom forall uint256 id. ghostMeReqAsset[id] == 0;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqAssetsRemaining128 {
    init_state axiom forall uint256 id. ghostMeReqAssetsRemaining128[id] == 0;
    axiom forall uint256 id.
        ghostMeReqAssetsRemaining128[id] >= 0 && ghostMeReqAssetsRemaining128[id] <= max_uint128;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqAssetsTotal128 {
    init_state axiom forall uint256 id. ghostMeReqAssetsTotal128[id] == 0;
    axiom forall uint256 id.
        ghostMeReqAssetsTotal128[id] >= 0 && ghostMeReqAssetsTotal128[id] <= max_uint128;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqMinFillAssets128 {
    init_state axiom forall uint256 id. ghostMeReqMinFillAssets128[id] == 0;
    axiom forall uint256 id.
        ghostMeReqMinFillAssets128[id] >= 0 && ghostMeReqMinFillAssets128[id] <= max_uint128;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqMaxShareBurn128 {
    init_state axiom forall uint256 id. ghostMeReqMaxShareBurn128[id] == 0;
    axiom forall uint256 id.
        ghostMeReqMaxShareBurn128[id] >= 0 && ghostMeReqMaxShareBurn128[id] <= max_uint128;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqStartRate96 {
    init_state axiom forall uint256 id. ghostMeReqStartRate96[id] == 0;
    axiom forall uint256 id.
        ghostMeReqStartRate96[id] >= 0 && ghostMeReqStartRate96[id] <= max_uint96;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqEndRate96 {
    init_state axiom forall uint256 id. ghostMeReqEndRate96[id] == 0;
    axiom forall uint256 id.
        ghostMeReqEndRate96[id] >= 0 && ghostMeReqEndRate96[id] <= max_uint96;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqRampStart32 {
    init_state axiom forall uint256 id. ghostMeReqRampStart32[id] == 0;
    axiom forall uint256 id.
        ghostMeReqRampStart32[id] >= 0 && ghostMeReqRampStart32[id] <= max_uint32;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqRampEnd32 {
    init_state axiom forall uint256 id. ghostMeReqRampEnd32[id] == 0;
    axiom forall uint256 id.
        ghostMeReqRampEnd32[id] >= 0 && ghostMeReqRampEnd32[id] <= max_uint32;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqCreatedAt40 {
    init_state axiom forall uint256 id. ghostMeReqCreatedAt40[id] == 0;
    axiom forall uint256 id.
        ghostMeReqCreatedAt40[id] >= 0 && ghostMeReqCreatedAt40[id] <= max_uint40;
}
persistent ghost mapping(uint256 => mathint) ghostMeReqDeadline40 {
    init_state axiom forall uint256 id. ghostMeReqDeadline40[id] == 0;
    axiom forall uint256 id.
        ghostMeReqDeadline40[id] >= 0 && ghostMeReqDeadline40[id] <= max_uint40;
}
persistent ghost mapping(uint256 => MorphoExitBook.ExitStatus) ghostMeReqStatus {
    init_state axiom forall uint256 id. ghostMeReqStatus[id] == MorphoExitBook.ExitStatus.NotCreated;
}

hook Sload uint256 val _MorphoExitBook._book.nextId {
    require(require_uint256(ghostMeNextId256) == val, "SAFE: ghostMeNextId256 sync");
}
hook Sstore _MorphoExitBook._book.nextId uint256 val {
    ghostMeNextId256 = val;
}
hook Sload address val _MorphoExitBook._book.requests[KEY uint256 id].owner {
    require(ghostMeReqOwner[id] == val, "SAFE: ghostMeReqOwner sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].owner address val {
    ghostMeReqOwner[id] = val;
}
hook Sload address val _MorphoExitBook._book.requests[KEY uint256 id].receiver {
    require(ghostMeReqReceiver[id] == val, "SAFE: ghostMeReqReceiver sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].receiver address val {
    ghostMeReqReceiver[id] = val;
}
hook Sload address val _MorphoExitBook._book.requests[KEY uint256 id].asset {
    require(ghostMeReqAsset[id] == val, "SAFE: ghostMeReqAsset sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].asset address val {
    ghostMeReqAsset[id] = val;
}
hook Sload uint128 val _MorphoExitBook._book.requests[KEY uint256 id].assetsRemaining {
    require(require_uint128(ghostMeReqAssetsRemaining128[id]) == val, "SAFE: ghostMeReqAssetsRemaining128 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].assetsRemaining uint128 val {
    ghostMeReqAssetsRemaining128[id] = val;
}
hook Sload uint128 val _MorphoExitBook._book.requests[KEY uint256 id].assetsTotal {
    require(require_uint128(ghostMeReqAssetsTotal128[id]) == val, "SAFE: ghostMeReqAssetsTotal128 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].assetsTotal uint128 val {
    ghostMeReqAssetsTotal128[id] = val;
}
hook Sload uint128 val _MorphoExitBook._book.requests[KEY uint256 id].minFillAssets {
    require(require_uint128(ghostMeReqMinFillAssets128[id]) == val, "SAFE: ghostMeReqMinFillAssets128 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].minFillAssets uint128 val {
    ghostMeReqMinFillAssets128[id] = val;
}
hook Sload uint128 val _MorphoExitBook._book.requests[KEY uint256 id].maxShareBurn {
    require(require_uint128(ghostMeReqMaxShareBurn128[id]) == val, "SAFE: ghostMeReqMaxShareBurn128 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].maxShareBurn uint128 val {
    ghostMeReqMaxShareBurn128[id] = val;
}
hook Sload uint96 val _MorphoExitBook._book.requests[KEY uint256 id].startRate {
    require(ghostMeReqStartRate96[id] == to_mathint(val), "SAFE: ghostMeReqStartRate96 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].startRate uint96 val {
    ghostMeReqStartRate96[id] = to_mathint(val);
}
hook Sload uint96 val _MorphoExitBook._book.requests[KEY uint256 id].endRate {
    require(ghostMeReqEndRate96[id] == to_mathint(val), "SAFE: ghostMeReqEndRate96 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].endRate uint96 val {
    ghostMeReqEndRate96[id] = to_mathint(val);
}
hook Sload uint32 val _MorphoExitBook._book.requests[KEY uint256 id].rampStart {
    require(require_uint32(ghostMeReqRampStart32[id]) == val, "SAFE: ghostMeReqRampStart32 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].rampStart uint32 val {
    ghostMeReqRampStart32[id] = val;
}
hook Sload uint32 val _MorphoExitBook._book.requests[KEY uint256 id].rampEnd {
    require(require_uint32(ghostMeReqRampEnd32[id]) == val, "SAFE: ghostMeReqRampEnd32 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].rampEnd uint32 val {
    ghostMeReqRampEnd32[id] = val;
}
hook Sload uint40 val _MorphoExitBook._book.requests[KEY uint256 id].createdAt {
    require(ghostMeReqCreatedAt40[id] == to_mathint(val), "SAFE: ghostMeReqCreatedAt40 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].createdAt uint40 val {
    ghostMeReqCreatedAt40[id] = to_mathint(val);
}
hook Sload uint40 val _MorphoExitBook._book.requests[KEY uint256 id].deadline {
    require(ghostMeReqDeadline40[id] == to_mathint(val), "SAFE: ghostMeReqDeadline40 sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].deadline uint40 val {
    ghostMeReqDeadline40[id] = to_mathint(val);
}
hook Sload MorphoExitBook.ExitStatus val _MorphoExitBook._book.requests[KEY uint256 id].status {
    require(ghostMeReqStatus[id] == val, "SAFE: ghostMeReqStatus sync");
}
hook Sstore _MorphoExitBook._book.requests[KEY uint256 id].status MorphoExitBook.ExitStatus val {
    ghostMeReqStatus[id] = val;
}

// --- _book.ownerRequestIds[owner] ---

persistent ghost mapping(address => mathint) ghostMeOwnerReqIdsLen {
    init_state axiom forall address o. ghostMeOwnerReqIdsLen[o] == 0;
    axiom forall address o. ghostMeOwnerReqIdsLen[o] >= 0 && ghostMeOwnerReqIdsLen[o] <= max_uint256;
}
persistent ghost mapping(address => mapping(uint256 => mathint)) ghostMeOwnerReqIds {
    init_state axiom forall address o. forall uint256 i. ghostMeOwnerReqIds[o][i] == 0;
    axiom forall address o. forall uint256 i.
        ghostMeOwnerReqIds[o][i] >= 0 && ghostMeOwnerReqIds[o][i] <= max_uint256;
}

hook Sload uint256 val _MorphoExitBook._book.ownerRequestIds[KEY address o].length {
    require(require_uint256(ghostMeOwnerReqIdsLen[o]) == val, "SAFE: ghostMeOwnerReqIdsLen sync");
}
hook Sstore _MorphoExitBook._book.ownerRequestIds[KEY address o].length uint256 val {
    ghostMeOwnerReqIdsLen[o] = val;
}
hook Sload uint256 val _MorphoExitBook._book.ownerRequestIds[KEY address o][INDEX uint256 i] {
    require(require_uint256(ghostMeOwnerReqIds[o][i]) == val, "SAFE: ghostMeOwnerReqIds sync");
}
hook Sstore _MorphoExitBook._book.ownerRequestIds[KEY address o][INDEX uint256 i] uint256 val {
    ghostMeOwnerReqIds[o][i] = val;
}

// --- market registry ---

persistent ghost mapping(MorphoExitBook.Id => bool) ghostMeIsMarketAllowed {
    init_state axiom forall MorphoExitBook.Id mid. ghostMeIsMarketAllowed[mid] == false;
}
persistent ghost mapping(MorphoExitBook.Id => address) ghostMeParamsLoanToken {
    init_state axiom forall MorphoExitBook.Id mid. ghostMeParamsLoanToken[mid] == 0;
}
persistent ghost mapping(MorphoExitBook.Id => address) ghostMeParamsCollateralToken {
    init_state axiom forall MorphoExitBook.Id mid. ghostMeParamsCollateralToken[mid] == 0;
}
persistent ghost mapping(MorphoExitBook.Id => address) ghostMeParamsOracle {
    init_state axiom forall MorphoExitBook.Id mid. ghostMeParamsOracle[mid] == 0;
}
persistent ghost mapping(MorphoExitBook.Id => address) ghostMeParamsIrm {
    init_state axiom forall MorphoExitBook.Id mid. ghostMeParamsIrm[mid] == 0;
}
persistent ghost mapping(MorphoExitBook.Id => mathint) ghostMeParamsLltv256 {
    init_state axiom forall MorphoExitBook.Id mid. ghostMeParamsLltv256[mid] == 0;
    axiom forall MorphoExitBook.Id mid.
        ghostMeParamsLltv256[mid] >= 0 && ghostMeParamsLltv256[mid] <= max_uint256;
}
// Write-latch, not a mirror: set by the loanToken store, never synced back.
persistent ghost mapping(MorphoExitBook.Id => bool) ghostMeParamsSet {
    init_state axiom forall MorphoExitBook.Id mid. ghostMeParamsSet[mid] == false;
}
persistent ghost mapping(uint256 => MorphoExitBook.Id) ghostMeMarketIdOf {
    init_state axiom forall uint256 id. ghostMeMarketIdOf[id] == to_bytes32(0);
}

hook Sload bool val _MorphoExitBook.isMarketAllowed[KEY MorphoExitBook.Id mid] {
    require(ghostMeIsMarketAllowed[mid] == val, "SAFE: ghostMeIsMarketAllowed sync");
}
hook Sstore _MorphoExitBook.isMarketAllowed[KEY MorphoExitBook.Id mid] bool val {
    ghostMeIsMarketAllowed[mid] = val;
}
hook Sload address val _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].loanToken {
    require(ghostMeParamsLoanToken[mid] == val, "SAFE: ghostMeParamsLoanToken sync");
}
hook Sstore _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].loanToken address val {
    ghostMeParamsLoanToken[mid] = val;
    ghostMeParamsSet[mid] = true;
}
hook Sload address val _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].collateralToken {
    require(ghostMeParamsCollateralToken[mid] == val, "SAFE: ghostMeParamsCollateralToken sync");
}
hook Sstore _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].collateralToken address val {
    ghostMeParamsCollateralToken[mid] = val;
}
hook Sload address val _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].oracle {
    require(ghostMeParamsOracle[mid] == val, "SAFE: ghostMeParamsOracle sync");
}
hook Sstore _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].oracle address val {
    ghostMeParamsOracle[mid] = val;
}
hook Sload address val _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].irm {
    require(ghostMeParamsIrm[mid] == val, "SAFE: ghostMeParamsIrm sync");
}
hook Sstore _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].irm address val {
    ghostMeParamsIrm[mid] = val;
}
hook Sload uint256 val _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].lltv {
    require(require_uint256(ghostMeParamsLltv256[mid]) == val, "SAFE: ghostMeParamsLltv256 sync");
}
hook Sstore _MorphoExitBook._marketParams[KEY MorphoExitBook.Id mid].lltv uint256 val {
    ghostMeParamsLltv256[mid] = val;
}
hook Sload MorphoExitBook.Id val _MorphoExitBook._marketIdOf[KEY uint256 id] {
    require(ghostMeMarketIdOf[id] == val, "SAFE: ghostMeMarketIdOf sync");
}
hook Sstore _MorphoExitBook._marketIdOf[KEY uint256 id] MorphoExitBook.Id val {
    ghostMeMarketIdOf[id] = val;
}

// --- core market existence mirror ---

persistent ghost mapping(MorphoExitBook.Id => mathint) ghostMeCoreLastUpdate128 {
    init_state axiom forall MorphoExitBook.Id mid. ghostMeCoreLastUpdate128[mid] == 0;
    axiom forall MorphoExitBook.Id mid.
        ghostMeCoreLastUpdate128[mid] >= 0 && ghostMeCoreLastUpdate128[mid] <= max_uint128;
}

hook Sload uint128 val _Core.market[KEY MorphoExitBook.Id mid].lastUpdate {
    require(require_uint128(ghostMeCoreLastUpdate128[mid]) == val, "SAFE: ghostMeCoreLastUpdate128 sync");
}
hook Sstore _Core.market[KEY MorphoExitBook.Id mid].lastUpdate uint128 val {
    ghostMeCoreLastUpdate128[mid] = val;
}
