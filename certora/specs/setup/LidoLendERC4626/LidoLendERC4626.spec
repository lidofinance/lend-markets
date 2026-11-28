// Attached when the scene runs the contract's real bytecode: storage mirrors, hooks and the base setup.

import "../env.spec";
import "../safeErc20.spec";
import "../marketParamsLib.spec";

using LidoLendERC4626 as _Vault;

methods {
    // Scene cleanup: the one-shot initializer
    function _Vault.initialize(LidoLendERC4626.MarketParams, address, string, string)
        external => NONDET DELETE;
}

definition EXCLUDED_FUNCTION_VA(method f) returns bool =
    f.isView || f.isPure || f.isFallback
    ;

// SAFE: contract constant (LidoLendERC4626.sol).
definition SHARE_DECIMALS_VA_CVL() returns mathint = 18;

function setupLidoLendERC4626(env e) {
    setupEnv(e);
    setupERC20();

    require(ghostVaController != 0, "TRUSTED: nonzero controller from initialize");
    require(ghostVaParamsLoanToken != 0, "TRUSTED: nonzero loan token from initialize");
    require(ghostVaParamsCollateralToken != 0, "TRUSTED: nonzero collateral token from initialize");

    require(ghostVaAsset != _Vault,
        "TRUSTED: deployer-wired underlying, never the vault's own share token");
    require(ghostVaParamsCollateralToken != ghostVaParamsLoanToken,
        "TRUSTED: the market governance created lends one token against another");
    // The vault supplies with empty callback data.
    require(e.msg.sender != _Vault.LIDO_LEND(e),
        "SCOPE: the core never calls a vault entry point");
    require(_Vault.LIDO_LEND(e) != _Vault,
        "TRUSTED: deployer-wired lender, never the vault itself");
}

// --- Own erc7201 fields ---

persistent ghost LidoLendERC4626.Id ghostVaMarketId {
    init_state axiom ghostVaMarketId == to_bytes32(0);
}

persistent ghost address ghostVaController {
    init_state axiom ghostVaController == 0;
}
persistent ghost address ghostVaParamsLoanToken {
    init_state axiom ghostVaParamsLoanToken == 0;
}
persistent ghost address ghostVaParamsCollateralToken {
    init_state axiom ghostVaParamsCollateralToken == 0;
}
persistent ghost address ghostVaParamsOracle {
    init_state axiom ghostVaParamsOracle == 0;
}
persistent ghost address ghostVaParamsIrm {
    init_state axiom ghostVaParamsIrm == 0;
}
persistent ghost mathint ghostVaParamsLltv256 {
    init_state axiom ghostVaParamsLltv256 == 0;
    axiom ghostVaParamsLltv256 >= 0 && ghostVaParamsLltv256 <= max_uint256;
}
persistent ghost mathint ghostVaLoanDecimalsOffset8 {
    init_state axiom ghostVaLoanDecimalsOffset8 == 0;
    axiom ghostVaLoanDecimalsOffset8 >= 0 && ghostVaLoanDecimalsOffset8 <= max_uint8;
}
persistent ghost mathint ghostVaManagedSupplyShares256 {
    init_state axiom ghostVaManagedSupplyShares256 == 0;
    axiom ghostVaManagedSupplyShares256 >= 0 && ghostVaManagedSupplyShares256 <= max_uint256;
}

