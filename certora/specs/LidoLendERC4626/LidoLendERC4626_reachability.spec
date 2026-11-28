// Each rule witnesses that a call can succeed and take real effect

import "LidoLendERC4626_valid_state.spec";
import "../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// VA-RC-01: A deposit can mint shares to the receiver and charge the depositor its loan tokens.
rule rcVaDepositIsReachable(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);
    mathint recvSharesBefore = ghostERC20Balances128[_Vault][receiver];
    mathint senderTokensBefore = ghostERC20Balances128[ghostVaParamsLoanToken][e.msg.sender];

    uint256 shares = deposit(e, assets, receiver);

    satisfy(shares > 0 && ghostERC20Balances128[_Vault][receiver] > recvSharesBefore
        && ghostERC20Balances128[ghostVaParamsLoanToken][e.msg.sender] < senderTokensBefore,
        "a deposit can mint positive shares and pull the depositor's loan tokens");
}

// VA-RC-02: A lender can withdraw loan tokens to a receiver, burning their own shares.
rule rcVaWithdrawIsReachable(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    mathint ownerSharesBefore = ghostERC20Balances128[_Vault][owner];
    mathint recvTokensBefore = ghostERC20Balances128[ghostVaParamsLoanToken][receiver];

    uint256 shares = withdraw(e, assets, receiver, owner);

    satisfy(shares > 0 && ghostERC20Balances128[_Vault][owner] < ownerSharesBefore
        && ghostERC20Balances128[ghostVaParamsLoanToken][receiver] > recvTokensBefore,
        "a withdraw can burn the owner's shares and deliver loan tokens to the receiver");
}

// VA-RC-03: A lender can redeem shares for a positive payout of loan tokens.
rule rcVaRedeemIsReachable(env e, uint256 shares, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    mathint ownerSharesBefore = ghostERC20Balances128[_Vault][owner];
    mathint recvTokensBefore = ghostERC20Balances128[ghostVaParamsLoanToken][receiver];

    uint256 assetsOut = redeem(e, shares, receiver, owner);

    satisfy(assetsOut > 0 && ghostERC20Balances128[_Vault][owner] < ownerSharesBefore
        && ghostERC20Balances128[ghostVaParamsLoanToken][receiver] > recvTokensBefore,
        "a redeem can return positive assets while burning the owner's shares");
}

// VA-RC-04: A lender can settle against chosen borrowers, burning exactly the shares the call reports.
rule rcVaSettleIsReachable(env e, uint256 shares, address[] borrowers, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    mathint ownerSharesBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    satisfy(sharesBurned > 0 && ghostERC20Balances128[_Vault][owner] == ownerSharesBefore - sharesBurned,
        "a targeted settle can burn a positive amount of the owner's shares");
}

// VA-RC-05: A fallback exit can burn exactly the shares it reports from the owner's balance.
rule rcVaFallbackExitIsReachable(env e, uint256 shares, address receiver, address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    mathint ownerSharesBefore = ghostERC20Balances128[_Vault][owner];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    satisfy(sharesBurned > 0 && ghostERC20Balances128[_Vault][owner] == ownerSharesBefore - sharesBurned,
        "the fallback exit can burn a positive amount of the owner's shares");
}

// VA-RC-06: The first deposit into an empty vault can create the whole initial share supply.
rule rcVaFirstDepositIsReachable(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(ghostERC20TotalSupply256[_Vault] == 0,
        "SCOPE: the empty-vault bootstrap leg");

    uint256 shares = deposit(e, assets, receiver);

    satisfy(shares > 0 && ghostERC20TotalSupply256[_Vault] == to_mathint(shares),
        "the first deposit can bootstrap the share supply from zero");
}

// VA-RC-07: The first entry through mint can also seed an empty vault, charging assets for the shares.
rule rcVaFirstMintIsReachable(env e, uint256 shares, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(ghostERC20TotalSupply256[_Vault] == 0,
        "SCOPE: the empty-vault bootstrap leg");

    uint256 assets = mint(e, shares, receiver);

    satisfy(assets > 0 && shares > 0 && ghostERC20TotalSupply256[_Vault] == to_mathint(shares),
        "the first mint can bootstrap the share supply from zero at ceil pricing");
}

// VA-RC-08: A deposit into a vault that already has shareholders can credit the receiver new shares.
rule rcVaDepositWithExistingSharesIsReachable(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(ghostERC20TotalSupply256[_Vault] > 0,
        "SCOPE: the vault already has shareholders");
    mathint recvSharesBefore = ghostERC20Balances128[_Vault][receiver];

    uint256 shares = deposit(e, assets, receiver);

    satisfy(shares > 0 && ghostERC20Balances128[_Vault][receiver] == recvSharesBefore + shares,
        "a deposit can mint proportional shares to the receiver on existing supply");
}

