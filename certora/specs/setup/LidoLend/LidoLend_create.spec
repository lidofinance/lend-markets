// Market creation scene: no storage mirror and no market pinned.

import "../env.spec";
import "../marketParamsLib.spec";
import "../Irm/irm.spec";

using LidoLend as _Core;

// Declared by every attachment mode: co-import fails as a duplicate declaration.
persistent ghost bool ghostLlModeMarker;

// Frozen per callee: one controller answers one market.
persistent ghost ghostCmMarketId(address) returns bytes32;

methods {
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => summaryMarketParamsId(marketParams);

    function _.marketId() external => ghostCmMarketId(calledContract) expect bytes32;

    // Scene cleanup: assembly sload loop + ecrecover (sig-path guard reviewed manually).
    function _Core.extSloads(bytes32[]) external returns (bytes32[]) => NONDET DELETE;
    function _Core.setAuthorizationWithSig(LidoLend.Authorization, LidoLend.Signature)
        external => NONDET DELETE;

    function _Core.owner() external returns (address) envfree;
    function _Core.market(LidoLend.Id) external
        returns (uint128, uint128, uint128, uint128, uint128, uint128) envfree;
    function _Core.idToMarketParams(LidoLend.Id) external
        returns (address, address, address, address, uint256) envfree;
    function _Core.marketController(LidoLend.Id) external returns (address) envfree;
    function _Core.isSettlementEnabled(LidoLend.Id) external returns (bool) envfree;
    function _Core.isIrmEnabled(address) external returns (bool) envfree;
    function _Core.isLltvEnabled(uint256) external returns (bool) envfree;
}

definition WAD_CM_CVL() returns mathint = 1000000000000000000;

function marketLastUpdateCmCVL(LidoLend.Id id) returns mathint {
    uint128 totalSupplyAssets; uint128 totalSupplyShares;
    uint128 totalBorrowAssets; uint128 totalBorrowShares;
    uint128 lastUpdate; uint128 fee;
    totalSupplyAssets, totalSupplyShares, totalBorrowAssets, totalBorrowShares, lastUpdate, fee
        = market(id);
    return to_mathint(lastUpdate);
}

function marketIdCmCVL(LidoLend.MarketParams marketParams) returns LidoLend.Id {
    return marketParamsIdCVL(
        marketParams.loanToken,
        marketParams.collateralToken,
        marketParams.oracle,
        marketParams.irm,
        marketParams.lltv
    );
}

function requireBlankRowCmCVL(LidoLend.Id id) {
    require(marketLastUpdateCmCVL(id) != 0
        || (marketController(id) == 0 && !isSettlementEnabled(id)),
        "SAFE: an unstamped row has no controller and settlement off");
}
