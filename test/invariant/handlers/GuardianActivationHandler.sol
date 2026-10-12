// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {ILidoLendMarketController} from "../../../src/interfaces/ILidoLendMarketController.sol";
import {IGuardianSignals} from "../../../src/interfaces/IGuardianSignals.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {BlockInfoWithHash, GuardiansOpinion} from "../../../src/types/GuardianSignalsTypes.sol";
import {CollateralActivationConfig} from "../../../src/types/CollateralActivationTypes.sol";

import {ActivationModel} from "../../setup/ActivationModel.sol";

/// @notice This handler calls the collateral, debt, guardian signal, committee, heartbeat and time actions. The
///         market has a non-zero frontier fallback and a non-zero per-suspect delay.
/// @dev The handler records the lot start and the base delay for each borrower. It reads the base delay from
///      `currentActivationDelay` immediately before the deposit that forms the lot. The suite then computes
///      the unlock time from the formula of the specification. It does not read that value from the
///      controller.
///
///      Each deposit is equal to or larger than `minActivationAmount`. Each deposit therefore enters the
///      activating bucket, and the dust rules stay outside the calculation. The handler has no voluntary
///      withdrawal action, because that action adds the rules for the inactive balance. Those rules are not
///      part of the property under test.
///
///      Each action calculates the available space and returns early if there is none.
contract GuardianActivationHandler is Test {
    ILidoLend internal immutable CORE;
    ILidoLendMarketController internal immutable CONTROLLER;
    IGuardianSignals internal immutable GS;
    IOracle internal immutable ORACLE;
    IERC20 internal immutable LOAN;
    IERC20 internal immutable COLLATERAL;
    Id internal immutable ID;
    uint256 internal immutable LLTV;

    MarketParams internal params;

    /// @dev The candidate committee members. The first three addresses are the initial committee, and the
    ///      other two permit a replacement.
    address[5] internal guardianPool =
        [address(0x6001), address(0x6002), address(0x6003), address(0x6004), address(0x6005)];
    address[3] internal borrowers;

    /// @dev The block timestamp of the start of the current lot for each borrower. The value is zero if the
    ///      borrower has no lot.
    mapping(address borrower => uint40) public lotStart;
    /// @dev The base activation delay of that lot. This value excludes the guardian surcharge.
    mapping(address borrower => uint40) public lotBaseDelay;

    uint256 public supplies;
    uint256 public borrows;
    uint256 public maturations;
    uint256 public maturedOnFrontier;
    uint256 public maturedOnFallback;
    uint256 public signals;
    uint256 public configChanges;

    constructor(
        ILidoLend core,
        ILidoLendMarketController controller,
        IGuardianSignals gs,
        IOracle oracle,
        IERC20 loan,
        IERC20 collateral,
        MarketParams memory marketParams,
        Id id,
        address[3] memory actors
    ) {
        CORE = core;
        CONTROLLER = controller;
        GS = gs;
        ORACLE = oracle;
        LOAN = loan;
        COLLATERAL = collateral;
        params = marketParams;
        ID = id;
        LLTV = marketParams.lltv;
        borrowers = actors;
    }

    // ── the values that the suite reads ──

    function borrowerAt(uint256 index) external view returns (address) {
        return borrowers[index];
    }

    function borrowerCount() external pure returns (uint256) {
        return 3;
    }

    /// @notice The required unlock time for the lot of the borrower. A value of zero shows that the borrower
    ///         has no lot.
    /// @dev This function calls `ActivationModel`. That library states the rules of
    ///      `docs/specs/market-controller.md` "Collateral activation". This suite and the activation unit tests
    ///      therefore use one model and not two copies of the same formula.
    function modelUnlockTime(address borrower) external view returns (uint256) {
        ActivationModel.Lot memory lot = _lot(borrower);
        if (lot.activating == 0 || lot.start == 0) return 0;
        return ActivationModel.unlockTime(lot, CONTROLLER.collateralActivationConfig(), GS.getOpinion(ID, borrower));
    }

    // ── collateral and debt ──

    /// @notice A deposit that is equal to or larger than the activation threshold. The deposit therefore
    ///         always enters the activating bucket. The action asserts the maturation decision against the
    ///         rules of the specification. It calculates that decision from the state before the call.
    function doSupplyCollateral(uint256 actorSeed, uint256 amountSeed) external {
        address borrower = borrowers[actorSeed % 3];
        CollateralActivationConfig memory cfg = CONTROLLER.collateralActivationConfig();
        uint256 amount = bound(amountSeed, cfg.minActivationAmount, cfg.minActivationAmount + 500 ether);

        uint256 activatingBefore = CONTROLLER.positionOf(borrower).activating;
        bool shouldMature = _shouldMature(borrower);
        // Read the base delay for this deposit. The calculation includes the size of the deposit, as `credit`
        // does.
        uint40 newBaseDelay = uint40(CONTROLLER.currentActivationDelay(amount));

        deal(address(COLLATERAL), borrower, COLLATERAL.balanceOf(borrower) + amount);
        vm.startPrank(borrower);
        COLLATERAL.approve(address(CORE), type(uint256).max);
        CORE.supplyCollateral(params, amount, borrower, "");
        vm.stopPrank();

        // The controller empties a matured lot before it records the deposit. The activating bucket therefore
        // holds the remaining lot and this deposit. Any other value shows an incorrect maturation.
        uint256 expectedActivating = (shouldMature ? 0 : activatingBefore) + amount;
        assertEq(
            CONTROLLER.positionOf(borrower).activating, expectedActivating, "the maturation decision is not correct"
        );

        if (shouldMature) ++maturations;
        // A deposit on an existing lot restarts the timer and gives a new base delay.
        lotStart[borrower] = uint40(block.timestamp);
        lotBaseDelay[borrower] = newBaseDelay;
        ++supplies;
    }

    function doBorrow(uint256 actorSeed, uint256 amountSeed) external {
        address borrower = borrowers[actorSeed % 3];
        if (GS.isBanned(ID, borrower)) return;
        if (CONTROLLER.isFrozen()) return;

        uint256 room = _borrowRoom(borrower);
        if (room < 1e12) return;
        if (LOAN.balanceOf(address(CORE)) < room) return;

        vm.prank(borrower);
        CORE.borrow(params, bound(amountSeed, 1e12, room), 0, borrower, borrower);
        ++borrows;
    }

    function doRepay(uint256 actorSeed, uint256 shareSeed) external {
        address borrower = borrowers[actorSeed % 3];
        uint256 shares = CORE.position(ID, borrower).borrowShares;
        if (shares == 0) return;

        uint256 repayShares = bound(shareSeed, 1, shares);
        uint256 assets = _repayAssets(repayShares);
        deal(address(LOAN), borrower, LOAN.balanceOf(borrower) + assets + 1);

        vm.startPrank(borrower);
        LOAN.approve(address(CORE), type(uint256).max);
        CORE.repay(params, 0, repayShares, borrower, "");
        vm.stopPrank();
    }

    // ── the guardian signals ──

    function doFlag(uint256 guardianSeed, uint256 actorSeed) external {
        address guardian = _currentGuardian(guardianSeed);
        address borrower = borrowers[actorSeed % 3];
        vm.prank(guardian);
        GS.flag(ID, guardian, _one(borrower));
        ++signals;
    }

    function doUnflag(uint256 guardianSeed, uint256 actorSeed) external {
        address guardian = _currentGuardian(guardianSeed);
        vm.prank(guardian);
        GS.unflag(ID, guardian, _one(borrowers[actorSeed % 3]));
    }

    function doSuspect(uint256 guardianSeed, uint256 actorSeed) external {
        address guardian = _currentGuardian(guardianSeed);
        vm.prank(guardian);
        GS.suspect(ID, guardian, _one(borrowers[actorSeed % 3]));
        ++signals;
    }

    function doUnsuspect(uint256 guardianSeed, uint256 actorSeed) external {
        address guardian = _currentGuardian(guardianSeed);
        vm.prank(guardian);
        GS.unsuspect(ID, guardian, _one(borrowers[actorSeed % 3]));
    }

    function doBan(uint256 actorSeed) external {
        GS.ban(ID, borrowers[actorSeed % 3]);
    }

    function doUnban(uint256 actorSeed) external {
        GS.unban(ID, borrowers[actorSeed % 3]);
    }

    // ── the committee and configuration actions ──

    /// @notice A new quorum. The registry does not recompute the stored frontier, so the frontier gate then
    ///         uses a frontier that a different quorum set.
    function doSetQuorum(uint256 quorumSeed) external {
        GS.setQuorum(bound(quorumSeed, 1, GS.getGuardianCount()));
        ++configChanges;
    }

    /// @notice A replacement. The new guardian has no heartbeat, and the stored frontier does not change.
    function doReplaceGuardian(uint256 oldSeed, uint256 newSeed) external {
        GS.replaceGuardian(_currentGuardian(oldSeed), _freeGuardian(newSeed));
        ++configChanges;
    }

    /// @notice A new suspect window. It changes the expiry of the cached snapshot, and that expiry decides
    ///         whether the suspect surcharge applies to a lot.
    function doSetSuspectWindow(uint256 windowSeed) external {
        GS.setSuspectWindow(bound(windowSeed, 0, GS.MAX_SUSPECT_WINDOW()));
        ++configChanges;
    }

    // ── the heartbeat and time actions ──

    /// @notice Heartbeats from a quorum of guardians. This is the only action that advances the frontier.
    ///         Without it, the gate stops each lot and the campaign shows nothing.
    function doHeartbeatQuorum(uint256 timestampSeed) external {
        if (block.number < 2) return;
        uint256 number = block.number - 1;
        bytes32 hash = blockhash(number);
        if (hash == bytes32(0)) return;

        (address[] memory current,) = GS.getGuardians();
        uint256 quorum = GS.getQuorum();
        for (uint256 i; i < current.length && i < quorum; ++i) {
            uint40 stored = GS.getHeartbeat(current[i]);
            if (stored > block.timestamp) continue;
            uint40 scannedAt = uint40(bound(timestampSeed, stored, block.timestamp));
            vm.prank(current[i]);
            GS.heartbeat(current[i], BlockInfoWithHash({hash: hash, number: uint40(number), timestamp: scannedAt}), "");
        }
    }

    function doWarp(uint256 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 minutes, 3 days));
        vm.roll(block.number + 1);
    }

    // ── the internal functions ──

    /// @dev The maturation rules of the specification, applied to the current state. A lot matures only if the
    ///      market is not frozen, the borrower is not banned, and the time is at or after the unlock time. One
    ///      more condition applies: the frontier reaches the unlock time, or the time is at or after the
    ///      fallback deadline of the lot.
    ///
    ///      The handler counts these last two conditions separately, and the campaign can then show both
    ///      results. If the surcharge moves the unlock time past the fallback deadline, the frontier condition
    ///      is never the deciding one. Each lot then matures on the fallback without scan evidence.
    function _shouldMature(address borrower) internal returns (bool) {
        ActivationModel.Lot memory lot = _lot(borrower);
        if (lot.start == 0) return false;

        CollateralActivationConfig memory cfg = CONTROLLER.collateralActivationConfig();
        GuardiansOpinion memory opinion = GS.getOpinion(ID, borrower);
        if (!ActivationModel.matures(lot, cfg, opinion, CONTROLLER.isFrozen(), block.timestamp)) return false;

        // Record the condition that decided the maturation, so the campaign can show both results.
        if (opinion.quorumFrontierTimestamp >= ActivationModel.unlockTime(lot, cfg, opinion)) ++maturedOnFrontier;
        else ++maturedOnFallback;
        return true;
    }

    /// @dev The lot of the borrower in the form that the model uses. It holds the current activating balance,
    ///      with the start and the base delay from the deposit that formed the lot.
    function _lot(address borrower) internal view returns (ActivationModel.Lot memory lot) {
        lot.activating = CONTROLLER.positionOf(borrower).activating;
        lot.start = lotStart[borrower];
        lot.baseDelay = lotBaseDelay[borrower];
    }

    /// @dev The remaining borrow capacity. The calculation uses the active collateral only, with the current
    ///      price and the market LLTV.
    function _borrowRoom(address borrower) internal view returns (uint256) {
        ILidoLendMarketController.BorrowerPosition memory position = CONTROLLER.positionOf(borrower);
        uint256 maxBorrow = position.active * ORACLE.price() / 1e36 * LLTV / 1e18;
        if (maxBorrow <= position.debtAssets) return 0;
        return (maxBorrow - position.debtAssets) / 2;
    }

    /// @dev The assets for `shares`. The calculation uses the rounding rules of the core, and the repay call
    ///      therefore always has enough tokens.
    function _repayAssets(uint256 shares) internal view returns (uint256) {
        uint256 totalBorrowAssets = CORE.market(ID).totalBorrowAssets;
        uint256 totalBorrowShares = CORE.market(ID).totalBorrowShares;
        return Math.mulDiv(shares, totalBorrowAssets + 1, totalBorrowShares + 1e6, Math.Rounding.Ceil);
    }

    function _currentGuardian(uint256 seed) internal view returns (address) {
        (address[] memory current,) = GS.getGuardians();
        return current[seed % current.length];
    }

    /// @dev A pool address that is not a guardian. The committee holds three of the five addresses, so the
    ///      result is never the zero address.
    function _freeGuardian(uint256 seed) internal view returns (address) {
        uint256 start = seed % guardianPool.length;
        for (uint256 i; i < guardianPool.length; ++i) {
            address candidate = guardianPool[(start + i) % guardianPool.length];
            if (!GS.isGuardian(candidate)) return candidate;
        }
        return address(0);
    }

    function _one(address account) internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
