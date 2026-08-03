// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

import {ILidoLendERC4626} from "../../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendMarketController} from "../../../src/controllers/LidoLendMarketController.sol";
import {PausableUntil} from "../../../src/utils/PausableUntil.sol";
import {MockPriceOracle} from "../../setup/Mocks.sol";

/// @notice Handler for the vault invariant suite. On top of the market actions (borrow/repay/crash/warp/liquidate)
///         it drives the ERC-4626 surface (deposit/mint/withdraw/redeem) and the NEW vault mechanics (targeted
///         `settle`, `fallbackExit`, direct donations). Around each new-mechanic call it records ghosts the
///         invariants read: `settle`/`fallbackExit` are pro-rata so they must NOT move the share price (interest is
///         accrued first to isolate them); a direct donation is uncounted so it must NOT move the price either; and
///         no exit burns more shares than requested.
contract VaultHandler is CommonBase, StdCheats, StdUtils {
    ILidoLend internal immutable CORE;
    ILidoLendERC4626 internal immutable VAULT;
    ILidoLendMarketController internal immutable CONTROLLER;
    IERC20 internal immutable LOAN;
    IERC20 internal immutable COLLATERAL;
    MarketParams internal params;
    Id internal immutable ID;
    uint256 internal immutable SEED_PRICE;
    address internal immutable ORACLE;
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant FLOOR = 10 ether;
    uint256 internal constant PPS_TOLERANCE = 3; // wei of rounding a pro-rata burn may shift convertToAssets(1e18)
    // Below one full share the price is dominated by the virtual-share offset: an exit that drains the vault to dust
    // leaves totalSupply/totalAssets at the offset scale, where `convertToAssets(1e18)` snaps back to parity. That is
    // an empty-vault artifact, not dilution — there are no remaining holders to dilute — so the no-drop check below
    // only applies while the vault still carries meaningful supply.
    uint256 internal constant MIN_SUPPLY_FOR_PPS = 1e18;

    address[] internal actors;

    // Ghosts read by the invariants.
    bool public exitDiluted; // a settle / fallbackExit dropped the share price (diluted remaining holders)
    bool public priceMovedByDonation; // a direct donation shifted the share price
    bool public exitBurnedTooMuch; // an exit burned more shares than requested
    bool public settleMovedLiquidity; // a targeted settle paid loan assets or changed idle (not liquidity-neutral)
    bool public fallbackExitLiquidityMismatch; // fallbackExit's idle drop != its redeem-leg payout
    bool public parViolated; // an exit seized collateral worth MORE than the debt it cancelled (a penalty)
    uint256 public totalDonated; // loan tokens sent straight to the vault (uncounted)

    // Coverage counters.
    uint256 public deposits;
    uint256 public withdraws;
    uint256 public settles;
    uint256 public fallbackExits;
    uint256 public borrows;
    uint256 public crashes;
    uint256 public liquidations;
    uint256 public donations;
    uint256 public pauses;
    uint256 public caps;

    constructor(
        ILidoLend core,
        ILidoLendERC4626 vault,
        ILidoLendMarketController controller,
        IERC20 loan,
        IERC20 collateral,
        MarketParams memory p,
        Id id,
        uint256 oraclePrice,
        address oracle,
        address[] memory actors_
    ) {
        CORE = core;
        VAULT = vault;
        CONTROLLER = controller;
        LOAN = loan;
        COLLATERAL = collateral;
        params = p;
        ID = id;
        SEED_PRICE = oraclePrice;
        ORACLE = oracle;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _price() internal view returns (uint256) {
        return IOracle(ORACLE).price();
    }

    function _pps() internal view returns (uint256) {
        return VAULT.convertToAssets(1e18);
    }

    function _mintTo(IERC20 token, address to, uint256 add) internal {
        deal(address(token), to, token.balanceOf(to) + add);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _idle() internal view returns (uint256) {
        MorphoMarket memory mk = CORE.market(ID);
        return mk.totalSupplyAssets - mk.totalBorrowAssets;
    }

    function _ctrl() internal view returns (LidoLendMarketController) {
        return LidoLendMarketController(address(CONTROLLER));
    }

    function _paused() internal view returns (bool) {
        return _ctrl().isPaused();
    }

    /// @dev At par, seized collateral is the cancelled debt priced at the oracle, rounded down — so its value is at
    ///      most the cancelled debt. A value ABOVE the cancelled debt would be a penalty extracted from the borrower.
    function _seizedValueExceedsDebt(uint256 collateralSeized, uint256 debtCanceled) internal view returns (bool) {
        return Math.mulDiv(collateralSeized, _price(), 1e36) > debtCanceled;
    }

    // ── ERC-4626 entry ──

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 room = VAULT.maxDeposit(a);
        if (!_paused() && room < 1e18) return;
        amount = bound(amount, 1e18, _paused() ? 1_000_000e18 : Math.min(room, 1_000_000e18));
        _mintTo(LOAN, a, amount);
        vm.startPrank(a);
        LOAN.approve(address(VAULT), amount);
        if (_paused()) {
            // Paused fails closed: with maxDeposit at 0 the ERC-4626 max gate rejects any positive deposit.
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, a, amount, 0));
            VAULT.deposit(amount, a);
            vm.stopPrank();
            return;
        }
        VAULT.deposit(amount, a);
        vm.stopPrank();
        deposits++;
    }

    function mint(uint256 actorSeed, uint256 shares) external {
        address a = _actor(actorSeed);
        uint256 shareRoom = VAULT.maxMint(a);
        if (!_paused() && shareRoom < 1e18) return;
        shares = bound(shares, 1e18, _paused() ? 1_000_000e18 : Math.min(shareRoom, 1_000_000e18));
        uint256 cost = VAULT.previewMint(shares);
        _mintTo(LOAN, a, cost);
        vm.startPrank(a);
        LOAN.approve(address(VAULT), cost);
        if (_paused()) {
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, a, shares, 0));
            VAULT.mint(shares, a);
            vm.stopPrank();
            return;
        }
        VAULT.mint(shares, a);
        vm.stopPrank();
        deposits++;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        if (_paused()) {
            // paused: maxWithdraw is 0, so any positive withdraw fails closed at the ERC-4626 max gate.
            vm.prank(a);
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, a, 1, 0));
            VAULT.withdraw(1, a, a);
            return;
        }
        uint256 max = VAULT.maxWithdraw(a);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        VAULT.withdraw(amount, a, a);
        withdraws++;
    }

    function redeem(uint256 actorSeed, uint256 shares) external {
        address a = _actor(actorSeed);
        if (_paused()) {
            vm.prank(a);
            vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, a, 1, 0));
            VAULT.redeem(1, a, a);
            return;
        }
        uint256 max = VAULT.maxRedeem(a);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(a);
        VAULT.redeem(shares, a, a);
        withdraws++;
    }

    // ── new mechanics: settle / fallbackExit / donation ──

    /// @dev Targeted settle by an owner against every actor that carries debt. Pro-rata, so it must not move the
    ///      share price (interest accrued first to isolate the burn). Skips when a bad-debt root would revert it.
    function settle(uint256 actorSeed, uint256 shares) external {
        address owner = _actor(actorSeed);
        uint256 bal = VAULT.balanceOf(owner);
        if (bal == 0 || _paused() || CONTROLLER.hasBadDebt() || CONTROLLER.settlementBorrowersCount() == 0) return;

        address[] memory borrowers = new address[](actors.length);
        uint256 n;
        for (uint256 i; i < actors.length; i++) {
            if (CORE.position(ID, actors[i]).borrowShares != 0) borrowers[n++] = actors[i];
        }
        if (n == 0) return;
        assembly {
            mstore(borrowers, n)
        }

        CORE.accrueInterest(params); // isolate the pro-rata burn from interest
        uint256 ppsBefore = _pps();
        uint256 idleBefore = _idle();
        shares = bound(shares, 1, bal);
        vm.prank(owner);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            VAULT.settle(shares, borrowers, owner, owner);

        if (sharesBurned > shares) exitBurnedTooMuch = true;
        // The burn is rounded up so remaining holders aren't diluted -> the price may tick up, but must never drop.
        // Skip once the vault is drained to dust, where the price is a virtual-share artifact (see MIN_SUPPLY_FOR_PPS).
        if (VAULT.totalSupply() >= MIN_SUPPLY_FOR_PPS && _pps() + PPS_TOLERANCE < ppsBefore) exitDiluted = true;
        // Liquidity-neutral: settle pays no loan and cancels debt + supply by the same amount, so idle is unchanged.
        if (loanAssets != 0 || _absDiff(_idle(), idleBefore) > PPS_TOLERANCE) settleMovedLiquidity = true;
        if (_seizedValueExceedsDebt(collateralSeized, debtCanceled)) parViolated = true;
        settles++;
    }

    /// @dev fallbackExit: redeem the liquid part then settle the rest. Both legs are pro-rata, so the price is
    ///      unchanged. Skips when a bad-debt root would revert the settle leg.
    function fallbackExit(uint256 actorSeed, uint256 shares, uint256 iterations) external {
        address owner = _actor(actorSeed);
        uint256 bal = VAULT.balanceOf(owner);
        if (bal == 0 || _paused() || CONTROLLER.hasBadDebt()) return;

        CORE.accrueInterest(params);
        uint256 ppsBefore = _pps();
        uint256 idleBefore = _idle();
        shares = bound(shares, 1, bal);
        vm.prank(owner);
        (uint256 sharesBurned, uint256 loanAssets, uint256 collateralSeized, uint256 debtCanceled) =
            VAULT.fallbackExit(shares, owner, owner, bound(iterations, 0, 50));

        if (sharesBurned > shares) exitBurnedTooMuch = true;
        // Skip once the vault is drained to dust, where the price is a virtual-share artifact (see MIN_SUPPLY_FOR_PPS).
        if (VAULT.totalSupply() >= MIN_SUPPLY_FOR_PPS && _pps() + PPS_TOLERANCE < ppsBefore) exitDiluted = true;
        // The redeem leg drops idle by exactly its payout; the settle leg is liquidity-neutral -> idle drop == loan.
        uint256 idleAfter = _idle();
        if (idleAfter > idleBefore || _absDiff(idleBefore - idleAfter, loanAssets) > PPS_TOLERANCE) {
            fallbackExitLiquidityMismatch = true;
        }
        if (_seizedValueExceedsDebt(collateralSeized, debtCanceled)) parViolated = true;
        fallbackExits++;
    }

    /// @dev A direct loan-token donation to the vault. `totalAssets` counts only the Morpho position, so this is
    ///      uncounted and must not move the share price.
    function donate(uint256 amount) external {
        if (_paused()) {
            vm.expectRevert(PausableUntil.ResumedExpected.selector); // paused: the accrue hook fails closed
            CORE.accrueInterest(params);
            return;
        }
        amount = bound(amount, 1, 1_000_000e18);
        CORE.accrueInterest(params);
        uint256 ppsBefore = _pps();
        _mintTo(LOAN, address(this), amount);
        LOAN.transfer(address(VAULT), amount);
        if (_pps() != ppsBefore) priceMovedByDonation = true;
        totalDonated += amount;
        donations++;
    }

    // ── market actions to reach illiquid / distressed states ──

    function supplyCollateral(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 50e18, 1_000_000e18);
        _mintTo(COLLATERAL, a, amount);
        vm.startPrank(a);
        COLLATERAL.approve(address(CORE), amount);
        if (_paused()) vm.expectRevert(PausableUntil.ResumedExpected.selector);
        CORE.supplyCollateral(params, amount, a, "");
        vm.stopPrank();
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        Position memory pos = CORE.position(ID, a);
        if (pos.collateral < FLOOR) return;
        MorphoMarket memory mk = CORE.market(ID);
        uint256 maxBorrow = Math.mulDiv(Math.mulDiv(pos.collateral, _price(), 1e36), LLTV, 1e18);
        uint256 debt =
            mk.totalBorrowShares == 0 ? 0 : Math.mulDiv(pos.borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        if (maxBorrow <= debt) return;
        uint256 healthRoom = (maxBorrow - debt) * 99 / 100;
        uint256 liquidity = mk.totalSupplyAssets - mk.totalBorrowAssets;
        uint256 room = healthRoom < liquidity ? healthRoom : liquidity;
        if (room < 1e18) return;
        amount = bound(amount, 1e18, room);
        uint256 mintShares = Math.mulDiv(
            amount, uint256(mk.totalBorrowShares) + 1e6, uint256(mk.totalBorrowAssets) + 1, Math.Rounding.Ceil
        );
        if (mintShares > type(uint128).max) return;
        bool paused = _paused();
        if (paused) vm.expectRevert(PausableUntil.ResumedExpected.selector);
        vm.prank(a);
        CORE.borrow(params, amount, 0, a, a);
        if (!paused) borrows++;
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        Position memory pos = CORE.position(ID, a);
        if (pos.borrowShares == 0) return;
        MorphoMarket memory mk = CORE.market(ID);
        uint256 shares = bound(amount, 1, pos.borrowShares);
        uint256 owed = Math.mulDiv(
            shares, uint256(mk.totalBorrowAssets) + 1, uint256(mk.totalBorrowShares) + 1e6, Math.Rounding.Ceil
        );
        _mintTo(LOAN, a, owed);
        vm.startPrank(a);
        LOAN.approve(address(CORE), owed);
        if (_paused()) vm.expectRevert(PausableUntil.ResumedExpected.selector);
        CORE.repay(params, 0, shares, a, "");
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 30 days);
        vm.warp(block.timestamp + dt);
        if (!_paused()) CORE.accrueInterest(params); // accrue gates on resume; let time advance so a pause expires
    }

    // ── governance state: pause / resume and the supply cap (the max* MUST track these) ──

    function pauseResume(uint256 seed) external {
        LidoLendMarketController c = _ctrl();
        if (c.isPaused()) c.resume();
        else c.pauseFor(bound(seed, 1 hours, 3 days));
        pauses++;
    }

    function setSupplyCap(uint256 seed) external {
        uint256 tSA = CORE.market(ID).totalSupplyAssets;
        // Mostly a binding cap near the current supply; sometimes uncap (0 == unlimited).
        _ctrl().setSupplyCap(seed % 4 == 0 ? 0 : tSA + bound(seed, 0, 500e18));
        caps++;
    }

    function crashPrice(uint256 factor) external {
        factor = bound(factor, 25, 90);
        MockPriceOracle(ORACLE).setPrice(SEED_PRICE * factor / 100);
        crashes++;
    }

    function liquidate(uint256 actorSeed, uint256 seize) external {
        address victim = _actor(actorSeed);
        Position memory pos = CORE.position(ID, victim);
        if (pos.borrowShares == 0 || pos.collateral == 0) return;
        MorphoMarket memory mk = CORE.market(ID);
        uint256 debt = Math.mulDiv(pos.borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        uint256 collValue = Math.mulDiv(pos.collateral, _price(), 1e36);
        if (debt <= collValue * LLTV / 1e18) return;

        uint256 amount;
        if (debt > collValue) {
            amount = pos.collateral;
        } else {
            uint256 maxSeize = Math.mulDiv(debt, 1e36, _price());
            if (maxSeize == 0) return;
            amount = bound(seize, 1, maxSeize);
        }
        address keeper = actors[(actorSeed % actors.length + 1) % actors.length];
        _mintTo(LOAN, keeper, type(uint128).max);
        vm.startPrank(keeper);
        LOAN.approve(address(CORE), type(uint256).max);
        if (_paused()) {
            vm.expectRevert(PausableUntil.ResumedExpected.selector);
            CORE.liquidate(params, victim, amount, 0, "");
            vm.stopPrank();
            return;
        }
        CORE.liquidate(params, victim, amount, 0, "");
        vm.stopPrank();
        liquidations++;
    }
}
