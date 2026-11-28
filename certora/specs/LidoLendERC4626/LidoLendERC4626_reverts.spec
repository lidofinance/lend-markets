// Each rule pins when a call must fail and when it must not

import "LidoLendERC4626_valid_state.spec";
import "../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// VA-RV-01: Settling against an empty borrower list fails rather than doing nothing.
rule rvVaSettleRevertsOnEmptyBorrowers(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    bool emptyBorrowers = borrowers.length == 0;

    settle@withrevert(e, shares, borrowers, receiver, owner);
    bool reverted = lastReverted;

    assert(emptyBorrowers => reverted, "settle rejects an empty borrower list");
}

// VA-RV-02: A settle of zero shares fails instead of returning an empty result.
rule rvVaSettleRevertsOnZeroShares(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    bool zeroShares = shares == 0;

    settle@withrevert(e, shares, borrowers, receiver, owner);
    bool reverted = lastReverted;

    assert(zeroShares => reverted, "settle rejects a zero share amount");
}

// VA-RV-03: A settle paying the zero address fails, so seized collateral is never sent into the void.
rule rvVaSettleRevertsOnZeroReceiver(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    bool zeroReceiver = receiver == 0;

    settle@withrevert(e, shares, borrowers, receiver, owner);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted, "settle rejects the zero receiver");
}

// VA-RV-04: Nobody can settle more shares than the share owner actually holds.
rule rvVaSettleRevertsAboveOwnerBalance(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    bool aboveBalance = to_mathint(shares) > ghostERC20Balances128[_Vault][owner];

    settle@withrevert(e, shares, borrowers, receiver, owner);
    bool reverted = lastReverted;

    assert(aboveBalance => reverted, "settle rejects a burn above the owner's share balance");
}

// VA-RV-18: A fallback exit whose slice funds no settlement budget fails when free liquidity is gone.
rule rvVaFallbackExitRevertsOnZeroSettlingShares(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(ghostMcCvlMaxWithdrawable[ghostVaController][currentContract] == 0,
        "SCOPE: no free liquidity");
    bool zeroSettling = ghostVaManagedSupplyShares256 * shares < ghostERC20TotalSupply256[_Vault];

    fallbackExit@withrevert(e, shares, receiver, owner, maxIterations);
    bool reverted = lastReverted;

    assert(zeroSettling => reverted, "the fallback exit rejects a slice worth zero managed supply shares");
}

// VA-RV-05: A settle whose slice is too small to fund any cut fails.
rule rvVaSettleRevertsOnZeroSettlingShares(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    bool zeroSettling = ghostVaManagedSupplyShares256 * shares < ghostERC20TotalSupply256[_Vault];

    settle@withrevert(e, shares, borrowers, receiver, owner);
    bool reverted = lastReverted;

    assert(zeroSettling => reverted, "settle rejects a dust exit worth zero managed supply shares");
}

// VA-RV-06: A third party settling for an owner fails when its allowance does not cover the burned shares.
rule rvVaSettleRevertsOnMissingAllowance(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    bool thirdParty = e.msg.sender != owner;
    mathint allowanceBefore = ghostERC20Allowances256[_Vault][owner][e.msg.sender];
    mathint ownerSharesBefore = ghostERC20Balances128[_Vault][owner];

    settle@withrevert(e, shares, borrowers, receiver, owner);
    bool reverted = lastReverted;

    mathint sharesBurned = ownerSharesBefore - ghostERC20Balances128[_Vault][owner];

    assert((thirdParty && allowanceBefore != max_uint256 && allowanceBefore < sharesBurned)
        => reverted,
        "a third-party settle needs an allowance covering the burned shares");
}

// VA-RV-07: A fallback exit of zero shares fails instead of returning an empty result.
rule rvVaFallbackExitRevertsOnZeroShares(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    bool zeroShares = shares == 0;

    fallbackExit@withrevert(e, shares, receiver, owner, maxIterations);
    bool reverted = lastReverted;

    assert(zeroShares => reverted, "fallbackExit rejects a zero share amount");
}

// VA-RV-08: A fallback exit paying the zero address fails, so the exiting assets are never sent into the void.
rule rvVaFallbackExitRevertsOnZeroReceiver(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    bool zeroReceiver = receiver == 0;

    fallbackExit@withrevert(e, shares, receiver, owner, maxIterations);
    bool reverted = lastReverted;

    assert(zeroReceiver => reverted, "fallbackExit rejects the zero receiver");
}

// VA-RV-09: Nobody can fallback exit more shares than the share owner actually holds.
rule rvVaFallbackExitRevertsAboveOwnerBalance(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    bool aboveBalance = to_mathint(shares) > ghostERC20Balances128[_Vault][owner];

    fallbackExit@withrevert(e, shares, receiver, owner, maxIterations);
    bool reverted = lastReverted;

    assert(aboveBalance => reverted,
        "fallbackExit rejects a burn above the owner's share balance");
}

// VA-RV-10: A third party withdrawing for an owner fails when its allowance does not cover the shares charged.
rule rvVaWithdrawRevertsOnMissingAllowance(env e, uint256 assets, address receiver,
    address owner) {

    setupLidoLendERC4626ValidState(e);
    uint256 sharesCharged = previewWithdraw(e, assets);
    bool thirdParty = e.msg.sender != owner;
    mathint allowanceBefore = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    withdraw@withrevert(e, assets, receiver, owner);
    bool reverted = lastReverted;

    assert((thirdParty && allowanceBefore != max_uint256
        && allowanceBefore < to_mathint(sharesCharged)) => reverted,
        "a third-party withdraw needs an allowance covering the charged shares");
}

