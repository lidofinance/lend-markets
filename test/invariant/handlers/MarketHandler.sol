// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Position, Market as MorphoMarket} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

import {ILidoLendERC4626} from "../../../src/interfaces/ILidoLendERC4626.sol";
import {MockPriceOracle} from "../../setup/Mocks.sol";

/// @notice Handler for the market-solvency invariant. Exposes bounded, defensively-guarded protocol actions
///         over a small fixed actor set holding instant activation (so supplied collateral is immediately
///         borrowable). Every action self-bounds and early-returns when there is no room, so the fuzzer
///         drives long valid sequences. Reads the LIVE oracle price so positions go unhealthy after a crash;
///         `liquidate` seizes ALL collateral when underwater to realize bad debt, stressing solvency under
///         socialization. (Note: handler state resets per fuzz run, so per-run coverage of the deep
///         supply→borrow→crash→liquidate chain is sparse; the bad-debt path is covered deterministically by
///         `test_badDebtSocialization_preservesSolvency`.)
contract MarketHandler is CommonBase, StdCheats, StdUtils {
    ILidoLend internal immutable CORE;
    ILidoLendERC4626 internal immutable VAULT;
    IERC20 internal immutable LOAN;
    IERC20 internal immutable COLLATERAL;
    MarketParams internal params;
    Id internal immutable ID;
    uint256 internal immutable SEED_PRICE;
    address internal immutable ORACLE;
    uint256 internal constant LLTV = 0.8e18;
    uint256 internal constant FLOOR = 10 ether; // minActivationAmount: a debt-bearing position can't drop below it

    address[] internal actors;

    // Coverage counters (read by `afterInvariant`) — incremented only on a successful action.
    uint256 public supplies;
    uint256 public borrows;
    uint256 public repays;
    uint256 public crashes;
    uint256 public liquidations;
    mapping(address => bool) public liquidated; // victims of a forced seizure (excluded from the floor invariant)

    constructor(
        ILidoLend core,
        ILidoLendERC4626 vault,
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

    function _mintTo(IERC20 token, address to, uint256 add) internal {
        deal(address(token), to, token.balanceOf(to) + add); // ADD (deal sets)
    }

    function supply(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1e18, 1_000_000e18);
        _mintTo(LOAN, a, amount);
        vm.startPrank(a);
        LOAN.approve(address(VAULT), amount);
        VAULT.deposit(amount, a);
        vm.stopPrank();
        supplies++;
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 max = VAULT.maxWithdraw(a);
        if (max == 0) return;
        amount = bound(amount, 1, max);
        vm.prank(a);
        VAULT.withdraw(amount, a, a);
    }

    function supplyCollateral(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        // Stay above minActivationAmount so the lot activates (instant → straight to active), not dust.
        amount = bound(amount, 50e18, 1_000_000e18);
        _mintTo(COLLATERAL, a, amount);
        vm.startPrank(a);
        COLLATERAL.approve(address(CORE), amount);
        CORE.supplyCollateral(params, amount, a, "");
        vm.stopPrank();
    }

    function borrow(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        Position memory pos = CORE.position(ID, a);
        // Borrowing against collateral below the activation floor now reverts `CollateralFloorBreached`; the
        // handler honours that gate (no dust action here, so raw collateral equals active collateral).
        if (pos.collateral < FLOOR) return;
        MorphoMarket memory mk = CORE.market(ID);

        uint256 maxBorrow = Math.mulDiv(Math.mulDiv(pos.collateral, _price(), 1e36), LLTV, 1e18);
        uint256 debt =
            mk.totalBorrowShares == 0 ? 0 : Math.mulDiv(pos.borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        if (maxBorrow <= debt) return;
        uint256 healthRoom = (maxBorrow - debt) * 99 / 100; // near the LLTV edge -> a crash tips it unhealthy
        uint256 liquidity = mk.totalSupplyAssets - mk.totalBorrowAssets;
        uint256 room = healthRoom < liquidity ? healthRoom : liquidity;
        if (room < 1e18) return;

        amount = bound(amount, 1e18, room);
        vm.prank(a);
        CORE.borrow(params, amount, 0, a, a);
        borrows++;
    }

    function repay(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        Position memory pos = CORE.position(ID, a);
        if (pos.borrowShares == 0) return;
        MorphoMarket memory mk = CORE.market(ID);
        uint256 shares = bound(amount, 1, pos.borrowShares);
        // Match the core's repay pull EXACTLY: SharesMathLib.toAssetsUp = mulDivUp(shares, tBA + 1, tBS + 1e6)
        // with the virtual offsets. The old `mulDiv(.,tBA,tBS)+1` omitted them and could under-fund by 1 wei
        // (ERC20InsufficientAllowance) once the assets/shares ratio drifted under interest.
        uint256 owed = Math.mulDiv(
            shares, uint256(mk.totalBorrowAssets) + 1, uint256(mk.totalBorrowShares) + 1e6, Math.Rounding.Ceil
        );
        _mintTo(LOAN, a, owed);
        vm.startPrank(a);
        LOAN.approve(address(CORE), owed);
        CORE.repay(params, 0, shares, a, "");
        vm.stopPrank();
        repays++;
    }

    function withdrawCollateral(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        Position memory pos = CORE.position(ID, a);
        if (pos.collateral == 0) return;
        MorphoMarket memory mk = CORE.market(ID);
        uint256 debt =
            mk.totalBorrowShares == 0 ? 0 : Math.mulDiv(pos.borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        // Collateral that can leave while keeping the position healthy: collateral - debt/(price*LLTV).
        uint256 requiredColl = debt == 0 ? 0 : Math.mulDiv(Math.mulDiv(debt, 1e18, LLTV), 1e36, _price());
        // A debt-bearing position also can't drop below the activation floor, so keep at least that too.
        uint256 floorKeep = pos.borrowShares == 0 ? 0 : FLOOR;
        uint256 minKeep = requiredColl > floorKeep ? requiredColl : floorKeep;
        if (pos.collateral <= minKeep) return;
        uint256 free = (uint256(pos.collateral) - minKeep) * 9 / 10; // 90% margin, clear of the gate
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(a);
        CORE.withdrawCollateral(params, amount, a, a);
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1 hours, 30 days);
        vm.warp(block.timestamp + dt);
        CORE.accrueInterest(params);
    }

    /// @dev Drop the collateral price to 25%..70% of the seed — a deep drop underwaters near-max positions,
    ///      exercising the liquidation and bad-debt-socialization paths.
    function crashPrice(uint256 factor) external {
        factor = bound(factor, 25, 70);
        MockPriceOracle(ORACLE).setPrice(SEED_PRICE * factor / 100);
        crashes++;
    }

    /// @dev Liquidate an unhealthy borrower. Underwater (debt > collateral value) → seize ALL collateral to
    ///      realize bad debt (socialization fires only at collateral==0); otherwise a bounded partial seize.
    ///      Skips healthy positions so the call never reverts on a sound position.
    function liquidate(uint256 actorSeed, uint256 seize) external {
        address victim = _actor(actorSeed);
        Position memory pos = CORE.position(ID, victim);
        if (pos.borrowShares == 0 || pos.collateral == 0) return;
        MorphoMarket memory mk = CORE.market(ID);
        uint256 debt = Math.mulDiv(pos.borrowShares, mk.totalBorrowAssets, mk.totalBorrowShares);
        uint256 collValue = Math.mulDiv(pos.collateral, _price(), 1e36);
        if (debt <= collValue * LLTV / 1e18) return; // healthy

        uint256 amount;
        if (debt > collValue) {
            amount = pos.collateral; // underwater: seize all -> bad-debt socialization (valid, shares clamp to 0)
        } else {
            // Solvent: the seize must not imply repaying MORE debt than exists, or the liquidation-incentive
            // math over-repays and the core (and its controller hook) revert. Collateral worth at most the
            // debt's FACE value maps, after the incentive divisor, to strictly less than the debt -> safe.
            uint256 maxSeize = Math.mulDiv(debt, 1e36, _price());
            if (maxSeize == 0) return;
            amount = bound(seize, 1, maxSeize);
        }
        // Pick a keeper distinct from the victim WITHOUT overflowing `actorSeed` (it may be `type(uint256).max`):
        // shift the victim's index by 1 modulo the actor count, which never coincides with the victim.
        address keeper = actors[(actorSeed % actors.length + 1) % actors.length];
        _mintTo(LOAN, keeper, type(uint128).max);
        vm.startPrank(keeper);
        LOAN.approve(address(CORE), type(uint256).max);
        CORE.liquidate(params, victim, amount, 0, "");
        vm.stopPrank();
        liquidations++;
        liquidated[victim] = true;
    }
}
