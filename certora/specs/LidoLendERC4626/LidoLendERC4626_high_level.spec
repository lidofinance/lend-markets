// Each rule walks a concrete scenario: one named external call, or a sequence of them, then asserts the end-to-end
// law (conservation, isolation, monotonicity, a round trip, the authority a piece of state requires).

import "LidoLendERC4626_valid_state.spec";
import "../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// VA-HL-01: A deposit leaves every share balance other than the receiver's untouched.
rule hlVaDepositLeavesOtherBalances(env e, uint256 assets, address receiver, address other) {

    setupLidoLendERC4626ValidState(e);
    require(other != receiver,
        "SCOPE: a bystander, not the receiver");
    mathint balBefore = ghostERC20Balances128[_Vault][other];

    deposit(e, assets, receiver);

    assert(ghostERC20Balances128[_Vault][other] == balBefore,
        "a deposit touches only the receiver");
}

// VA-HL-02: A redeem leaves every share balance other than the owner's untouched.
rule hlVaRedeemLeavesOtherBalances(env e, uint256 shares, address receiver, address owner, address other) {

    setupLidoLendERC4626ValidState(e);
    require(other != owner,
        "SCOPE: a bystander, not the owner");
    mathint balBefore = ghostERC20Balances128[_Vault][other];

    redeem(e, shares, receiver, owner);

    assert(ghostERC20Balances128[_Vault][other] == balBefore,
        "a redeem touches only the owner");
}

// VA-HL-03: Settling for someone else spends exactly the burned shares of their approval, and unlimited approval stays unlimited.
rule hlVaSettleSpendsAllowanceExactly(env e, uint256 shares, address[] borrowers, address receiver, address owner) {
    require(e.msg.sender != owner,
        "SCOPE: the third-party allowance leg");

    setupLidoLendERC4626ValidState(e);
    mathint allowBefore = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    assert((allowBefore == max_uint256 => ghostERC20Allowances256[_Vault][owner][e.msg.sender] == max_uint256)
        && (allowBefore != max_uint256
            => ghostERC20Allowances256[_Vault][owner][e.msg.sender]
                == allowBefore - sharesBurned),
        "settle spends exactly the burned shares; infinite approval is untouched");
}

// VA-HL-04: An exit quote never costs fewer shares or pays more assets than the matching entry quote.
rule hlVaPreviewRoundingFavorsVault(env e, uint256 assets, uint256 shares) {

    setupLidoLendERC4626ValidState(e);
    uint256 sharesCharged = previewWithdraw(e, assets);
    uint256 sharesGranted = previewDeposit(e, assets);
    uint256 assetsCharged = previewMint(e, shares);
    uint256 assetsGranted = previewRedeem(e, shares);

    assert(sharesCharged >= sharesGranted && assetsCharged >= assetsGranted,
        "the shares charged to exit never undercut the shares granted to enter");
}

// VA-HL-05: A withdraw burns exactly the shares its quote advertised, with no repricing during the call.
rule hlVaWithdrawBurnsAtMostPreview(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    uint256 quote = previewWithdraw(e, assets);
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    withdraw(e, assets, receiver, owner);

    assert(balBefore - ghostERC20Balances128[_Vault][owner] == to_mathint(quote),
        "a withdraw burns exactly the advertised quote");
}