// VA-RV-11: Redeeming more shares than the owner holds fails, and a redeem that goes through debits exactly those shares.
rule rvVaRedeemRevertsAboveOwnerBalance(env e, uint256 shares, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    mathint balBefore = ghostERC20Balances128[_Vault][owner];
    bool aboveBalance = to_mathint(shares) > balBefore;

    redeem@withrevert(e, shares, receiver, owner);
    bool reverted = lastReverted;

    assert(aboveBalance => reverted, "redeem rejects a burn above the owner's share balance");
    assert(!reverted => ghostERC20Balances128[_Vault][owner] == balBefore - shares,
        "a redeem that goes through debits exactly the requested shares from the owner");
}

// VA-RV-12: Reading the number of decimals the vault's shares use never fails.
rule rvVaDecimalsNeverReverts(env e) {

    setupLidoLendERC4626ValidState(e);
    require(ghostVaUnderlyingDecimals8 + ghostVaLoanDecimalsOffset8 <= max_uint8,
        "TRUSTED: init-frozen offset of 18 minus token decimals");

    decimals@withrevert(e);
    bool reverted = lastReverted;

    assert(!reverted, "decimals never reverts under valid state");
}

// VA-RV-13: Quoting a deposit never fails for asset amounts in the supported range.
rule rvVaPreviewDepositNeverReverts(env e, uint256 assets) {

    setupLidoLendERC4626ValidState(e);
    require(to_mathint(assets) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    require(ghostERC20TotalSupply256[_Vault] <= max_uint128 - 10 ^ 18,
        "SCOPE: share supply inside the uint128 band");

    previewDeposit@withrevert(e, assets);
    bool reverted = lastReverted;

    assert(!reverted, "previewDeposit never reverts under valid state");
}

// VA-RV-14: Quoting a mint never fails for share amounts in the supported range.
rule rvVaPreviewMintNeverReverts(env e, uint256 shares) {

    setupLidoLendERC4626ValidState(e);
    require(to_mathint(shares) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");

    previewMint@withrevert(e, shares);
    bool reverted = lastReverted;

    assert(!reverted, "previewMint never reverts under valid state");
}

// VA-RV-15: Quoting a withdrawal never fails for asset amounts in the supported range.
rule rvVaPreviewWithdrawNeverReverts(env e, uint256 assets) {

    setupLidoLendERC4626ValidState(e);
    require(to_mathint(assets) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    require(ghostERC20TotalSupply256[_Vault] <= max_uint128 - 10 ^ 18,
        "SCOPE: share supply inside the uint128 band");

    previewWithdraw@withrevert(e, assets);
    bool reverted = lastReverted;

    assert(!reverted, "previewWithdraw never reverts under valid state");
}

// VA-RV-16: Quoting a redemption never fails for share amounts in the supported range.
rule rvVaPreviewRedeemNeverReverts(env e, uint256 shares) {

    setupLidoLendERC4626ValidState(e);
    require(to_mathint(shares) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");

    previewRedeem@withrevert(e, shares);
    bool reverted = lastReverted;

    assert(!reverted, "previewRedeem never reverts under valid state");
}

// VA-RV-17: An authorized exit of shares the market's free liquidity fully covers is never refused.
rule rvVaFallbackExitDoesNotRevertWhenLiquidityCovers(env e, uint256 shares, address receiver, address owner,
    uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(receiver != 0 && shares != 0
            && to_mathint(shares) <= ghostERC20Balances128[_Vault][owner],
        "SCOPE: a nonzero receiver and nonzero shares within the owner's balance");
    require(e.msg.sender == owner
            || ghostERC20Allowances256[_Vault][owner][e.msg.sender] >= to_mathint(shares),
        "SCOPE: the spend is authorized");
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(liquid != 0 && to_mathint(previewRedeem(e, shares)) <= liquid,
        "SCOPE: positive free liquidity covers the whole request");

    fallbackExit@withrevert(e, shares, receiver, owner, maxIterations);
    bool reverted = lastReverted;

    assert(!reverted,
        "an authorized exit the free liquidity covers is never refused");
}

// VA-RV-19: A deposit that pays assets but would mint no shares fails, so nobody pays for nothing.
rule rvVaDepositRevertsWhenItWouldMintNothing(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);
    bool mintsNothing = assets > 0 && previewDeposit(e, assets) == 0;

    deposit@withrevert(e, assets, receiver);
    bool reverted = lastReverted;

    assert(mintsNothing => reverted,
        "a deposit whose shares floor to zero is refused rather than absorbed");
}

// VA-RV-20: Every settle that goes through burns shares and consumes the core supply the vault manages, never a silent no-op.
rule rvVaSettleRevertsWhenNothingIsSettled(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    mathint managedBefore = ghostVaManagedSupplyShares256;

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    assert(ghostVaManagedSupplyShares256 < managedBefore,
        "a settle that goes through consumes managed supply shares");
    assert(sharesBurned != 0, "a settle that goes through burns shares");
}

// VA-RV-21: Every fallback exit that goes through burns shares from the owner, never a silent no-op.
rule rvVaFallbackExitRevertsWhenNothingIsSettled(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(sharesBurned != 0, "a fallback exit that goes through burns shares");
    assert(ghostERC20Balances128[_Vault][owner] < balBefore,
        "the owner pays for every exit that goes through");
}

// VA-RV-22: A funded deposit that goes through always buys core supply, so no share is backed by nothing.
rule rvVaDepositRevertsWhenCoreMintsNothing(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);
    mathint managedBefore = ghostVaManagedSupplyShares256;

    deposit(e, assets, receiver);

    assert(assets != 0 => ghostVaManagedSupplyShares256 > managedBefore,
        "a funded deposit that goes through buys core supply shares");
}
