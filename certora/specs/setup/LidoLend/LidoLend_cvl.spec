// A light CVL implementation of the contract, behind the core calls a consumer makes: scalar ghosts under
// idToMarketParams / market / position. Never co-imported with LidoLend.spec.

import "../erc20.spec";
import "../marketParamsLib.spec";
import "../oracle.spec";

// SAFE: contract constants (SharesMathLib.sol).
definition VIRTUAL_SHARES_LL_CVL() returns mathint = 1000000;
definition VIRTUAL_ASSETS_LL_CVL() returns mathint = 1;

// SAFE: contract constant (ConstantsLib.sol).
definition ORACLE_PRICE_SCALE_LL_CVL() returns mathint = 10^36;

// Declared by every attachment mode: co-import fails as a duplicate declaration.
persistent ghost bool ghostLlModeMarker;

methods {
    function _.idToMarketParams(bytes32 id) external
        => idToMarketParamsLlCVL() expect (address, address, address, address, uint256) UNRESOLVED;
    function _.market(bytes32 id) external
        => marketLlCVL() expect (uint128, uint128, uint128, uint128, uint128, uint128) UNRESOLVED;
    function _.position(bytes32 id, address user) external
        => positionLlCVL(user) expect (uint256, uint128, uint128) UNRESOLVED;

    // UNSAFE: no interest simulation, so consumer views read frozen totals
    function _.expectedMarketBalances(address morpho, MarketParamsLib.MarketParams memory params) internal
        => expectedMarketBalancesLlCVL() expect (uint256, uint256, uint256, uint256);

    function _.supply(MarketParamsLib.MarketParams marketParams, uint256 assets, uint256 shares,
        address onBehalf, bytes data) external with (env e)
        => supplyLlCVL(e, calledContract, assets, shares, onBehalf) expect (uint256, uint256) UNRESOLVED;
    function _.withdraw(MarketParamsLib.MarketParams marketParams, uint256 assets, uint256 shares,
        address onBehalf, address receiver) external with (env e)
        => withdrawLlCVL(e, calledContract, assets, shares, onBehalf, receiver) expect (uint256, uint256) UNRESOLVED;
    function _.settle(MarketParamsLib.MarketParams marketParams, uint256 borrowShares,
        address onBehalf, address borrower, address receiver) external with (env e)
        => settleLlCVL(e, calledContract, borrowShares, onBehalf, borrower, receiver)
            expect (uint256, uint256, uint256, uint256) UNRESOLVED;
}

// The identity fields never move; the totals and positions move only through the mutators below.

persistent ghost address ghostLlCvlLoanToken {
    init_state axiom ghostLlCvlLoanToken == 0;
}
persistent ghost address ghostLlCvlCollateralToken {
    init_state axiom ghostLlCvlCollateralToken == 0;
}
persistent ghost address ghostLlCvlOracle {
    init_state axiom ghostLlCvlOracle == 0;
}
persistent ghost address ghostLlCvlIrm {
    init_state axiom ghostLlCvlIrm == 0;
}
// SAFE: contract constant (WAD).
definition WAD_LL_CVL() returns mathint = 10^18;

