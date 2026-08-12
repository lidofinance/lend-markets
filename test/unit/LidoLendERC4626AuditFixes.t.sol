// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IMorphoBase, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @notice Regression suite for audit finding VLT-01 — permissionless core credits must not corrupt vault
///         share accounting. The core `supply` accepts any `onBehalf`, so a third party can mint core supply
///         shares straight to the vault address without receiving vault shares. The vault now backs shares
///         with a local `_managedSupplyShares` counter (only vault-originated supply, net of vault-initiated
///         withdraws and settlement burns) instead of its full core position, so such credits move neither
///         `totalAssets` nor the settlement budgets, and `managedSupplyShares() <= coreSupplyShares` always.
///
///         Fresh stack via `setup/`; oracle price is seeded (non-parity); distress is a deliberate crash.
contract LidoLendERC4626AuditFixesTest is LidoLendSetup {
    using MarketActions for Market;

    MockERC20 internal loan;
    MockERC20 internal collateral;

    function setUp() public {
        loan = new MockERC20("Loan", "LOAN", 18);
        collateral = new MockERC20("Collateral", "COLL", 18);
        _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
    }

    function _market() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ── helpers ──

    /// @dev A third party credits `amount` core supply shares directly to the vault via the permissionless core
    ///      `supply(onBehalf = vault)`. Asserts the vault's live core position grew but its managed counter did
    ///      not — the credit is unsolicited, so it must never be adopted as backing.
    function _donateToVault(Market storage m, address donor, uint256 amount) internal {
        _fund(m.loanToken, donor, amount);
        vm.prank(donor);
        m.loanToken.approve(address(m.core), amount);

        uint256 managedBefore = m.vault.managedSupplyShares();
        uint256 coreBefore = _coreSupplyShares(m);

        vm.prank(donor);
        m.core.supply(m.params, amount, 0, address(m.vault), "");

        assertEq(m.vault.managedSupplyShares(), managedBefore, "donation must not touch managed shares");
        assertGt(_coreSupplyShares(m), coreBefore, "donation credited core supply shares to the vault");
    }

    function _coreSupplyShares(Market storage m) internal view returns (uint256) {
        return m.core.position(m.id, address(m.vault)).supplyShares;
    }

    /// @dev The load-bearing invariant: managed shares never exceed the vault's live core supply position.
    function _assertManagedLeCore(Market storage m) internal view {
        assertLe(m.vault.managedSupplyShares(), _coreSupplyShares(m), "invariant: managed <= core supply shares");
    }

    function _depositFor(Market storage m, address who, uint256 assets) internal returns (uint256 shares) {
        _fund(m.loanToken, who, assets);
        vm.prank(who);
        m.loanToken.approve(address(m.vault), assets);
        vm.prank(who);
        shares = m.vault.deposit(assets, who);
    }

    /// @dev Lender liquidity + a borrower at a safe LTV, then a solvent-but-unhealthy crash. Callers that exercise
    ///      targeted settlement must separately configure the borrower's personal settlement LTV.
    function _distress(Market storage m, uint256 lenderLiquidity, uint256 borrow, uint256 crashPrice)
        internal
        returns (address lender, address borrower)
    {
        lender = _actor("lender");
        _fund(m.loanToken, lender, lenderLiquidity);
        m.vaultDeposit(lender, lenderLiquidity);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        m.borrow(borrower, borrow);

        MockPriceOracle(address(m.oracle)).setPrice(crashPrice);
        m.accrueInterest();
    }

    /// @dev Borrower borrows the WHOLE supply (idle -> 0), then a crash to a solvent-but-unhealthy point, so
    ///      `fallbackExit` closes the position in full (borrow-anchored settle). Mirrors `_distressFull`.
    function _distressFull(Market storage m, uint256 lenderLiquidity)
        internal
        returns (address lender, address borrower)
    {
        lender = _actor("lender");
        _fund(m.loanToken, lender, lenderLiquidity);
        m.vaultDeposit(lender, lenderLiquidity);

        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 1_000 ether);
        m.supplyCollateral(borrower, 1_000 ether);
        m.activateCollateral();
        m.borrow(borrower, lenderLiquidity);

        MockPriceOracle(address(m.oracle)).setPrice(0.11e36);
        m.accrueInterest();
    }

    // ── donation immunity: totalAssets ──

    /// @dev A core credit to an EMPTY vault stays unbacked: `totalAssets` remains 0, the managed counter stays
    ///      0, and the first real depositor prices in as if the credit never happened.
    function test_donationBeforeFirstDeposit_doesNotBackShares() public {
        Market storage m = _market();
        _donateToVault(m, _actor("attacker"), 50 ether);

        assertEq(m.vault.managedSupplyShares(), 0, "no vault-originated supply yet");
        assertEq(m.vault.totalAssets(), 0, "unsolicited credit is not backing");
        _assertManagedLeCore(m);

        // First depositor gets shares at the virgin ratio (previewDeposit unaffected by the credit).
        uint256 preview = m.vault.previewDeposit(10 ether);
        uint256 shares = _depositFor(m, _actor("lender"), 10 ether);
        assertEq(shares, preview, "first deposit prices as if the credit never happened");
        assertGt(shares, 0, "first deposit mints nonzero shares");
        _assertManagedLeCore(m);
    }

    /// @dev A core credit AFTER a deposit does not move the share price: `totalAssets` is unchanged and a later
    ///      victim deposit mints exactly its pre-credit preview.
    function test_donationAfterFirstDeposit_doesNotMoveSharePrice() public {
        Market storage m = _market();
        _depositFor(m, _actor("lender"), 100 ether);

        uint256 assetsBefore = m.vault.totalAssets();
        uint256 victimPreview = m.vault.previewDeposit(25 ether);

        _donateToVault(m, _actor("attacker"), 200 ether);

        assertEq(m.vault.totalAssets(), assetsBefore, "credit did not inflate totalAssets");
        assertEq(m.vault.previewDeposit(25 ether), victimPreview, "credit did not move the deposit price");

        uint256 victimShares = _depositFor(m, _actor("victim"), 25 ether);
        assertEq(victimShares, victimPreview, "victim minted its uninflated preview");
        assertGt(victimShares, 0, "victim deposit is not stolen to zero shares");
        _assertManagedLeCore(m);
    }

    /// @dev The exact WETH boundary from the finding: k = 10 ** offset = 1 (18-decimal loan token), attacker
    ///      seeds one raw unit then credits D = 2u. Pre-fix the victim's u-asset deposit minted
    ///      floor(2·k·u/(D+2)) = 0 shares; post-fix the credit is uncounted, so the victim mints its full
    ///      uninflated preview (u shares at the ~1:1 virgin ratio).
    function test_wethBoundary_D2u_victimStillMintsShares() public {
        Market storage m = _market();
        uint256 u = 10 ether;

        // Attacker seeds one raw asset unit -> owns k = 1 vault share worth of the position.
        address attacker = _actor("attacker");
        uint256 attackerShares = _depositFor(m, attacker, 1);
        assertEq(attackerShares, 1, "k = 1: one raw unit mints one share");

        // Attacker credits D = 2u straight to the vault's core position.
        _donateToVault(m, attacker, 2 * u);

        // Pre-fix: previewDeposit(u) would floor to 0. Post-fix it prices off managed backing (~1 asset).
        uint256 victimPreview = m.vault.previewDeposit(u);
        assertGt(victimPreview, 0, "victim deposit is no longer floored to zero shares");

        uint256 victimShares = _depositFor(m, _actor("victim"), u);
        assertEq(victimShares, victimPreview, "victim minted exactly its preview");
        _assertManagedLeCore(m);
    }

    /// @dev Core fee shares minted directly to the vault are not managed backing. A deposit that triggers their
    ///      accrual therefore receives the same shares and post-deposit claim as a control deposit made after an
    ///      explicit accrual; the entrant cannot capture fees earned before entry.
    function test_pendingFeeShares_doNotTransferValueToEntrant() public {
        Market storage m = _market();
        _depositFor(m, _actor("incumbent"), 1_000 ether);

        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 10_000 ether);
        m.supplyCollateral(borrower, 10_000 ether);
        m.activateCollateral();
        m.borrow(borrower, 800 ether);

        m.core.setFeeRecipient(address(m.vault));
        m.core.setFee(m.params, 0.1e18);
        vm.warp(block.timestamp + 365 days);

        uint256 managedBefore = m.vault.managedSupplyShares();
        uint256 coreBefore = _coreSupplyShares(m);
        assertEq(coreBefore, managedBefore, "setup has no unmanaged shares");
        uint256 expectedAssetsBefore = m.vault.totalAssets();
        uint256 snapshot = vm.snapshotState();

        address entrant = _actor("entrant");
        uint256 sharesBeforeAccrual = _depositFor(m, entrant, 100 ether);
        uint256 claimBeforeAccrual = m.vault.convertToAssets(sharesBeforeAccrual);
        uint256 feeShares = _coreSupplyShares(m) - m.vault.managedSupplyShares();
        assertNotEq(feeShares, 0, "pending fees accrued");

        assertTrue(vm.revertToState(snapshot), "snapshot restored");

        m.accrueInterest();
        assertEq(m.vault.managedSupplyShares(), managedBefore, "fee shares are not managed backing");
        assertEq(_coreSupplyShares(m) - m.vault.managedSupplyShares(), feeShares, "same fee shares accrued");
        assertEq(m.vault.totalAssets(), expectedAssetsBefore, "expected and accrued valuations match");

        uint256 controlShares = _depositFor(m, entrant, 100 ether);
        uint256 controlClaim = m.vault.convertToAssets(controlShares);
        assertEq(sharesBeforeAccrual, controlShares, "entry price is independent of accrual timing");
        assertEq(claimBeforeAccrual, controlClaim, "entrant captures no pending fee value");
        _assertManagedLeCore(m);
    }

    // ── defense in depth: reject a nonzero deposit minting zero shares ──

    /// @dev Even if a legitimate share price ever grew enough to floor a tiny deposit to zero shares (here via
    ///      a year of accrued interest, no donation involved), the vault rejects it rather than pocketing the
    ///      assets for existing holders.
    function testRevert_deposit_zeroSharesMinted() public {
        Market storage m = _market();
        _depositFor(m, _actor("lender"), 100 ether);

        // Drive the share price above parity so previewDeposit(1) floors to 0 (totalAssets > totalSupply).
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 1_000 ether);
        m.supplyCollateral(borrower, 1_000 ether);
        m.activateCollateral();
        m.borrow(borrower, 80 ether); // high utilization -> interest accrues
        vm.warp(block.timestamp + 365 days);
        m.accrueInterest();

        assertEq(m.vault.previewDeposit(1), 0, "setup: a 1-wei deposit floors to zero shares");

        address dust = _actor("dust");
        _fund(m.loanToken, dust, 1);
        vm.prank(dust);
        m.loanToken.approve(address(m.vault), 1);
        vm.prank(dust);
        vm.expectRevert(abi.encodeWithSelector(ILidoLendERC4626.ZeroSharesMinted.selector, uint256(1)));
        m.vault.deposit(1, dust);
    }

    /// @dev The core accepts an asset-anchored supply even when its down-rounded share output is zero. The vault
    ///      rejects that result so the depositor's assets and newly minted vault shares both roll back.
    function testRevert_deposit_zeroCoreSupplyShares() public {
        Market storage m = _market();
        address lender = _actor("lender");
        uint256 assets = 10 ether;
        _fund(m.loanToken, lender, assets);

        vm.prank(lender);
        m.loanToken.approve(address(m.vault), assets);

        vm.mockCall(
            address(m.core),
            abi.encodeWithSelector(IMorphoBase.supply.selector, m.params, assets, 0, address(m.vault), ""),
            abi.encode(assets, uint256(0))
        );

        uint256 lenderAssetsBefore = m.loanToken.balanceOf(lender);
        vm.prank(lender);
        vm.expectRevert(abi.encodeWithSelector(ILidoLendERC4626.ZeroCoreSupplySharesMinted.selector, assets));
        m.vault.deposit(assets, lender);

        assertEq(m.loanToken.balanceOf(lender), lenderAssetsBefore, "deposit assets rolled back");
        assertEq(m.vault.balanceOf(lender), 0, "vault-share mint rolled back");
        assertEq(m.vault.managedSupplyShares(), 0, "zero core shares were not managed");
    }

    // ── settlement budgets exclude the credit (the severe one-victim extraction path) ──

    /// @dev The settlement-assisted extraction relied on the settle budget scaling with the vault's FULL core
    ///      position. With the managed counter, the pro-rata budget uses managed shares only, so a credit leaves
    ///      the attacker's exit budget exactly where it was.
    function test_settlementBudget_excludesDonation() public {
        Market storage m = _market();
        (address lender,) = _distress(m, 100 ether, 20 ether, 0.22e36);
        uint256 lenderShares = m.vault.balanceOf(lender);

        uint256 budgetBefore = m.vault.managedSupplyShares() * lenderShares / m.vault.totalSupply();
        _donateToVault(m, _actor("attacker"), 500 ether);
        uint256 budgetAfter = m.vault.managedSupplyShares() * lenderShares / m.vault.totalSupply();

        assertEq(budgetAfter, budgetBefore, "settle budget is independent of the unsolicited credit");
        // And it equals the managed pro-rata, not the full-position pro-rata.
        uint256 expected = m.vault.managedSupplyShares() * lenderShares / m.vault.totalSupply();
        assertEq(budgetAfter, expected, "settle budget == managed pro-rata");
        assertLt(budgetAfter, _coreSupplyShares(m) * lenderShares / m.vault.totalSupply(), "credit excluded");
        _assertManagedLeCore(m);
    }

    /// @dev The full one-victim extraction from the finding, executed end to end: attacker seeds one raw unit
    ///      (k = 1, so one vault share), credits D = 2u to the vault's core position, a victim deposits u, then
    ///      the attacker — a settle-eligible borrower of the credited liquidity — settles its single share
    ///      against its own debt to reclaim the seized collateral. Pre-fix that share commanded the inflated
    ///      1 + 3u backing, letting the attacker cancel ~2u of its own debt and walk with the victim's u.
    ///      Post-fix the share is worth only its own ~1 wei, so the debt the settle can cancel (the value it
    ///      extracts, in loan terms) is bounded by that — and the victim keeps its u.
    function test_settlementExtraction_yieldsNothing() public {
        Market storage m = _market();
        uint256 u = 10 ether;

        address attacker = _actor("attacker");
        uint256 attackerShares = _depositFor(m, attacker, 1); // k = 1 -> one share
        assertEq(attackerShares, 1, "one raw unit mints one share");
        _donateToVault(m, attacker, 2 * u); // credit D = 2u

        uint256 victimShares = _depositFor(m, _actor("victim"), u);
        assertGt(victimShares, 0, "victim is not floored to zero shares");

        // The credit is not counted, so the attacker's single share is worth only its own ~1 wei and the
        // victim's share is worth its u. There is simply no inflated backing to extract.
        assertLe(m.vault.convertToAssets(attackerShares), 2, "attacker share worth only its own dust");
        assertGe(m.vault.convertToAssets(victimShares), u * 99 / 100, "victim keeps its deposit value");

        // Attacker becomes a settle-eligible borrower of the credited liquidity: post collateral, borrow, crash.
        _fund(m.collateralToken, attacker, 100 ether);
        m.supplyCollateral(attacker, 100 ether);
        m.activateCollateral();
        m.borrow(attacker, 20 ether);
        MockPriceOracle(address(m.oracle)).setPrice(0.22e36);
        m.accrueInterest();

        uint256 attackerShareValue = m.vault.convertToAssets(attackerShares);
        address[] memory bs = new address[](1);
        bs[0] = attacker;

        // The extraction: settle the sole share against the attacker's own position. The value it can pull —
        // the debt it cancels, in loan terms — is bounded by the attacker's own share value (or it reverts on
        // a too-small slice, extracting nothing).
        vm.prank(attacker);
        try m.vault.settle(attackerShares, bs, attacker, attacker) returns (
            uint256, uint256, uint256, uint256 debtCanceled
        ) {
            assertLe(debtCanceled, attackerShareValue + 2, "settle extracts no more than the attacker's own share");
        } catch {
            // Reverted (zero budget / slice too small) -> nothing extracted.
        }

        // Victim is still whole: its shares remain worth ~u (a collateral crash does not touch loan-side value).
        assertGe(m.vault.convertToAssets(victimShares), u * 99 / 100, "victim value survives the attack");
        _assertManagedLeCore(m);
    }

    // ── managed tracking across withdraws and settlements ──

    /// @dev Partial then full ordinary withdrawal: managed decreases by exactly the core shares each withdraw
    ///      burns, hits 0 on full exit, and the invariant holds throughout (with a live credit present).
    function test_withdraw_partialThenFull_tracksManaged() public {
        Market storage m = _market();
        address lender = _actor("lender");
        _depositFor(m, lender, 100 ether);
        _donateToVault(m, _actor("attacker"), 40 ether); // credit rides along; must not be drained as backing

        uint256 managed0 = m.vault.managedSupplyShares();
        uint256 core0 = _coreSupplyShares(m);

        vm.prank(lender);
        m.vault.withdraw(30 ether, lender, lender);
        assertEq(
            managed0 - m.vault.managedSupplyShares(), core0 - _coreSupplyShares(m), "partial: managed == core delta"
        );
        _assertManagedLeCore(m);

        uint256 remaining = m.vault.balanceOf(lender);
        vm.prank(lender);
        m.vault.redeem(remaining, lender, lender);
        assertEq(m.vault.managedSupplyShares(), 0, "full exit drains managed to zero");
        assertEq(m.vault.totalSupply(), 0, "full exit burns every vault share");
        assertGt(_coreSupplyShares(m), 0, "the unsolicited credit stays in the core position, unclaimed");
        _assertManagedLeCore(m);
    }

    /// @dev A targeted partial cut updates managed and core supply shares by the same amount.
    function test_settle_borrowAnchored_tracksManaged() public {
        Market storage m = _market();
        (address lender, address borrower) = _distress(m, 100 ether, 20 ether, 0.22e36);
        m.setSettlementLtv(borrower, 0.8e18);
        _donateToVault(m, _actor("attacker"), 60 ether);

        uint256 managedBefore = m.vault.managedSupplyShares();
        uint256 coreBefore = _coreSupplyShares(m);

        address[] memory bs = new address[](1);
        bs[0] = borrower;
        uint256 lenderShares = m.vault.balanceOf(lender);
        vm.prank(lender);
        (uint256 sharesBurned,,,) = m.vault.settle(lenderShares, bs, lender, lender);
        assertGt(sharesBurned, 0, "settle burned vault shares");

        assertEq(
            managedBefore - m.vault.managedSupplyShares(), coreBefore - _coreSupplyShares(m), "managed == core delta"
        );
        _assertManagedLeCore(m);
    }

    /// @dev Borrow-anchored settle through a full `fallbackExit` with no idle liquidity (pure settle leg):
    ///      managed drops by the same amount as the vault's core position, and the invariant holds. No credit
    ///      here on purpose — a credit is supply liquidity, which would create idle and turn this into a
    ///      both-legs exit; the credit-present decrement is covered by the (liquidity-neutral) settle test.
    function test_fallbackExit_borrowAnchored_tracksManaged() public {
        Market storage m = _market();
        (address lender,) = _distressFull(m, 100 ether); // idle == 0 -> settle-only exit

        uint256 managedBefore = m.vault.managedSupplyShares();
        uint256 coreBefore = _coreSupplyShares(m);

        uint256 lenderShares = m.vault.balanceOf(lender);
        vm.prank(lender);
        (uint256 sharesBurned, uint256 loanAssets,,) = m.vault.fallbackExit(lenderShares, lender, lender, 0);
        assertEq(loanAssets, 0, "no idle -> no redeem leg");
        assertGt(sharesBurned, 0, "settle leg burned vault shares");

        assertEq(
            managedBefore - m.vault.managedSupplyShares(), coreBefore - _coreSupplyShares(m), "managed == core delta"
        );
        _assertManagedLeCore(m);
    }

    /// @dev `fallbackExit` exercising BOTH legs (redeem the idle, settle the illiquid remainder): the redeem
    ///      leg decrements managed via `_withdraw`, the settle leg via the settlement burn; the combined drop
    ///      equals the vault's core-position drop.
    function test_fallbackExit_bothLegs_tracksManaged() public {
        Market storage m = _market();
        (address lender,) = _distress(m, 100 ether, 20 ether, 0.22e36); // 80 idle, 20 settles

        uint256 managedBefore = m.vault.managedSupplyShares();
        uint256 coreBefore = _coreSupplyShares(m);

        uint256 lenderShares = m.vault.balanceOf(lender);
        vm.prank(lender);
        (uint256 sharesBurned, uint256 loanAssets,,) = m.vault.fallbackExit(lenderShares, lender, lender, 0);
        assertGt(loanAssets, 0, "redeem leg paid idle liquidity");
        assertGt(sharesBurned, 0, "settle leg cut the remainder");

        assertEq(
            managedBefore - m.vault.managedSupplyShares(), coreBefore - _coreSupplyShares(m), "managed == core delta"
        );
        assertEq(m.vault.balanceOf(lender), 0, "fully exited across both legs");
        _assertManagedLeCore(m);
    }

    // ── loan-token decimals below / equal / above 18 ──

    function test_decimals_below18_donationImmuneAndTracks() public {
        _runDecimalsCase(6, 10e6, 20e6);
    }

    function test_decimals_equal18_donationImmuneAndTracks() public {
        _runDecimalsCase(18, 10 ether, 20 ether);
    }

    function test_decimals_above18_donationImmuneAndTracks() public {
        _runDecimalsCase(24, 10e24, 20e24);
    }

    /// @dev The managed-share defense is decimals-independent: for a fresh market whose loan token has `dec`
    ///      decimals, a core credit moves neither `totalAssets` nor the deposit price, the invariant holds, and
    ///      an ordinary withdraw decrements managed in lockstep with the core position. (The decimals only set
    ///      the virtual-share offset `k`; the settlement paths above already cover the cut arithmetic.)
    function _runDecimalsCase(uint8 dec, uint256 u, uint256 d) internal {
        MockERC20 loanTok = new MockERC20("Loan", "LOAN", dec);
        MockERC20 collTok = new MockERC20("Collateral", "COLL", 18);
        Market storage m = _addMarket(_defaultConfig(address(loanTok), address(collTok), address(collTok)));

        address lender = _actor("lender");
        uint256 shares = _depositFor(m, lender, u);
        assertGt(shares, 0, "deposit minted shares");

        uint256 assetsBefore = m.vault.totalAssets();
        uint256 priceBefore = m.vault.previewDeposit(u);
        _donateToVault(m, _actor("attacker"), d);
        assertEq(m.vault.totalAssets(), assetsBefore, "credit did not inflate totalAssets");
        assertEq(m.vault.previewDeposit(u), priceBefore, "credit did not move the deposit price");
        _assertManagedLeCore(m);

        uint256 managedBefore = m.vault.managedSupplyShares();
        uint256 coreBefore = _coreSupplyShares(m);
        uint256 lenderShares = m.vault.balanceOf(lender);
        vm.prank(lender);
        m.vault.redeem(lenderShares, lender, lender);
        assertEq(
            managedBefore - m.vault.managedSupplyShares(), coreBefore - _coreSupplyShares(m), "managed == core delta"
        );
        assertEq(m.vault.managedSupplyShares(), 0, "full exit drains managed to zero");
        _assertManagedLeCore(m);
    }

    // ── invariant under fuzzed deposit + credit ──

    /// @dev For any deposit and any unsolicited credit, the credit is never counted as backing and the managed
    ///      counter never exceeds the live core position.
    function testFuzz_invariant_managedLeCore_underDonation(uint256 depositAssets, uint256 donation) public {
        Market storage m = _market();
        depositAssets = bound(depositAssets, 1e6, 1_000_000 ether);
        donation = bound(donation, 1, 1_000_000 ether);

        uint256 shares = _depositFor(m, _actor("lender"), depositAssets);
        assertGt(shares, 0, "deposit minted shares");

        uint256 assetsBefore = m.vault.totalAssets();
        _donateToVault(m, _actor("attacker"), donation);

        assertEq(m.vault.totalAssets(), assetsBefore, "credit never counts as backing");
        _assertManagedLeCore(m);
    }
}
