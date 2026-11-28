// Conformance rules for LidoLendERC4626 against EIP-4626, one rule per requirement over the getters,
// conversions, previews, limits and entry points, each quoting its requirement. The Deposit and Withdraw
// event clauses have no rule, and a rule proving less than its quote says so.

import "LidoLendERC4626_valid_state.spec";
import "../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";

// ERC4626-01: The vault names the loan token of its own market as its underlying asset.
// "The address of the underlying token used for the Vault for accounting, depositing, and withdrawing."
rule assetReturnsConfiguredToken(env e) {

    setupLidoLendERC4626ValidState(e);

    address assetToken = asset(e);

    assert(assetToken == ghostVaParamsLoanToken,
        "asset MUST be the loan token of the market the vault was configured with");
}

// ERC4626-02: Reading the vault's underlying token never fails.
// "MUST _NOT_ revert."
rule assetNeverReverts(env e) {

    setupLidoLendERC4626ValidState(e);

    asset@withrevert(e);

    assert(!lastReverted, "asset MUST NOT revert");
}

// ERC4626-03: Reading the vault's total assets never fails, even with nothing supplied yet.
// "MUST _NOT_ revert."
rule totalAssetsNeverReverts(env e) {

    setupLidoLendERC4626ValidState(e);

    totalAssets@withrevert(e);

    assert(!lastReverted, "totalAssets MUST NOT revert");
}

// ERC4626-04: Every caller gets the same share quote for the same amount of assets.
// "MUST NOT show any variations depending on the caller."
rule convertToSharesSameForAnyCaller(env e1, env e2, uint256 assets) {

    setupLidoLendERC4626ValidState(e1);
    setupLidoLendERC4626ValidState(e2);
    require(e1.block.timestamp == e2.block.timestamp,
        "SCOPE: both reads at one timestamp");

    storage init = lastStorage;
    mathint shares1 = convertToShares(e1, assets) at init;
    mathint shares2 = convertToShares(e2, assets) at init;

    assert(shares1 == shares2, "convertToShares MUST NOT depend on the caller");
}

// ERC4626-05: Quoting shares for a realistic amount of assets never fails.
// "MUST NOT revert unless due to integer overflow caused by an unreasonably large input."
rule convertToSharesNeverReverts(env e, uint256 assets) {

    setupLidoLendERC4626ValidState(e);
    require(assets < max_uint128, "SCOPE: sub-2^128 asset input");
    require(ghostERC20TotalSupply256[_Vault] <= max_uint128 - 10^18,
        "SCOPE: uint128-band share supply");

    convertToShares@withrevert(e, assets);

    assert(!lastReverted, "convertToShares MUST NOT revert for bounded input");
}

// ERC4626-06: Converting assets into shares and back never returns more assets than were put in.
// "MUST round down towards 0."
rule sharesToAssetsRoundTripNeverExceeds(env e, uint256 assets) {

    setupLidoLendERC4626ValidState(e);
    require(assets < max_uint128,
        "SCOPE: sub-2^128 asset input");

    uint256 shares = convertToShares(e, assets);
    mathint assetsBack = convertToAssets(e, shares);

    assert(assetsBack <= to_mathint(assets),
        "the assets -> shares -> assets round trip MUST NOT exceed the original assets");
}

// ERC4626-07: Every caller gets the same asset quote for the same number of shares.
// "MUST NOT show any variations depending on the caller."
rule convertToAssetsSameForAnyCaller(env e1, env e2, uint256 shares) {

    setupLidoLendERC4626ValidState(e1);
    setupLidoLendERC4626ValidState(e2);
    require(e1.block.timestamp == e2.block.timestamp,
        "SCOPE: both reads at one timestamp");

    storage init = lastStorage;
    mathint assets1 = convertToAssets(e1, shares) at init;
    mathint assets2 = convertToAssets(e2, shares) at init;

    assert(assets1 == assets2, "convertToAssets MUST NOT depend on the caller");
}

