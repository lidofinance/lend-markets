// Attached when the scene runs the contract's real bytecode: storage mirrors, hooks and the base setup.

import "../safeTransferLib.spec";
import "../erc721.spec";
import "../erc1155.spec";
import "../erc4626.spec";
import "../oracle.spec";
import "../Irm/irm.spec";
import "../LidoLend/LidoLend_cvl.spec";
import "../LidoLendMarketController/LidoLendMarketController_cvl.spec";

using Erc4626ExitBookHarness as _Erc4626ExitBook;
using LidoLend as _Core;

methods {
    // Market ids come from the shared injective ghost, not from keccak.
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    // Scene cleanup: assembly sload loop; its failed memory partitioning degrades the whole scene.
    function _Core.extSloads(bytes32[]) external returns (bytes32[]) => NONDET DELETE;

    // The asset-denominated half of the ERC-4626 surface, on the model of erc4626.spec.
    function _.previewWithdraw(uint256 assets) external
        => ghostErc4626PreviewWithdraw[calledContract][assets] expect uint256 UNRESOLVED;
    function _.withdraw(uint256 assets, address receiver, address owner) external
        => withdrawErc4626CVL(calledContract, assets, receiver, owner) expect uint256 UNRESOLVED;

    function _Erc4626ExitBook.MAX_REQUEST_LIFETIME() external returns (uint256) envfree;
    function _Erc4626ExitBook.MAX_PRIORITY_FEE() external returns (uint256) envfree;
    function _Erc4626ExitBook.MAX_SERVICE_FEE() external returns (uint256) envfree;
    function _Erc4626ExitBook.ALLOWLIST_MANAGER_ROLE() external returns (bytes32) envfree;
    function _Erc4626ExitBook.FEE_MANAGER_ROLE() external returns (bytes32) envfree;
    function _Erc4626ExitBook.RECOVERER_ROLE() external returns (bytes32) envfree;
}

