// Properties of the linked pair: both contracts run their real bytecode, neither is a stub of the other.

import "../LidoLend/LidoLend_valid_state.spec";
import "../LidoLendERC4626/LidoLendERC4626_valid_state.spec";
import "../setup/LidoLendERC4626_LinkedCore/LidoLendERC4626_LinkedCore.spec";

// --- high_level ---

// VC-HL-01: No ordinary vault call changes who may act for the vault inside the market.
rule hlVcVaultNeverAuthorizesInCore(env e, method f, calldataarg args, address a)
    filtered { f -> f.contract == _Vault && !EXCLUDED_FUNCTION_VC(f) } {

    setupLidoLendERC4626_LinkedCore(e);

    bool authorized0 = ghostLlIsAuthorized[_Vault][a];

    f(e, args);

    assert(ghostLlIsAuthorized[_Vault][a] == authorized0,
        "no vault entry point moves the core's authorization row for the vault");
}

// VC-HL-02: A deposit adds exactly its assets to the market's supply side.
rule hlVcDepositSuppliesExactAssetsToCore(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual; no interest lands alongside the deposit");

    mathint totalBefore = ghostLlTotalSupplyAssets128;

    deposit(e, assets, receiver);

    assert(ghostLlTotalSupplyAssets128 == totalBefore + to_mathint(assets),
        "a vault deposit supplies exactly its assets to the core market");
}

// VC-HL-03: No ordinary vault call moves a supply position in the market other than the vault's own and the fee recipient's.
rule hlVcVaultMovesOnlyItsOwnCorePosition(env e, method f, calldataarg args, address a)
    filtered { f -> f.contract == _Vault && !EXCLUDED_FUNCTION_VC(f) } {

    setupLidoLendERC4626_LinkedCore(e);
    require(a != _Vault,
        "SCOPE: the vault's own core row legitimately moves");
    require(a != ghostLlFeeRecipient,
        "SCOPE: an accrual legitimately credits the fee row");

    mathint positionBefore = ghostLlSupplyShares256[a];

    f(e, args);

    assert(ghostLlSupplyShares256[a] == positionBefore,
        "no vault entry point moves a core supply position other than the vault's own");
}

// VC-HL-04: A deposit buys no more market shares than the price before it allows.
rule hlVcDepositCreditCappedByPreDepositRate(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual; the rate the deposit pays is the stored one");

    mathint marketAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint marketSharesBefore = ghostLlTotalSupplyShares128;
    mathint positionBefore = ghostLlSupplyShares256[_Vault];

    deposit(e, assets, receiver);

    mathint credited = ghostLlSupplyShares256[_Vault] - positionBefore;

    assert(credited * (marketAssetsBefore + VIRTUAL_ASSETS_LL_CVL())
            <= to_mathint(assets) * (marketSharesBefore + VIRTUAL_SHARES_LL_CVL()),
        "the deposit is credited no more core shares than the pre-deposit rate prices its assets at");
}

// VC-HL-05: A deposit is credited every whole market share the pre-deposit price pays for.
rule hlVcDepositCreditReachesPreDepositRateFloor(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual; the rate the deposit pays is the stored one");

    mathint marketAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint marketSharesBefore = ghostLlTotalSupplyShares128;
    mathint positionBefore = ghostLlSupplyShares256[_Vault];

    deposit(e, assets, receiver);

    mathint credited = ghostLlSupplyShares256[_Vault] - positionBefore;

    assert(to_mathint(assets) * (marketSharesBefore + VIRTUAL_SHARES_LL_CVL())
            < (credited + 1) * (marketAssetsBefore + VIRTUAL_ASSETS_LL_CVL()),
        "the deposit is credited no fewer core shares than the floor of that price");
}

// VC-HL-06: A withdrawal burns at least the market shares the pre-withdrawal price charges, so leaving never dilutes the holders who stay.
rule hlVcWithdrawBurnCoversPreWithdrawRate(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual; the rate the withdrawal pays is the stored one");

    mathint marketAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint marketSharesBefore = ghostLlTotalSupplyShares128;
    mathint positionBefore = ghostLlSupplyShares256[_Vault];

    withdraw(e, assets, receiver, owner);

    mathint burned = positionBefore - ghostLlSupplyShares256[_Vault];

    assert(to_mathint(assets) * (marketSharesBefore + VIRTUAL_SHARES_LL_CVL())
            <= burned * (marketAssetsBefore + VIRTUAL_ASSETS_LL_CVL()),
        "the withdrawal burns no fewer core shares than the pre-withdrawal rate prices its assets at");
}

// VC-HL-07: A withdrawal burns no more market shares than the pre-withdrawal price rounded up, so the leaver is not overcharged.
rule hlVcWithdrawBurnCappedByPreWithdrawRateCeiling(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp),
        "SCOPE: fresh accrual; the rate the withdrawal pays is the stored one");

    mathint marketAssetsBefore = ghostLlTotalSupplyAssets128;
    mathint marketSharesBefore = ghostLlTotalSupplyShares128;
    mathint positionBefore = ghostLlSupplyShares256[_Vault];

    withdraw(e, assets, receiver, owner);

    mathint burned = positionBefore - ghostLlSupplyShares256[_Vault];

    assert((burned - 1) * (marketAssetsBefore + VIRTUAL_ASSETS_LL_CVL())
            < to_mathint(assets) * (marketSharesBefore + VIRTUAL_SHARES_LL_CVL()),
        "the withdrawal burns no more core shares than the ceiling of that price");
}