persistent ghost uint256 ghostLlCvlLltv {
    init_state axiom ghostLlCvlLltv == 0;
    // SAFE: _createMarket refuses a market whose lltv reaches WAD.
    axiom to_mathint(ghostLlCvlLltv) < WAD_LL_CVL();
}
persistent ghost uint128 ghostLlCvlTotalSupplyAssets {
    init_state axiom ghostLlCvlTotalSupplyAssets == 0;
}
persistent ghost uint128 ghostLlCvlTotalSupplyShares {
    init_state axiom ghostLlCvlTotalSupplyShares == 0;
    // UNSAFE: no market carries 2^128 shares; at the ceiling mulDivUp's rounding addend overflows uint256.
    axiom to_mathint(ghostLlCvlTotalSupplyShares) + VIRTUAL_SHARES_LL_CVL() <= max_uint128;
}
persistent ghost uint128 ghostLlCvlTotalBorrowAssets {
    init_state axiom ghostLlCvlTotalBorrowAssets == 0;
}
persistent ghost uint128 ghostLlCvlTotalBorrowShares {
    init_state axiom ghostLlCvlTotalBorrowShares == 0;
    // UNSAFE: no market carries 2^128 shares; at the ceiling mulDivUp's rounding addend overflows uint256.
    axiom to_mathint(ghostLlCvlTotalBorrowShares) + VIRTUAL_SHARES_LL_CVL() <= max_uint128;
}
persistent ghost uint128 ghostLlCvlLastUpdate {
    init_state axiom ghostLlCvlLastUpdate == 0;
}
persistent ghost uint128 ghostLlCvlFee {
    init_state axiom ghostLlCvlFee == 0;
}
persistent ghost mapping(address => uint256) ghostLlCvlPosSupplyShares {
    init_state axiom forall address u. ghostLlCvlPosSupplyShares[u] == 0;
    // SAFE: true of every settled core state; the set-sum invariant alone does not entail it
    axiom forall address u.
        to_mathint(ghostLlCvlPosSupplyShares[u]) <= to_mathint(ghostLlCvlTotalSupplyShares);
}
persistent ghost mapping(address => uint128) ghostLlCvlPosBorrowShares {
    init_state axiom forall address u. ghostLlCvlPosBorrowShares[u] == 0;
    // SAFE: true of every settled core state; the set-sum invariant alone does not entail it
    axiom forall address u.
        to_mathint(ghostLlCvlPosBorrowShares[u]) <= to_mathint(ghostLlCvlTotalBorrowShares);
    // SAFE: borrow rejects a zero onBehalf, so the zero row never takes on debt
    axiom ghostLlCvlPosBorrowShares[0] == 0;
}
persistent ghost mapping(address => uint128) ghostLlCvlPosCollateral {
    init_state axiom forall address u. ghostLlCvlPosCollateral[u] == 0;
}
persistent ghost bool ghostLlCvlIsSettlementEnabled {
    init_state axiom ghostLlCvlIsSettlementEnabled == false;
}

function idToMarketParamsLlCVL() returns (address, address, address, address, uint256) {
    return (ghostLlCvlLoanToken, ghostLlCvlCollateralToken, ghostLlCvlOracle,
        ghostLlCvlIrm, ghostLlCvlLltv);
}

function marketLlCVL() returns (uint128, uint128, uint128, uint128, uint128, uint128) {
    return (ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares,
        ghostLlCvlTotalBorrowAssets, ghostLlCvlTotalBorrowShares,
        ghostLlCvlLastUpdate, ghostLlCvlFee);
}

function positionLlCVL(address user) returns (uint256, uint128, uint128) {
    return (ghostLlCvlPosSupplyShares[user], ghostLlCvlPosBorrowShares[user],
        ghostLlCvlPosCollateral[user]);
}

function expectedMarketBalancesLlCVL() returns (uint256, uint256, uint256, uint256) {
    return (ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares,
        ghostLlCvlTotalBorrowAssets, ghostLlCvlTotalBorrowShares);
}

// --- SharesMathLib ---

function toSharesDownLlCVL(mathint assets, mathint totalAssets, mathint totalShares) returns mathint {
    return assets * (totalShares + VIRTUAL_SHARES_LL_CVL()) / (totalAssets + VIRTUAL_ASSETS_LL_CVL());
}

function toSharesUpLlCVL(mathint assets, mathint totalAssets, mathint totalShares) returns mathint {
    mathint den = totalAssets + VIRTUAL_ASSETS_LL_CVL();
    return (assets * (totalShares + VIRTUAL_SHARES_LL_CVL()) + den - 1) / den;
}

function toAssetsDownLlCVL(mathint shares, mathint totalAssets, mathint totalShares) returns mathint {
    return shares * (totalAssets + VIRTUAL_ASSETS_LL_CVL()) / (totalShares + VIRTUAL_SHARES_LL_CVL());
}

