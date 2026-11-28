// Storage mirrors, hooks and the base setup for scenes running the forked core's own bytecode, plus the
// position sums the ledger invariants hold against market totals. One market exists, every call names it,
// positions cover seven holders, and the borrower callbacks are summarized away.

import "../env.spec";
import "../oracle.spec";
import "../safeTransferLib.spec";
import "../marketParamsLib.spec";
import "../Irm/irm.spec";

using LidoLend as _Core;

methods {
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => marketParamsIdRowPinnedCVL(marketParams);

    // Always reverts here: setupLidoLend pins the contract initialized and the market created.
    function _Core.initialize(address) external => NONDET DELETE;
    function _Core.createMarket(LidoLend.MarketParams) external => NONDET DELETE;
    function _Core.createMarket(LidoLend.MarketParams, address, bool) external => NONDET DELETE;

    // Scene cleanup: assembly sload loop + ecrecover (sig-path guard reviewed manually).
    function _Core.extSloads(bytes32[]) external returns (bytes32[]) => NONDET DELETE;
    function _Core.setAuthorizationWithSig(LidoLend.Authorization, LidoLend.Signature)
        external => NONDET DELETE;

    // UNSAFE: the borrower callbacks are summarized away, so what a real one moves is unanalyzed.
    function _.onMorphoSupply(uint256, bytes) external => NONDET;
    function _.onMorphoRepay(uint256, bytes) external => NONDET;
    function _.onMorphoSupplyCollateral(uint256, bytes) external => NONDET;
    function _.onMorphoLiquidate(uint256, bytes) external => NONDET;
    function _.onMorphoFlashLoan(uint256, bytes) external => NONDET;
}