// VC-HL-08: A deposit moves the loan token from the depositor straight to the market, with none kept by the vault.
rule hlVcDepositPassesAssetsThroughToCore(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626_LinkedCore(e);

    mathint coreBefore = ghostERC20Balances128[ghostLlLoanToken][_Core];
    mathint callerBefore = ghostERC20Balances128[ghostLlLoanToken][e.msg.sender];
    mathint vaultBefore = ghostERC20Balances128[ghostLlLoanToken][_Vault];

    deposit(e, assets, receiver);

    assert(ghostERC20Balances128[ghostLlLoanToken][_Core] == coreBefore + to_mathint(assets),
        "the deposited assets land on the core");
    assert(ghostERC20Balances128[ghostLlLoanToken][e.msg.sender] == callerBefore - to_mathint(assets),
        "the deposited assets come out of the caller");
    assert(ghostERC20Balances128[ghostLlLoanToken][_Vault] == vaultBefore,
        "the vault keeps none of the deposited assets");
}

// VC-HL-09: The vault's reported assets already include pending interest, so booking that interest moves nothing.
rule hlVcTotalAssetsAccrualInvariant(env e, LidoLend.MarketParams p) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlFee128 == 0 || ERC20_ACCOUNT_BOUNDS(ghostLlLoanToken, ghostLlFeeRecipient),
        "SCOPE: no fee, or the fee recipient is a modeled account");

    mathint viewBefore = totalAssets(e);

    _Core.accrueInterest(e, p);

    assert(to_mathint(totalAssets(e)) == viewBefore,
        "the projection the vault prices by is the accrual the core books");
}

// VC-HL-10: The vault's reported assets hold steady across an accrual even when the vault is the market's fee recipient.
rule hlVcTotalAssetsStableAcrossOwnFeeCredit(env e, LidoLend.MarketParams p) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlFeeRecipient == _Vault,
        "SCOPE: the owner named the vault the market's fee recipient");

    mathint viewBefore = totalAssets(e);

    _Core.accrueInterest(e, p);

    assert(to_mathint(totalAssets(e)) == viewBefore,
        "the price per share does not move when the accrual credits the vault's own row");
}

// --- reachability ---

// VC-RC-01: A lender can deposit into the vault and have it land on the vault's own market position.
rule rcVcDepositReachesCorePosition(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp), "SCOPE: fresh accrual");

    mathint positionBefore = ghostLlSupplyShares256[_Vault];

    deposit(e, assets, receiver);

    satisfy(ghostLlSupplyShares256[_Vault] > positionBefore,
        "a vault deposit lands in the core's supply position");
}

// VC-RC-02: A supply made into the market on the vault's behalf can lift its share price.
rule rcVcCoreSideDonationMovesSharePrice(env e, LidoLend.MarketParams p, uint256 amount, uint256 shares,
    bytes data) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp), "SCOPE: fresh accrual");
    require(data.length == 0, "SCOPE: no supply callback");

    mathint previewBefore = previewRedeem(e, shares);
    mathint positionBefore = ghostLlSupplyShares256[_Vault];

    _Core.supply(e, p, amount, 0, _Vault, data);

    mathint previewAfter = previewRedeem(e, shares);

    satisfy(ghostLlSupplyShares256[_Vault] > positionBefore && previewAfter > previewBefore,
        "a third-party core supply on the vault's behalf credits the vault and lifts the share price");
}

// VC-RC-03: A lender can exit the vault by drawing on its position in the market.
rule rcVcWithdrawDebitsCorePosition(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp), "SCOPE: fresh accrual");

    mathint positionBefore = ghostLlSupplyShares256[_Vault];

    withdraw(e, assets, receiver, owner);

    satisfy(ghostLlSupplyShares256[_Vault] < positionBefore,
        "the vault's exit leg reaches the core and debits its supply position");
}

// VC-RC-04: The vault can exit its own market position while holding no permission grant in the market.
rule rcVcVaultExitsWithoutCoreGrant(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 == to_mathint(e.block.timestamp), "SCOPE: fresh accrual");
    require(forall address a. !ghostLlIsAuthorized[_Vault][a],
        "SCOPE: the vault holds no authorization row in the core");

    mathint positionBefore = ghostLlSupplyShares256[_Vault];

    withdraw(e, assets, receiver, owner);

    satisfy(ghostLlSupplyShares256[_Vault] < positionBefore,
        "the vault debits its own core position holding no grant in the core");
}

// VC-RC-05: A market accrual can add interest to the supply side and credit the fee recipient.
rule rcVcAccrualLandsInterestAndFeeCredit(env e, LidoLend.MarketParams p) {

    setupLidoLendERC4626_LinkedCore(e);
    require(ghostLlLastUpdate128 < to_mathint(e.block.timestamp),
        "SCOPE: real elapsed time since the last accrual");
    require(ERC20_ACCOUNT_BOUNDS(ghostLlLoanToken, ghostLlFeeRecipient),
        "SCOPE: the fee recipient is a modeled account");

    address feeRow = ghostLlFeeRecipient;
    mathint supplyBefore = ghostLlTotalSupplyAssets128;
    mathint feeRowBefore = ghostLlSupplyShares256[feeRow];

    _Core.accrueInterest(e, p);

    satisfy(ghostLlTotalSupplyAssets128 > supplyBefore && ghostLlSupplyShares256[feeRow] > feeRowBefore,
        "an accrual mints real interest and credits the fee row");
}

// --- reverts ---

// VC-RV-01: A withdrawal larger than the market's free liquidity fails.
rule rvVcWithdrawAboveCoreLiquidityReverts(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626_LinkedCore(e);

    mathint idle = ghostLlTotalSupplyAssets128 - ghostLlTotalBorrowAssets128;

    withdraw@withrevert(e, assets, receiver, owner);
    bool reverted = lastReverted;

    assert(to_mathint(assets) > idle => reverted,
        "a withdrawal past the market's free liquidity reverts in the core");
}