// VA-HL-06: Minting shares and redeeming them straight back never returns more assets than the mint cost.
rule hlVaMintRedeemNoProfit(env e, uint256 shares, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(shares < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    require(ghostERC20TotalSupply256[_Vault] < max_uint128 - 10^18,
        "SCOPE: share supply inside the uint128 band");

    uint256 assetsIn = mint(e, shares, receiver);
    uint256 assetsOut = redeem(e, shares, receiver, receiver);

    assert(assetsOut <= assetsIn,
        "a mint-redeem round trip never returns more assets than it cost");
}

// VA-HL-07: Only deposits and mints create shares, and only the withdraw, redeem and settlement paths burn them.
rule hlVaSupplyMovesOnlyOnFlows(env e, method f, calldataarg args)
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) } {

    setupLidoLendERC4626ValidState(e);

    mathint supplyBefore = ghostERC20TotalSupply256[_Vault];

    f(e, args);

    mathint supplyAfter = ghostERC20TotalSupply256[_Vault];

    assert(supplyAfter > supplyBefore
        => (f.selector == sig:deposit(uint256,address).selector
            || f.selector == sig:mint(uint256,address).selector),
        "only deposit and mint create shares");
    assert(supplyAfter < supplyBefore
        => (f.selector == sig:withdraw(uint256,address,address).selector
            || f.selector == sig:redeem(uint256,address,address).selector
            || f.selector == sig:settle(uint256,address[],address,address).selector
            || f.selector == sig:fallbackExit(uint256,address,address,uint256).selector),
        "only the withdraw and exit flows burn shares");
}

// VA-HL-08: A settlement burns at most the shares the caller asked for, all taken from the named owner.
rule hlVaSettleBurnsAtMostRequestedShares(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    assert(sharesBurned <= shares, "settle never burns past the requested shares");
    assert(ghostERC20Balances128[_Vault][owner] == balBefore - sharesBurned,
        "the reported burn is exactly what the owner lost");
}

// VA-HL-09: A settlement burns the requested shares scaled by the position its cuts actually consumed, rounded up.
rule hlVaSettleBurnsProRataOfConsumedBudget(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    mathint managedBefore = ghostVaManagedSupplyShares256;
    mathint supplyBefore = ghostERC20TotalSupply256[_Vault];

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    mathint budget = managedBefore * shares / supplyBefore;
    mathint consumed = managedBefore - ghostVaManagedSupplyShares256;

    assert(budget != 0
        => to_mathint(sharesBurned) == (shares * consumed + budget - 1) / budget,
        "the burn is the request scaled by the consumed managed budget, rounded up");
}

// VA-HL-10: With no free liquidity, a fallback exit burns the request scaled by the position its sweep consumed, rounded up.
rule hlVaFallbackExitBurnsProRataOfConsumedBudget(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(ghostMcCvlMaxWithdrawable[ghostVaController][currentContract] == 0,
        "SCOPE: no free liquidity");
    mathint managedBefore = ghostVaManagedSupplyShares256;
    mathint supplyBefore = ghostERC20TotalSupply256[_Vault];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    mathint budget = managedBefore * shares / supplyBefore;
    mathint consumed = managedBefore - ghostVaManagedSupplyShares256;

    assert(budget != 0
        => to_mathint(sharesBurned) == (shares * consumed + budget - 1) / budget,
        "the burn is the request scaled by the consumed managed budget, rounded up");
}

// VA-HL-11: A settlement never dilutes the holders who stay, since the backing per remaining share never falls.
rule hlVaSettleDoesNotDiluteRemainingHolders(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    mathint managedBefore = ghostVaManagedSupplyShares256;
    mathint supplyBefore = ghostERC20TotalSupply256[_Vault];

    settle(e, shares, borrowers, receiver, owner);

    assert(ghostVaManagedSupplyShares256 * supplyBefore
            >= managedBefore * ghostERC20TotalSupply256[_Vault],
        "managed core supply per remaining share never falls");
}

// VA-HL-12: A settlement pays every token of seized collateral to the receiver the caller named, and the vault keeps none.
rule hlVaSettlePaysSeizedCollateralToReceiver(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(receiver != LIDO_LEND(e),
        "SCOPE: the receiver is not the core");
    mathint recvBefore = ghostERC20Balances128[ghostVaParamsCollateralToken][receiver];
    mathint vaultBefore = ghostERC20Balances128[ghostVaParamsCollateralToken][currentContract];

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    assert(ghostERC20Balances128[ghostVaParamsCollateralToken][receiver] == recvBefore + collateralSeized,
        "the receiver gains exactly the seized collateral, whoever it is");
    assert(receiver != currentContract
        => ghostERC20Balances128[ghostVaParamsCollateralToken][currentContract] == vaultBefore,
        "the vault custodies no collateral unless the caller named it as the receiver");
}

