// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams, Market, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILidoLendMarketController} from "../../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendERC4626} from "../../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendOwner} from "../../../src/interfaces/ILidoLendOwner.sol";
import {IGuardianSignals} from "../../../src/interfaces/IGuardianSignals.sol";
import {IPausableUntil} from "../../../src/interfaces/IPausableUntil.sol";
import {IRiskStewardDashboard} from "../../../src/interfaces/IRiskStewardDashboard.sol";
import {LidoLendMarketController} from "../../../src/controllers/LidoLendMarketController.sol";
import {CollateralActivationConfig} from "../../../src/types/CollateralActivationTypes.sol";
import {WAD} from "../../../src/libs/Constants.sol";
import {Approvals} from "../../setup/Approvals.sol";
import {ForkTest} from "./ForkTest.sol";
import {IWstETH} from "./ForkTokens.sol";

/// @dev The immutable each deployed oracle exposes for its price source, i.e. what a price mock targets.
interface IReadWstEthRateOracle {
    function WSTETH() external view returns (address);
}

interface IReadUsdyStableOracle {
    function USDY_ORACLE() external view returns (address);
}

/// @dev Ondo's USDY NAV oracle: the exact member `UsdyStableOracle.price()` reads.
interface IReadNavOracle {
    function getPrice() external view returns (uint256);
}