// ERC4626-08: Quoting assets for a realistic number of shares never fails.
// "MUST NOT revert unless due to integer overflow caused by an unreasonably large input."
rule convertToAssetsNeverReverts(env e, uint256 shares) {

    setupLidoLendERC4626ValidState(e);
    require(shares < max_uint128, "SCOPE: sub-2^128 share input");

    convertToAssets@withrevert(e, shares);

    assert(!lastReverted, "convertToAssets MUST NOT revert for bounded input");
}

// ERC4626-09: Converting shares into assets and back never returns more shares than were converted.
// "MUST round down towards 0."
rule assetsToSharesRoundTripNeverExceeds(env e, uint256 shares) {

    setupLidoLendERC4626ValidState(e);
    require(shares < max_uint128,
        "SCOPE: sub-2^128 share input");

    uint256 assets = convertToAssets(e, shares);
    mathint sharesBack = convertToShares(e, assets);

    assert(sharesBack <= to_mathint(shares),
        "the shares -> assets -> shares round trip MUST NOT exceed the original shares");
}

// ERC4626-10: A deposit larger than the advertised deposit limit always fails.
rule depositAboveMaxLimitReverts(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);

    storage init = lastStorage;
    mathint limit = maxDeposit(e, receiver) at init;

    deposit@withrevert(e, assets, receiver) at init;
    bool reverted = lastReverted;

    assert(to_mathint(assets) > limit => reverted,
        "a deposit above the advertised max must revert");
}

// ERC4626-11: The vault adds no failure of its own when it reports the deposit limit.
// "MUST NOT revert."
rule maxDepositNeverReverts(env e, address receiver) {

    setupLidoLendERC4626ValidState(e);

    maxDeposit@withrevert(e, receiver);

    assert(!lastReverted, "maxDeposit must not revert");
}

// ERC4626-12: A mint of more shares than the advertised mint limit always fails.
rule mintAboveMaxLimitReverts(env e, uint256 shares, address receiver) {

    setupLidoLendERC4626ValidState(e);

    storage init = lastStorage;
    mathint limit = maxMint(e, receiver) at init;

    mint@withrevert(e, shares, receiver) at init;
    bool reverted = lastReverted;

    assert(to_mathint(shares) > limit => reverted,
        "a mint above the advertised max must revert");
}

// ERC4626-13: Reading the vault's advertised mint limit never fails.
// "MUST NOT revert."
rule maxMintNeverReverts(env e, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(ghostERC20TotalSupply256[_Vault] <= max_uint128 - 10^18,
        "SCOPE: uint128-band share supply");

    maxMint@withrevert(e, receiver);

    assert(!lastReverted, "maxMint must not revert");
}

// ERC4626-14: A withdrawal of more assets than the advertised withdraw limit always fails.
rule withdrawAboveMaxLimitReverts(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);

    storage init = lastStorage;
    mathint limit = maxWithdraw(e, owner) at init;

    withdraw@withrevert(e, assets, receiver, owner) at init;
    bool reverted = lastReverted;

    assert(to_mathint(assets) > limit => reverted,
        "a withdraw above the advertised max must revert");
}

// ERC4626-15: Reading how much a holder may withdraw never fails.
// "MUST NOT revert."
rule maxWithdrawNeverReverts(env e, address owner) {

    setupLidoLendERC4626ValidState(e);

    maxWithdraw@withrevert(e, owner);

    assert(!lastReverted, "maxWithdraw must not revert");
}

// ERC4626-16: Reading how many shares a holder may redeem never fails.
// "MUST NOT revert."
rule maxRedeemNeverReverts(env e, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(ghostERC20TotalSupply256[_Vault] < max_uint128 - 10^18,
        "SCOPE: uint128-band share supply");

    maxRedeem@withrevert(e, owner);

    assert(!lastReverted, "maxRedeem must not revert");
}

