// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Call} from "@bundler3/src/interfaces/IBundler3.sol";

import {BundlerSetup} from "../setup/BundlerSetup.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {Market} from "../setup/Types.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";

/// @dev Transfer-gated collateral (USDY/treasuries style): any transfer TO a blocked address reverts. Models
///      an allowlisted RWA token where the protocol must fail cleanly when collateral would move to a
///      blocked recipient (a seizing keeper or a fallback-exit receiver), never strand or mis-credit it.
///      An issuer freeze goes further: a frozen address can neither send nor receive.
contract GatedCollateral is MockERC20 {
    mapping(address => bool) public blocked;
    mapping(address => bool) public frozen;

    constructor() MockERC20("Gated Collateral", "gCOLL", 18) {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setFrozen(address account, bool isFrozen) external {
        frozen[account] = isFrozen;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to] && !frozen[from] && !frozen[to], "transfer reverted");
        super._update(from, to, value);
    }
}

/// @notice L2 scenario for a market with TRANSFER-GATED collateral (the USDY case the per-method
///         suites never reach). The borrower posts gated collateral and goes unhealthy; the gate must reject
///         a liquidation seizing to a blocked keeper and a fallbackExit seizing to a blocked receiver, while
///         allowlisted recipients are serviced normally.
contract GatedCollateralMarketTest is LidoLendSetup {
    using MarketActions for Market;

    GatedCollateral internal gated;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        gated = new GatedCollateral();
        _deployProtocol(_defaultConfig(address(loan), address(gated), address(gated)));
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev Lender liquidity + a borrower at ~99% LLTV on gated collateral, then a -10% crash → unhealthy
    ///      (but solvent, so liquidation is clean).
    function _seedUnhealthy() internal returns (address borrower) {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
        borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        uint256 maxBorrow = 100 ether * oraclePrice / 1e36 * 80 / 100;
        m.borrow(borrower, maxBorrow * 99 / 100);
        MockPriceOracle(address(m.oracle)).setPrice(oraclePrice * 9 / 10);
    }

    /// @dev Liquidating into a keeper the gated collateral blocks reverts on the seized-collateral transfer.
    function testRevert_liquidate_seizeToBlockedKeeper() public {
        Market storage m = _m();
        address borrower = _seedUnhealthy();

        address keeper = _actor("keeper");
        gated.setBlocked(keeper, true); // collateral cannot move to this keeper
        _fund(m.loanToken, keeper, 1000 ether);
        vm.prank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);

        vm.prank(keeper);
        vm.expectRevert("transfer reverted"); // the seized-collateral transfer to the blocked keeper reverts
        m.core.liquidate(m.params, borrower, 10 ether, 0, "");
    }

    /// @dev An allowlisted keeper liquidates and receives exactly the seized gated collateral.
    function test_liquidate_toAllowlistedKeeper_succeeds() public {
        Market storage m = _m();
        address borrower = _seedUnhealthy();

        address keeper = _actor("keeper"); // not blocked
        _fund(m.loanToken, keeper, 1000 ether);
        (uint256 seized,) = m.liquidate(keeper, borrower, 10 ether, 0);

        assertEq(seized, 10 ether, "allowlisted keeper seizes the gated collateral");
        assertEq(gated.balanceOf(keeper), seized, "keeper received the seized collateral");
    }

    /// @dev A fallbackExit whose settle leg would move gated collateral to a blocked receiver reverts on transfer.
    function testRevert_fallbackExit_seizeToBlockedReceiver() public {
        Market storage m = _m();
        address lender = _actor("lender2");
        _fund(m.loanToken, lender, 100 ether);
        uint256 shares = m.vaultDeposit(lender, 100 ether);

        // A borrower draws most of the new liquidity so the lender's exit needs the settle leg (seizing
        // gated collateral).
        address borrower = _actor("borrower2");
        _fund(m.collateralToken, borrower, 400 ether);
        m.supplyCollateral(borrower, 400 ether);
        m.activateCollateral();
        m.borrow(borrower, 80 ether);

        address receiver = _actor("receiver");
        gated.setBlocked(receiver, true); // gated collateral cannot land on this receiver

        vm.prank(lender);
        vm.expectRevert("transfer reverted"); // the settle leg's collateral transfer to the receiver reverts
        m.vault.fallbackExit(shares, receiver, lender, 0);
    }

    /// @dev A fallbackExit to an allowlisted receiver engages the settle leg and delivers exactly the seized
    /// collateral.
    function test_fallbackExit_toAllowlistedReceiver_seizesCollateral() public {
        Market storage m = _m();
        address lender = _actor("lender3");
        _fund(m.loanToken, lender, 100 ether);
        uint256 shares = m.vaultDeposit(lender, 100 ether);

        address borrower = _actor("borrower3");
        _fund(m.collateralToken, borrower, 400 ether);
        m.supplyCollateral(borrower, 400 ether);
        m.activateCollateral();
        m.borrow(borrower, 80 ether); // drain most liquidity -> exit needs the settle leg

        address receiver = _actor("receiver3"); // not blocked
        uint256 balBefore = gated.balanceOf(receiver);
        vm.prank(lender);
        (,, uint256 collateralSeized,) = m.vault.fallbackExit(shares, receiver, lender, 0);

        assertGt(collateralSeized, 0, "settle leg engaged (not a pure idle redeem)");
        assertEq(
            gated.balanceOf(receiver) - balBefore,
            collateralSeized,
            "allowlisted receiver got exactly the seized collateral"
        );
    }

    /// @dev An issuer freeze of the core's collateral balance does not stop borrowing against it, since a borrow
    ///      moves only the loan token, but every liquidation reverts on the seizure. If the issuer then takes the
    ///      frozen balance, the core still books collateral it no longer holds and the debt is unbacked.
    function test_issuerFreezeOfCore_borrowingContinues_liquidationReverts() public {
        Market storage m = _m();
        address lender = _actor("lender");
        _fund(m.loanToken, lender, 1000 ether);
        m.vaultDeposit(lender, 1000 ether);
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        m.activateCollateral();
        uint256 collateralValue = 100 ether * oraclePrice / 1e36;
        m.borrow(borrower, collateralValue / 2); // 50% LTV

        gated.setFrozen(address(m.core), true);

        m.borrow(borrower, collateralValue / 4); // to 75% LTV against the frozen collateral
        m.distress(borrower, 0.9e18); // past the 80% LLTV
        address keeper = _actor("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        vm.prank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
        vm.prank(keeper);
        vm.expectRevert("transfer reverted");
        m.core.liquidate(m.params, borrower, 10 ether, 0, "");

        // The issuer takes the frozen balance and lifts the freeze.
        deal(address(gated), address(m.core), 0);
        gated.setFrozen(address(m.core), false);
        assertEq(m.core.position(m.id, borrower).collateral, 100 ether, "the core still books the collateral");
        assertGt(m.core.position(m.id, borrower).borrowShares, 0, "the debt remains");
        vm.prank(keeper);
        vm.expectRevert("transfer reverted");
        m.core.liquidate(m.params, borrower, 10 ether, 0, "");
    }
}

