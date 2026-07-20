// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Market as CoreMarketStruct, Position as CorePosition} from "@lido-lend/src/interfaces/IMorpho.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {Call} from "@bundler3/src/interfaces/IBundler3.sol";
import {ErrorsLib as BundlerErrorsLib} from "@bundler3/src/libraries/ErrorsLib.sol";
import {LidoLendVaultAdapter} from "../../src/periphery/LidoLendVaultAdapter.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {BlockInfoWithHash} from "../../src/types/GuardianSignalsTypes.sol";

import {BundlerSetup} from "../setup/BundlerSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {Market} from "../setup/Types.sol";

/// @notice End-to-end bundled user flows on a freshly deployed stack: the main lender and borrower
///         operations sent through the stock Bundler3, the vendored general adapter, and the Lido vault adapter,
///         the fallback exit that ends in stETH, and the controller rules a bundle can run into. Every
///         bundle runs through `_exec`, which also checks that nothing is left behind on the dispatcher
///         or the adapters.
contract BundledFlowsTest is BundlerSetup {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    uint256 internal constant COLLATERAL_AMOUNT = 100 ether;
    uint256 internal constant IDLE_LIQUIDITY = 1 ether;

    address internal lender;
    address internal borrower;
    uint256 internal borrowerKey;

    function setUp() public {
        _deployBundledMarket();
        lender = _actor("lender");
        (borrower, borrowerKey) = makeAddrAndKey("borrower");
    }

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    // ---
    // SHARED SETUP
    // ---

    /// @dev Sets up a borrower with open debt on a market that still has unborrowed loan tokens. Also
    ///      returns the exact amount a repay-everything bundle must pull; no time passes between this
    ///      setup and the bundle, so the number does not drift.
    function _setUpBorrowerWithDebt(uint256 liquidity, uint256 borrowAmount)
        internal
        returns (Market storage m, uint256 fullRepayAssets)
    {
        m = _m();

        _fund(m.loanToken, lender, liquidity);
        m.vaultDeposit(lender, liquidity);

        _fund(m.collateralToken, borrower, COLLATERAL_AMOUNT);
        m.supplyCollateral(borrower, COLLATERAL_AMOUNT);
        m.activateCollateral();
        m.borrow(borrower, borrowAmount);

        CoreMarketStruct memory mkt = m.core.market(m.id);
        fullRepayAssets = uint256(m.core.position(m.id, borrower).borrowShares)
            .toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
    }

    /// @dev Sets up a vault lender who cannot exit normally: the borrower has taken all but
    ///      `IDLE_LIQUIDITY` of the pool and has opted into settlement, so a fallback exit pays out
    ///      that remainder in WETH and settles the rest for the borrower's collateral. The borrow is
    ///      sized from the seeded oracle price to sit at half of what the collateral allows.
    function _setUpIlliquidVaultLender() internal returns (Market storage m, uint256 borrowAmount) {
        m = _m();
        borrowAmount = (COLLATERAL_AMOUNT * oraclePrice) / 1e36 / 2;

        (m,) = _setUpBorrowerWithDebt(borrowAmount + IDLE_LIQUIDITY, borrowAmount);
        m.setSettlementLtv(borrower, 0.25e18);

        // Vault shares have no signature-based approval, so the adapter must be approved up front.
        vm.prank(lender);
        m.vault.approve(address(vaultAdapter), type(uint256).max);
    }

    // ---
    // LENDER: DEPOSITS
    // ---

    /// @dev A user holding only plain ETH becomes a vault lender in one transaction: the first call
    ///      sends the ETH to the adapter, the next wraps it into WETH, the last deposits it for the
    ///      user.
    function testFuzz_bundle_depositNativeEth(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);
        Market storage m = _m();
        address user = _actor("ethOnlyUser");
        vm.deal(user, amount);

        // Independent expectation: the first deposit into a fresh vault mints one share per asset.
        uint256 expectedShares = amount;

        Call[] memory bundle = new Call[](3);
        bundle[0] = _callValue(address(adapter), "", amount);
        bundle[1] = _adapterCall(abi.encodeCall(adapter.wrapNative, (type(uint256).max, address(adapter))));
        bundle[2] = _adapterCall(
            abi.encodeCall(adapter.erc4626Deposit, (address(m.vault), type(uint256).max, MAX_SHARE_PRICE_E27, user))
        );
        _exec(user, amount, bundle);

        assertEq(m.vault.balanceOf(user), expectedShares, "first deposit mints one share per asset");
        assertEq(user.balance, 0, "all ETH spent");
        assertEq(weth.balanceOf(address(m.core)), amount, "wrapped deposit reached the core");
    }

    function test_bundle_depositWeth() public {
        Market storage m = _m();
        address user = _actor("wethUser");
        _fund(m.loanToken, user, 5 ether);
        vm.prank(user);
        weth.approve(address(adapter), 5 ether);

        uint256 expectedShares = m.vault.previewDeposit(5 ether);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(weth), address(adapter), 5 ether)));
        bundle[1] = _adapterCall(
            abi.encodeCall(adapter.erc4626Deposit, (address(m.vault), type(uint256).max, MAX_SHARE_PRICE_E27, user))
        );
        _exec(user, 0, bundle);

        assertEq(m.vault.balanceOf(user), expectedShares, "vault shares match the preview");
        assertEq(weth.balanceOf(user), 0);
    }

    /// @dev A minimum share price the deposit cannot meet makes the whole bundle revert, and the user
    ///      keeps their funds.
    function testRevert_bundle_deposit_slippageAtomic() public {
        Market storage m = _m();
        address user = _actor("wethUser");
        _fund(m.loanToken, user, 5 ether);
        vm.prank(user);
        weth.approve(address(adapter), 5 ether);

        // A fresh vault's exact share price is 1e27; asking for even slightly more must revert.
        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(weth), address(adapter), 5 ether)));
        bundle[1] =
            _adapterCall(abi.encodeCall(adapter.erc4626Deposit, (address(m.vault), type(uint256).max, 1e27 - 1, user)));

        vm.prank(user);
        vm.expectRevert(BundlerErrorsLib.SlippageExceeded.selector);
        bundler3.multicall(bundle);

        assertEq(weth.balanceOf(user), 5 ether, "the failed bundle returned the funds");
        assertEq(m.vault.balanceOf(user), 0);
    }

    // ---
    // LENDER: EXITS
    // ---

    /// @dev Full circle in two bundles: deposit plain ETH, then redeem back to plain ETH. The redeem
    ///      pays the adapter, which unwraps the WETH and forwards the ETH; the minimum share price
    ///      comes from the vault's own preview, so the check is a real one.
    function testFuzz_bundle_depositThenRedeemToNativeEth_roundTrip(uint256 amount) public {
        amount = bound(amount, 2, 1_000_000 ether);
        Market storage m = _m();
        address user = _actor("roundTripper");
        vm.deal(user, amount);

        Call[] memory depositBundle = new Call[](3);
        depositBundle[0] = _callValue(address(adapter), "", amount);
        depositBundle[1] = _adapterCall(abi.encodeCall(adapter.wrapNative, (type(uint256).max, address(adapter))));
        depositBundle[2] = _adapterCall(
            abi.encodeCall(adapter.erc4626Deposit, (address(m.vault), type(uint256).max, MAX_SHARE_PRICE_E27, user))
        );
        _exec(user, amount, depositBundle);

        uint256 shares = m.vault.balanceOf(user);
        uint256 expectedAssets = m.vault.previewRedeem(shares);
        uint256 minSharePrice = (expectedAssets * 1e27) / shares;
        vm.prank(user);
        m.vault.approve(address(adapter), shares);

        Call[] memory redeemBundle = new Call[](2);
        redeemBundle[0] = _adapterCall(
            abi.encodeCall(
                adapter.erc4626Redeem, (address(m.vault), type(uint256).max, minSharePrice, address(adapter), user)
            )
        );
        redeemBundle[1] = _adapterCall(abi.encodeCall(adapter.unwrapNative, (type(uint256).max, user)));
        _exec(user, 0, redeemBundle);

        assertEq(m.vault.balanceOf(user), 0, "all shares redeemed");
        assertEq(user.balance, expectedAssets, "round trip pays the previewed assets in native ETH");
        assertLe(amount - expectedAssets, 1, "round-trip loss is at most rounding");
    }

    /// @dev The main exit scenario from a drained market: `fallbackExit` pays the adapter the
    ///      remaining WETH plus the seized wstETH; the bundle then forwards the WETH and unwraps the
    ///      wstETH, so the lender walks away holding stETH, all in one transaction.
    function test_bundle_fallbackExit_paysWethAndUnwrapsCollateralToStEth() public {
        (Market storage m,) = _setUpIlliquidVaultLender();

        uint256 sharesBefore = m.vault.balanceOf(lender);
        uint128 debtBefore = m.core.position(m.id, borrower).borrowShares;
        uint128 borrowerCollateralBefore = m.core.position(m.id, borrower).collateral;

        Call[] memory bundle = new Call[](3);
        bundle[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(
                vaultAdapter.fallbackExit,
                (address(m.vault), type(uint256).max, 0, address(adapter), IDLE_LIQUIDITY + 1, 1)
            )
        );
        bundle[1] = _adapterCall(abi.encodeCall(adapter.unwrapStEth, (type(uint256).max, lender)));
        bundle[2] = _adapterCall(abi.encodeCall(adapter.erc20Transfer, (address(weth), lender, type(uint256).max)));
        _exec(lender, 0, bundle);

        // No time passed since the borrow, so the exit pays out exactly the unborrowed WETH, and
        // everything settlement seized from the borrower must reach the lender as stETH.
        uint256 seizedWst = borrowerCollateralBefore - m.core.position(m.id, borrower).collateral;
        assertGt(seizedWst, 0, "settlement seized collateral");
        assertEq(weth.balanceOf(lender), IDLE_LIQUIDITY, "the unborrowed WETH was paid out");
        assertEq(
            steth.balanceOf(lender),
            (seizedWst * wsteth.stEthPerToken()) / 1e18,
            "all seized collateral unwrapped to the lender"
        );
        assertEq(wsteth.balanceOf(lender), 0, "no raw wstETH left with the lender");
        assertLt(m.vault.balanceOf(lender), sharesBefore, "shares were burned");
        assertLt(m.core.position(m.id, borrower).borrowShares, debtBefore, "borrower debt was cut");
    }

    /// @dev A minimum the exit cannot meet makes the whole bundle revert: the lender keeps every
    ///      share.
    function testRevert_bundle_fallbackExit_belowFloorAtomic() public {
        (Market storage m,) = _setUpIlliquidVaultLender();
        uint256 sharesBefore = m.vault.balanceOf(lender);

        Call[] memory bundle = new Call[](1);
        bundle[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(
                vaultAdapter.fallbackExit,
                (address(m.vault), type(uint256).max, 0, address(vaultAdapter), type(uint256).max, 0)
            )
        );

        vm.prank(lender);
        // Match only the error type: its amounts depend on the seeded oracle price.
        vm.expectPartialRevert(LidoLendVaultAdapter.ExitBelowMinimum.selector);
        bundler3.multicall(bundle);

        assertEq(m.vault.balanceOf(lender), sharesBefore, "lender kept all shares");
        assertEq(weth.balanceOf(lender), 0, "no partial payout");
    }

    /// @dev The share approvals the vault adapter holds are useless to anyone else: whoever starts a
    ///      bundle can only burn their own shares, and the attacker has none, however they ask for
    ///      the lender's.
    function testRevert_bundle_fallbackExit_foreignInitiatorCannotSpendApproval() public {
        (Market storage m,) = _setUpIlliquidVaultLender();
        uint256 lenderShares = m.vault.balanceOf(lender);
        address attacker = _actor("attacker");

        Call[] memory bundle = new Call[](1);
        bundle[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(m.vault), type(uint256).max, 0, attacker, 0, 0))
        );
        vm.prank(attacker);
        vm.expectRevert(BundlerErrorsLib.ZeroShares.selector);
        bundler3.multicall(bundle);

        bundle[0] = _call(
            address(vaultAdapter),
            abi.encodeCall(vaultAdapter.fallbackExit, (address(m.vault), lenderShares, 0, attacker, 0, 0))
        );
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ILidoLendERC4626.ExceededBalance.selector, attacker, lenderShares, 0));
        bundler3.multicall(bundle);

        assertEq(m.vault.balanceOf(lender), lenderShares, "another user's bundle could not touch the lender's shares");
    }

    // ---
    // BORROWER: COLLATERAL ONBOARDING
    // ---

    /// @dev A user holding only plain ETH posts wstETH collateral in one transaction: stake the ETH
    ///      for stETH, wrap it into wstETH, supply it, and finally return any stETH crumbs to the
    ///      user (on mainnet, Lido transfers can come up 1-2 wei short).
    function testFuzz_bundle_supplyCollateralFromNativeEth(uint256 amount) public {
        // From 2 wei up: a 1 wei stake mints zero stETH shares, and the general adapter's share-price
        // check then divides by zero and reverts.
        amount = bound(amount, 2, 1_000_000 ether);
        Market storage m = _m();
        address user = _actor("ethStaker");
        vm.deal(user, amount);

        uint256 expectedWst = (amount * 1e18) / wsteth.stEthPerToken();

        Call[] memory bundle = new Call[](5);
        bundle[0] = _callValue(address(adapter), "", amount);
        bundle[1] = _adapterCall(
            abi.encodeCall(adapter.stakeEth, (type(uint256).max, MAX_SHARE_PRICE_E27, address(0), address(adapter)))
        );
        bundle[2] = _adapterCall(abi.encodeCall(adapter.wrapStEth, (type(uint256).max, address(adapter))));
        bundle[3] =
            _adapterCall(abi.encodeCall(adapter.morphoSupplyCollateral, (m.params, type(uint256).max, user, hex"")));
        bundle[4] = _adapterCall(abi.encodeCall(adapter.erc20Transfer, (address(steth), user, type(uint256).max)));
        _exec(user, amount, bundle);

        assertEq(m.core.position(m.id, user).collateral, expectedWst, "collateral posted at the mock rates");
        assertEq(user.balance, 0, "all ETH staked");
    }

    function test_bundle_supplyCollateralFromWstEth() public {
        Market storage m = _m();
        _fund(m.collateralToken, borrower, 40 ether);
        vm.prank(borrower);
        wsteth.approve(address(adapter), 40 ether);

        Call[] memory bundle = new Call[](2);
        bundle[0] =
            _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(wsteth), address(adapter), 40 ether)));
        bundle[1] = _adapterCall(
            abi.encodeCall(adapter.morphoSupplyCollateral, (m.params, type(uint256).max, borrower, hex""))
        );
        _exec(borrower, 0, bundle);

        assertEq(m.core.position(m.id, borrower).collateral, 40 ether, "collateral posted");
        assertEq(wsteth.balanceOf(borrower), 0);
    }

    // ---
    // BORROWER: DEBT LIFECYCLE
    // ---

    /// @dev Borrow against already-activated collateral straight to plain ETH: authorize the adapter
    ///      inside the bundle, borrow to the adapter, unwrap to the user. On a fresh borrow side the
    ///      minimum share price can be computed exactly, so the check is exact too.
    function test_bundle_borrowToNativeEth() public {
        (Market storage m,) = _setUpBorrowerWithDebt(50 ether, 1 ether);
        // The setup already opened a small borrow; borrow more against the remaining activated
        // collateral.
        uint256 amount = 5 ether;
        uint256 ethBefore = borrower.balance;

        CoreMarketStruct memory mkt = m.core.market(m.id);
        uint256 expectedShares = amount.toSharesUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        uint256 minSharePrice = (amount * 1e27) / expectedShares;

        Call[] memory bundle = new Call[](3);
        bundle[0] = _authorizationCall(borrowerKey, address(adapter));
        bundle[1] =
            _adapterCall(abi.encodeCall(adapter.morphoBorrow, (m.params, amount, 0, minSharePrice, address(adapter))));
        bundle[2] = _adapterCall(abi.encodeCall(adapter.unwrapNative, (type(uint256).max, borrower)));
        _exec(borrower, 0, bundle);

        assertEq(borrower.balance, ethBefore + amount, "borrowed straight to native ETH");
        assertTrue(protocol.core.isAuthorized(borrower, address(adapter)), "in-bundle authorization took effect");
    }

    /// @dev Closes a whole position in one transaction, step by step: pull the exact repay amount
    ///      from the user, authorize the adapter, repay all debt, withdraw all collateral.
    function test_bundle_repayAndWithdrawCollateral_closesPosition() public {
        (Market storage m, uint256 fullRepayAssets) = _setUpBorrowerWithDebt(50 ether, 10 ether);
        uint256 wethBefore = weth.balanceOf(borrower);
        vm.prank(borrower);
        weth.approve(address(adapter), fullRepayAssets);

        Call[] memory bundle = new Call[](4);
        bundle[0] =
            _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(weth), address(adapter), fullRepayAssets)));
        bundle[1] = _authorizationCall(borrowerKey, address(adapter));
        bundle[2] = _adapterCall(
            abi.encodeCall(adapter.morphoRepay, (m.params, 0, type(uint256).max, MAX_SHARE_PRICE_E27, borrower, ""))
        );
        bundle[3] =
            _adapterCall(abi.encodeCall(adapter.morphoWithdrawCollateral, (m.params, type(uint256).max, borrower)));
        _exec(borrower, 0, bundle);

        CorePosition memory pos = m.core.position(m.id, borrower);
        assertEq(pos.borrowShares, 0, "debt fully repaid");
        assertEq(pos.collateral, 0, "collateral fully withdrawn");
        assertEq(wsteth.balanceOf(borrower), COLLATERAL_AMOUNT, "collateral returned");
        assertEq(weth.balanceOf(borrower), wethBefore - fullRepayAssets, "exact repay assets spent");
    }

    /// @dev The same position close, but the collateral withdrawal runs inside the core's repay
    ///      callback: the core calls the adapter back before pulling the loan tokens, and the adapter
    ///      re-enters the dispatcher with the exact calls promised up front. Passing proves two things
    ///      at once: the dispatcher saw the promised re-entry (a swallowed callback reverts
    ///      `MissingExpectedReenter`), and the core released its hook lock before the callback
    ///      (otherwise `HOOK_REENTRANCY`).
    function test_bundle_repayWithCallback_reentersThroughHookLock() public {
        (Market storage m, uint256 fullRepayAssets) = _setUpBorrowerWithDebt(50 ether, 10 ether);
        vm.prank(borrower);
        weth.approve(address(adapter), fullRepayAssets);

        Call[] memory callbackBundle = new Call[](1);
        callbackBundle[0] =
            _adapterCall(abi.encodeCall(adapter.morphoWithdrawCollateral, (m.params, type(uint256).max, borrower)));
        bytes memory callbackData = abi.encode(callbackBundle);

        Call[] memory bundle = new Call[](3);
        bundle[0] =
            _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(weth), address(adapter), fullRepayAssets)));
        bundle[1] = _authorizationCall(borrowerKey, address(adapter));
        bundle[2] = _callWithCallback(
            address(adapter),
            abi.encodeCall(
                adapter.morphoRepay, (m.params, 0, type(uint256).max, MAX_SHARE_PRICE_E27, borrower, callbackData)
            ),
            callbackData
        );
        _exec(borrower, 0, bundle);

        CorePosition memory pos = m.core.position(m.id, borrower);
        assertEq(pos.borrowShares, 0, "debt fully repaid");
        assertEq(pos.collateral, 0, "collateral withdrawn inside the repay callback");
        assertEq(wsteth.balanceOf(borrower), COLLATERAL_AMOUNT, "collateral returned");
    }

    // ---
    // CONTROLLER POLICY INTERACTIONS
    // ---

    /// @dev Collateral supplied in the same bundle cannot be borrowed against yet: the controller's
    ///      activation rule rejects the borrow. That is the controller's decision, not a bundler
    ///      limit, and the whole bundle is undone.
    function testRevert_bundle_supplyCollateralThenBorrow_activationGate() public {
        // Gives the market loan tokens and one active borrower.
        (Market storage m,) = _setUpBorrowerWithDebt(50 ether, 1 ether);
        (address fresh, uint256 freshKey) = makeAddrAndKey("freshBorrower");
        _fund(m.collateralToken, fresh, COLLATERAL_AMOUNT);
        vm.prank(fresh);
        wsteth.approve(address(adapter), COLLATERAL_AMOUNT);

        Call[] memory bundle = new Call[](4);
        bundle[0] = _adapterCall(
            abi.encodeCall(adapter.erc20TransferFrom, (address(wsteth), address(adapter), COLLATERAL_AMOUNT))
        );
        bundle[1] =
            _adapterCall(abi.encodeCall(adapter.morphoSupplyCollateral, (m.params, type(uint256).max, fresh, hex"")));
        bundle[2] = _authorizationCall(freshKey, address(adapter));
        bundle[3] = _adapterCall(abi.encodeCall(adapter.morphoBorrow, (m.params, 1 ether, 0, 0, fresh)));

        vm.prank(fresh);
        vm.expectRevert(ILidoLendMarketController.InsufficientActiveCollateral.selector);
        bundler3.multicall(bundle);

        assertEq(wsteth.balanceOf(fresh), COLLATERAL_AMOUNT, "the failed bundle returned the collateral");
    }

    /// @dev A repay-everything bundle for a user with no debt reverts: the adapter reads the user's
    ///      debt from the core, finds zero, and refuses a zero repay.
    function testRevert_bundle_repayAllWithNoDebt() public {
        (Market storage m,) = _setUpBorrowerWithDebt(50 ether, 10 ether);
        address debtFree = _actor("debtFree");
        _fund(m.loanToken, debtFree, 1 ether);
        vm.prank(debtFree);
        weth.approve(address(adapter), 1 ether);

        Call[] memory bundle = new Call[](2);
        bundle[0] = _adapterCall(abi.encodeCall(adapter.erc20TransferFrom, (address(weth), address(adapter), 1 ether)));
        bundle[1] = _adapterCall(
            abi.encodeCall(adapter.morphoRepay, (m.params, 0, type(uint256).max, MAX_SHARE_PRICE_E27, debtFree, ""))
        );

        vm.prank(debtFree);
        vm.expectRevert(BundlerErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);

        assertEq(weth.balanceOf(debtFree), 1 ether, "the failed bundle returned the funds");
    }

    /// @dev A guardian ban on the borrower blocks borrows through the bundler too: the controller
    ///      checks whose position is borrowed against, and the adapter always sets that to the user
    ///      who started the bundle, so a banned user cannot hide behind the bundler.
    function testRevert_bundle_borrow_bannedBorrower() public {
        (Market storage m,) = _setUpBorrowerWithDebt(50 ether, 1 ether);

        vm.roll(block.number + 10);
        address[] memory accounts = new address[](1);
        accounts[0] = borrower;
        uint40 n = uint40(block.number - 1);
        protocol.guardianSignals
            .flag(
                m.id, accounts, BlockInfoWithHash({hash: blockhash(n), number: n, timestamp: uint40(block.timestamp)})
            );

        Call[] memory bundle = new Call[](2);
        bundle[0] = _authorizationCall(borrowerKey, address(adapter));
        bundle[1] = _adapterCall(abi.encodeCall(adapter.morphoBorrow, (m.params, 1 ether, 0, 0, borrower)));

        vm.prank(borrower);
        vm.expectRevert(ILidoLendMarketController.AddressBanned.selector);
        bundler3.multicall(bundle);
    }
}
