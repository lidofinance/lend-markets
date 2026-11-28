// Each rule bounds how storage may move in any single call: snapshot it, invoke any external method, assert
// the law; first a single variable's own band, then the co-change of the variables that move together.

import "LidoLendERC4626_valid_state.spec";
import "../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// VA-VT-01: The vault's controller, market and token pair never change after it is set up.
rule vtVaMarketIdentityImmutable(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) } {

    setupLidoLendERC4626(e);

    LidoLendERC4626.Id marketIdBefore = ghostVaMarketId;
    address controllerBefore = ghostVaController;
    address loanTokenBefore = ghostVaParamsLoanToken;
    address collateralTokenBefore = ghostVaParamsCollateralToken;

    f(e, args);

    LidoLendERC4626.Id marketIdAfter = ghostVaMarketId;
    address controllerAfter = ghostVaController;
    address loanTokenAfter = ghostVaParamsLoanToken;
    address collateralTokenAfter = ghostVaParamsCollateralToken;

    assert(marketIdAfter == marketIdBefore, "the market id never changes");
    assert(controllerAfter == controllerBefore, "the controller never changes");
    assert(loanTokenAfter == loanTokenBefore, "the loan token never changes");
    assert(collateralTokenAfter == collateralTokenBefore, "the collateral token never changes");
}

// VA-VT-02: The vault's oracle, rate model, loan-to-value limit and decimals offset never change after setup.
rule vtVaMarketParamsImmutable(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) } {

    setupLidoLendERC4626(e);

    address oracleBefore = ghostVaParamsOracle;
    address irmBefore = ghostVaParamsIrm;
    mathint lltvBefore = ghostVaParamsLltv256;
    mathint offsetBefore = ghostVaLoanDecimalsOffset8;

    f(e, args);

    address oracleAfter = ghostVaParamsOracle;
    address irmAfter = ghostVaParamsIrm;
    mathint lltvAfter = ghostVaParamsLltv256;
    mathint offsetAfter = ghostVaLoanDecimalsOffset8;

    assert(oracleAfter == oracleBefore, "the oracle never changes");
    assert(irmAfter == irmBefore, "the irm never changes");
    assert(lltvAfter == lltvBefore, "the lltv never changes");
    assert(offsetAfter == offsetBefore, "the loan-decimals offset never changes");
}

// VA-VT-03: Only the vault's own deposits and exits move the core supply it manages, and by exactly the amount they moved.
rule vtVaManagedCounterTracksCoreSupplyMoves(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) } {

    setupLidoLendERC4626ValidState(e);

    mathint managedBefore = ghostVaManagedSupplyShares256;
    mathint posBefore = ghostLlCvlPosSupplyShares[currentContract];

    f(e, args);

    assert(ghostVaManagedSupplyShares256 != managedBefore
        => (f.selector == sig:deposit(uint256,address).selector
            || f.selector == sig:mint(uint256,address).selector
            || f.selector == sig:withdraw(uint256,address,address).selector
            || f.selector == sig:redeem(uint256,address,address).selector
            || f.selector == sig:settle(uint256,address[],address,address).selector
            || f.selector == sig:fallbackExit(uint256,address,address,uint256).selector),
        "only the entry and exit flows move the managed counter");
    assert(ghostVaManagedSupplyShares256 - managedBefore
            == ghostLlCvlPosSupplyShares[currentContract] - posBefore,
        "the counter moves by exactly the core supply shares the call moved");
}

// VA-ST-01: An allowance rises only when its own holder is the caller.
rule stVaAllowanceSpendOnly(env e, method f, calldataarg args, address o, address s)
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) } {

    setupLidoLendERC4626ValidState(e);
    mathint allowBefore = ghostERC20Allowances256[_Vault][o][s];

    f(e, args);

    assert(ghostERC20Allowances256[_Vault][o][s] > allowBefore => o == e.msg.sender,
        "only the owner raises an allowance");
}

// VA-ST-02: Shares leave a holder only by the holder's own act or within an allowance covering the whole debit.
rule stVaThirdPartyDebitIsAuthorized(env e, method f, calldataarg args, address a)
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) } {

    setupLidoLendERC4626ValidState(e);
    mathint balBefore = ghostERC20Balances128[_Vault][a];
    mathint allowBefore = ghostERC20Allowances256[_Vault][a][e.msg.sender];

    f(e, args);

    assert((ghostERC20Balances128[_Vault][a] < balBefore && a != e.msg.sender)
            => allowBefore >= balBefore - ghostERC20Balances128[_Vault][a],
        "a third-party debit never exceeds the allowance the holder granted");
}