definition EXCLUDED_FUNCTION_LL(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

// SAFE: contract hard caps (ConstantsLib.sol, MathLib.sol).
definition MAX_FEE_LL_CVL() returns mathint = 250000000000000000;
definition WAD_LL_CVL() returns mathint = 1000000000000000000;

// SAFE: contract hard caps (SharesMathLib.sol); the virtual offsets that price shares in an empty market.
definition VIRTUAL_SHARES_LL_CVL() returns mathint = 1000000;
definition VIRTUAL_ASSETS_LL_CVL() returns mathint = 1;

// SAFE: contract constants (ConstantsLib.sol); the oracle scale and the liquidation incentive band.
definition ORACLE_PRICE_SCALE_LL_CVL() returns mathint = 10^36;
definition LIQUIDATION_CURSOR_LL_CVL() returns mathint = 300000000000000000;
definition MAX_LIF_LL_CVL() returns mathint = 1150000000000000000;

// Declared by every attachment mode: co-import fails as a duplicate declaration.
persistent ghost bool ghostLlModeMarker;

function setupLidoLend(env e) {
    setupEnv(e);
    setupERC20();

    require(ghostLlFee128 == 0 || ghostLlFeeRecipient != 0,
        "TRUSTED: a fee is enabled only with a real recipient");

    require(ghostLlIsInitialized && ghostLlOwner != 0, "TRUSTED: deployment ran initialize");
    require(ghostLlLastUpdate128 != 0,
        "TRUSTED: the owner-deployed market exists");
    require(ghostLlLoanToken != 0 && ghostLlCollateralToken != 0,
        "TRUSTED: the market names real token contracts");

    require(ghostLlLastUpdate128 != 0 => ghostLlIsIrmEnabled[ghostLlIrm],
        "TRUSTED: createMarket whitelists the irm it binds");
    require(ghostLlLastUpdate128 != 0 => ghostLlIsLltvEnabled[require_uint256(ghostLlLltv256)],
        "TRUSTED: createMarket whitelists the lltv it binds");
    require(forall uint256 l. ghostLlIsLltvEnabled[l] => to_mathint(l) < WAD_LL_CVL(),
        "TRUSTED: createMarket rejects an lltv at or above WAD");
    require(ghostLlIsSettlementEnabled => ghostLlMarketController != 0,
        "TRUSTED: createMarket enables settlement only under a controller");
}

// Every market call reaches the id computation, so the pin sits here
function marketParamsIdRowPinnedCVL(MarketParamsLib.MarketParams params)
    returns MarketParamsLib.Id {
    require(ghostLlLastUpdate128 == 0
        || (ghostLlLoanToken == params.loanToken
            && ghostLlCollateralToken == params.collateralToken
            && ghostLlOracle == params.oracle
            && ghostLlIrm == params.irm
            && ghostLlLltv256 == to_mathint(params.lltv)),
        "SAFE: the call's params describe the one created market");
    return summaryMarketParamsId(params);
}

// --- Scalars ---

persistent ghost address ghostLlOwner {
    init_state axiom ghostLlOwner == 0;
}
persistent ghost address ghostLlFeeRecipient {
    init_state axiom ghostLlFeeRecipient == 0;
}
persistent ghost bool ghostLlIsInitialized {
    init_state axiom ghostLlIsInitialized == false;
}

hook Sload address val _Core.owner {
    require(ghostLlOwner == val, "SAFE: ghostLlOwner sync");
}
hook Sstore _Core.owner address val {
    ghostLlOwner = val;
}
hook Sload address val _Core.feeRecipient {
    require(ghostLlFeeRecipient == val, "SAFE: ghostLlFeeRecipient sync");
}
hook Sstore _Core.feeRecipient address val {
    ghostLlFeeRecipient = val;
}
hook Sload bool val _Core.isInitialized {
    require(ghostLlIsInitialized == val, "SAFE: ghostLlIsInitialized sync");
}
hook Sstore _Core.isInitialized bool val {
    ghostLlIsInitialized = val;
}

// --- Simple maps ---

persistent ghost mapping(address => bool) ghostLlIsIrmEnabled {
    init_state axiom forall address a. ghostLlIsIrmEnabled[a] == false;
}
persistent ghost mapping(uint256 => bool) ghostLlIsLltvEnabled {
    init_state axiom forall uint256 l. ghostLlIsLltvEnabled[l] == false;
}
persistent ghost mapping(address => mapping(address => bool)) ghostLlIsAuthorized {
    init_state axiom forall address a. forall address b. ghostLlIsAuthorized[a][b] == false;
}
persistent ghost mapping(address => mathint) ghostLlNonce256 {
    init_state axiom forall address a. ghostLlNonce256[a] == 0;
    axiom forall address a. ghostLlNonce256[a] >= 0 && ghostLlNonce256[a] <= max_uint256;
}
persistent ghost address ghostLlMarketController {
    init_state axiom ghostLlMarketController == 0;
}
persistent ghost bool ghostLlIsSettlementEnabled {
    init_state axiom ghostLlIsSettlementEnabled == false;
}

hook Sload bool val _Core.isIrmEnabled[KEY address a] {
    require(ghostLlIsIrmEnabled[a] == val, "SAFE: ghostLlIsIrmEnabled sync");
}
hook Sstore _Core.isIrmEnabled[KEY address a] bool val {
    ghostLlIsIrmEnabled[a] = val;
}
hook Sload bool val _Core.isLltvEnabled[KEY uint256 l] {
    require(ghostLlIsLltvEnabled[l] == val, "SAFE: ghostLlIsLltvEnabled sync");
}
hook Sstore _Core.isLltvEnabled[KEY uint256 l] bool val {
    ghostLlIsLltvEnabled[l] = val;
}
hook Sload bool val _Core.isAuthorized[KEY address a][KEY address b] {
    require(ghostLlIsAuthorized[a][b] == val, "SAFE: ghostLlIsAuthorized sync");
}
hook Sstore _Core.isAuthorized[KEY address a][KEY address b] bool val {
    ghostLlIsAuthorized[a][b] = val;
}
hook Sload uint256 val _Core.nonce[KEY address a] {
    require(require_uint256(ghostLlNonce256[a]) == val, "SAFE: ghostLlNonce256 sync");
}
hook Sstore _Core.nonce[KEY address a] uint256 val {
    ghostLlNonce256[a] = val;
}
hook Sload address val _Core.marketController[KEY LidoLend.Id id] {
    require(ghostLlMarketController == val, "SAFE: ghostLlMarketController sync (one-market scalar)");
}
hook Sstore _Core.marketController[KEY LidoLend.Id id] address val {
    ghostLlMarketController = val;
}
hook Sload bool val _Core.isSettlementEnabled[KEY LidoLend.Id id] {
    require(ghostLlIsSettlementEnabled == val, "SAFE: ghostLlIsSettlementEnabled sync (one-market scalar)");
}
hook Sstore _Core.isSettlementEnabled[KEY LidoLend.Id id] bool val {
    ghostLlIsSettlementEnabled = val;
}

// --- market[id] (Market, 3 packed uint128 pairs; one-market scalars) ---

persistent ghost mathint ghostLlTotalSupplyAssets128 {
    init_state axiom ghostLlTotalSupplyAssets128 == 0;
    axiom ghostLlTotalSupplyAssets128 >= 0 && ghostLlTotalSupplyAssets128 <= max_uint128;
}
persistent ghost mathint ghostLlTotalSupplyShares128 {
    init_state axiom ghostLlTotalSupplyShares128 == 0;
    axiom ghostLlTotalSupplyShares128 >= 0 && ghostLlTotalSupplyShares128 <= max_uint128;
}
persistent ghost mathint ghostLlTotalBorrowAssets128 {
    init_state axiom ghostLlTotalBorrowAssets128 == 0;
    axiom ghostLlTotalBorrowAssets128 >= 0 && ghostLlTotalBorrowAssets128 <= max_uint128;
}
persistent ghost mathint ghostLlTotalBorrowShares128 {
    init_state axiom ghostLlTotalBorrowShares128 == 0;
    axiom ghostLlTotalBorrowShares128 >= 0 && ghostLlTotalBorrowShares128 <= max_uint128;
}
persistent ghost mathint ghostLlLastUpdate128 {
    init_state axiom ghostLlLastUpdate128 == 0;
    axiom ghostLlLastUpdate128 >= 0 && ghostLlLastUpdate128 <= max_uint128;
}
persistent ghost mathint ghostLlFee128 {
    init_state axiom ghostLlFee128 == 0;
    axiom ghostLlFee128 >= 0 && ghostLlFee128 <= max_uint128;
}

hook Sload uint128 val _Core.market[KEY LidoLend.Id id].totalSupplyAssets {
    require(require_uint128(ghostLlTotalSupplyAssets128) == val,
        "SAFE: ghostLlTotalSupplyAssets128 sync (one-market scalar)");
}
hook Sstore _Core.market[KEY LidoLend.Id id].totalSupplyAssets uint128 val {
    ghostLlTotalSupplyAssets128 = val;
}
hook Sload uint128 val _Core.market[KEY LidoLend.Id id].totalSupplyShares {
    require(require_uint128(ghostLlTotalSupplyShares128) == val,
        "SAFE: ghostLlTotalSupplyShares128 sync (one-market scalar)");
}
hook Sstore _Core.market[KEY LidoLend.Id id].totalSupplyShares uint128 val {
    ghostLlTotalSupplyShares128 = val;
}
hook Sload uint128 val _Core.market[KEY LidoLend.Id id].totalBorrowAssets {
    require(require_uint128(ghostLlTotalBorrowAssets128) == val,
        "SAFE: ghostLlTotalBorrowAssets128 sync (one-market scalar)");
}
hook Sstore _Core.market[KEY LidoLend.Id id].totalBorrowAssets uint128 val {
    ghostLlTotalBorrowAssets128 = val;
}
hook Sload uint128 val _Core.market[KEY LidoLend.Id id].totalBorrowShares {
    require(require_uint128(ghostLlTotalBorrowShares128) == val,
        "SAFE: ghostLlTotalBorrowShares128 sync (one-market scalar)");
}
hook Sstore _Core.market[KEY LidoLend.Id id].totalBorrowShares uint128 val {
    ghostLlTotalBorrowShares128 = val;
}
hook Sload uint128 val _Core.market[KEY LidoLend.Id id].lastUpdate {
    require(require_uint128(ghostLlLastUpdate128) == val,
        "SAFE: ghostLlLastUpdate128 sync (one-market scalar)");
}
hook Sstore _Core.market[KEY LidoLend.Id id].lastUpdate uint128 val {
    ghostLlLastUpdate128 = val;
}
hook Sload uint128 val _Core.market[KEY LidoLend.Id id].fee {
    require(require_uint128(ghostLlFee128) == val, "SAFE: ghostLlFee128 sync (one-market scalar)");
}
hook Sstore _Core.market[KEY LidoLend.Id id].fee uint128 val {
    ghostLlFee128 = val;
}

// --- idToMarketParams[id] (MarketParams, 5 slots; one-market scalars) ---

persistent ghost address ghostLlLoanToken {
    init_state axiom ghostLlLoanToken == 0;
}
persistent ghost address ghostLlCollateralToken {
    init_state axiom ghostLlCollateralToken == 0;
}
persistent ghost address ghostLlOracle {
    init_state axiom ghostLlOracle == 0;
}
persistent ghost address ghostLlIrm {
    init_state axiom ghostLlIrm == 0;
}
persistent ghost mathint ghostLlLltv256 {
    init_state axiom ghostLlLltv256 == 0;
    axiom ghostLlLltv256 >= 0 && ghostLlLltv256 <= max_uint256;
    // SAFE: createMarket rejects an lltv at or above WAD
    axiom ghostLlLltv256 < WAD_LL_CVL();
}

hook Sload address val _Core.idToMarketParams[KEY LidoLend.Id id].loanToken {
    require(ghostLlLoanToken == val, "SAFE: ghostLlLoanToken sync (one-market scalar)");
}
hook Sstore _Core.idToMarketParams[KEY LidoLend.Id id].loanToken address val {
    ghostLlLoanToken = val;
}
hook Sload address val _Core.idToMarketParams[KEY LidoLend.Id id].collateralToken {
    require(ghostLlCollateralToken == val, "SAFE: ghostLlCollateralToken sync (one-market scalar)");
}
hook Sstore _Core.idToMarketParams[KEY LidoLend.Id id].collateralToken address val {
    ghostLlCollateralToken = val;
}
hook Sload address val _Core.idToMarketParams[KEY LidoLend.Id id].oracle {
    require(ghostLlOracle == val, "SAFE: ghostLlOracle sync (one-market scalar)");
}
hook Sstore _Core.idToMarketParams[KEY LidoLend.Id id].oracle address val {
    ghostLlOracle = val;
}
hook Sload address val _Core.idToMarketParams[KEY LidoLend.Id id].irm {
    require(ghostLlIrm == val, "SAFE: ghostLlIrm sync (one-market scalar)");
}
hook Sstore _Core.idToMarketParams[KEY LidoLend.Id id].irm address val {
    ghostLlIrm = val;
}
hook Sload uint256 val _Core.idToMarketParams[KEY LidoLend.Id id].lltv {
    require(require_uint256(ghostLlLltv256) == val, "SAFE: ghostLlLltv256 sync (one-market scalar)");
}
hook Sstore _Core.idToMarketParams[KEY LidoLend.Id id].lltv uint256 val {
    ghostLlLltv256 = val;
}

// --- position[id][user] summed over the loan token's account set, plus the zero account at [0] ---

definition LL_SUPPLY_SHARES_SUM() returns mathint =
    ghostLlSupplyShares256[ghostERC20AccountsValues[ghostLlLoanToken][0]]
    + ghostLlSupplyShares256[ghostERC20AccountsValues[ghostLlLoanToken][1]]
    + ghostLlSupplyShares256[ghostERC20AccountsValues[ghostLlLoanToken][2]]
    + ghostLlSupplyShares256[ghostERC20AccountsValues[ghostLlLoanToken][3]]
    + ghostLlSupplyShares256[ghostERC20AccountsValues[ghostLlLoanToken][4]]
    + ghostLlSupplyShares256[ghostERC20AccountsValues[ghostLlLoanToken][5]]
    + ghostLlSupplyShares256[ghostERC20AccountsValues[ghostLlLoanToken][6]]
    + ghostLlSupplyShares256[0];

definition LL_BORROW_SHARES_SUM() returns mathint =
    ghostLlBorrowShares128[ghostERC20AccountsValues[ghostLlLoanToken][0]]
    + ghostLlBorrowShares128[ghostERC20AccountsValues[ghostLlLoanToken][1]]
    + ghostLlBorrowShares128[ghostERC20AccountsValues[ghostLlLoanToken][2]]
    + ghostLlBorrowShares128[ghostERC20AccountsValues[ghostLlLoanToken][3]]
    + ghostLlBorrowShares128[ghostERC20AccountsValues[ghostLlLoanToken][4]]
    + ghostLlBorrowShares128[ghostERC20AccountsValues[ghostLlLoanToken][5]]
    + ghostLlBorrowShares128[ghostERC20AccountsValues[ghostLlLoanToken][6]]
    + ghostLlBorrowShares128[0];

// UNSAFE: keyed on the loan token's account set; the max_uint128 balance cap bounds the whole sum, not each holder
definition LL_COLLATERAL_SUM() returns mathint =
    ghostLlCollateral128[ghostERC20AccountsValues[ghostLlLoanToken][0]]
    + ghostLlCollateral128[ghostERC20AccountsValues[ghostLlLoanToken][1]]
    + ghostLlCollateral128[ghostERC20AccountsValues[ghostLlLoanToken][2]]
    + ghostLlCollateral128[ghostERC20AccountsValues[ghostLlLoanToken][3]]
    + ghostLlCollateral128[ghostERC20AccountsValues[ghostLlLoanToken][4]]
    + ghostLlCollateral128[ghostERC20AccountsValues[ghostLlLoanToken][5]]
    + ghostLlCollateral128[ghostERC20AccountsValues[ghostLlLoanToken][6]]
    + ghostLlCollateral128[0];

persistent ghost mapping(address => mathint) ghostLlSupplyShares256 {
    init_state axiom forall address u. ghostLlSupplyShares256[u] == 0;
    axiom forall address u.
        ghostLlSupplyShares256[u] >= 0 && ghostLlSupplyShares256[u] <= max_uint256;
}
persistent ghost mapping(address => mathint) ghostLlBorrowShares128 {
    init_state axiom forall address u. ghostLlBorrowShares128[u] == 0;
    axiom forall address u.
        ghostLlBorrowShares128[u] >= 0 && ghostLlBorrowShares128[u] <= max_uint128;
}
persistent ghost mapping(address => mathint) ghostLlCollateral128 {
    init_state axiom forall address u. ghostLlCollateral128[u] == 0;
    axiom forall address u.
        ghostLlCollateral128[u] >= 0 && ghostLlCollateral128[u] <= max_uint128;
}
hook Sload uint256 val _Core.position[KEY LidoLend.Id id][KEY address u].supplyShares {
    require(ERC20_ACCOUNT_BOUNDS_OR_ZERO(ghostLlLoanToken, u),
        "UNSAFE: position users restricted to the loan token's 7-slot account set");
    require(require_uint256(ghostLlSupplyShares256[u]) == val,
        "SAFE: ghostLlSupplyShares256 sync (one-market scalar)");
}
hook Sstore _Core.position[KEY LidoLend.Id id][KEY address u].supplyShares uint256 val {
    require(ERC20_ACCOUNT_BOUNDS_OR_ZERO(ghostLlLoanToken, u),
        "UNSAFE: only the 7 modelled holders can take a supply position");
    ghostLlSupplyShares256[u] = val;
}
hook Sload uint128 val _Core.position[KEY LidoLend.Id id][KEY address u].borrowShares {
    require(ERC20_ACCOUNT_BOUNDS_OR_ZERO(ghostLlLoanToken, u),
        "UNSAFE: borrower reads restricted to the loan token's 7-slot account set");
    require(require_uint128(ghostLlBorrowShares128[u]) == val,
        "SAFE: ghostLlBorrowShares128 sync (one-market scalar)");
}
hook Sstore _Core.position[KEY LidoLend.Id id][KEY address u].borrowShares uint128 val {
    require(ERC20_ACCOUNT_BOUNDS_OR_ZERO(ghostLlLoanToken, u),
        "UNSAFE: only the 7 modelled holders can carry debt");
    ghostLlBorrowShares128[u] = val;
}
hook Sload uint128 val _Core.position[KEY LidoLend.Id id][KEY address u].collateral {
    require(ERC20_ACCOUNT_BOUNDS_OR_ZERO(ghostLlLoanToken, u),
        "UNSAFE: collateral reads restricted to the loan token's 7-slot account set");
    require(require_uint128(ghostLlCollateral128[u]) == val,
        "SAFE: ghostLlCollateral128 sync (one-market scalar)");
}
hook Sstore _Core.position[KEY LidoLend.Id id][KEY address u].collateral uint128 val {
    require(ERC20_ACCOUNT_BOUNDS_OR_ZERO(ghostLlLoanToken, u),
        "UNSAFE: only the 7 modelled holders can hold collateral");
    ghostLlCollateral128[u] = val;
}

// What the contract owes on a token: idle loan liquidity plus collateral, added when one address serves both
definition LL_TOKEN_BACKING(address t) returns mathint =
    (t == ghostLlLoanToken
        ? ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128 : 0)
    + (t == ghostLlCollateralToken ? LL_COLLATERAL_SUM() : 0);