/// @dev Default-deny collateral (a memberlist RWA token): a transfer reverts unless both its sender and its
///      recipient are on the allowlist. Mints and burns have no counterparty to check. The core's transfer
///      library replaces the token's revert reason with its own "transfer reverted" / "transferFrom reverted".
contract AllowlistedCollateral is MockERC20 {
    mapping(address => bool) public allowed;

    constructor() MockERC20("Allowlisted Collateral", "aCOLL", 18) {}

    function setAllowed(address account, bool isAllowed) external {
        allowed[account] = isAllowed;
    }

    function _update(address from, address to, uint256 value) internal override {
        require((from == address(0) || allowed[from]) && (to == address(0) || allowed[to]), "not allowlisted");
        super._update(from, to, value);
    }
}

/// @notice L2 scenario for a market whose collateral is DEFAULT-DENY. The issuer allowlists the core and the
///         users who hold the collateral, and nothing else: the vault, the controller and the oracle stay off the
///         list. Every lender, borrower and keeper method must work under that list alone, and a collateral
///         transfer must revert whenever its counterparty or the core is off it.
contract AllowlistedCollateralMarketTest is LidoLendSetup {
    using MarketActions for Market;

    AllowlistedCollateral internal gated;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        gated = new AllowlistedCollateral();
        _deployProtocol(_defaultConfig(address(loan), address(gated), address(gated)));
        gated.setAllowed(address(_m().core), true);
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev An actor the issuer has allowlisted.
    function _member(string memory name) internal returns (address account) {
        account = _actor(name);
        gated.setAllowed(account, true);
    }

    /// @dev A lender off the allowlist deposits `assets` of the loan token.
    function _lend(string memory name, uint256 assets) internal returns (address lender, uint256 shares) {
        Market storage m = _m();
        lender = _actor(name);
        _fund(m.loanToken, lender, assets);
        shares = m.vaultDeposit(lender, assets);
    }

    /// @dev An allowlisted borrower posts `collateral`, matures it and borrows up to `ltv` (WAD) at the seeded price.
    function _borrowAt(string memory name, uint256 collateral, uint256 ltv) internal returns (address borrower) {
        Market storage m = _m();
        borrower = _member(name);
        _fund(m.collateralToken, borrower, collateral);
        m.supplyCollateral(borrower, collateral);
        m.activateCollateral();
        m.borrow(borrower, collateral * oraclePrice / 1e36 * ltv / 1e18);
    }

    /// @dev `keeper` holds loan tokens and has approved the core, ready for a raw `liquidate` call.
    function _armKeeper(address keeper) internal {
        Market storage m = _m();
        _fund(m.loanToken, keeper, 1000 ether);
        vm.prank(keeper);
        m.loanToken.approve(address(m.core), type(uint256).max);
    }

    /// @dev The allowlist holds the core and no other protocol contract.
    function test_allowlist_holdsOnlyTheCore() public view {
        Market storage m = _m();
        assertTrue(gated.allowed(address(m.core)), "core allowlisted");
        assertFalse(gated.allowed(address(m.vault)), "vault off the list");
        assertFalse(gated.allowed(address(m.controller)), "controller off the list");
        assertFalse(gated.allowed(address(m.oracle)), "oracle off the list");
        assertFalse(gated.allowed(address(m.irm)), "irm off the list");
        assertFalse(gated.allowed(address(m.guardianSignals)), "guardian registry off the list");
    }

    /// @dev The vault's ERC-4626 methods move only the loan token, so a lender off the allowlist uses all four.
    function test_lenderVaultMethods_workOffTheAllowlist() public {
        Market storage m = _m();
        (address lender,) = _lend("lender", 100 ether);
        _fund(m.loanToken, lender, 100 ether);
        uint256 minted = m.vaultMint(lender, 50 ether);
        assertGt(minted, 0, "mint took assets");

        _borrowAt("borrower", 100 ether, 0.4e18); // the exits run against a market that carries gated collateral

        m.vaultWithdraw(lender, 10 ether);
        m.vaultRedeem(lender, 10 ether);
        assertEq(gated.balanceOf(lender), 0, "the lender never held collateral");
    }

    /// @dev An allowlisted borrower runs its whole lifecycle: supply, activate, borrow, set a settlement LTV,
    ///      repay by shares and by assets, and withdraw every unit of collateral back.
    function test_borrowerLifecycle_allowlistedBorrower() public {
        Market storage m = _m();
        _lend("lender", 1000 ether);
        address borrower = _borrowAt("borrower", 100 ether, 0.4e18);
        assertEq(gated.balanceOf(address(m.core)), 100 ether, "core holds the collateral");

        m.setSettlementLtv(borrower, 0.7e18);
        m.withdrawCollateral(borrower, 10 ether, borrower); // partial draw with debt outstanding

        _fund(m.loanToken, borrower, 1000 ether);
        m.repayByAssets(borrower, 1 ether);
        m.repay(borrower, m.core.position(m.id, borrower).borrowShares);
        m.withdrawCollateral(borrower, 90 ether, borrower);

        assertEq(gated.balanceOf(borrower), 100 ether, "borrower got all its collateral back");
        assertEq(gated.balanceOf(address(m.core)), 0, "core holds none");
    }

    /// @dev A borrower withdraws its collateral to another allowlisted account.
    function test_withdrawCollateral_toAllowlistedReceiver() public {
        Market storage m = _m();
        address borrower = _member("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);

        address receiver = _member("receiver");
        m.withdrawCollateral(borrower, 100 ether, receiver);
        assertEq(gated.balanceOf(receiver), 100 ether, "receiver got the collateral");
    }

    /// @dev An allowlisted keeper liquidates an unhealthy, solvent position and receives the seized collateral.
    function test_liquidate_allowlistedKeeper() public {
        Market storage m = _m();
        _lend("lender", 1000 ether);
        address borrower = _borrowAt("borrower", 100 ether, 0.75e18);
        m.distress(borrower, 0.9e18);

        address keeper = _member("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        (uint256 seized,) = m.liquidate(keeper, borrower, 10 ether, 0);

        assertEq(seized, 10 ether, "keeper seized the requested collateral");
        assertEq(gated.balanceOf(keeper), 10 ether, "keeper received it");
    }

    /// @dev An allowlisted keeper seizes a whole underwater position, and the loss is socialized.
    function test_liquidateBadDebt_allowlistedKeeper() public {
        Market storage m = _m();
        _lend("lender", 1000 ether);
        address borrower = _borrowAt("borrower", 100 ether, 0.75e18);
        m.distress(borrower, 2e18); // debt is twice the collateral value

        address keeper = _member("keeper");
        _fund(m.loanToken, keeper, 1000 ether);
        (uint256 seized,) = m.liquidateBadDebt(keeper, borrower, 100 ether, 0);

        assertEq(seized, 100 ether, "keeper seized every unit");
        assertEq(gated.balanceOf(keeper), 100 ether, "keeper received it");
        assertEq(gated.balanceOf(address(m.core)), 0, "core holds none");
    }

    /// @dev A lender off the allowlist settles a distressed borrower, with the collateral paid to an allowlisted
    ///      receiver. The vault makes the call and never holds the collateral.
    function test_settle_allowlistedReceiver() public {
        Market storage m = _m();
        (address lender, uint256 shares) = _lend("lender", 1000 ether);
        address borrower = _borrowAt("borrower", 100 ether, 0.4e18);
        m.distress(borrower, 0.9e18);
        m.accrueInterest();
        m.setSettlementLtv(borrower, 0.8e18);

        address receiver = _member("receiver");
        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        (uint256 burned, uint256 collateralSeized, uint256 debtCanceled) =
            m.settle(lender, shares / 2, borrowers, receiver);

        assertGt(burned, 0, "settle burned shares");
        assertGt(debtCanceled, 0, "settle canceled debt");
        assertGt(collateralSeized, 0, "settle seized collateral");
        assertEq(gated.balanceOf(receiver), collateralSeized, "receiver got the seized collateral");
        assertEq(gated.balanceOf(address(m.vault)), 0, "vault never held collateral");
    }

    /// @dev A fallbackExit that needs its settle leg delivers the seized collateral to an allowlisted receiver.
    function test_fallbackExit_allowlistedReceiver() public {
        Market storage m = _m();
        (address lender, uint256 shares) = _lend("lender", 100 ether);
        address borrower = _member("borrower");
        _fund(m.collateralToken, borrower, 400 ether);
        m.supplyCollateral(borrower, 400 ether);
        m.activateCollateral();
        m.borrow(borrower, 80 ether); // most of the liquidity is out, so the exit needs the settle leg

        address receiver = _member("receiver");
        (,, uint256 collateralSeized,) = m.fallbackExit(lender, shares, receiver, 0);

        assertGt(collateralSeized, 0, "settle leg engaged");
        assertEq(gated.balanceOf(receiver), collateralSeized, "receiver got the seized collateral");
        assertEq(gated.balanceOf(address(m.vault)), 0, "vault never held collateral");
    }

    /// @dev With the core off the allowlist no collateral enters the market, even from an allowlisted borrower.
    function testRevert_supplyCollateral_coreNotAllowlisted() public {
        Market storage m = _m();
        gated.setAllowed(address(m.core), false);
        address borrower = _member("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        vm.prank(borrower);
        gated.approve(address(m.core), 100 ether);

        vm.prank(borrower);
        vm.expectRevert("transferFrom reverted");
        m.core.supplyCollateral(m.params, 100 ether, borrower, "");
    }

    /// @dev A borrower off the allowlist cannot post collateral.
    function testRevert_supplyCollateral_borrowerNotAllowlisted() public {
        Market storage m = _m();
        address borrower = _actor("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        vm.prank(borrower);
        gated.approve(address(m.core), 100 ether);

        vm.prank(borrower);
        vm.expectRevert("transferFrom reverted");
        m.core.supplyCollateral(m.params, 100 ether, borrower, "");
    }

    /// @dev Collateral cannot be withdrawn to a receiver off the allowlist.
    function testRevert_withdrawCollateral_receiverNotAllowlisted() public {
        Market storage m = _m();
        address borrower = _member("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);

        address receiver = _actor("receiver");
        vm.prank(borrower);
        vm.expectRevert("transfer reverted");
        m.core.withdrawCollateral(m.params, 100 ether, borrower, receiver);
    }

    /// @dev A borrower the issuer removes after supplying cannot take its collateral back.
    function testRevert_withdrawCollateral_borrowerRemovedFromAllowlist() public {
        Market storage m = _m();
        address borrower = _member("borrower");
        _fund(m.collateralToken, borrower, 100 ether);
        m.supplyCollateral(borrower, 100 ether);
        gated.setAllowed(borrower, false);

        vm.prank(borrower);
        vm.expectRevert("transfer reverted");
        m.core.withdrawCollateral(m.params, 100 ether, borrower, borrower);
    }

    /// @dev A keeper off the allowlist cannot liquidate: the seizure to it reverts.
    function testRevert_liquidate_keeperNotAllowlisted() public {
        Market storage m = _m();
        _lend("lender", 1000 ether);
        address borrower = _borrowAt("borrower", 100 ether, 0.75e18);
        m.distress(borrower, 0.9e18);

        address keeper = _actor("keeper");
        _armKeeper(keeper);
        vm.prank(keeper);
        vm.expectRevert("transfer reverted");
        m.core.liquidate(m.params, borrower, 10 ether, 0, "");
    }

    /// @dev A targeted settle to a receiver off the allowlist reverts. The lender itself is such a receiver.
    function testRevert_settle_receiverNotAllowlisted() public {
        Market storage m = _m();
        (address lender, uint256 shares) = _lend("lender", 1000 ether);
        address borrower = _borrowAt("borrower", 100 ether, 0.4e18);
        m.distress(borrower, 0.9e18);
        m.accrueInterest();
        m.setSettlementLtv(borrower, 0.8e18);

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        vm.prank(lender);
        vm.expectRevert("transfer reverted");
        m.vault.settle(shares / 2, borrowers, lender, lender);
    }

    /// @dev A fallbackExit whose settle leg pays a receiver off the allowlist reverts.
    function testRevert_fallbackExit_receiverNotAllowlisted() public {
        Market storage m = _m();
        (address lender, uint256 shares) = _lend("lender", 100 ether);
        address borrower = _member("borrower");
        _fund(m.collateralToken, borrower, 400 ether);
        m.supplyCollateral(borrower, 400 ether);
        m.activateCollateral();
        m.borrow(borrower, 80 ether);

        vm.prank(lender);
        vm.expectRevert("transfer reverted");
        m.vault.fallbackExit(shares, lender, lender, 0);
    }
}

/// @notice L2 scenario for the bundler stack on a market whose collateral is DEFAULT-DENY, with the core and the
///         users allowlisted and the dispatcher and both adapters off the list. A bundle step that parks the
///         collateral on the general adapter reverts, in either direction. A step where the adapter only makes the
///         call, and the core pays an allowlisted receiver directly, still works.
contract AllowlistedCollateralBundlerTest is BundlerSetup {
    using MarketActions for Market;

    uint256 internal constant COLLATERAL_AMOUNT = 100 ether;

    AllowlistedCollateral internal gated;
    address internal borrower;
    uint256 internal borrowerKey;

    function setUp() public {
        _deployBundledMarket();
        gated = new AllowlistedCollateral();
        _addMarket(_defaultConfig(address(weth), address(gated), address(gated)));
        gated.setAllowed(address(protocol.core), true);

        (borrower, borrowerKey) = makeAddrAndKey("borrower");
        gated.setAllowed(borrower, true);
        _fund(_m().collateralToken, borrower, COLLATERAL_AMOUNT);
    }

    /// @dev The market on the allowlisted collateral.
    function _m() internal view returns (Market storage) {
        return protocol.markets[1];
    }

    /// @dev A lender whose exit needs the settle leg: the borrower has drawn most of the pool. The lender has
    ///      approved the vault adapter for its shares.
    function _setUpIlliquidVaultLender() internal returns (address lender) {
        Market storage m = _m();
        lender = _actor("lender");
        _fund(m.loanToken, lender, 100 ether);
        m.vaultDeposit(lender, 100 ether);

        _fund(m.collateralToken, borrower, 400 ether);
        m.supplyCollateral(borrower, 400 ether);
        m.activateCollateral();
        m.borrow(borrower, 80 ether);

        vm.prank(lender);
        m.vault.approve(address(vaultAdapter), type(uint256).max);
    }

    function _fallbackExitBundle(address receiver) internal view returns (Call[] memory bundle) {
        bundle = new Call[](1);
        bundle[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(_m().vault), type(uint256).max, 0, receiver, 0, 0))
        );
    }

    /// @dev The allowlist holds the core and the borrower, and no part of the bundler stack.
    function test_allowlist_excludesTheBundlerStack() public view {
        assertTrue(gated.allowed(address(protocol.core)), "core allowlisted");
        assertTrue(gated.allowed(borrower), "borrower allowlisted");
        assertFalse(gated.allowed(address(bundler3)), "dispatcher off the list");
        assertFalse(gated.allowed(address(adapter)), "general adapter off the list");
        assertFalse(gated.allowed(address(vaultAdapter)), "vault adapter off the list");
    }

    /// @dev The first step of a supply bundle pulls the user's collateral onto the adapter, and the token rejects
    ///      the adapter as recipient.
    function testRevert_bundle_pullCollateralToAdapter() public {
        vm.prank(borrower);
        gated.approve(address(adapter), COLLATERAL_AMOUNT);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(
            abi.encodeCall(adapter.erc20TransferFrom, (address(gated), address(adapter), COLLATERAL_AMOUNT))
        );
        bundle[1] = _adapterCall(
            abi.encodeCall(adapter.morphoSupplyCollateral, (_m().params, type(uint256).max, borrower, hex""))
        );
        vm.prank(borrower);
        vm.expectRevert("not allowlisted");
        bundler3.multicall(bundle);

        assertEq(gated.balanceOf(borrower), COLLATERAL_AMOUNT, "the borrower keeps its collateral");
    }

    /// @dev Collateral that reached the adapter some other way still cannot be supplied from it: the core's pull
    ///      has the adapter as sender.
    function testRevert_bundle_supplyCollateral_fromAdapterBalance() public {
        deal(address(gated), address(adapter), COLLATERAL_AMOUNT);

        Call[] memory bundle = new Call[](1);
        bundle[0] = _adapterCall(
            abi.encodeCall(adapter.morphoSupplyCollateral, (_m().params, type(uint256).max, borrower, hex""))
        );
        vm.prank(borrower);
        vm.expectRevert("transferFrom reverted");
        bundler3.multicall(bundle);
    }

    /// @dev A withdrawal routed to the adapter, as a bundle does before unwrapping or swapping, reverts.
    function testRevert_bundle_withdrawCollateralToAdapter() public {
        Market storage m = _m();
        m.supplyCollateral(borrower, COLLATERAL_AMOUNT);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _authorizationCall(borrowerKey, address(adapter));
        bundle[1] = _adapterCall(
            abi.encodeCall(adapter.morphoWithdrawCollateral, (m.params, COLLATERAL_AMOUNT, address(adapter)))
        );
        vm.prank(borrower);
        vm.expectRevert("transfer reverted");
        bundler3.multicall(bundle);

        assertEq(m.core.position(m.id, borrower).collateral, COLLATERAL_AMOUNT, "the collateral stays posted");
    }

    /// @dev A fallback exit that sends the seized collateral to the adapter reverts.
    function testRevert_bundle_fallbackExit_toAdapter() public {
        address lender = _setUpIlliquidVaultLender();
        uint256 sharesBefore = _m().vault.balanceOf(lender);

        Call[] memory bundle = _fallbackExitBundle(address(adapter));
        vm.prank(lender);
        vm.expectRevert("transfer reverted");
        bundler3.multicall(bundle);

        assertEq(_m().vault.balanceOf(lender), sharesBefore, "the lender keeps every share");
    }

    /// @dev The adapter can still make the withdrawal call when the core pays an allowlisted receiver directly.
    function test_bundle_withdrawCollateral_directToAllowlistedReceiver() public {
        Market storage m = _m();
        m.supplyCollateral(borrower, COLLATERAL_AMOUNT);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _authorizationCall(borrowerKey, address(adapter));
        bundle[1] =
            _adapterCall(abi.encodeCall(adapter.morphoWithdrawCollateral, (m.params, COLLATERAL_AMOUNT, borrower)));
        _exec(borrower, 0, bundle);

        assertEq(m.core.position(m.id, borrower).collateral, 0, "collateral withdrawn");
        assertEq(gated.balanceOf(borrower), COLLATERAL_AMOUNT, "paid straight to the borrower");
    }

    /// @dev The vault adapter can still run a fallback exit that pays an allowlisted receiver directly.
    function test_bundle_fallbackExit_directToAllowlistedReceiver() public {
        address lender = _setUpIlliquidVaultLender();
        address receiver = _actor("receiver");
        gated.setAllowed(receiver, true);
        uint128 collateralBefore = _m().core.position(_m().id, borrower).collateral;

        _exec(lender, 0, _fallbackExitBundle(receiver));

        uint256 seized = collateralBefore - _m().core.position(_m().id, borrower).collateral;
        assertGt(seized, 0, "settle leg engaged");
        assertEq(gated.balanceOf(receiver), seized, "receiver got the seized collateral");
    }

    /// @dev Control for the reverts above: the same supply bundle passes once the issuer allowlists the adapter.
    function test_bundle_supplyCollateral_worksOnceAdapterAllowlisted() public {
        Market storage m = _m();
        gated.setAllowed(address(adapter), true);
        vm.prank(borrower);
        gated.approve(address(adapter), COLLATERAL_AMOUNT);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(
            abi.encodeCall(adapter.erc20TransferFrom, (address(gated), address(adapter), COLLATERAL_AMOUNT))
        );
        bundle[1] = _adapterCall(
            abi.encodeCall(adapter.morphoSupplyCollateral, (m.params, type(uint256).max, borrower, hex""))
        );
        _exec(borrower, 0, bundle);

        assertEq(m.core.position(m.id, borrower).collateral, COLLATERAL_AMOUNT, "collateral posted");
    }
}