// ERC4626-17: A redemption of more shares than the advertised redeem limit always fails.
rule redeemAboveMaxLimitReverts(env e, uint256 shares, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);

    storage init = lastStorage;
    mathint limit = maxRedeem(e, owner) at init;

    redeem@withrevert(e, shares, receiver, owner) at init;
    bool reverted = lastReverted;

    assert(to_mathint(shares) > limit => reverted,
        "a redeem above the advertised max must revert");
}

// ERC4626-18: A deposit quote never promises more shares than the ideal conversion would give.
// "MUST be inclusive of deposit fees."
rule previewDepositIncludesFees(env e, uint256 assets) {

    setupLidoLendERC4626ValidState(e);
    require(assets < max_uint128,
        "SCOPE: sub-2^128 asset input");

    mathint previewed = previewDeposit(e, assets);
    mathint ideal = convertToShares(e, assets);

    assert(previewed <= ideal,
        "previewDeposit quotes at most the ideal share conversion");
}

// ERC4626-19: Every caller gets the same quote for the assets a mint costs.
// "MUST NOT account for mint limits like those returned from maxMint and should always act as though the mint would be accepted..."
rule previewMintSameForAnyCaller(env e1, env e2, uint256 shares) {

    setupLidoLendERC4626ValidState(e1);
    setupLidoLendERC4626ValidState(e2);
    require(e1.block.timestamp == e2.block.timestamp, "SCOPE: both reads at one timestamp");

    storage init = lastStorage;
    mathint assets1 = previewMint(e1, shares) at init;
    mathint assets2 = previewMint(e2, shares) at init;

    assert(assets1 == assets2, "previewMint is caller-agnostic");
}

// ERC4626-20: A mint quote never understates the assets the minter must pay.
// "MUST be inclusive of deposit fees."
rule previewMintIncludesFees(env e, uint256 shares) {

    setupLidoLendERC4626ValidState(e);
    require(shares < max_uint128,
        "SCOPE: sub-2^128 share input");

    mathint previewed = previewMint(e, shares);
    mathint ideal = convertToAssets(e, shares);

    assert(previewed >= ideal,
        "previewMint quotes at least the ideal asset conversion");
}

// ERC4626-21: Every caller gets the same quote for the shares a withdrawal burns.
// "MUST NOT account for withdrawal limits like those returned from maxWithdraw and should always act as though the withdrawal would be accepted..."
rule previewWithdrawSameForAnyCaller(env e1, env e2, uint256 assets) {

    setupLidoLendERC4626ValidState(e1);
    setupLidoLendERC4626ValidState(e2);
    require(e1.block.timestamp == e2.block.timestamp, "SCOPE: both reads at one timestamp");

    storage init = lastStorage;
    mathint shares1 = previewWithdraw(e1, assets) at init;
    mathint shares2 = previewWithdraw(e2, assets) at init;

    assert(shares1 == shares2, "previewWithdraw is caller-agnostic");
}

// ERC4626-22: A redemption quote never overstates the assets an exiting holder receives.
// "MUST be inclusive of withdrawal fees."
rule previewRedeemIncludesFees(env e, uint256 shares) {

    setupLidoLendERC4626ValidState(e);
    require(shares < max_uint128,
        "SCOPE: sub-2^128 share input");

    mathint previewed = previewRedeem(e, shares);
    mathint ideal = convertToAssets(e, shares);

    assert(previewed <= ideal,
        "previewRedeem quotes at most the ideal asset conversion");
}

// ERC4626-23: A deposit charges the caller the named assets and mints the receiver the reported shares.
// "Mints `shares` Vault shares to `receiver` by depositing exactly `assets` of underlying tokens."
rule depositTransfersAndMintsCorrectly(env e, uint256 assets, address receiver) {

    setupLidoLendERC4626ValidState(e);
    // Two asset legs, one token: safeTransferFrom(caller -> vault), then the stub's pull (vault -> core).
    mathint callerAssetsBefore = ghostERC20Balances128[ghostVaAsset][e.msg.sender];
    mathint receiverSharesBefore = ghostERC20Balances128[_Vault][receiver];
    mathint totalSupplyBefore = ghostERC20TotalSupply256[_Vault];

    uint256 shares = deposit(e, assets, receiver);

    assert(ghostERC20Balances128[ghostVaAsset][e.msg.sender] == callerAssetsBefore - assets,
        "the caller pays exactly the deposited assets");
    assert(ghostERC20Balances128[_Vault][receiver] == receiverSharesBefore + shares,
        "the receiver gains exactly the minted shares");
    assert(ghostERC20TotalSupply256[_Vault] == totalSupplyBefore + shares,
        "the total supply grows by exactly the minted shares");
}

