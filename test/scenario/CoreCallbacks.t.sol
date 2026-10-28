// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Market as MorphoMarket, MarketParams, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IMorphoFlashLoanCallback, IMorphoLiquidateCallback} from "@lido-lend/src/interfaces/IMorphoCallbacks.sol";

import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {Erc4626Math} from "../setup/Erc4626Math.sol";
import {LidoLendSetup} from "../setup/LidoLendSetup.sol";
import {MarketActions} from "../setup/MarketActions.sol";
import {MockERC20, MockPriceOracle} from "../setup/Mocks.sol";
import {Market} from "../setup/Types.sol";

/// @dev An integrator that calls the vault from inside the core's flash-loan and liquidation callbacks.
contract CoreCallbackActor is IMorphoFlashLoanCallback, IMorphoLiquidateCallback {
    enum VaultCall {
        Settle,
        FallbackExit
    }

    ILidoLend private immutable CORE;
    ILidoLendERC4626 private immutable VAULT;
    MarketParams private params;
    VaultCall private vaultCall;
    address[] private settleList;

    uint256 public sharesBurned;
    uint256 public loanAssets;
    uint256 public collateralSeized;
    uint256 public debtCanceled;

    constructor(ILidoLend core, ILidoLendERC4626 vault, MarketParams memory marketParams) {
        CORE = core;
        VAULT = vault;
        params = marketParams;
        IERC20(marketParams.loanToken).approve(address(core), type(uint256).max);
        IERC20(marketParams.loanToken).approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 assets) external {
        VAULT.deposit(assets, address(this));
    }

    /// @dev Flash-borrows `assets`, deposits them and fallback-exits every vault share in the callback.
    function flashDepositExit(uint256 assets) external {
        CORE.flashLoan(params.loanToken, assets, hex"01");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        VAULT.deposit(assets, address(this));
        _fallbackExit();
    }

    /// @dev Liquidates `borrower` and runs `call` on every vault share in the callback, before the core pulls the
    ///      repaid assets.
    function liquidateThen(VaultCall call, address borrower, uint256 repaidShares, address[] calldata borrowers)
        external
    {
        vaultCall = call;
        settleList = borrowers;
        CORE.liquidate(params, borrower, 0, repaidShares, hex"01");
    }

    function onMorphoLiquidate(uint256, bytes calldata) external {
        if (vaultCall == VaultCall.Settle) {
            (sharesBurned, collateralSeized, debtCanceled) =
                VAULT.settle(VAULT.balanceOf(address(this)), settleList, address(this), address(this));
        } else {
            _fallbackExit();
        }
    }

    function _fallbackExit() private {
        (sharesBurned, loanAssets, collateralSeized, debtCanceled) =
            VAULT.fallbackExit(VAULT.balanceOf(address(this)), address(this), address(this), 0);
    }
}