// VA-HL-13: A fallback exit pays the collateral it seizes to the caller's named receiver, and the vault keeps none.
rule hlVaFallbackExitPaysSeizedCollateralToReceiver(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(receiver != LIDO_LEND(e),
        "SCOPE: the receiver is not the core");
    mathint recvBefore = ghostERC20Balances128[ghostVaParamsCollateralToken][receiver];
    mathint vaultBefore = ghostERC20Balances128[ghostVaParamsCollateralToken][currentContract];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(ghostERC20Balances128[ghostVaParamsCollateralToken][receiver] == recvBefore + collateralSeized,
        "the receiver gains exactly the seized collateral, whoever it is");
    assert(receiver != currentContract
        => ghostERC20Balances128[ghostVaParamsCollateralToken][currentContract] == vaultBefore,
        "the vault custodies no collateral unless the caller named it as the receiver");
}

// VA-HL-14: A settlement cuts only the borrowers the caller listed, leaving every other borrower's debt and collateral untouched.
rule hlVaSettleTouchesOnlyNamedBorrowers(env e, uint256 shares, address[] borrowers,
    address receiver, address owner, address other) {

    setupLidoLendERC4626ValidState(e);
    require(borrowers.length == 2, "SCOPE: a two-name list within the unrolled loop bound");
    require(other != borrowers[0] && other != borrowers[1],
        "SCOPE: a bystander outside the caller's list");
    mathint debtBefore = ghostLlCvlPosBorrowShares[other];
    mathint collateralBefore = ghostLlCvlPosCollateral[other];

    settle(e, shares, borrowers, receiver, owner);

    assert(ghostLlCvlPosBorrowShares[other] == debtBefore
        && ghostLlCvlPosCollateral[other] == collateralBefore,
        "a borrower outside the caller's list is never cut");
}

// VA-HL-15: A fallback exit capped at one round never settles two different borrowers.
rule hlVaFallbackExitSettleLegRespectsIterationCap(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations, address b1, address b2) {

    setupLidoLendERC4626ValidState(e);
    require(maxIterations == 1,
        "SCOPE: the tightest iteration cap");
    require(b1 != b2,
        "SCOPE: two distinct borrowers");
    mathint debtBefore1 = ghostLlCvlPosBorrowShares[b1];
    mathint collateralBefore1 = ghostLlCvlPosCollateral[b1];
    mathint debtBefore2 = ghostLlCvlPosBorrowShares[b2];
    mathint collateralBefore2 = ghostLlCvlPosCollateral[b2];

    fallbackExit(e, shares, receiver, owner, maxIterations);

    assert((ghostLlCvlPosBorrowShares[b1] == debtBefore1 && ghostLlCvlPosCollateral[b1] == collateralBefore1)
        || (ghostLlCvlPosBorrowShares[b2] == debtBefore2 && ghostLlCvlPosCollateral[b2] == collateralBefore2),
        "a one-iteration sweep never cuts two borrowers");
}

// VA-HL-16: With no free liquidity, a fallback exit still never dilutes the holders who stay.
rule hlVaFallbackExitDoesNotDiluteRemainingHolders(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(ghostMcCvlMaxWithdrawable[ghostVaController][currentContract] == 0,
        "SCOPE: no free liquidity");
    mathint managedBefore = ghostVaManagedSupplyShares256;
    mathint supplyBefore = ghostERC20TotalSupply256[_Vault];

    fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(ghostVaManagedSupplyShares256 * supplyBefore
            >= managedBefore * ghostERC20TotalSupply256[_Vault],
        "managed core supply per remaining share never falls");
}

// VA-HL-17: The collateral a settlement reports as seized comes out of the named borrower's own position.
rule hlVaSettleCutsTheNamedBorrower(env e, uint256 shares, address[] borrowers,
    address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(borrowers.length == 1, "SCOPE: a single named borrower");
    mathint collateralBefore = ghostLlCvlPosCollateral[borrowers[0]];

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    assert(ghostLlCvlPosCollateral[borrowers[0]] == collateralBefore - collateralSeized,
        "the reported seizure comes out of the named borrower's collateral");
}