definition EXCLUDED_FUNCTION_EE(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

definition MAX_PRIORITY_FEE_EE_CVL() returns mathint = ghostEeMaxPriorityFee256;
definition MAX_SERVICE_FEE_EE_CVL() returns mathint = ghostEeMaxServiceFee256;

// SAFE: contract constant (src/libs/Constants.sol).
definition WAD_EE_CVL() returns mathint = 1000000000000000000;

// Per-callee, per-argument frozen draw for the share quote a placement snapshots.
persistent ghost mapping(address => mapping(uint256 => uint256)) ghostErc4626PreviewWithdraw;

// Moves `assets` of the vault's asset to `receiver`; the shares burned are a fresh draw.
function withdrawErc4626CVL(address vault, uint256 assets, address receiver, address owner) returns uint256 {
    uint256 shares;
    transferERC20CVL(ghostErc4626Asset[vault], vault, receiver, assets);
    return shares;
}

function setupErc4626ExitBook(env e) {
    // Inherited: the caller is any address but the core, which never calls into the book.
    setupLidoLendERC4626(e);
    requireLidoLendERC4626Invariants(e);

    require(forall uint256 i. ghostEeReqOwner[i] != currentContract,
        "SAFE: no exit request is owned by the book itself");
    require(forall uint256 i. ghostEeVaultOf[i] != currentContract,
        "SAFE: no exit request names the book itself as its vault");
    require(ghostEeMaxLifetime256 == to_mathint(_Erc4626ExitBook.MAX_REQUEST_LIFETIME()),
        "SAFE: mirrors the MAX_REQUEST_LIFETIME immutable");
    require(ghostEeMaxPriorityFee256 == to_mathint(_Erc4626ExitBook.MAX_PRIORITY_FEE()),
        "SAFE: mirrors the MAX_PRIORITY_FEE constant");
    require(ghostEeMaxServiceFee256 == to_mathint(_Erc4626ExitBook.MAX_SERVICE_FEE()),
        "SAFE: mirrors the MAX_SERVICE_FEE constant");
    require(ghostErc4626Asset[_Vault] == ghostVaAsset,
        "SAFE: the linked vault's asset() is the mirrored _asset");
    require(forall address o. forall uint256 i. to_mathint(i) >= ghostEeOwnerReqIdsLen[o]
        => ghostEeOwnerReqIds[o][i] == 0,
        "SAFE: an owner listing reads zero past its length");
    require(ghostEeFeeRecipient != currentContract,
        "TRUSTED: the fee recipient is not the book itself");
}

// --- roles + fee config + pause ---

persistent ghost mapping(bytes32 => mapping(address => bool)) ghostEeHasRole {
    init_state axiom forall bytes32 r. forall address a. ghostEeHasRole[r][a] == false;
}
persistent ghost mapping(bytes32 => bytes32) ghostEeRoleAdmin {
    init_state axiom forall bytes32 r. ghostEeRoleAdmin[r] == to_bytes32(0);
}
persistent ghost address ghostEeFeeRecipient {
    init_state axiom ghostEeFeeRecipient == 0;
}
persistent ghost bool ghostEePaused {
    init_state axiom ghostEePaused == false;
}
persistent ghost mathint ghostEeServiceFee256 {
    init_state axiom ghostEeServiceFee256 == 0;
    axiom ghostEeServiceFee256 >= 0 && ghostEeServiceFee256 <= max_uint256;
}
persistent ghost mathint ghostEeMaxLifetime256 {
    axiom ghostEeMaxLifetime256 >= 0 && ghostEeMaxLifetime256 <= max_uint256;
}
// Pinned to the getters in the setup: quantified formulas cannot call them directly.
persistent ghost mathint ghostEeMaxPriorityFee256 {
    axiom ghostEeMaxPriorityFee256 >= 0 && ghostEeMaxPriorityFee256 <= max_uint256;
}
persistent ghost mathint ghostEeMaxServiceFee256 {
    axiom ghostEeMaxServiceFee256 >= 0 && ghostEeMaxServiceFee256 <= max_uint256;
}

hook Sload bool val _Erc4626ExitBook._roles[KEY bytes32 role].hasRole[KEY address account] {
    require(ghostEeHasRole[role][account] == val, "SAFE: ghostEeHasRole sync");
}
hook Sstore _Erc4626ExitBook._roles[KEY bytes32 role].hasRole[KEY address account] bool val {
    ghostEeHasRole[role][account] = val;
}
hook Sload bytes32 val _Erc4626ExitBook._roles[KEY bytes32 role].adminRole {
    require(ghostEeRoleAdmin[role] == val, "SAFE: ghostEeRoleAdmin sync");
}
hook Sstore _Erc4626ExitBook._roles[KEY bytes32 role].adminRole bytes32 val {
    ghostEeRoleAdmin[role] = val;
}
hook Sload address val _Erc4626ExitBook.feeRecipient {
    require(ghostEeFeeRecipient == val, "SAFE: ghostEeFeeRecipient sync");
}
hook Sstore _Erc4626ExitBook.feeRecipient address val {
    ghostEeFeeRecipient = val;
}
hook Sload bool val _Erc4626ExitBook.paused {
    require(ghostEePaused == val, "SAFE: ghostEePaused sync");
}
hook Sstore _Erc4626ExitBook.paused bool val {
    ghostEePaused = val;
}
hook Sload uint256 val _Erc4626ExitBook.serviceFee {
    require(require_uint256(ghostEeServiceFee256) == val, "SAFE: ghostEeServiceFee256 sync");
}
hook Sstore _Erc4626ExitBook.serviceFee uint256 val {
    ghostEeServiceFee256 = val;
}

// --- _book.nextId + requests[id] ---

persistent ghost mathint ghostEeNextId256 {
    init_state axiom ghostEeNextId256 == 0;
    axiom ghostEeNextId256 >= 0 && ghostEeNextId256 <= max_uint256;
}
persistent ghost mapping(uint256 => address) ghostEeReqOwner {
    init_state axiom forall uint256 id. ghostEeReqOwner[id] == 0;
}
persistent ghost mapping(uint256 => address) ghostEeReqReceiver {
    init_state axiom forall uint256 id. ghostEeReqReceiver[id] == 0;
}
persistent ghost mapping(uint256 => address) ghostEeReqAsset {
    init_state axiom forall uint256 id. ghostEeReqAsset[id] == 0;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqAssetsRemaining128 {
    init_state axiom forall uint256 id. ghostEeReqAssetsRemaining128[id] == 0;
    axiom forall uint256 id.
        ghostEeReqAssetsRemaining128[id] >= 0 && ghostEeReqAssetsRemaining128[id] <= max_uint128;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqAssetsTotal128 {
    init_state axiom forall uint256 id. ghostEeReqAssetsTotal128[id] == 0;
    axiom forall uint256 id.
        ghostEeReqAssetsTotal128[id] >= 0 && ghostEeReqAssetsTotal128[id] <= max_uint128;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqMinFillAssets128 {
    init_state axiom forall uint256 id. ghostEeReqMinFillAssets128[id] == 0;
    axiom forall uint256 id.
        ghostEeReqMinFillAssets128[id] >= 0 && ghostEeReqMinFillAssets128[id] <= max_uint128;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqMaxShareBurn128 {
    init_state axiom forall uint256 id. ghostEeReqMaxShareBurn128[id] == 0;
    axiom forall uint256 id.
        ghostEeReqMaxShareBurn128[id] >= 0 && ghostEeReqMaxShareBurn128[id] <= max_uint128;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqStartRate96 {
    init_state axiom forall uint256 id. ghostEeReqStartRate96[id] == 0;
    axiom forall uint256 id.
        ghostEeReqStartRate96[id] >= 0 && ghostEeReqStartRate96[id] <= max_uint96;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqEndRate96 {
    init_state axiom forall uint256 id. ghostEeReqEndRate96[id] == 0;
    axiom forall uint256 id.
        ghostEeReqEndRate96[id] >= 0 && ghostEeReqEndRate96[id] <= max_uint96;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqRampStart32 {
    init_state axiom forall uint256 id. ghostEeReqRampStart32[id] == 0;
    axiom forall uint256 id.
        ghostEeReqRampStart32[id] >= 0 && ghostEeReqRampStart32[id] <= max_uint32;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqRampEnd32 {
    init_state axiom forall uint256 id. ghostEeReqRampEnd32[id] == 0;
    axiom forall uint256 id.
        ghostEeReqRampEnd32[id] >= 0 && ghostEeReqRampEnd32[id] <= max_uint32;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqCreatedAt40 {
    init_state axiom forall uint256 id. ghostEeReqCreatedAt40[id] == 0;
    axiom forall uint256 id.
        ghostEeReqCreatedAt40[id] >= 0 && ghostEeReqCreatedAt40[id] <= max_uint40;
}
persistent ghost mapping(uint256 => mathint) ghostEeReqDeadline40 {
    init_state axiom forall uint256 id. ghostEeReqDeadline40[id] == 0;
    axiom forall uint256 id.
        ghostEeReqDeadline40[id] >= 0 && ghostEeReqDeadline40[id] <= max_uint40;
}
persistent ghost mapping(uint256 => Erc4626ExitBook.ExitStatus) ghostEeReqStatus {
    init_state axiom forall uint256 id. ghostEeReqStatus[id] == Erc4626ExitBook.ExitStatus.NotCreated;
}

hook Sload uint256 val _Erc4626ExitBook._book.nextId {
    require(require_uint256(ghostEeNextId256) == val, "SAFE: ghostEeNextId256 sync");
}
hook Sstore _Erc4626ExitBook._book.nextId uint256 val {
    ghostEeNextId256 = val;
}
hook Sload address val _Erc4626ExitBook._book.requests[KEY uint256 id].owner {
    require(ghostEeReqOwner[id] == val, "SAFE: ghostEeReqOwner sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].owner address val {
    ghostEeReqOwner[id] = val;
}
hook Sload address val _Erc4626ExitBook._book.requests[KEY uint256 id].receiver {
    require(ghostEeReqReceiver[id] == val, "SAFE: ghostEeReqReceiver sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].receiver address val {
    ghostEeReqReceiver[id] = val;
}
hook Sload address val _Erc4626ExitBook._book.requests[KEY uint256 id].asset {
    require(ghostEeReqAsset[id] == val, "SAFE: ghostEeReqAsset sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].asset address val {
    ghostEeReqAsset[id] = val;
}
hook Sload uint128 val _Erc4626ExitBook._book.requests[KEY uint256 id].assetsRemaining {
    require(require_uint128(ghostEeReqAssetsRemaining128[id]) == val, "SAFE: ghostEeReqAssetsRemaining128 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].assetsRemaining uint128 val {
    ghostEeReqAssetsRemaining128[id] = val;
}
hook Sload uint128 val _Erc4626ExitBook._book.requests[KEY uint256 id].assetsTotal {
    require(require_uint128(ghostEeReqAssetsTotal128[id]) == val, "SAFE: ghostEeReqAssetsTotal128 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].assetsTotal uint128 val {
    ghostEeReqAssetsTotal128[id] = val;
}
hook Sload uint128 val _Erc4626ExitBook._book.requests[KEY uint256 id].minFillAssets {
    require(require_uint128(ghostEeReqMinFillAssets128[id]) == val, "SAFE: ghostEeReqMinFillAssets128 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].minFillAssets uint128 val {
    ghostEeReqMinFillAssets128[id] = val;
}
hook Sload uint128 val _Erc4626ExitBook._book.requests[KEY uint256 id].maxShareBurn {
    require(require_uint128(ghostEeReqMaxShareBurn128[id]) == val, "SAFE: ghostEeReqMaxShareBurn128 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].maxShareBurn uint128 val {
    ghostEeReqMaxShareBurn128[id] = val;
}
hook Sload uint96 val _Erc4626ExitBook._book.requests[KEY uint256 id].startRate {
    require(ghostEeReqStartRate96[id] == to_mathint(val), "SAFE: ghostEeReqStartRate96 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].startRate uint96 val {
    ghostEeReqStartRate96[id] = to_mathint(val);
}
hook Sload uint96 val _Erc4626ExitBook._book.requests[KEY uint256 id].endRate {
    require(ghostEeReqEndRate96[id] == to_mathint(val), "SAFE: ghostEeReqEndRate96 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].endRate uint96 val {
    ghostEeReqEndRate96[id] = to_mathint(val);
}
hook Sload uint32 val _Erc4626ExitBook._book.requests[KEY uint256 id].rampStart {
    require(require_uint32(ghostEeReqRampStart32[id]) == val, "SAFE: ghostEeReqRampStart32 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].rampStart uint32 val {
    ghostEeReqRampStart32[id] = val;
}
hook Sload uint32 val _Erc4626ExitBook._book.requests[KEY uint256 id].rampEnd {
    require(require_uint32(ghostEeReqRampEnd32[id]) == val, "SAFE: ghostEeReqRampEnd32 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].rampEnd uint32 val {
    ghostEeReqRampEnd32[id] = val;
}
hook Sload uint40 val _Erc4626ExitBook._book.requests[KEY uint256 id].createdAt {
    require(ghostEeReqCreatedAt40[id] == to_mathint(val), "SAFE: ghostEeReqCreatedAt40 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].createdAt uint40 val {
    ghostEeReqCreatedAt40[id] = to_mathint(val);
}
hook Sload uint40 val _Erc4626ExitBook._book.requests[KEY uint256 id].deadline {
    require(ghostEeReqDeadline40[id] == to_mathint(val), "SAFE: ghostEeReqDeadline40 sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].deadline uint40 val {
    ghostEeReqDeadline40[id] = to_mathint(val);
}
hook Sload Erc4626ExitBook.ExitStatus val _Erc4626ExitBook._book.requests[KEY uint256 id].status {
    require(ghostEeReqStatus[id] == val, "SAFE: ghostEeReqStatus sync");
}
hook Sstore _Erc4626ExitBook._book.requests[KEY uint256 id].status Erc4626ExitBook.ExitStatus val {
    ghostEeReqStatus[id] = val;
}

// --- _book.ownerRequestIds[owner] ---

persistent ghost mapping(address => mathint) ghostEeOwnerReqIdsLen {
    init_state axiom forall address o. ghostEeOwnerReqIdsLen[o] == 0;
    axiom forall address o. ghostEeOwnerReqIdsLen[o] >= 0 && ghostEeOwnerReqIdsLen[o] <= max_uint256;
}
persistent ghost mapping(address => mapping(uint256 => mathint)) ghostEeOwnerReqIds {
    init_state axiom forall address o. forall uint256 i. ghostEeOwnerReqIds[o][i] == 0;
    axiom forall address o. forall uint256 i.
        ghostEeOwnerReqIds[o][i] >= 0 && ghostEeOwnerReqIds[o][i] <= max_uint256;
}

hook Sload uint256 val _Erc4626ExitBook._book.ownerRequestIds[KEY address o].length {
    require(require_uint256(ghostEeOwnerReqIdsLen[o]) == val, "SAFE: ghostEeOwnerReqIdsLen sync");
}
hook Sstore _Erc4626ExitBook._book.ownerRequestIds[KEY address o].length uint256 val {
    ghostEeOwnerReqIdsLen[o] = val;
}
hook Sload uint256 val _Erc4626ExitBook._book.ownerRequestIds[KEY address o][INDEX uint256 i] {
    require(require_uint256(ghostEeOwnerReqIds[o][i]) == val, "SAFE: ghostEeOwnerReqIds sync");
}
hook Sstore _Erc4626ExitBook._book.ownerRequestIds[KEY address o][INDEX uint256 i] uint256 val {
    ghostEeOwnerReqIds[o][i] = val;
}

// --- vault registry ---

persistent ghost mapping(address => bool) ghostEeIsVaultAllowed {
    init_state axiom forall address v. ghostEeIsVaultAllowed[v] == false;
}
persistent ghost mapping(uint256 => address) ghostEeVaultOf {
    init_state axiom forall uint256 id. ghostEeVaultOf[id] == 0;
}

hook Sload bool val _Erc4626ExitBook.isVaultAllowed[KEY address v] {
    require(ghostEeIsVaultAllowed[v] == val, "SAFE: ghostEeIsVaultAllowed sync");
}
hook Sstore _Erc4626ExitBook.isVaultAllowed[KEY address v] bool val {
    ghostEeIsVaultAllowed[v] = val;
}
hook Sload address val _Erc4626ExitBook.vaultOf[KEY uint256 id] {
    require(ghostEeVaultOf[id] == val, "SAFE: ghostEeVaultOf sync");
}
hook Sstore _Erc4626ExitBook.vaultOf[KEY uint256 id] address val {
    ghostEeVaultOf[id] = val;
}