/// @notice Shared base for fork suites over an already-deployed, activated market: binds one market from the run's
///         artifacts, names the privileged actors the run recorded, and drives governance through the deployed
///         surfaces as their real holders. Deploys nothing; a missing market role or optional artifact skips, any
///         other inconsistency fails loudly (`"ForkStack: ..."`).
abstract contract ForkStack is Test, ForkTest {
    using MarketParamsLib for MarketParams;
    using SharesMathLib for uint256;

    uint256 private constant BPS = 10_000;

    /// @dev The revert a mocked-down oracle source returns, so a suite can match the outage by exact bytes.
    error ForkOracleDown();

    /// @notice Which deployed oracle prices the market, and therefore which external call a price mock targets.
    enum OracleKind {
        WstEthRate,
        UsdyStable
    }

    /// @notice One bound market, resolved from the run artifacts and the live core; `params` is read back from
    ///         the core so it always matches `id`. `oracleSource` is the external contract the oracle prices from.
    struct BoundMarket {
        string name;
        ILidoLend core;
        MarketParams params;
        Id id;
        ILidoLendMarketController controller;
        ILidoLendERC4626 vault;
        IOracle oracle;
        IGuardianSignals guardianSignals;
        IERC20 loanToken;
        IERC20 collateralToken;
        CollateralActivationConfig activation;
        OracleKind oracleKind;
        address oracleSource;
    }

    // ---
    // BINDING
    // ---

    /// @notice The name of the run's market playing `role`; marks the test skipped when the run has none. A run
    ///         recording no markets at all is a broken setup and reverts.
    function _marketForRole(string memory role) internal returns (string memory marketName) {
        Vm.DirEntry[] memory entries = vm.readDir(string.concat(_runArtifactsDir(), "/markets"));
        uint256 seen;
        uint256 matches;
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
        if (matches == 0) vm.skip(true, string.concat("ForkStack: run has no market for role '", role, "'"));
    }

    /// @notice Resolve the market recorded as `name` and check it is activated, consistent with its artifacts (id
    ///         and oracle), and live (neither paused nor frozen).
    function _bindMarket(string memory name) internal returns (BoundMarket memory m) {
        m.name = name;
        m.core = ILidoLend(_protocol("core"));
        m.id = Id.wrap(_marketId(name));
        m.controller = ILidoLendMarketController(_market(name, "controller"));
        m.vault = ILidoLendERC4626(_market(name, "vault"));
        m.oracle = IOracle(_market(name, "oracle"));
        m.guardianSignals = IGuardianSignals(_market(name, "guardian_signals"));

        // `lastUpdate == 0` is a created market whose activation motion has not run: no interest clock yet.
        require(
            m.core.market(m.id).lastUpdate != 0,
            string.concat(
                "ForkStack: market '",
                name,
                "' is not activated on the core; run deploy + activation provisioning (see script/DEPLOYMENT.md)"
            )
        );

        m.params = m.core.idToMarketParams(m.id);
        require(
            Id.unwrap(m.params.id()) == Id.unwrap(m.id),
            string.concat("ForkStack: market '", name, "' artifact id does not match core params")
        );
        require(
            address(m.oracle) == m.params.oracle,
            string.concat("ForkStack: artifact oracle does not match the market's oracle for '", name, "'")
        );

        m.loanToken = IERC20(m.params.loanToken);
        m.collateralToken = IERC20(m.params.collateralToken);
        m.activation = m.controller.collateralActivationConfig();

        _bindOracle(m);
        _requireLive(m);
    }

    /// @notice Assert the bound market is neither paused nor frozen: every suite starts live and halts it itself.
    function _requireLive(BoundMarket memory m) internal view {
        require(
            !IPausableUntil(address(m.controller)).isPaused(),
            string.concat("ForkStack: market '", m.name, "' is paused; fork suites bind a live market")
        );
        require(
            !m.controller.isFrozen(),
            string.concat("ForkStack: market '", m.name, "' is frozen; fork suites bind a live market")
        );
    }

    /// @dev The oracle's kind comes from its artifact, its price source from the deployed oracle's own immutable.
    function _bindOracle(BoundMarket memory m) private view {
        string memory relPath = string.concat("oracles/", _marketString(m.name, "oracle_artifact"), ".toml");
        bytes32 kind = keccak256(bytes(_artifactString(relPath, "oracle.kind")));
        if (kind == keccak256("wsteth-rate")) {
            m.oracleKind = OracleKind.WstEthRate;
            m.oracleSource = IReadWstEthRateOracle(address(m.oracle)).WSTETH();
        } else if (kind == keccak256("usdy-stable")) {
            m.oracleKind = OracleKind.UsdyStable;
            m.oracleSource = IReadUsdyStableOracle(address(m.oracle)).USDY_ORACLE();
        } else {
            revert(string.concat("ForkStack: market '", m.name, "' records an unknown oracle kind"));
        }
    }

    /// @notice Mark the test skipped when the run does not record the optional artifact at `relPath`.
    function _skipUnlessArtifact(string memory relPath) internal {
        if (!_hasArtifact(relPath)) vm.skip(true, string.concat("ForkStack: run has no ", relPath));
    }

    // ---
    // PRIVILEGED ACTORS AND DEPLOYED SURFACES, AS THE RUN RECORDED THEM
    // ---

    /// @notice The protocol admin (Lido Agent).
    function _admin() internal view returns (address) {
        return _protocol("agent");
    }

    /// @notice The EasyTrack EVMScriptExecutor, the owner facade's role holder.
    function _executor() internal view returns (address) {
        return _protocol("evm_script_executor");
    }

    /// @notice The reseal manager (Dual Governance): the controller's `PAUSER_ROLE` and sole `RESUMER_ROLE` holder.
    function _resealManager() internal view returns (address) {
        return _protocol("reseal_manager");
    }

    /// @notice The owner facade (`LidoLendOwner`), the manager of every controller and the core's owner.
    function _facade() internal view returns (ILidoLendOwner) {
        return ILidoLendOwner(_protocol("owner_facade"));
    }

    /// @notice The risk-steward dashboard, the controller's `FREEZER_ROLE` holder.
    function _dashboard() internal view returns (IRiskStewardDashboard) {
        return IRiskStewardDashboard(_protocol("risk_steward_dashboard"));
    }

    /// @notice OZ AccessControl's refusal for `account` lacking `role`, for `vm.expectRevert`.
    function _unauthorized(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    // ---
    // GOVERNANCE, THROUGH THE DEPLOYED SURFACES
    // ---

    /// @notice Grant or revoke instant activation for `caller` as the executor through the facade.
    function _setInstantActivation(BoundMarket memory m, address caller, bool enabled) internal {
        vm.prank(_executor());
        _facade().setInstantActivation(m.id, caller, enabled);
        require(
            m.controller.hasInstantActivation(caller) == enabled,
            "ForkStack: facade did not change instant activation (does it hold MANAGER_ROLE?)"
        );
    }

    /// @notice Unfreeze the market as the executor through the facade, the only `UNFREEZER_ROLE` holder.
    function _unfreeze(BoundMarket memory m) internal {
        vm.prank(_executor());
        _facade().unfreezeMarket(m.id);
        require(!m.controller.isFrozen(), "ForkStack: facade did not unfreeze the market");
    }

    /// @notice Set the market's supply cap as the executor through the facade; 0 lifts the cap.
    function _setSupplyCap(BoundMarket memory m, uint256 cap) internal {
        vm.prank(_executor());
        _facade().setMarketSupplyCap(m.id, cap);
        require(
            LidoLendMarketController(address(m.controller)).supplyCap() == cap,
            "ForkStack: facade did not change the supply cap"
        );
    }

    /// @notice Appoint a fresh steward for the market as the executor through the dashboard.
    function _appointSteward(BoundMarket memory m, string memory label) internal returns (address steward) {
        steward = makeAddr(label);
        vm.prank(_executor());
        _dashboard().addMarketSteward(m.id, steward);
        require(_dashboard().isMarketSteward(m.id, steward), "ForkStack: dashboard did not appoint the steward");
    }

    /// @notice Freeze the market as `steward` through the dashboard.
    function _freezeViaSteward(BoundMarket memory m, address steward) internal {
        vm.prank(steward);
        _dashboard().freezeMarket(m.id);
        require(m.controller.isFrozen(), "ForkStack: dashboard did not freeze the market");
    }

    /// @notice Pause the controller for `duration` as the reseal manager.
    function _pauseViaResealManager(BoundMarket memory m, uint256 duration) internal {
        vm.prank(_resealManager());
        m.controller.pauseFor(duration);
        require(IPausableUntil(address(m.controller)).isPaused(), "ForkStack: reseal manager did not pause");
    }

    /// @notice The first `quorum` guardians of the market's live committee: enough distinct flags to latch a ban.
    function _quorumGuardians(BoundMarket memory m) internal view returns (address[] memory quorum) {
        (address[] memory guardians,) = m.guardianSignals.getGuardians();
        uint256 n = m.guardianSignals.getQuorum();
        require(guardians.length >= n, "ForkStack: live guardian set smaller than its quorum");
        quorum = new address[](n);
        for (uint256 i; i < n; ++i) {
            quorum[i] = guardians[i];
        }
    }

    // ---
    // STATE SHAPING
    // ---

    /// @notice Accrue pending interest now, so exact total-delta assertions hold; reverts if the market is paused.
    function _pokeAccrue(BoundMarket memory m) internal {
        m.core.accrueInterest(m.params);
    }

    /// @notice Warp one second past the market's maximum activation delay, so a fresh collateral lot matures.
    function _warpPastActivation(BoundMarket memory m) internal {
        vm.warp(block.timestamp + uint256(m.activation.maxActivationDelay) + 1);
    }

    /// @notice The market's unborrowed liquidity at the last-accrued totals: `totalSupplyAssets - totalBorrowAssets`.
    function _freeLiquidity(BoundMarket memory m) internal view returns (uint256) {
        Market memory mkt = m.core.market(m.id);
        return uint256(mkt.totalSupplyAssets) - uint256(mkt.totalBorrowAssets);
    }

    /// @notice Assert the controller's supply headroom (what the supply hook enforces) covers `assets`.
    function _requireSupplyHeadroom(BoundMarket memory m, uint256 assets) internal view {
        uint256 headroom = m.controller.maxDeposit();
        require(
            headroom >= assets,
            string.concat("ForkStack: supply ", vm.toString(assets), " exceeds market headroom ", vm.toString(headroom))
        );
    }

    /// @notice Borrow the market's free liquidity down to exactly `target` into a fresh, instant-activated,
    ///         over-collateralized pin borrower.
    function _pinFreeLiquidity(BoundMarket memory m, uint256 target) internal {
        _pokeAccrue(m); // same-block borrow moves totals by exactly the borrowed amount

        uint256 free = _freeLiquidity(m);
        require(
            free >= target,
            string.concat("ForkStack: free liquidity ", vm.toString(free), " below pin target ", vm.toString(target))
        );
        uint256 excess = free - target;
        if (excess == 0) return;

        address pinBorrower = makeAddr("forkstack.pinBorrower");
        uint256 collateral = _collateralFor(m, excess, BPS);
        _setInstantActivation(m, pinBorrower, true); // manager-gated, so through the facade as the executor

        deal(address(m.collateralToken), pinBorrower, collateral);
        _approve(address(m.collateralToken), pinBorrower, address(m.core), collateral);
        vm.startPrank(pinBorrower);
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
    // PRICING
    // ---

    /// @notice Move the price so `borrower` lands at `targetLtv` (WAD) and assert it did; returns the mocked price.
    ///         The price that does it is `debt * WAD * SCALE / (collateral * target)` off the accrued position.
    function _distress(BoundMarket memory m, address borrower, uint256 targetLtv) internal returns (uint256 mocked) {
        _pokeAccrue(m);
        Position memory p = m.core.position(m.id, borrower);
        require(p.borrowShares != 0 && p.collateral != 0, "ForkStack: borrower has no position to distress");
        Market memory mkt = m.core.market(m.id);
        uint256 debt = uint256(p.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);

        mocked = _mockCollateralPrice(m, Math.mulDiv(debt * WAD, ORACLE_PRICE_SCALE, uint256(p.collateral) * targetLtv));

        uint256 collateralValue = Math.mulDiv(p.collateral, mocked, ORACLE_PRICE_SCALE);
        assertApproxEqRel(Math.mulDiv(debt, WAD, collateralValue), targetLtv, 1e15, "distress: realized LTV");
    }

    /// @notice Take the oracle's source down so `price()` reverts `ForkOracleDown()`; returns those bytes.
    function _mockOracleRevert(BoundMarket memory m) internal returns (bytes memory err) {
        err = abi.encodeWithSelector(ForkOracleDown.selector);
        vm.mockCallRevert(m.oracleSource, _oracleSourceCall(m), err);
        (bool ok,) = address(m.oracle).staticcall(abi.encodeCall(IOracle.price, ()));
        require(!ok, "ForkStack: oracle still prices after its source was mocked down");
    }

    /// @dev Move the oracle price to `target` by mocking the deployed oracle's own source (the wstETH rate call, or
    ///      the Ondo NAV scaled so `price()` lands on `target`); returns the post-mock `price()`. The USDY oracle's
    ///      immutable band still applies and reverts `PriceOutOfBounds` for a `target` outside it.
    function _mockCollateralPrice(BoundMarket memory m, uint256 target) private returns (uint256 mocked) {
        if (m.oracleKind == OracleKind.WstEthRate) {
            vm.mockCall(m.oracleSource, _oracleSourceCall(m), abi.encode(target));
        } else {
            // `price()` is linear in the NAV, so scale the NAV by target/current.
            uint256 currentNav = IReadNavOracle(m.oracleSource).getPrice();
            uint256 mockNav = Math.mulDiv(currentNav, target, m.oracle.price());
            vm.mockCall(m.oracleSource, _oracleSourceCall(m), abi.encode(mockNav));
        }
        mocked = m.oracle.price();
    }

    /// @dev The exact external call the deployed oracle makes on its source, i.e. what a price mock targets.
    function _oracleSourceCall(BoundMarket memory m) private pure returns (bytes memory) {
        if (m.oracleKind == OracleKind.WstEthRate) {
            return abi.encodeCall(IWstETH.getStETHByWstETH, (ORACLE_PRICE_SCALE));
        }
        return abi.encodeCall(IReadNavOracle.getPrice, ());
    }

    // ---
    // LIVE SIZING
    // ---

    /// @notice One whole loan token (`10 ** decimals`).
    function _loanUnit(BoundMarket memory m) internal view returns (uint256) {
        return 10 ** IERC20Metadata(address(m.loanToken)).decimals();
    }

    /// @notice Largest debt `collateral` carries at `price` and the live LLTV, floored twice like the controller.
    function _maxBorrow(BoundMarket memory m, uint256 collateral, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(collateral, price, ORACLE_PRICE_SCALE), m.params.lltv, WAD);
    }

    /// @dev Collateral carrying `loanAssets` at the live LLTV and price with `marginBps` of slack, floored at twice
    ///      the activation threshold so the lot activates and holds real capacity.
    function _collateralFor(BoundMarket memory m, uint256 loanAssets, uint256 marginBps)
        private
        view
        returns (uint256 collateral)
    {
        uint256 valueNeeded = Math.mulDiv(loanAssets, WAD, m.params.lltv, Math.Rounding.Ceil);
        valueNeeded = Math.mulDiv(valueNeeded, BPS + marginBps, BPS, Math.Rounding.Ceil);
        collateral = Math.mulDiv(valueNeeded, ORACLE_PRICE_SCALE, m.oracle.price(), Math.Rounding.Ceil);
        uint256 dustFloor = 2 * uint256(m.activation.minActivationAmount);
        if (collateral < dustFloor) collateral = dustFloor;
    }

    // ---
    // FUNDING AND ACTORS
    // ---

    /// @notice `owner` approves `spender` for `amount` of `token`, tolerating USDT's no-return, zero-first `approve`.
    function _approve(address token, address owner, address spender, uint256 amount) internal {
        Approvals.approve(token, owner, spender, amount);
    }

    /// @notice A fresh labelled actor, asserted clean of any position, vault shares and market tokens, so its
    ///         post-action balances read as deltas.
    function _freshActor(BoundMarket memory m, string memory label) internal returns (address a) {
        a = makeAddr(label);
        Position memory p = m.core.position(m.id, a);
        require(
            p.supplyShares == 0 && p.borrowShares == 0 && p.collateral == 0,
            string.concat("ForkStack: actor '", label, "' already has a market position")
        );
        require(m.vault.balanceOf(a) == 0, string.concat("ForkStack: actor '", label, "' already holds vault shares"));
        require(m.loanToken.balanceOf(a) == 0, string.concat("ForkStack: actor '", label, "' already holds loan token"));
        require(
            m.collateralToken.balanceOf(a) == 0,
            string.concat("ForkStack: actor '", label, "' already holds collateral token")
        );
    }
}