// ERC4626-24: A mint gives the receiver the requested shares and charges the caller the reported assets.
// "Mints exactly `shares` Vault shares to `receiver` by depositing `assets` of underlying tokens."
rule mintTransfersAndMintsCorrectly(env e, uint256 shares, address receiver) {

    setupLidoLendERC4626ValidState(e);
    // Two asset legs, one token: safeTransferFrom(caller -> vault), then the stub's pull (vault -> core).
    mathint callerAssetsBefore = ghostERC20Balances128[ghostVaAsset][e.msg.sender];
    mathint receiverSharesBefore = ghostERC20Balances128[_Vault][receiver];
    mathint totalSupplyBefore = ghostERC20TotalSupply256[_Vault];

    uint256 assetsCharged = mint(e, shares, receiver);

    assert(ghostERC20Balances128[ghostVaAsset][e.msg.sender] == callerAssetsBefore - assetsCharged,
        "the caller pays exactly the charged assets");
    assert(ghostERC20Balances128[_Vault][receiver] == receiverSharesBefore + shares,
        "the receiver gains exactly the requested shares");
    assert(ghostERC20TotalSupply256[_Vault] == totalSupplyBefore + shares,
        "the total supply grows by exactly the requested shares");
}

// ERC4626-25: A mint spends exactly the charged assets from the caller's token allowance.
// "MUST support EIP-20 `approve` / `transferFrom` on `asset` as a mint flow."
rule mintDecreasesAllowanceByAssetsSpent(env e, uint256 shares, address receiver) {

    setupLidoLendERC4626ValidState(e);
    mathint allowanceBefore = ghostERC20Allowances256[ghostVaAsset][e.msg.sender][_Vault];
    require(allowanceBefore != max_uint256,
        "SCOPE: the finite asset allowance branch");

    uint256 assetsCharged = mint(e, shares, receiver);

    assert(ghostERC20Allowances256[ghostVaAsset][e.msg.sender][_Vault]
        == allowanceBefore - assetsCharged,
        "a mint decrements the asset allowance by exactly the charged assets");
}

// ERC4626-26: A withdrawal burns the reported shares from the owner and pays the receiver the named assets.
// "Burns `shares` from `owner` and sends exactly `assets` of underlying tokens to `receiver`."
rule withdrawBurnsAndTransfersCorrectly(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    // Two asset legs of one token (core -> vault -> receiver), so a receiver that is either nets out.
    address core = _Vault.LIDO_LEND(e);
    mathint ownerSharesBefore = ghostERC20Balances128[_Vault][owner];
    mathint receiverAssetsBefore = ghostERC20Balances128[ghostVaAsset][receiver];
    mathint totalSupplyBefore = ghostERC20TotalSupply256[_Vault];

    uint256 sharesBurned = withdraw(e, assets, receiver, owner);

    assert(ghostERC20Balances128[_Vault][owner] == ownerSharesBefore - sharesBurned,
        "the owner loses exactly the burned shares");
    assert(receiver != _Vault && receiver != core =>
        ghostERC20Balances128[ghostVaAsset][receiver] == receiverAssetsBefore + assets,
        "the receiver gains exactly the withdrawn assets");
    assert(ghostERC20TotalSupply256[_Vault] == totalSupplyBefore - sharesBurned,
        "the total supply shrinks by exactly the burned shares");
}

