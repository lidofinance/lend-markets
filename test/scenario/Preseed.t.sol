// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";

import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";

/// @notice The dead-share preseed of the Easy Track activation motion, replayed on a fresh stack. Then a
///         first-depositor donation attack on the preseeded vault and core market. The replay makes the two calls of
///         `LidoLendPreseeder.preseedMarket`, with its amounts and checks. Both the `MIN_DEAD_DEPOSIT_SHARES` core
///         supply and the vault deposit go to `PRESEED_RECIPIENT`.
/// @dev There is no control without the preseed. The vault counts only its own core supply shares, and the core
///      counts no token transfers. So the same donations also leave an unseeded market unchanged.
contract PreseedTest is LidoLendSetup {
    using MarketActions for Market;

    // `LidoLendPreseeder` constants.
    address internal constant PRESEED_RECIPIENT = address(0xdead);
    uint256 internal constant MARKET_VIRTUAL_SHARES = 1e6;
    uint256 internal constant MIN_DEAD_DEPOSIT_SHARES = 1e9;
    uint256 internal constant MIN_VAULT_ASSET_UNITS = 1e6;

    /// @dev `MIN_DEAD_DEPOSIT_SHARES` on an empty market at the core's 1 virtual asset per 1e6 virtual shares,
    ///      rounded up.
    uint256 internal constant PRESEED_MARKET_ASSETS = 1_000;

    uint256 internal constant DONATION = 1_234.5 ether;
    uint256 internal constant VICTIM_DEPOSIT = 7.654321 ether;

    address internal preseeder;
    address internal attacker;
    address internal victim;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));

        preseeder = _actor("preseeder");
        attacker = _actor("attacker");
        victim = _actor("victim");
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ── The preseed ──

    /// @dev With 18 decimals the vault has no share offset, so 1e9 shares cost 1e9 assets, above the asset floor.
    function test_Preseed_18DecimalLoan_LocksDeadSharesInMarketAndVault() public {
        Market storage m = _m();
        _preseed(m);

        assertEq(m.core.position(m.id, PRESEED_RECIPIENT).supplyShares, MIN_DEAD_DEPOSIT_SHARES, "dead market shares");
        assertEq(m.vault.balanceOf(PRESEED_RECIPIENT), 1e9, "dead vault shares");
        assertEq(m.core.market(m.id).totalSupplyAssets, PRESEED_MARKET_ASSETS + 1e9, "market holds both preseeds");
    }

    /// @dev With 6 decimals, the vault's 1e12 share offset prices 1e9 shares below one unit. So the preseed deposits
    ///      the `MIN_VAULT_ASSET_UNITS` floor and mints 1e6 * 1e12 shares.
    function test_Preseed_6DecimalLoan_DepositsVaultAssetFloor() public {
        MockERC20 loan = new MockERC20("Loan6", "LOAN6", 6);
        MockERC20 collateral = new MockERC20("Collateral6", "COLL6", 18);
        Market storage m = _addMarket(_defaultConfig(address(loan), address(collateral), address(collateral)));
        _preseed(m);

        assertEq(m.core.position(m.id, PRESEED_RECIPIENT).supplyShares, MIN_DEAD_DEPOSIT_SHARES, "dead market shares");
        assertEq(m.vault.balanceOf(PRESEED_RECIPIENT), 1e18, "dead vault shares");
        assertEq(
            m.core.market(m.id).totalSupplyAssets,
            PRESEED_MARKET_ASSETS + MIN_VAULT_ASSET_UNITS,
            "market holds both preseeds"
        );
    }

    // ── First-depositor donation attack after the preseed ──

    /// @dev The attacker takes the first vault share after the preseed. Then it donates twice: loan tokens sent to the
    ///      vault, and a core supply credited to the vault. The victim then deposits and exits.
    function test_VaultDonationAfterPreseed_VictimKeepsDeposit() public {
        Market storage m = _m();
        _preseed(m);
        uint256 bound = _vaultRoundingBound(m);

        _fund(m.loanToken, attacker, 1 + 2 * DONATION);
        m.vaultDeposit(attacker, 1);
        uint256 vaultAssetsBefore = m.vault.totalAssets();
        vm.startPrank(attacker);
        m.loanToken.transfer(address(m.vault), DONATION);
        m.loanToken.approve(address(m.core), DONATION);
        m.core.supply(m.params, DONATION, 0, address(m.vault), "");
        vm.stopPrank();
        assertEq(m.vault.totalAssets(), vaultAssetsBefore, "donations do not count as vault assets");

        _fund(m.loanToken, victim, VICTIM_DEPOSIT);
        m.vaultRedeem(victim, m.vaultDeposit(victim, VICTIM_DEPOSIT));
        assertGe(m.loanToken.balanceOf(victim), VICTIM_DEPOSIT - bound, "victim lost more than rounding");
    }

    /// @dev The attacker takes the first market shares after the preseed. Then it sends loan tokens straight to the
    ///      core. The victim then supplies and withdraws.
    function test_CoreDonationAfterPreseed_VictimKeepsDeposit() public {
        Market storage m = _m();
        _preseed(m);
        uint256 bound = _coreRoundingBound(m);

        _fund(m.loanToken, attacker, 1 + DONATION);
        m.coreSupply(attacker, 1);
        vm.prank(attacker);
        m.loanToken.transfer(address(m.core), DONATION);

        _fund(m.loanToken, victim, VICTIM_DEPOSIT);
        m.coreWithdraw(victim, m.coreSupply(victim, VICTIM_DEPOSIT));
        assertGe(m.loanToken.balanceOf(victim), VICTIM_DEPOSIT - bound, "victim lost more than rounding");
    }

    // ── Helpers ──

    /// @dev Replays `LidoLendPreseeder.preseedMarket` from a funded actor: the same two calls, amounts and checks.
    function _preseed(Market storage m) internal {
        assertEq(m.core.market(m.id).totalSupplyShares, 0, "setup: preseed needs an empty market");
        assertEq(m.vault.totalSupply(), 0, "setup: preseed needs an empty vault");

        uint256 marketSupplyAssets = (MIN_DEAD_DEPOSIT_SHARES - 1) / MARKET_VIRTUAL_SHARES + 1;
        uint256 vaultAssets = Math.max(m.vault.previewMint(MIN_DEAD_DEPOSIT_SHARES), MIN_VAULT_ASSET_UNITS);
        _fund(m.loanToken, preseeder, marketSupplyAssets + vaultAssets);

        vm.startPrank(preseeder);
        m.loanToken.approve(address(m.core), marketSupplyAssets);
        m.core.supply(m.params, 0, MIN_DEAD_DEPOSIT_SHARES, PRESEED_RECIPIENT, "");
        uint256 requiredVaultShares = Math.max(m.vault.previewDeposit(MIN_VAULT_ASSET_UNITS), MIN_DEAD_DEPOSIT_SHARES);
        m.loanToken.approve(address(m.vault), vaultAssets);
        uint256 vaultShares = m.vault.deposit(vaultAssets, PRESEED_RECIPIENT);
        vm.stopPrank();

        assertGe(vaultShares, requiredVaultShares, "preseed: vault shares too low");
        assertEq(m.loanToken.balanceOf(preseeder), 0, "preseed: core and vault took exactly the previewed amounts");
    }

    /// @dev A core depositor loses at most one market share's worth to the floor on its mint, plus one unit to the
    ///      floor on its exit. Priced at the totals before the attack, so a donation that moves the price breaks it.
    function _coreRoundingBound(Market storage m) internal view returns (uint256) {
        MorphoMarket memory mkt = m.core.market(m.id);
        return
            Math.ceilDiv(uint256(mkt.totalSupplyAssets) + 1, uint256(mkt.totalSupplyShares) + MARKET_VIRTUAL_SHARES) + 1;
    }

    /// @dev A vault depositor loses the same two roundings on vault shares, plus what the core rounding takes from
    ///      the deposit the vault forwards. Priced at the totals before the attack.
    function _vaultRoundingBound(Market storage m) internal view returns (uint256) {
        uint256 virtualShares = 10 ** (m.vault.decimals() - MockERC20(address(m.loanToken)).decimals());
        return
            Math.ceilDiv(m.vault.totalAssets() + 1, m.vault.totalSupply() + virtualShares) + 1 + _coreRoundingBound(m);
    }
}