// VA-HL-18: A deposit mints the receiver at least the shares its quote advertised.
rule hlVaDepositMintsAtLeastPreview(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);
    uint256 quote = previewDeposit(e, assets);
    mathint balBefore = ghostERC20Balances128[_Vault][receiver];

    deposit(e, assets, receiver);

    assert(ghostERC20Balances128[_Vault][receiver] - balBefore >= to_mathint(quote),
        "a deposit never mints fewer shares than the advertised quote");
}

// VA-HL-19: A mint charges the caller no more assets than its quote advertised.
rule hlVaMintChargesAtMostPreview(env e, uint256 shares, address receiver) {

    setupLidoLendERC4626ValidState(e);
    uint256 quote = previewMint(e, shares);
    mathint balBefore = ghostERC20Balances128[ghostVaAsset][e.msg.sender];

    mint(e, shares, receiver);

    assert(balBefore - ghostERC20Balances128[ghostVaAsset][e.msg.sender] <= to_mathint(quote),
        "a mint never charges more assets than the advertised quote");
}

// VA-HL-20: A redeem pays the receiver at least the assets its quote advertised.
rule hlVaRedeemPaysAtLeastPreview(env e, uint256 shares, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    // Two asset legs in one token: receiver == vault self-cancels and receiver == core nets to zero.
    address core = _Vault.LIDO_LEND(e);
    uint256 quote = previewRedeem(e, shares);
    mathint balBefore = ghostERC20Balances128[ghostVaAsset][receiver];

    redeem(e, shares, receiver, owner);

    assert(receiver != _Vault && receiver != core
        => ghostERC20Balances128[ghostVaAsset][receiver] - balBefore >= to_mathint(quote),
        "a redeem never pays fewer assets than the advertised quote");
}

// VA-HL-21: When positive free liquidity covers an owner's whole position, the vault quotes their exact share balance as redeemable.
rule hlVaMaxRedeemIsWholeBalanceWhenLiquidityCovers(env e, address owner) {

    setupLidoLendERC4626ValidState(e);
    uint256 bal = require_uint256(ghostERC20Balances128[_Vault][owner]);
    uint256 liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(liquid != 0 && to_mathint(previewRedeem(e, bal)) <= to_mathint(liquid),
        "SCOPE: positive free liquidity covers the owner's whole position");

    uint256 room = maxRedeem(e, owner);

    assert(room == bal,
        "an exit free liquidity fully covers is quoted as the exact share balance, no wei rounded away");
}