// ERC4626-27: A redemption burns the named shares from the owner and pays the receiver the reported assets.
// "Burns exactly `shares` from `owner` and sends `assets` of underlying tokens to `receiver`."
rule redeemBurnsAndTransfersCorrectly(env e, uint256 shares, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    // Two asset legs of one token (core -> vault -> receiver), so a receiver that is either nets out.
    address core = _Vault.LIDO_LEND(e);
    mathint ownerSharesBefore = ghostERC20Balances128[_Vault][owner];
    mathint receiverAssetsBefore = ghostERC20Balances128[ghostVaAsset][receiver];
    mathint totalSupplyBefore = ghostERC20TotalSupply256[_Vault];

    uint256 assetsOut = redeem(e, shares, receiver, owner);

    assert(ghostERC20Balances128[_Vault][owner] == ownerSharesBefore - shares,
        "the owner loses exactly the redeemed shares");
    assert(receiver != _Vault && receiver != core =>
        ghostERC20Balances128[ghostVaAsset][receiver] == receiverAssetsBefore + assetsOut,
        "the receiver gains exactly the returned assets");
    assert(ghostERC20TotalSupply256[_Vault] == totalSupplyBefore - shares,
        "the total supply shrinks by exactly the redeemed shares");
}

// ERC4626-28: A third party's withdrawal spends exactly the shares burned from its allowance, and never an unlimited one.
// "MUST support a withdraw flow where the shares are burned from `owner` directly where `msg.sender` has EIP-20 approval over the shares of `owner`."
rule withdrawDecrementsShareAllowanceCorrectly(env e, uint256 assets, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(e.msg.sender != owner,
        "SCOPE: the third-party allowance leg");

    mathint allowanceBefore = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    mathint sharesBurned = withdraw(e, assets, receiver, owner);

    mathint allowanceAfter = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    assert(allowanceBefore != max_uint256 => allowanceAfter == allowanceBefore - sharesBurned,
        "a finite share allowance drops by exactly the burned shares");
    assert(allowanceBefore == max_uint256 => allowanceAfter == max_uint256,
        "an infinite share allowance is never decremented");
}

// ERC4626-29: A third party's redemption spends exactly the shares redeemed from its allowance, and never an unlimited one.
// "MUST support a redeem flow where the shares are burned from `owner` directly where `msg.sender` has EIP-20 approval over the shares of `owner`."
rule redeemDecrementsShareAllowanceCorrectly(env e, uint256 shares, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(e.msg.sender != owner,
        "SCOPE: the third-party allowance leg");

    mathint allowanceBefore = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    redeem(e, shares, receiver, owner);

    mathint allowanceAfter = ghostERC20Allowances256[_Vault][owner][e.msg.sender];

    assert(allowanceBefore != max_uint256 => allowanceAfter == allowanceBefore - to_mathint(shares),
        "a finite share allowance drops by exactly the redeemed shares");
    assert(allowanceBefore == max_uint256 => allowanceAfter == max_uint256,
        "an infinite share allowance is never decremented");
}

// ERC4626-30: Sending tokens straight to the vault cannot move the price of its shares.
// "they are manipulable by altering the on-chain conditions and are not always safe to be used as price oracles" (Security Considerations).
rule donationCannotMoveSharePrice(env e, uint256 shares, uint256 donation) {

    setupLidoLendERC4626ValidState(e);

    mathint previewBefore = previewRedeem(e, shares);

    require(ERC20_ACCOUNT_BOUNDS(ghostVaAsset, _Vault),
        "SCOPE: the vault sits in the ledger's account set");
    ghostERC20Balances128[ghostVaAsset][_Vault] =
        ghostERC20Balances128[ghostVaAsset][_Vault] + donation;

    mathint previewAfter = previewRedeem(e, shares);

    assert(previewAfter == previewBefore,
        "a direct asset donation MUST NOT change the previewRedeem quote");
}