function toAssetsUpLlCVL(mathint shares, mathint totalAssets, mathint totalShares) returns mathint {
    mathint den = totalShares + VIRTUAL_SHARES_LL_CVL();
    return (shares * (totalAssets + VIRTUAL_ASSETS_LL_CVL()) + den - 1) / den;
}

// UNSAFE: the mutators write the ghosts the reads see, but nothing here accrues interest.
function supplyLlCVL(env e, address core, uint256 assets, uint256 shares, address onBehalf)
    returns (uint256, uint256) {

    require(ghostLlCvlLastUpdate != 0, "ASSERT: MARKET_NOT_CREATED");
    require((assets == 0) != (shares == 0), "ASSERT: INCONSISTENT_INPUT");
    require(onBehalf != 0, "ASSERT: ZERO_ADDRESS");

    mathint suppliedAssets = assets;
    mathint suppliedShares = shares;
    if (assets != 0) {
        suppliedShares = toSharesDownLlCVL(assets, ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares);
    } else {
        suppliedAssets = toAssetsUpLlCVL(shares, ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares);
    }

    require(ghostLlCvlTotalSupplyAssets + suppliedAssets <= max_uint128
        && ghostLlCvlTotalSupplyShares + suppliedShares + VIRTUAL_SHARES_LL_CVL() <= max_uint128,
        "ASSERT: toUint128 on the credited totals");

    // The total is credited before the row it backs: the axiom is re-assumed after each write.
    ghostLlCvlTotalSupplyShares = require_uint128(ghostLlCvlTotalSupplyShares + suppliedShares);
    ghostLlCvlPosSupplyShares[onBehalf] =
        require_uint256(ghostLlCvlPosSupplyShares[onBehalf] + suppliedShares);
    ghostLlCvlTotalSupplyAssets = require_uint128(ghostLlCvlTotalSupplyAssets + suppliedAssets);

    // TRUSTED: the initializer force-approved the core, so no allowance leg is modelled
    bool pulled = transferERC20CVL(ghostLlCvlLoanToken, e.msg.sender, core,
        require_uint256(suppliedAssets));

    return (require_uint256(suppliedAssets), require_uint256(suppliedShares));
}

function withdrawLlCVL(env e, address core, uint256 assets, uint256 shares, address onBehalf, address receiver)
    returns (uint256, uint256) {

    require(ghostLlCvlLastUpdate != 0, "ASSERT: MARKET_NOT_CREATED");
    require((assets == 0) != (shares == 0), "ASSERT: INCONSISTENT_INPUT");
    require(receiver != 0, "ASSERT: ZERO_ADDRESS");
    require(e.msg.sender == onBehalf,
        "SAFE: the vault withdraws on its own behalf");

    mathint withdrawnAssets = assets;
    mathint withdrawnShares = shares;
    if (assets != 0) {
        withdrawnShares = toSharesUpLlCVL(assets, ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares);
    } else {
        withdrawnAssets = toAssetsDownLlCVL(shares, ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares);
    }

    require(ghostLlCvlPosSupplyShares[onBehalf] >= withdrawnShares,
        "ASSERT: the supplier position covers the burn");
    require(ghostLlCvlTotalSupplyAssets >= withdrawnAssets, "ASSERT: the market covers the debit");

    ghostLlCvlPosSupplyShares[onBehalf] =
        require_uint256(ghostLlCvlPosSupplyShares[onBehalf] - withdrawnShares);
    ghostLlCvlTotalSupplyShares = require_uint128(ghostLlCvlTotalSupplyShares - withdrawnShares);
    ghostLlCvlTotalSupplyAssets = require_uint128(ghostLlCvlTotalSupplyAssets - withdrawnAssets);

    require(ghostLlCvlTotalBorrowAssets <= ghostLlCvlTotalSupplyAssets, "ASSERT: INSUFFICIENT_LIQUIDITY");

    bool paid = transferERC20CVL(ghostLlCvlLoanToken, core, receiver, require_uint256(withdrawnAssets));

    return (require_uint256(withdrawnAssets), require_uint256(withdrawnShares));
}

