// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Market, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendMarketController} from "../../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendERC4626} from "../../../src/interfaces/ILidoLendERC4626.sol";
import {IGuardianSignals} from "../../../src/interfaces/IGuardianSignals.sol";
import {CollateralActivationConfig} from "../../../src/types/CollateralActivationTypes.sol";
import {WAD} from "../../../src/libs/Constants.sol";
import {ForkTest} from "./ForkTest.sol";

/// @dev Read-only view of the IRM router's manager — production wiring assigns it to the EasyTrack
///      EVMScriptExecutor, which is how `_executor` resolves the executor on-chain.
interface IReadRouter {
    function manager() external view returns (address);
}

/// @notice Shared base for fork suites that exercise an ALREADY-DEPLOYED, ALREADY-ACTIVATED market. It binds a
///         suite to one market read from the deploy run's artifacts (via {ForkTest}) and hands back the privileged
///         actors and state-shaping utilities the suites share, so each `setUp` shrinks to `_fork()` +
///         `_bindMarket(name)`. Fork suites deploy nothing and create no market — every address and every role
///         holder is resolved on-chain from the live stack, so the helper stays network-blind.
///
///         Every helper here fails loudly (a `require` prefixed `"ForkStack: "` and naming the market) rather
///         than skipping or returning a silent default — a mis-provisioned or half-wired stack must stop the run,
///         not pass a hollow one. The `Test` / `ForkTest` shared `CommonBase` ancestor is the intended diamond;
///         `Test` supplies `deal` / `makeAddr` / assertions, `ForkTest` supplies the artifact accessors.
abstract contract ForkStack is Test, ForkTest {
    using MarketParamsLib for MarketParams;

    // ---
    // CONSTANTS
    // ---

    /// @dev OZ AccessControl's default admin role id (`0x00`); the interface exposes no getter for it.
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    // ---
    // TYPES
    // ---

    /// @notice Everything a fork suite needs about one bound market, resolved from the run artifacts and the live
    ///         core. `params` is reconstructed from the core (never hand-built) so it always matches the id.
    /// @param core The Morpho-fork core hosting the market.
    /// @param params The market's params, read back from `core.idToMarketParams(id)`.
    /// @param id The market id (bytes32) from the market artifact.
    /// @param controller The market's Lido-policy controller.
    /// @param vault The market's ERC-4626 vault.
    /// @param oracle The market's price oracle.
    /// @param guardianSignals The guardian-signal registry wired into the controller.
    /// @param irmRouter The protocol IRM router address.
    /// @param loanToken The market's loan token (`params.loanToken`).
    /// @param collateralToken The market's collateral token (`params.collateralToken`).
    /// @param activation The controller's live collateral-activation config.
    struct BoundMarket {
        ILidoLend core;
        MarketParams params;
        Id id;
        ILidoLendMarketController controller;
        ILidoLendERC4626 vault;
        IOracle oracle;
        IGuardianSignals guardianSignals;
        address irmRouter;
        IERC20 loanToken;
        IERC20 collateralToken;
        CollateralActivationConfig activation;
    }

    // ---
    // BINDING
    // ---

    /// @notice The name of the run's market playing `role`, or an empty string when it has none — in which case
    ///         the calling test is marked skipped and the caller returns without binding. Roles are shared across
    ///         deployments while market names are not, so a suite names the part it drives rather than one
    ///         deployment's market.
    /// @dev A deployment need not contain every role: a run may carry no `usdy-usdt`, and a suite bound
    ///      to that role is not applicable there. That is a fact about the deployment, readable from its
    ///      artifacts. A run recording no markets at all IS a broken setup and reverts, so a mistyped role cannot
    ///      pass as an absent one.
    function _marketForRole(string memory role) internal returns (string memory) {
        Vm.DirEntry[] memory entries = vm.readDir(string.concat(_runArtifactsDir(), "/markets"));
        uint256 seen;
        uint256 matches;
        string memory marketName;
        bytes32 expected = keccak256(bytes(role));
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].isDir || entries[i].isSymlink) continue;
            ++seen;
            string memory artifact = _readCompatibleArtifact(entries[i].path);
            require(
                vm.keyExistsToml(artifact, ".market.role"),
                string.concat("ForkStack: market artifact is missing market.role: ", entries[i].path)
            );
            string memory recorded = vm.parseTomlString(artifact, ".market.role");
            require(
                bytes(recorded).length != 0,
                string.concat("ForkStack: market artifact has empty market.role: ", entries[i].path)
            );
            if (keccak256(bytes(recorded)) != expected) continue;
            ++matches;
            require(matches == 1, string.concat("ForkStack: multiple markets have role '", role, "'"));
            marketName = vm.parseTomlString(artifact, ".market.name");
        }
        require(seen != 0, "ForkStack: the bound run records no markets");
        if (matches == 0) {
            vm.skip(true, string.concat("ForkStack: run has no market for role '", role, "'"));
            return "";
        }
        return marketName;
    }

    /// @notice Resolve and validate the market recorded as `name` in the run, returning a fully-typed handle.
    /// @dev Loud-fails when: any artifact key is missing (the {ForkTest} accessors revert first); the core,
    ///      controller, vault, oracle, or guardian registry has no code; the market is not activated on the core
    ///      (`lastUpdate == 0`) — the caller must run deploy + activation provisioning first
    ///      (see script/DEPLOYMENT.md); the reconstructed params do not hash to the recorded id; or the artifact's
    ///      oracle does not match the core params' oracle. Reading `params` from the core (not the artifact)
    ///      keeps the params/id pair internally consistent.
    /// @param name The market name, i.e. the `markets/<name>.toml` artifact in the run directory.
    /// @return m The bound market handle.
    function _bindMarket(string memory name) internal returns (BoundMarket memory m) {
        m.core = ILidoLend(_protocol("core"));
        m.id = Id.wrap(_marketId(name));
        m.controller = ILidoLendMarketController(_market(name, "controller"));
        m.vault = ILidoLendERC4626(_market(name, "vault"));
        m.oracle = IOracle(_market(name, "oracle"));
        m.guardianSignals = IGuardianSignals(_market(name, "guardian_signals"));
        m.irmRouter = _protocol("irm_router");

        // Every contract the suite drives must actually be deployed at the recorded address.
        _requireHasCode(address(m.core), name, "core");
        _requireHasCode(address(m.controller), name, "controller");
        _requireHasCode(address(m.vault), name, "vault");
        _requireHasCode(address(m.oracle), name, "oracle");
        _requireHasCode(address(m.guardianSignals), name, "guardianSignals");

        // A never-touched market has `lastUpdate == 0`: it exists on the core but the activation motion has not
        // run, so the suite would drive a market with no interest clock. Stop, do not silently proceed.
        require(
            m.core.market(m.id).lastUpdate != 0,
            string.concat(
                "ForkStack: market '",
                name,
                "' is not activated on the core; run deploy + activation provisioning (see script/DEPLOYMENT.md)"
            )
        );

        // Reconstruct params from the core and assert they hash to the recorded id: catches an artifact pointing
        // at a stale or wrong id for `name`.
        m.params = m.core.idToMarketParams(m.id);
        require(
            Id.unwrap(m.params.id()) == Id.unwrap(m.id),
            string.concat("ForkStack: market '", name, "' artifact id does not match core params")
        );

        // Catches an artifact oracle pointing at a stale or wrong instance for `name`: the two are independently
        // recorded (the market artifact vs. the core's params), and must agree.
        require(
            address(m.oracle) == m.params.oracle,
            string.concat("ForkStack: artifact oracle does not match the market's oracle for '", name, "'")
        );

        m.loanToken = IERC20(m.params.loanToken);
        m.collateralToken = IERC20(m.params.collateralToken);
        m.activation = m.controller.collateralActivationConfig();
    }

    // ---
    // PRIVILEGED ACTORS
    // ---

    /// @notice The protocol admin (Lido Agent): the sole `DEFAULT_ADMIN_ROLE` holder of the guardian registry.
    /// @dev Resolved off the guardian registry because it is `AccessControlEnumerable`, whereas the controller is
    ///      plain `AccessControlUpgradeable` (no member enumeration). Loud-fails when the registry has no default
    ///      admin, or when that admin does not also administer the controller — a mis-wired stack, not a live one.
    /// @param m The bound market.
    /// @return admin The protocol admin address.
    function _admin(BoundMarket memory m) internal view returns (address admin) {
        IAccessControlEnumerable registry = IAccessControlEnumerable(address(m.guardianSignals));
        require(
            registry.getRoleMemberCount(DEFAULT_ADMIN_ROLE) != 0, "ForkStack: guardian registry has no default admin"
        );
        admin = registry.getRoleMember(DEFAULT_ADMIN_ROLE, 0);
        require(
            m.controller.hasRole(DEFAULT_ADMIN_ROLE, admin), "ForkStack: guardian admin does not admin the controller"
        );
    }

    /// @notice The EasyTrack executor: the IRM router's `manager`, which the deploy assigns to the
    ///         EVMScriptExecutor. (The guardian registry's `MANAGER_ROLE` belongs to the owner facade, so it
    ///         cannot resolve the executor.)
    /// @dev Loud-fails when the router reports no manager (an unprovisioned backbone).
    /// @param m The bound market.
    /// @return executor The EasyTrack executor address.
    function _executor(BoundMarket memory m) internal view returns (address executor) {
        executor = IReadRouter(m.irmRouter).manager();
        require(executor != address(0), "ForkStack: irm router has no manager");
    }

    /// @notice Grant the calling test contract the controller's `MANAGER_ROLE`, pranking the protocol admin.
    /// @dev Idempotent: returns early when this contract already holds the role, so repeated calls do not revert
    ///      or emit spurious grants. Lets a suite drive manager-only controller levers (supply cap, instant
    ///      activation, settlement config) without hunting for the live manager key.
    /// @param m The bound market.
    function _grantSelfManager(BoundMarket memory m) internal {
        bytes32 role = m.controller.MANAGER_ROLE();
        if (m.controller.hasRole(role, address(this))) return;
        vm.prank(_admin(m));
        m.controller.grantRole(role, address(this));
    }

    // ---
    // STATE SHAPING
    // ---

    /// @notice Accrue the market's pending interest now.
    /// @dev A latest-block fork carries pending interest; without this the first state-mutating call folds it in
    ///      and breaks exact `totalAssets` / `totalSupplyAssets` delta assertions. Reverts loudly if the market is
    ///      paused (the core's `AccrueInterest` hook checks the controller is resumed).
    /// @param m The bound market.
    function _pokeAccrue(BoundMarket memory m) internal {
        m.core.accrueInterest(m.params);
    }

    /// @notice Warp past the market's maximum activation delay, so a freshly supplied collateral lot matures.
    /// @dev Advances one second beyond `maxActivationDelay` from the current timestamp.
    /// @param m The bound market.
    function _warpPastActivation(BoundMarket memory m) internal {
        vm.warp(block.timestamp + uint256(m.activation.maxActivationDelay) + 1);
    }

    /// @notice The market's free (unborrowed) liquidity: `totalSupplyAssets - totalBorrowAssets`.
    /// @dev Reads the last-accrued core totals; call `_pokeAccrue` first when an exact figure matters.
    /// @param m The bound market.
    /// @return The free liquidity, in loan-token assets.
    function _freeLiquidity(BoundMarket memory m) internal view returns (uint256) {
        Market memory mkt = m.core.market(m.id);
        return uint256(mkt.totalSupplyAssets) - uint256(mkt.totalBorrowAssets);
    }

    /// @notice Assert the market accepts a lender deposit of `assets`.
    /// @dev Deposits are capped: the controller's supply cap surfaces through the vault's ERC-4626 `maxDeposit`
    ///      (which also returns 0 while the controller is paused). Loud-fails when `assets` exceeds that headroom.
    /// @param m The bound market.
    /// @param assets The intended deposit, in loan-token assets.
    function _requireDepositHeadroom(BoundMarket memory m, uint256 assets) internal view {
        uint256 headroom = m.vault.maxDeposit(address(this));
        require(
            headroom >= assets,
            string.concat("ForkStack: deposit ", vm.toString(assets), " exceeds vault headroom ", vm.toString(headroom))
        );
    }

    /// @notice Drive the market's free liquidity down to exactly `target` by borrowing the excess into a fresh,
    ///         amply-collateralized borrower.
    /// @dev Accrues first so the borrow (same block, zero elapsed) moves totals by exactly the borrowed amount,
    ///      landing free liquidity on `target`. The pin borrower is instant-activated (no maturation warp) and
    ///      over-collateralized to ~2x the LLTV requirement, floored at twice the activation dust threshold so the
    ///      lot both activates and carries borrow capacity. Loud-fails when free liquidity is already below
    ///      `target`, or when the post-borrow free liquidity does not land exactly on it.
    /// @param m The bound market.
    /// @param target The free liquidity to leave in the market.
    /// @return pinBorrower The borrower that absorbed the excess, or `address(0)` when there was no excess.
    function _pinFreeLiquidity(BoundMarket memory m, uint256 target) internal returns (address pinBorrower) {
        // Freeze pending interest so the borrow below accrues nothing more and the post-state is exact.
        _pokeAccrue(m);

        uint256 free = _freeLiquidity(m);
        require(
            free >= target,
            string.concat("ForkStack: free liquidity ", vm.toString(free), " below pin target ", vm.toString(target))
        );
        uint256 excess = free - target;
        if (excess == 0) return address(0);

        pinBorrower = makeAddr("forkstack.pinBorrower");

        // Size collateral to back `excess` at ~2x margin over the LLTV requirement, then floor at twice the dust
        // threshold so the lot clears `minActivationAmount` and holds real borrow capacity. `price` quotes one
        // collateral unit in loan-token assets, scaled by `ORACLE_PRICE_SCALE` (1e36).
        uint256 price = m.oracle.price();
        uint256 valueNeeded = Math.mulDiv(excess, 2 * WAD, m.params.lltv, Math.Rounding.Ceil);
        uint256 collateral = Math.mulDiv(valueNeeded, ORACLE_PRICE_SCALE, price, Math.Rounding.Ceil);
        uint256 dustFloor = 2 * uint256(m.activation.minActivationAmount);
        if (collateral < dustFloor) collateral = dustFloor;

        // Instant-activate the pin borrower's own supply (keyed on the supply caller), so its collateral is
        // borrowable with no maturation wait. Granting instant activation is manager-gated.
        _grantSelfManager(m);
        m.controller.setInstantActivation(pinBorrower, true);

        deal(address(m.collateralToken), pinBorrower, collateral);
        vm.startPrank(pinBorrower);
        m.collateralToken.approve(address(m.core), collateral);
        m.core.supplyCollateral(m.params, collateral, pinBorrower, "");
        m.core.borrow(m.params, excess, 0, pinBorrower, pinBorrower);
        vm.stopPrank();

        uint256 freeAfter = _freeLiquidity(m);
        require(
            freeAfter == target,
            string.concat(
                "ForkStack: pin left free liquidity ", vm.toString(freeAfter), " != target ", vm.toString(target)
            )
        );
    }

    // ---
    // ACTOR HYGIENE
    // ---

    /// @notice A fresh labelled actor guaranteed clean of this market's state.
    /// @dev Loud-fails when the address already holds any core position (supply / borrow / collateral) or any
    ///      vault shares — so suites bind actors by intent instead of reusing fixed constants that may collide
    ///      with the live deployment's existing participants.
    /// @param m The bound market.
    /// @param label The `makeAddr` label identifying the actor.
    /// @return a The fresh actor address.
    function _freshActor(BoundMarket memory m, string memory label) internal returns (address a) {
        a = makeAddr(label);
        Position memory p = m.core.position(m.id, a);
        require(
            p.supplyShares == 0 && p.borrowShares == 0 && p.collateral == 0,
            string.concat("ForkStack: actor '", label, "' already has a market position")
        );
        require(m.vault.balanceOf(a) == 0, string.concat("ForkStack: actor '", label, "' already holds vault shares"));
    }

    // ---
    // PRIVATE HELPERS
    // ---

    /// @dev Loud-fail when `addr` (the market's `what` contract) carries no code.
    function _requireHasCode(address addr, string memory name, string memory what) private view {
        require(addr.code.length != 0, string.concat("ForkStack: market '", name, "' ", what, " has no code"));
    }
}