hook Sload LidoLendERC4626.Id val _Vault.marketId {
    require(ghostVaMarketId == val, "SAFE: ghostVaMarketId sync");
}
hook Sstore _Vault.marketId LidoLendERC4626.Id val {
    ghostVaMarketId = val;
}
hook Sload address val _Vault.controller {
    require(ghostVaController == val, "SAFE: ghostVaController sync");
}
hook Sstore _Vault.controller address val {
    ghostVaController = val;
}
hook Sload address val _Vault._marketParams.loanToken {
    require(ghostVaParamsLoanToken == val, "SAFE: ghostVaParamsLoanToken sync");
}
hook Sstore _Vault._marketParams.loanToken address val {
    ghostVaParamsLoanToken = val;
}
hook Sload address val _Vault._marketParams.collateralToken {
    require(ghostVaParamsCollateralToken == val, "SAFE: ghostVaParamsCollateralToken sync");
}
hook Sstore _Vault._marketParams.collateralToken address val {
    ghostVaParamsCollateralToken = val;
}
hook Sload address val _Vault._marketParams.oracle {
    require(ghostVaParamsOracle == val, "SAFE: ghostVaParamsOracle sync");
}
hook Sstore _Vault._marketParams.oracle address val {
    ghostVaParamsOracle = val;
}
hook Sload address val _Vault._marketParams.irm {
    require(ghostVaParamsIrm == val, "SAFE: ghostVaParamsIrm sync");
}
hook Sstore _Vault._marketParams.irm address val {
    ghostVaParamsIrm = val;
}
hook Sload uint256 val _Vault._marketParams.lltv {
    require(require_uint256(ghostVaParamsLltv256) == val, "SAFE: ghostVaParamsLltv256 sync");
}
hook Sstore _Vault._marketParams.lltv uint256 val {
    ghostVaParamsLltv256 = val;
}
hook Sload uint8 val _Vault._loanDecimalsOffset {
    require(require_uint8(ghostVaLoanDecimalsOffset8) == val, "SAFE: ghostVaLoanDecimalsOffset8 sync");
}
hook Sstore _Vault._loanDecimalsOffset uint8 val {
    ghostVaLoanDecimalsOffset8 = val;
}
hook Sload uint256 val _Vault._managedSupplyShares {
    require(require_uint256(ghostVaManagedSupplyShares256) == val, "SAFE: ghostVaManagedSupplyShares256 sync");
}
hook Sstore _Vault._managedSupplyShares uint256 val {
    ghostVaManagedSupplyShares256 = val;
}

// --- OZ ERC20 namespace: _balances, _allowances, _totalSupply, mirrored onto erc20.spec's ghosts ---

hook Sload uint256 val _Vault.(slot 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00)[KEY address a] {
    require(ERC20_ACCOUNT_BOUNDS(_Vault, a),
        "UNSAFE: share holders restricted to the 7 modelled accounts");
    require(require_uint256(ghostERC20Balances128[_Vault][a]) == val,
        "SAFE: share balance mirror sync");
}
hook Sstore _Vault.(slot 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00)[KEY address a] uint256 val {
    require(ERC20_ACCOUNT_BOUNDS(_Vault, a),
        "UNSAFE: only the 7 modelled accounts receive shares");
    ghostERC20Balances128[_Vault][a] = val;
}
hook Sload uint256 val _Vault.(slot 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace01)[KEY address o][KEY address s] {
    require(ERC20_ACCOUNT_BOUNDS(_Vault, o)
            && ERC20_ACCOUNT_BOUNDS(_Vault, s),
        "UNSAFE: share allowances only between the 7 modelled accounts");
    require(require_uint256(ghostERC20Allowances256[_Vault][o][s]) == val,
        "SAFE: share allowance mirror sync");
}
hook Sstore _Vault.(slot 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace01)[KEY address o][KEY address s] uint256 val {
    require(ERC20_ACCOUNT_BOUNDS(_Vault, o)
            && ERC20_ACCOUNT_BOUNDS(_Vault, s),
        "UNSAFE: share-allowance writes only between the 7 modelled accounts");
    ghostERC20Allowances256[_Vault][o][s] = val;
}
hook Sload uint256 val _Vault.(slot 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace02) {
    require(require_uint256(ghostERC20TotalSupply256[_Vault]) == val,
        "SAFE: share supply mirror sync");
}
hook Sstore _Vault.(slot 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace02) uint256 val {
    ghostERC20TotalSupply256[_Vault] = val;
}

// --- OZ ERC4626 namespace: _asset, _underlyingDecimals (per-field byte hooks) ---

persistent ghost address ghostVaAsset {
    init_state axiom ghostVaAsset == 0;
}
persistent ghost mathint ghostVaUnderlyingDecimals8 {
    init_state axiom ghostVaUnderlyingDecimals8 == 0;
    axiom ghostVaUnderlyingDecimals8 >= 0 && ghostVaUnderlyingDecimals8 <= max_uint8;
}

hook Sload address val _Vault.(slot 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00, offset 0) {
    require(ghostVaAsset == val, "SAFE: ghostVaAsset sync");
}
hook Sstore _Vault.(slot 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00, offset 0) address val {
    ghostVaAsset = val;
}
hook Sload uint8 val _Vault.(slot 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00, offset 20) {
    require(require_uint8(ghostVaUnderlyingDecimals8) == val, "SAFE: ghostVaUnderlyingDecimals8 sync");
}
hook Sstore _Vault.(slot 0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00, offset 20) uint8 val {
    ghostVaUnderlyingDecimals8 = val;
}
