// Each rule bounds how one storage variable may move in any single call: snapshot it, invoke any external method,
// assert the law (monotonicity, a step bound, a permitted-value set).

import "LidoLend_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// LL-VT-01: A market's interest clock only ever moves forward.
rule vtLlLastUpdateMonotonic(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    requireInvariant lastUpdateNotInFuture(e);
    mathint lastUpdateBefore = ghostLlLastUpdate128;

    f(e, args);

    mathint lastUpdateAfter = ghostLlLastUpdate128;

    assert(lastUpdateAfter >= lastUpdateBefore,
        "lastUpdate must only increase or stay the same");
}

// LL-VT-02: Once initialized, the pool can never be returned to an uninitialized state.
rule vtLlInitializedLatchesOn(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    bool initializedBefore = ghostLlIsInitialized;

    f(e, args);

    bool initializedAfter = ghostLlIsInitialized;

    assert(initializedBefore => initializedAfter,
        "isInitialized cannot be reset once set");
}

// LL-VT-03: Apart from signature based authorization, no call moves a signer's nonce.
rule vtLlNonceMonotonic(env e, method f, calldataarg args, address account)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    mathint nonceBefore = ghostLlNonce256[account];

    f(e, args);

    mathint nonceAfter = ghostLlNonce256[account];

    assert(nonceAfter == nonceBefore,
        "no method in this scene may move a signer's nonce");
}

// LL-VT-04: Only withdraw, borrow, collateral withdrawal, liquidation, settlement and flash loans can reduce the pool's token balance.
rule vtLlCoreBalanceOutflowOnlyViaExits(env e, method f, calldataarg args, address token)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f)
        && f.selector != sig:withdraw(LidoLend.MarketParams,uint256,uint256,address,address).selector
        && f.selector != sig:borrow(LidoLend.MarketParams,uint256,uint256,address,address).selector
        && f.selector != sig:withdrawCollateral(LidoLend.MarketParams,uint256,address,address).selector
        && f.selector != sig:liquidate(LidoLend.MarketParams,address,uint256,uint256,bytes).selector
        && f.selector != sig:settle(LidoLend.MarketParams,uint256,address,address,address).selector
        && f.selector != sig:flashLoan(address,uint256,bytes).selector } {

    setupLidoLend(e);

    mathint balanceBefore = ghostERC20Balances128[token][_Core];

    f(e, args);

    mathint balanceAfter = ghostERC20Balances128[token][_Core];

    assert(balanceAfter >= balanceBefore,
        "outside the exit entry points the pool's token balance never decreases");
}

// LL-VT-05: A market's tokens, oracle, rate model, liquidation threshold, controller and settlement switch never change after creation.
rule vtLlMarketWiringImmutable(env e, method f, calldataarg args, address anyIrm, uint256 anyLltv)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    address controllerBefore = ghostLlMarketController;
    bool settlementBefore = ghostLlIsSettlementEnabled;
    bool irmEnabledBefore = ghostLlIsIrmEnabled[anyIrm];
    bool lltvEnabledBefore = ghostLlIsLltvEnabled[anyLltv];
    address loanBefore = ghostLlLoanToken;
    address collateralBefore = ghostLlCollateralToken;
    address oracleBefore = ghostLlOracle;
    address irmBefore = ghostLlIrm;
    mathint lltvBefore = ghostLlLltv256;

    f(e, args);

    assert(ghostLlMarketController == controllerBefore
        && ghostLlIsSettlementEnabled == settlementBefore
        && ghostLlIsIrmEnabled[anyIrm] == irmEnabledBefore
        && ghostLlIsLltvEnabled[anyLltv] == lltvEnabledBefore
        && ghostLlLoanToken == loanBefore
        && ghostLlCollateralToken == collateralBefore
        && ghostLlOracle == oracleBefore
        && ghostLlIrm == irmBefore
        && ghostLlLltv256 == lltvBefore,
        "market wiring and terms move only through the creation path, which no live call reaches");
}
