// A mutation kill twin of the vault rule that a mint and redeem round trip never returns more assets than it
// cost, with the parent's name and body. The lane computes mulDiv in CVL, an exact cut dropping only a revert
// the uint128 band excludes.

import "../LidoLendERC4626_valid_state.spec";
import "../../setup/LidoLendERC4626/LidoLendERC4626_valid_state_cvl.spec";
import "../../setup/LidoLendMarketController/LidoLendMarketController_cvl.spec";
import "../../setup/math.spec";

// Fast twin of VA-HL-06.
rule hlVaMintRedeemNoProfit(env e, uint256 shares, address receiver) {

    setupLidoLendERC4626ValidState(e);
    require(shares < max_uint128,
        "SCOPE: input band, unreasonably large amounts excluded");
    require(ghostERC20TotalSupply256[_Vault] < max_uint128 - 10^18,
        "SCOPE: uint128-band share supply, above it the conversion leaves uint256");

    uint256 assetsIn = mint(e, shares, receiver);
    uint256 assetsOut = redeem(e, shares, receiver, receiver);

    assert(assetsOut <= assetsIn,
        "a mint-redeem round trip never returns more assets than it cost");
}
