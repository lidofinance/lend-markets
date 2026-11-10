// Forked core scene for the accrual comparison: base setup, deterministic summaries for share math, borrow
// rate, oracle price and market id, and no storage mirrors. The summaries are consistent, not exact, so a
// rule shows two paths agreeing, never that a number is right.

import "../env.spec";

using LidoLend as _Core;

// Declared by every attachment mode: co-import fails as a duplicate declaration.
persistent ghost bool ghostLlModeMarker;

// Uninterpreted but consistent within a rule: both paths applying the same arguments get the same result.
ghost ghostAiMulDivDown(uint256, uint256, uint256) returns uint256;
ghost ghostAiMulDivUp(uint256, uint256, uint256) returns uint256;
ghost ghostAiTaylorCompounded(uint256, uint256) returns uint256;
ghost ghostAiBorrowRate(address, uint256) returns uint256;
ghost ghostAiOraclePrice(address, uint256) returns uint256;
ghost ghostAiMarketId(address) returns bytes32;
ghost ghostAiMarketParamsId(address, address, address, address, uint256) returns MarketParamsLib.Id;

methods {
    // Scene cleanup: assembly sload loop + ecrecover (sig-path guard reviewed manually).
    function _Core.extSloads(bytes32[]) external returns (bytes32[]) => NONDET DELETE;
    function _Core.setAuthorizationWithSig(LidoLend.Authorization, LidoLend.Signature)
        external => NONDET DELETE;

    // Deterministic math: SharesMathLib and the w* helpers all route through these three entry points.
    function MathLib.mulDivDown(uint256 x, uint256 y, uint256 d) internal returns (uint256)
        => ghostAiMulDivDown(x, y, d);
    function MathLib.mulDivUp(uint256 x, uint256 y, uint256 d) internal returns (uint256)
        => ghostAiMulDivUp(x, y, d);
    function MathLib.wTaylorCompounded(uint256 x, uint256 n) internal returns (uint256)
        => ghostAiTaylorCompounded(x, n);

    // Deterministic rate: the same irm at the same timestamp always quotes the same rate.
    function _.borrowRate(LidoLend.MarketParams marketParams, LidoLend.Market) external with (env e)
        => ghostAiBorrowRate(marketParams.irm, e.block.timestamp) expect uint256;

    // Deterministic price: the same oracle at the same timestamp always quotes the same price.
    function _.price() external with (env e)
        => ghostAiOraclePrice(calledContract, e.block.timestamp) expect uint256;

    // Transfers leave no trace: no token contract in the scene, the paths only need to agree.
    function SafeTransferLib.safeTransfer(address token, address to, uint256 value)
        internal => aiNoOpCVL();
    function SafeTransferLib.safeTransferFrom(address token, address from, address to, uint256 value)
        internal => aiNoOpCVL();

    // Controller surface: on() is a non-mutating no-op on both paths; marketId is per-callee frozen.
    function _.on(bytes32 id, uint8 hookEvent, bytes data) external => aiNoOpCVL() expect void;
    function _.marketId() external => ghostAiMarketId(calledContract) expect bytes32;

    // The market row a call addresses, as a deterministic function of the params.
    function MarketParamsLib.id(MarketParamsLib.MarketParams memory marketParams)
        internal returns MarketParamsLib.Id => aiMarketParamsIdCVL(marketParams);

    // Callbacks: untrusted, void, no return value is consumed.
    function _.onMorphoSupply(uint256, bytes) external => NONDET;
    function _.onMorphoRepay(uint256, bytes) external => NONDET;
    function _.onMorphoSupplyCollateral(uint256, bytes) external => NONDET;
    function _.onMorphoLiquidate(uint256, bytes) external => NONDET;
    function _.onMorphoFlashLoan(uint256, bytes) external => NONDET;
}

function aiNoOpCVL() {
}

function aiMarketParamsIdCVL(MarketParamsLib.MarketParams marketParams) returns MarketParamsLib.Id {
    return ghostAiMarketParamsId(
        marketParams.loanToken,
        marketParams.collateralToken,
        marketParams.oracle,
        marketParams.irm,
        marketParams.lltv
    );
}
