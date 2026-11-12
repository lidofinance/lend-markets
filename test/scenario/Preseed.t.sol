// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20} from "../setup/Mocks.sol";
import {PreseedLib} from "../setup/PreseedLib.sol";

/// @notice Two subjects on a fresh stack. First, the dead-share preseed that `PreseedLib` models. Second, donation
///         immunity of the vault and the core market for a first depositor.
/// @dev Assumption: `PreseedLib` matches `LidoLendPreseeder.preseedMarket`, which the Easy Track activation motion
///      calls. That code is outside this repository, and this repository cannot check the library or its constants
///      against it. The preseed tests prove only that the library calls mint the dead shares that the library states.
///      The donation tests run without the preseed. The vault counts only its own core supply shares, and the core
///      counts no token transfers, so no donation moves a share price.
contract PreseedTest is LidoLendSetup {
    using MarketActions for Market;

    /// @dev `PreseedLib.MIN_DEAD_DEPOSIT_SHARES` on an empty market at the core's 1 virtual asset per 1e6 virtual
    ///      shares, rounded up.
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

    /// @dev With 18 decimals the vault has no share offset, so 1e9 shares cost 1e9 assets, above the library's
    ///      asset floor.
    function test_preseed_18DecimalLoan_mintsDeadSharesInMarketAndVault() public {
        Market storage m = _m();
        _preseed(m);

        assertEq(m.core.position(m.id, PreseedLib.RECIPIENT).supplyShares, 1e9, "dead market shares");
        assertEq(m.vault.balanceOf(PreseedLib.RECIPIENT), 1e9, "dead vault shares");
        assertEq(m.core.market(m.id).totalSupplyAssets, PRESEED_MARKET_ASSETS + 1e9, "market holds both preseeds");
    }

    /// @dev With 6 decimals, the vault's 1e12 share offset prices 1e9 shares below one unit. So the library deposits
    ///      its 1e6 asset floor and mints 1e6 * 1e12 shares.
    function test_preseed_6DecimalLoan_depositsVaultAssetFloor() public {
        MockERC20 loan = new MockERC20("Loan6", "LOAN6", 6);
        MockERC20 collateral = new MockERC20("Collateral6", "COLL6", 18);
        Market storage m = _addMarket(_defaultConfig(address(loan), address(collateral), address(collateral)));
        _preseed(m);

        assertEq(m.core.position(m.id, PreseedLib.RECIPIENT).supplyShares, 1e9, "dead market shares");
        assertEq(m.vault.balanceOf(PreseedLib.RECIPIENT), 1e18, "dead vault shares");
        assertEq(m.core.market(m.id).totalSupplyAssets, PRESEED_MARKET_ASSETS + 1e6, "market holds both preseeds");
    }

    // ── Donation immunity for the first depositor ──

    /// @dev The attacker takes the first vault share of an empty vault. Then it donates twice: loan tokens sent to
    ///      the vault, and a core supply credited to the vault. The victim then deposits and exits.
    function test_vaultDonation_victimKeepsDeposit() public {
        Market storage m = _m();
        uint256 roundingBound = _vaultRoundingBound(m);

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
        assertGe(m.loanToken.balanceOf(victim), VICTIM_DEPOSIT - roundingBound, "victim lost more than rounding");
    }

    /// @dev The attacker takes the first shares of an empty market. Then it sends loan tokens straight to the core.
    ///      The victim then supplies and withdraws.
    function test_coreDonation_victimKeepsDeposit() public {
        Market storage m = _m();
        uint256 roundingBound = _coreRoundingBound(m);

        _fund(m.loanToken, attacker, 1 + DONATION);
        m.coreSupply(attacker, 1);
        MorphoMarket memory beforeDonation = m.core.market(m.id);
        vm.prank(attacker);
        m.loanToken.transfer(address(m.core), DONATION);
        assertEq(
            m.core.market(m.id).totalSupplyAssets, beforeDonation.totalSupplyAssets, "donation is not market supply"
        );

        _fund(m.loanToken, victim, VICTIM_DEPOSIT);
        m.coreWithdraw(victim, m.coreSupply(victim, VICTIM_DEPOSIT));
        assertGe(m.loanToken.balanceOf(victim), VICTIM_DEPOSIT - roundingBound, "victim lost more than rounding");
    }

    // ── Helpers ──

    /// @dev Runs `PreseedLib.preseed` from an actor that holds exactly the previewed amounts.
    function _preseed(Market storage m) internal {
        assertEq(m.core.market(m.id).totalSupplyShares, 0, "setup: preseed needs an empty market");
        assertEq(m.vault.totalSupply(), 0, "setup: preseed needs an empty vault");

        _fund(m.loanToken, preseeder, PreseedLib.marketAssets() + PreseedLib.vaultAssets(m.vault));
        PreseedLib.preseed(m.core, m.params, m.vault, preseeder);
        assertEq(m.loanToken.balanceOf(preseeder), 0, "preseed: core and vault took exactly the previewed amounts");
    }

    /// @dev A core depositor loses at most one market share's worth to the floor on its mint, plus one unit to the
    ///      floor on its exit. Priced at the totals before the attack, so a donation that moves the price breaks it.
    function _coreRoundingBound(Market storage m) internal view returns (uint256) {
        MorphoMarket memory mkt = m.core.market(m.id);
        return SharesMathLib.toAssetsUp(1, mkt.totalSupplyAssets, mkt.totalSupplyShares) + 1;
    }

    /// @dev A vault depositor loses the same two roundings on vault shares, plus what the core rounding takes from
    ///      the deposit the vault forwards. Priced at the totals before the attack.
    function _vaultRoundingBound(Market storage m) internal view returns (uint256) {
        return Erc4626Math.toAssets(m.vault, 1, Math.Rounding.Ceil) + 1 + _coreRoundingBound(m);
    }
}