// ERC4626-31: A deposit of exactly the advertised deposit limit is never refused, provided it buys at least one share.
rule depositAtAdvertisedMaxDoesNotRevert(env e, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(receiver != 0,
        "SCOPE: a nonzero mint receiver");
    require(ghostERC20TotalSupply256[_Vault] <= max_uint128 - 10 ^ 18,
        "SCOPE: uint128-band share supply");

    uint256 limit = maxDeposit(e, receiver);
    require(to_mathint(limit) < max_uint128,
        "SCOPE: a bounded limit, not the unlimited sentinel");
    require(limit == 0
            || to_mathint(limit) * (to_mathint(ghostLlCvlTotalSupplyShares) + VIRTUAL_SHARES_LL_CVL())
                > to_mathint(ghostLlCvlTotalSupplyAssets),
        "SCOPE: the advertised assets buy at least one core supply share");
    // Ground form of previewDeposit(limit) != 0, in place of the inlined call.
    require(limit == 0
            || to_mathint(limit)
                * (to_mathint(ghostERC20TotalSupply256[_Vault]) + 10 ^ ghostVaLoanDecimalsOffset8)
                * (to_mathint(ghostLlCvlTotalSupplyShares) + VIRTUAL_SHARES_LL_CVL())
                > to_mathint(ghostVaManagedSupplyShares256) * (to_mathint(ghostLlCvlTotalSupplyAssets) + 1),
        "SCOPE: the advertised assets buy at least one vault share");

    deposit@withrevert(e, limit, receiver);
    bool reverted = lastReverted;

    assert(!reverted, "a deposit of exactly the advertised max must not revert");
}

// ERC4626-32: A mint of exactly the advertised mint limit is never refused, provided its assets buy a share.
rule mintAtAdvertisedMaxDoesNotRevert(env e, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(receiver != 0,
        "SCOPE: a nonzero mint receiver");
    require(ghostERC20TotalSupply256[_Vault] <= max_uint128 - 10 ^ 18,
        "SCOPE: uint128-band share supply");

    uint256 limit = maxMint(e, receiver);
    require(to_mathint(limit) < max_uint128,
        "SCOPE: a bounded limit, not the unlimited sentinel");
    uint256 assetsAtLimit = previewMint(e, limit);
    require(assetsAtLimit == 0
            || to_mathint(assetsAtLimit) * (to_mathint(ghostLlCvlTotalSupplyShares) + VIRTUAL_SHARES_LL_CVL())
                > to_mathint(ghostLlCvlTotalSupplyAssets),
        "SCOPE: the minted assets buy at least one core supply share");

    mint@withrevert(e, limit, receiver);
    bool reverted = lastReverted;

    assert(!reverted, "a mint of exactly the advertised max must not revert");
}

// ERC4626-33: A withdrawal of exactly the advertised withdrawable amount is never refused.
rule withdrawAtAdvertisedMaxDoesNotRevert(env e, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(e.msg.sender == owner,
        "SCOPE: the self-exit");
    require(ghostERC20TotalSupply256[_Vault] <= max_uint128 - 10 ^ 18,
        "SCOPE: uint128-band share supply");

    uint256 limit = maxWithdraw(e, owner);

    withdraw@withrevert(e, limit, receiver, owner);
    bool reverted = lastReverted;

    assert(!reverted, "a withdraw of exactly the advertised max must not revert");
}

// ERC4626-34: A redemption of exactly the advertised redeemable share count is never refused.
rule redeemAtAdvertisedMaxDoesNotRevert(env e, address receiver, address owner) {

    setupLidoLendERC4626ValidState(e);
    require(e.msg.sender == owner,
        "SCOPE: the self-exit");
    require(ghostERC20TotalSupply256[_Vault] <= max_uint128 - 10 ^ 18,
        "SCOPE: uint128-band share supply");

    uint256 limit = maxRedeem(e, owner);

    redeem@withrevert(e, limit, receiver, owner);
    bool reverted = lastReverted;

    assert(!reverted, "a redeem of exactly the advertised max must not revert");
}