// VA-RC-09: A deposit of a single unit can still mint shares and charge the depositor exactly that unit.
rule rcVaDepositOneWeiIsReachable(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(assets == 1, "SCOPE: the smallest non-zero deposit");
    mathint senderTokensBefore = ghostERC20Balances128[ghostVaParamsLoanToken][e.msg.sender];

    uint256 shares = deposit(e, assets, receiver);

    satisfy(shares > 0
        && ghostERC20Balances128[ghostVaParamsLoanToken][e.msg.sender] == senderTokensBefore - 1,
        "a one-wei deposit can mint positive shares and charge the depositor its wei");
}

// VA-RC-10: A lender can withdraw the full amount the vault advertises as withdrawable.
rule rcVaWithdrawMaxIsReachable(env e, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    uint256 room = maxWithdraw(e, owner);
    require(room > 0, "SCOPE: positive withdrawable room");

    uint256 shares = withdraw(e, room, receiver, owner);

    satisfy(shares > 0,
        "a withdraw of the full maxWithdraw amount can succeed");
}

// VA-RC-11: A lender can redeem their entire share balance and receive a positive payout.
rule rcVaRedeemFullBalanceIsReachable(env e, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    uint256 bal = require_uint256(ghostERC20Balances128[_Vault][owner]);
    require(bal > 0, "SCOPE: a positive share balance");

    uint256 assetsOut = redeem(e, bal, receiver, owner);

    satisfy(assetsOut > 0 && ghostERC20Balances128[_Vault][owner] == 0,
        "a full-balance redeem can zero the owner's shares and pay positive assets");
}

// VA-RC-12: A lender can exit their entire share balance through the fallback exit.
rule rcVaFallbackExitFullBalanceIsReachable(env e, address receiver, address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    uint256 bal = require_uint256(ghostERC20Balances128[_Vault][owner]);

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, bal, receiver, owner, maxIterations);

    satisfy(sharesBurned > 0 && ghostERC20Balances128[_Vault][owner] == 0,
        "a full-balance fallback exit can burn the owner's entire position");
}

// VA-RC-13: A lender can settle against a single named borrower and still burn shares.
rule rcVaSettleSingleBorrowerIsReachable(env e, uint256 shares, address[] borrowers, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(borrowers.length == 1, "SCOPE: a single named borrower");

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    satisfy(sharesBurned > 0,
        "a settle against exactly one named borrower can burn a positive share amount");
}

// VA-RC-14: A lender can name several borrowers in one settle and still burn shares.
rule rcVaSettleMultipleBorrowersIsReachable(env e, uint256 shares, address[] borrowers, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(borrowers.length == 2, "SCOPE: a two-name list within the unrolled loop bound");

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    satisfy(sharesBurned > 0,
        "a settle sweeping several named borrowers can burn a positive share amount");
}

// VA-RC-15: The fallback exit can pay the receiver loan tokens out of the market's free liquidity.
rule rcVaFallbackExitLiquidLegIsReachable(env e, uint256 shares, address receiver, address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    mathint recvTokensBefore = ghostERC20Balances128[ghostVaParamsLoanToken][receiver];

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    satisfy(sharesBurned > 0 && loanAssets > 0
        && ghostERC20Balances128[ghostVaParamsLoanToken][receiver] > recvTokensBefore,
        "the fallback exit can resolve through the liquid leg, delivering loan tokens");
}

// VA-RC-16: A fallback exit limited to one settlement round can still seize collateral or cancel debt.
rule rcVaFallbackExitSingleIterationIsReachable(env e, uint256 shares, address receiver, address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(maxIterations == 1, "SCOPE: the tightest settlement-sweep cap");

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    // The settlement-loop-exclusive outputs pin the witness to the one permitted iteration.
    satisfy(sharesBurned > 0 && (collateralSeized > 0 || debtCanceled > 0),
        "a fallback exit capped at one iteration can burn shares in a settle cut");
}

// VA-RC-17: A lender can deposit for shares and redeem them back for assets in the same transaction.
rule rcVaDepositThenRedeemIsReachable(env e, uint256 assets) {

    setupLidoLendERC4626ValidState(e);

    uint256 shares = deposit(e, assets, e.msg.sender);
    uint256 assetsBack = redeem(e, shares, e.msg.sender, e.msg.sender);

    satisfy(shares > 0 && assetsBack > 0,
        "a lender can deposit for shares and redeem them back in one round trip");
}