// UNSAFE: the settle hook is not modelled, so the scene reaches settles the controller refuses.
function settleLlCVL(env e, address core, uint256 borrowShares, address onBehalf,
    address borrower, address receiver) returns (uint256, uint256, uint256, uint256) {

    require(ghostLlCvlLastUpdate != 0, "ASSERT: MARKET_NOT_CREATED");
    require(ghostLlCvlIsSettlementEnabled, "ASSERT: SETTLEMENT_DISABLED");
    require(borrowShares != 0, "ASSERT: SETTLEMENT_SLICE_TOO_SMALL");
    require(receiver != 0, "ASSERT: ZERO_ADDRESS");
    require(e.msg.sender == onBehalf,
        "SAFE: the vault settles on its own behalf");

    mathint borrowSharesCanceled = borrowShares;
    mathint borrowAssetsCanceled = toAssetsUpLlCVL(borrowShares,
        ghostLlCvlTotalBorrowAssets, ghostLlCvlTotalBorrowShares);
    mathint supplySharesBurned = toSharesUpLlCVL(borrowAssetsCanceled,
        ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares);

    require(borrowSharesCanceled <= to_mathint(ghostLlCvlPosBorrowShares[borrower]),
        "ASSERT: SETTLEMENT_EXCEEDS_DEBT");

    mathint price = ghostOraclePrice256[ghostLlCvlOracle];
    require(price != 0, "ASSERT: a zero price reverts the seizure division");
    mathint seizedAssets = toAssetsDownLlCVL(borrowShares,
        ghostLlCvlTotalBorrowAssets, ghostLlCvlTotalBorrowShares)
        * ORACLE_PRICE_SCALE_LL_CVL() / price;
    require(seizedAssets != 0, "ASSERT: SETTLEMENT_SLICE_TOO_SMALL");
    require(seizedAssets <= to_mathint(ghostLlCvlPosCollateral[borrower]),
        "ASSERT: SETTLEMENT_EXCEEDS_COLLATERAL");

    require(supplySharesBurned <= ghostLlCvlPosSupplyShares[onBehalf],
        "ASSERT: SETTLEMENT_EXCEEDS_SUPPLY");
    require(borrowAssetsCanceled <= ghostLlCvlTotalSupplyAssets
        && borrowSharesCanceled <= ghostLlCvlTotalBorrowShares,
        "ASSERT: the market totals cover the cancellation");

    ghostLlCvlPosSupplyShares[onBehalf] =
        require_uint256(ghostLlCvlPosSupplyShares[onBehalf] - supplySharesBurned);
    ghostLlCvlTotalSupplyShares = require_uint128(ghostLlCvlTotalSupplyShares - supplySharesBurned);
    ghostLlCvlTotalSupplyAssets = require_uint128(ghostLlCvlTotalSupplyAssets - borrowAssetsCanceled);

    ghostLlCvlPosBorrowShares[borrower] =
        require_uint128(ghostLlCvlPosBorrowShares[borrower] - borrowSharesCanceled);
    ghostLlCvlTotalBorrowShares = require_uint128(ghostLlCvlTotalBorrowShares - borrowSharesCanceled);
    // The cancellation is the debt slice valued up, so it may outrun the debt total by a wei.
    if (borrowAssetsCanceled < ghostLlCvlTotalBorrowAssets) {
        ghostLlCvlTotalBorrowAssets = require_uint128(ghostLlCvlTotalBorrowAssets - borrowAssetsCanceled);
    } else {
        ghostLlCvlTotalBorrowAssets = 0;
    }

    ghostLlCvlPosCollateral[borrower] =
        require_uint128(ghostLlCvlPosCollateral[borrower] - seizedAssets);

    bool seized = transferERC20CVL(ghostLlCvlCollateralToken, core, receiver,
        require_uint256(seizedAssets));

    return (require_uint256(seizedAssets), require_uint256(borrowAssetsCanceled),
        require_uint256(borrowSharesCanceled), require_uint256(supplySharesBurned));
}
