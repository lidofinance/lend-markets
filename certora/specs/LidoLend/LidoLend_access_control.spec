// Each rule names the authority a piece of state requires: snapshot it, invoke any external method,
// assert it moved only if the caller held that role or committee seat.

import "LidoLend_valid_state.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// LL-AC-01: Only the current owner can hand over ownership, apart from the one time initial setup.
rule acLlOnlyOwnerOrInitLatchMovesOwner(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    address ownerBefore = ghostLlOwner;
    bool initializedBefore = ghostLlIsInitialized;

    f(e, args);

    assert(ghostLlOwner != ownerBefore
        => e.msg.sender == ownerBefore || (!initializedBefore && ghostLlIsInitialized),
        "the owner changes only by the owner or through the one-shot initializer");
}

// LL-AC-02: Only the owner can change the address that receives protocol fees.
rule acLlOnlyOwnerMovesFeeRecipient(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    address ownerBefore = ghostLlOwner;
    address feeRecipientBefore = ghostLlFeeRecipient;

    f(e, args);

    assert(ghostLlFeeRecipient != feeRecipientBefore => e.msg.sender == ownerBefore,
        "only the owner may change the fee recipient");
}

// LL-AC-03: Only the owner can change a market's interest fee.
rule acLlOnlyOwnerMovesMarketFee(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    address ownerBefore = ghostLlOwner;
    mathint feeBefore = ghostLlFee128;

    f(e, args);

    assert(ghostLlFee128 != feeBefore => e.msg.sender == ownerBefore,
        "only the owner may change a market fee");
}

// LL-AC-04: Only the lender or an account they authorized can reduce their supply shares.
rule acLlUnauthorizedCannotReduceSupplyShares(env e, method f, calldataarg args, address user)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    mathint supplySharesBefore = ghostLlSupplyShares256[user];
    bool authorizedBefore = ghostLlIsAuthorized[user][e.msg.sender];

    f(e, args);

    assert(e.msg.sender != user && !authorizedBefore
        => ghostLlSupplyShares256[user] >= supplySharesBefore,
        "an unauthorized caller must not reduce a user's supply shares");
}

// LL-AC-05: Only the borrower or an account they authorized can add to their debt.
rule acLlUnauthorizedCannotIncreaseBorrowShares(env e, method f, calldataarg args, address user)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    mathint borrowSharesBefore = ghostLlBorrowShares128[user];
    bool authorizedBefore = ghostLlIsAuthorized[user][e.msg.sender];

    f(e, args);

    assert(e.msg.sender != user && !authorizedBefore
        => ghostLlBorrowShares128[user] <= borrowSharesBefore,
        "an unauthorized caller must not increase a user's borrow shares");
}

// LL-AC-06: Only the account itself grants or revokes permission over its positions.
rule acLlAuthorizationRowMovesOnlyByAuthorizer(
    env e, method f, calldataarg args, address authorizer, address authorized
) filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    bool isAuthorizedBefore = ghostLlIsAuthorized[authorizer][authorized];

    f(e, args);

    assert(ghostLlIsAuthorized[authorizer][authorized] != isAuthorizedBefore
        => e.msg.sender == authorizer,
        "an authorization row changes only by its authorizer");
}

// LL-AC-07: Collateral leaves a user without their consent only through liquidation or settlement.
rule acLlSeizureOnlyByLiquidateOrSettle(env e, method f, calldataarg args, address user)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    mathint collateralBefore = ghostLlCollateral128[user];
    bool authorizedBefore = ghostLlIsAuthorized[user][e.msg.sender];

    f(e, args);

    assert((ghostLlCollateral128[user] < collateralBefore
            && e.msg.sender != user && !authorizedBefore)
        => (f.selector == sig:liquidate(LidoLend.MarketParams,address,uint256,uint256,bytes).selector
            || f.selector
                == sig:settle(LidoLend.MarketParams,uint256,address,address,address).selector),
        "a non-consenting user's collateral decreases only through liquidate or settle");
}

// LL-AC-08: A user with no debt never loses collateral to a caller they did not authorize.
rule acLlDebtFreeCollateralNeverSeized(env e, method f, calldataarg args, address user)
    filtered { f -> !EXCLUDED_FUNCTION_LL(f) } {

    setupLidoLend(e);

    mathint collateralBefore = ghostLlCollateral128[user];
    mathint borrowSharesBefore = ghostLlBorrowShares128[user];
    bool authorizedBefore = ghostLlIsAuthorized[user][e.msg.sender];

    f(e, args);

    assert((e.msg.sender != user && !authorizedBefore && borrowSharesBefore == 0)
        => ghostLlCollateral128[user] >= collateralBefore,
        "a debt-free user's collateral never decreases on an unauthorized call");
}