// VA-HL-22: When free liquidity covers the whole request, a fallback exit reports paying exactly the quoted loan assets.
rule hlVaFallbackExitDeliversPreviewedLoanAssetsWhenLiquidCovers(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(to_mathint(shares) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(liquid != 0 && to_mathint(previewRedeem(e, shares)) <= liquid,
        "SCOPE: positive free liquidity covers the whole request");

    mathint quotedLoanAssets = previewRedeem(e, shares);

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(to_mathint(loanAssets) == quotedLoanAssets,
        "the exit pays the quoted loan assets, neither more nor less");
}

// VA-HL-23: When free liquidity is short of the request, a fallback exit reports paying out exactly the free liquidity.
rule hlVaFallbackExitDeliversPreviewedLoanAssetsWhenLiquidPartial(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(to_mathint(shares) < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(to_mathint(previewRedeem(e, shares)) > liquid && liquid != 0,
        "SCOPE: free liquidity is positive and short of the request");

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(to_mathint(loanAssets) == liquid,
        "a short liquid leg pays exactly the free liquidity");
}

// VA-HL-24: A fallback exit that free liquidity fully covers burns exactly the shares asked for and reports that burn honestly.
rule hlVaFallbackExitBurnsAtMostRequestedSharesWhenLiquidCovers(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(liquid != 0 && to_mathint(previewRedeem(e, shares)) <= liquid,
        "SCOPE: positive free liquidity covers the whole request");
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(sharesBurned == shares, "a fully liquid exit burns exactly the request");
    assert(ghostERC20Balances128[_Vault][owner] == balBefore - sharesBurned,
        "the reported burn is exactly what the owner lost");
}

// VA-HL-25: When free liquidity is short, a fallback exit burns at most the requested shares across both legs and reports it honestly.
rule hlVaFallbackExitBurnsAtMostRequestedSharesWhenLiquidPartial(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(to_mathint(previewRedeem(e, shares)) > liquid && liquid != 0,
        "SCOPE: free liquidity is positive and short of the request");
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(sharesBurned <= shares, "the redeem and settle legs together never burn past the requested shares");
    assert(ghostERC20Balances128[_Vault][owner] == balBefore - sharesBurned,
        "the reported burn is exactly what the owner lost");
}

// VA-HL-26: With no free liquidity, a fallback exit's settlement leg alone burns at most the requested shares and reports it honestly.
rule hlVaFallbackExitBurnsAtMostRequestedSharesWhenNoLiquidity(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(ghostMcCvlMaxWithdrawable[ghostVaController][currentContract] == 0,
        "SCOPE: no free liquidity");
    mathint balBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(sharesBurned <= shares, "the settle leg alone never burns past the requested shares");
    assert(ghostERC20Balances128[_Vault][owner] == balBefore - sharesBurned,
        "the reported burn is exactly what the owner lost");
}

// VA-HL-27: When free liquidity falls short, the redeemable quote is that liquidity in shares, not the owner's balance.
rule hlVaMaxRedeemIsConvertedLiquidityWhenShort(env e, address owner) {

    setupLidoLendERC4626ValidState(e);
    uint256 bal = require_uint256(ghostERC20Balances128[_Vault][owner]);
    uint256 liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(liquid == 0 || to_mathint(previewRedeem(e, bal)) > to_mathint(liquid),
        "SCOPE: the branch the liquidity cap binds");

    uint256 room = maxRedeem(e, owner);

    assert(room == convertToShares(e, liquid),
        "a quote the liquidity cap binds is that liquidity in shares, never the balance the owner cannot exit");
}

// VA-HL-28: The share price counts only the core supply the vault itself made, so outside top ups cannot inflate it.
rule hlVaTotalAssetsPricesTheManagedCounter(env e) {

    setupLidoLendERC4626ValidState(e);
    mathint managed = ghostVaManagedSupplyShares256;

    mathint reported = totalAssets(e);

    assert(reported == toAssetsDownLlCVL(managed, ghostLlCvlTotalSupplyAssets, ghostLlCvlTotalSupplyShares),
        "totalAssets values the managed counter at the market's supply price");
}

// VA-HL-29: With no free liquidity, a fallback exit pays out no loan tokens at all.
rule hlVaFallbackExitSkipsRedeemLegWhenIlliquid(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(ghostMcCvlMaxWithdrawable[ghostVaController][currentContract] == 0,
        "SCOPE: no free liquidity");
    mathint recvBefore = ghostERC20Balances128[ghostVaAsset][receiver];
    mathint vaultBefore = ghostERC20Balances128[ghostVaAsset][currentContract];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    assert(loanAssets == 0, "an exit with no free liquidity quotes no loan assets");
    assert(ghostERC20Balances128[ghostVaAsset][receiver] == recvBefore
        && ghostERC20Balances128[ghostVaAsset][currentContract] == vaultBefore,
        "an exit with no free liquidity moves no loan tokens");
}

// VA-AC-01: A share allowance changes only when the caller is its owner or its spender.
rule acVaAllowanceMovesOnlyByOwnerOrSpender(env e, method f, calldataarg args, address o, address s)
    filtered { f -> !EXCLUDED_FUNCTION_VA(f) } {

    setupLidoLendERC4626(e);

    mathint allowBefore = ghostERC20Allowances256[_Vault][o][s];

    f(e, args);

    assert(ghostERC20Allowances256[_Vault][o][s] != allowBefore
        => (e.msg.sender == o || e.msg.sender == s),
        "an allowance row moves only when the caller is its owner or its spender");
}