/// @notice L2 vault calls from inside core callbacks, against the real controller and vault. Inside a flash loan or a
///         liquidation callback the market's accounting liquidity can exceed the loan tokens the core holds. A liquid
///         leg then fails on the token transfer in a single market, or borrows pooled tokens of another market on the
///         same loan token that the core pulls back before the call ends. After each case the pooled balance covers
///         the free liquidity of every market, and the settlement queue matches the positions.
contract CoreCallbacksTest is LidoLendSetup {
    using MarketActions for Market;

    uint256 internal constant PRICE = 1.2e36;
    // `victim` is liquidatable at this price and `other` is not.
    uint256 internal constant LIQUIDATION_PRICE = 1.08e36;

    CoreCallbackActor internal actor;
    address internal lender;
    address internal victim;
    address internal other;

    function setUp() public {
        MockERC20 loan = new MockERC20("Loan", "LOAN", 18);
        MockERC20 collateral = new MockERC20("Collateral", "COLL", 18);
        Market storage m = _deployProtocol(_defaultConfig(address(loan), address(collateral), address(collateral)));
        MockPriceOracle(address(m.oracle)).setPrice(PRICE);
        actor = new CoreCallbackActor(m.core, m.vault, m.params);
        lender = _actor("lender");
        victim = _actor("victim");
        other = _actor("other");
    }

    // ── Flash-loan callback: vault deposit, then fallbackExit ──

    /// @dev In a liquid market the flash-loaned deposit leaves through the liquid leg alone. The actor gets what a
    ///      plain deposit and liquid exit of its own funds would pay.
    function test_flashLoanCallback_depositExit_liquidMarket_matchesPlainRoundTrip() public {
        Market storage m = _m();
        _lend(100 ether);
        _fund(m.loanToken, address(actor), 1 ether); // pays the rounding on the flash repayment
        uint256 vaultSupplyBefore = m.vault.totalSupply();

        uint256 snapshot = vm.snapshotState();
        _fund(m.loanToken, address(actor), 50 ether);
        uint256 plainShares = m.vaultDeposit(address(actor), 50 ether);
        uint256 plainLoan = m.fallbackExitLiquid(address(actor), plainShares, address(actor));
        assertTrue(vm.revertToState(snapshot), "plain round trip restored");

        actor.flashDepositExit(50 ether);

        assertEq(actor.loanAssets(), plainLoan, "the liquid leg pays the plain round trip");
        assertEq(actor.collateralSeized(), 0, "no settle leg");
        assertEq(actor.debtCanceled(), 0, "no settle leg");
        assertEq(m.vault.balanceOf(address(actor)), 0, "every share burned");
        assertEq(m.vault.totalSupply(), vaultSupplyBefore, "vault supply unchanged");
        _assertCustodyAndQueue();
    }

    /// @dev One market with 10 free loan tokens. After the flash-loaned deposit the vault sizes its liquid leg at the
    ///      20 of accounting liquidity, but the core holds only 10, so the withdraw transfer reverts.
    function testRevert_flashLoanCallback_depositExit_illiquidSingleMarket() public {
        Market storage m = _m();
        _seedIlliquid();
        uint256 sharesBefore = m.vault.balanceOf(address(actor));

        vm.expectRevert(bytes("transfer reverted"));
        actor.flashDepositExit(10 ether);

        assertEq(m.vault.balanceOf(address(actor)), sharesBefore, "actor shares untouched");
        _assertCustodyAndQueue();
    }

    /// @dev A second market on the same loan token holds 50 idle tokens in the pooled balance. The liquid leg pays the
    ///      20 of accounting liquidity from that pool, and the flash repayment restores it. The actor nets the same
    ///      loan and collateral as a plain fallbackExit from the same state.
    function test_flashLoanCallback_depositExit_pooledBalance_matchesPlainExit() public {
        Market storage m = _m();
        _seedIlliquid();
        _addIdleMarket(50 ether);

        uint256 snapshot = vm.snapshotState();
        (, uint256 plainLoan, uint256 plainCollateral,) =
            m.fallbackExit(address(actor), m.vault.balanceOf(address(actor)), address(actor), 0);
        assertTrue(vm.revertToState(snapshot), "plain exit restored");

        actor.flashDepositExit(10 ether);

        assertEq(actor.loanAssets(), 20 ether, "the liquid leg pays all accounting liquidity");
        assertEq(m.loanToken.balanceOf(address(actor)), plainLoan, "net loan equals the plain exit");
        assertEq(actor.collateralSeized(), plainCollateral, "collateral equals the plain exit");
        _assertCustodyAndQueue();
    }

    // ── Liquidation callback: vault settle or fallbackExit before the repay is pulled ──

    /// @dev The settle runs on the state the liquidation has written and cuts `other` by its personal slice, as the
    ///      same settle after a plain liquidation would.
    function test_liquidateCallback_vaultSettle_cutsPersonalSlice() public {
        Market storage m = _m();
        _seedLiquidatable();
        uint256 repaidShares = m.core.position(m.id, victim).borrowShares / 2;
        uint256 shares = m.vault.balanceOf(address(actor));
        uint256 otherCollateralBefore = m.core.position(m.id, other).collateral;

        uint256 snapshot = vm.snapshotState();
        vm.prank(address(actor));
        m.core.liquidate(m.params, victim, 0, repaidShares, "");
        MarketActions.SettlementExpectation memory expected = m.expectedPersonalSettlement(shares, other);
        assertTrue(vm.revertToState(snapshot), "plain liquidation restored");

        actor.liquidateThen(CoreCallbackActor.VaultCall.Settle, victim, repaidShares, _one(other));

        assertEq(actor.collateralSeized(), expected.collateralSeized, "seizure matches the personal recompute");
        assertEq(actor.debtCanceled(), expected.debtCanceled, "debt canceled matches the personal recompute");
        assertEq(actor.sharesBurned(), expected.sharesBurned, "shares burned match the personal recompute");
        assertEq(
            m.core.position(m.id, other).collateral,
            otherCollateralBefore - expected.collateralSeized,
            "collateral taken from other"
        );
        _assertCustodyAndQueue();
    }

    /// @dev The market lends out every loan token, so the core holds none. The liquidation already counts the unpaid
    ///      repay as liquidity, but the liquid leg's withdraw transfer reverts and the whole liquidation reverts.
    function testRevert_liquidateCallback_fallbackExit_utilizedSingleMarket() public {
        Market storage m = _m();
        _seedLiquidatable();
        assertEq(m.loanToken.balanceOf(address(m.core)), 0, "setup: the core holds no loan tokens");
        uint256 victimSharesBefore = m.core.position(m.id, victim).borrowShares;

        vm.expectRevert(bytes("transfer reverted"));
        actor.liquidateThen(CoreCallbackActor.VaultCall.FallbackExit, victim, victimSharesBefore / 2, new address[](0));

        assertEq(m.core.position(m.id, victim).borrowShares, victimSharesBefore, "liquidation undone");
        _assertCustodyAndQueue();
    }

    /// @dev With 50 idle tokens of a second market in the pooled balance, the liquid leg pays the actor's whole
    ///      position inside the callback. The liquidation then pulls the repay, and no settle leg runs.
    function test_liquidateCallback_fallbackExit_pooledBalance_paysLiquidLeg() public {
        Market storage m = _m();
        _seedLiquidatable();
        _addIdleMarket(50 ether);
        uint256 repaidShares = m.core.position(m.id, victim).borrowShares / 2;
        uint256 shares = m.vault.balanceOf(address(actor));
        uint256 expectedLoan = Erc4626Math.toAssets(m.vault, shares, Math.Rounding.Floor);
        (,, uint256 repaidAssets) = m.expectedLiquidation(0, repaidShares);
        assertGe(repaidAssets, expectedLoan, "setup: the unpaid repay covers the actor's position");

        actor.liquidateThen(CoreCallbackActor.VaultCall.FallbackExit, victim, repaidShares, new address[](0));

        assertEq(actor.loanAssets(), expectedLoan, "the liquid leg pays the whole position");
        assertEq(actor.sharesBurned(), shares, "every share burned");
        assertEq(actor.collateralSeized(), 0, "no settle leg");
        _assertCustodyAndQueue();
    }

    // ── Fixtures ──

    function _m() internal view returns (Market storage) {
        return protocol.markets[0];
    }

    /// @dev The actor holds 40 of 100 vault assets. `victim` borrows 90 against 150 collateral and opts into a 25%
    ///      personal target, so the core keeps 10 free loan tokens.
    function _seedIlliquid() internal {
        Market storage m = _m();
        _fund(m.loanToken, address(actor), 40 ether);
        actor.deposit(40 ether);
        _lend(60 ether);
        _borrow(victim, 150 ether, 90 ether);
        m.setSettlementLtv(victim, 0.25e18);
        assertEq(m.loanToken.balanceOf(address(m.core)), 10 ether, "setup: 10 free loan tokens");
    }

    /// @dev The actor holds 40 of 100 vault assets. `other` borrows 12 against 20 collateral with a 25% personal
    ///      target, and `victim` borrows 88 against 100. The price drop makes only `victim` liquidatable, and the actor
    ///      gets 60 loan tokens to pay the repay.
    function _seedLiquidatable() internal {
        Market storage m = _m();
        _fund(m.loanToken, address(actor), 40 ether);
        actor.deposit(40 ether);
        _lend(60 ether);
        _borrow(other, 20 ether, 12 ether);
        m.setSettlementLtv(other, 0.25e18);
        _borrow(victim, 100 ether, 88 ether);
        MockPriceOracle(address(m.oracle)).setPrice(LIQUIDATION_PRICE);
        _fund(m.loanToken, address(actor), 60 ether);
    }

    /// @dev A second market on the same loan token, with its own collateral token and `idle` unborrowed supply.
    function _addIdleMarket(uint256 idle) internal {
        MockERC20 collateral = new MockERC20("Collateral2", "COLL2", 18);
        address loan = address(_m().loanToken);
        Market storage second = _addMarket(_defaultConfig(loan, address(collateral), address(collateral)));
        address secondLender = _actor("secondLender");
        _fund(second.loanToken, secondLender, idle);
        second.vaultDeposit(secondLender, idle);
    }

    function _lend(uint256 assets) internal {
        _fund(_m().loanToken, lender, assets);
        _m().vaultDeposit(lender, assets);
    }

    function _borrow(address borrower, uint256 collateral, uint256 debt) internal {
        Market storage m = _m();
        _fund(m.collateralToken, borrower, collateral);
        m.supplyCollateral(borrower, collateral);
        m.activateCollateral();
        m.borrow(borrower, debt);
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    // ── Consistency ──

    /// @dev The pooled loan balance covers the free liquidity of every market. In the first market each tracked
    ///      borrower is queued exactly when it has debt and collateral, under the key `borrowShares * 1e18 /
    ///      collateral`.
    function _assertCustodyAndQueue() internal view {
        uint256 freeLiquidity;
        for (uint256 i; i < protocol.markets.length; ++i) {
            MorphoMarket memory mkt = protocol.core.market(protocol.markets[i].id);
            freeLiquidity += mkt.totalSupplyAssets - mkt.totalBorrowAssets;
        }
        assertGe(_m().loanToken.balanceOf(address(protocol.core)), freeLiquidity, "pooled balance covers markets");

        Market storage m = _m();
        (address[] memory queued, uint256[] memory keys) =
            m.controller.settlementBorrowers(0, m.controller.settlementBorrowersCount());
        address[3] memory tracked = [address(actor), victim, other];
        for (uint256 i; i < tracked.length; ++i) {
            Position memory p = m.core.position(m.id, tracked[i]);
            bool found;
            uint256 key;
            for (uint256 j; j < queued.length; ++j) {
                if (queued[j] == tracked[i]) (found, key) = (true, keys[j]);
            }
            bool expectQueued = p.borrowShares > 0 && p.collateral > 0;
            assertEq(found, expectQueued, "queue membership matches the position");
            assertEq(key, expectQueued ? uint256(p.borrowShares) * 1e18 / p.collateral : 0, "queue key");
        }
    }
}