// VA-RC-18: Shares just deposited can immediately fund a settle cut against borrowers.
rule rcVaDepositThenSettleIsReachable(env e, uint256 assets, address[] borrowers, address receiver) {

    setupLidoLendERC4626ValidState(e);

    uint256 shares = deposit(e, assets, e.msg.sender);
    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, e.msg.sender);

    satisfy(shares > 0 && sharesBurned > 0,
        "freshly deposited shares can immediately fund a targeted settle cut");
}

// VA-RC-19: An approved third party can withdraw for the owner, spending the owner's allowance.
rule rcVaWithdrawOnBehalfIsReachable(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(e.msg.sender != owner, "SCOPE: the third-party allowance leg");
    mathint allowBefore = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    uint256 shares = withdraw(e, assets, receiver, owner);

    satisfy(shares > 0 && ghostERC20Allowances256[_Vault][owner][e.msg.sender] < allowBefore,
        "a third party with allowance can withdraw for the owner, consuming it");
}

// VA-RC-20: An approved third party can redeem for the owner, spending the owner's allowance.
rule rcVaRedeemOnBehalfIsReachable(env e, uint256 shares, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(e.msg.sender != owner, "SCOPE: the third-party allowance leg");
    mathint allowBefore = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    uint256 assetsOut = redeem(e, shares, receiver, owner);

    satisfy(assetsOut > 0 && ghostERC20Allowances256[_Vault][owner][e.msg.sender] < allowBefore,
        "a third party with allowance can redeem for the owner, consuming it");
}

// VA-RC-21: An approved third party can settle the owner's shares, spending the owner's allowance.
rule rcVaSettleOnBehalfIsReachable(env e, uint256 shares, address[] borrowers, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(e.msg.sender != owner, "SCOPE: the third-party allowance leg");
    mathint allowBefore = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    uint256 sharesBurned; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, collateralSeized, debtCanceled = settle(e, shares, borrowers, receiver, owner);

    satisfy(sharesBurned > 0 && ghostERC20Allowances256[_Vault][owner][e.msg.sender] < allowBefore,
        "a third party with allowance can run a settle cut on the owner's shares");
}

// VA-RC-22: A mint into a vault that already has shareholders can charge assets and credit the requested shares.
rule rcVaMintWithExistingSharesIsReachable(env e, uint256 shares, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(ghostERC20TotalSupply256[_Vault] > 0,
        "SCOPE: the vault already has shareholders");
    mathint recvSharesBefore = ghostERC20Balances128[_Vault][receiver];

    uint256 assets = mint(e, shares, receiver);

    satisfy(assets > 0 && shares > 0 && ghostERC20Balances128[_Vault][receiver] == recvSharesBefore + shares,
        "a mint can pull positive assets and credit the receiver the requested shares");
}

// VA-RC-23: A fallback exit can burn fewer shares than requested instead of reverting.
rule rcVaFallbackExitPartialFillIsReachable(env e, uint256 shares, address receiver, address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    satisfy(sharesBurned > 0 && to_mathint(sharesBurned) < to_mathint(shares),
        "a fallback exit can succeed on a shortfall, burning fewer shares than asked");
}

// VA-RC-25: A fallback exit can keep its liquid payout when the settlement sweep cuts nobody.
rule rcVaFallbackExitEmptySweepKeepsLiquidPayout(env e, uint256 shares, address receiver,
    address owner, uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    mathint liquid = ghostMcCvlMaxWithdrawable[ghostVaController][currentContract];
    require(to_mathint(previewRedeem(e, shares)) > liquid && liquid != 0,
        "SCOPE: free liquidity is positive and short of the request");

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    // The short burn keeps the settlement leg in the picture; zero seizures and cancellations say it cut nobody.
    satisfy(loanAssets > 0 && sharesBurned > 0 && to_mathint(sharesBurned) < to_mathint(shares)
        && collateralSeized == 0 && debtCanceled == 0,
        "a sweep that cuts nobody still delivers the liquid leg's payout");
}

// VA-RC-24: A fallback exit that asks for zero settlement rounds can still cut a borrower.
rule rcVaFallbackExitDefaultIterationCapSettles(env e, uint256 shares, address receiver, address owner,
    uint256 maxIterations) {

    setupLidoLendERC4626ValidState(e);
    require(maxIterations == 0, "SCOPE: the argument that stands for the 150-iteration default");

    uint256 sharesBurned; uint256 loanAssets; uint256 collateralSeized; uint256 debtCanceled;
    sharesBurned, loanAssets, collateralSeized, debtCanceled = fallbackExit(e, shares, receiver, owner, maxIterations);

    // The settlement-loop-exclusive outputs pin the witness to a sweep the zero argument did not skip.
    satisfy(sharesBurned > 0 && (collateralSeized > 0 || debtCanceled > 0),
        "a zero iteration argument can still burn shares through a settle cut");
}
