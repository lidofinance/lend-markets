// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ForkNetwork, ForkNetworks} from "./ForkNetworks.sol";
import {ForkCollateralIssuer} from "./ForkCollateralIssuer.sol";
import {ForkCollateralIssuerCentrifuge} from "./ForkCollateralIssuerCentrifuge.sol";
import {ForkCollateralIssuerLido} from "./ForkCollateralIssuerLido.sol";
import {ForkCollateralIssuerOndo} from "./ForkCollateralIssuerOndo.sol";

import {Test, console2} from "forge-std/Test.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Market as MarketState, Position} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IErc4626ExitBook} from "../../../src/interfaces/IErc4626ExitBook.sol";
import {ILidoLendMarketController} from "../../../src/interfaces/ILidoLendMarketController.sol";
import {ILidoLendERC4626} from "../../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendOwner} from "../../../src/interfaces/ILidoLendOwner.sol";
import {IGuardianSignals} from "../../../src/interfaces/IGuardianSignals.sol";
import {IMorphoExitBook} from "../../../src/interfaces/IMorphoExitBook.sol";
import {IPausableUntil} from "../../../src/interfaces/IPausableUntil.sol";
import {IRiskStewardDashboard} from "../../../src/interfaces/IRiskStewardDashboard.sol";
import {LidoLendMarketController} from "../../../src/controllers/LidoLendMarketController.sol";
import {TrailingAnchorOracleBase} from "../../../src/oracle/TrailingAnchorOracleBase.sol";
import {CollateralActivationConfig} from "../../../src/types/CollateralActivationTypes.sol";
import {BlockInfoWithHash} from "../../../src/types/GuardianSignalsTypes.sol";
import {WAD} from "../../../src/libs/Constants.sol";
import {Approvals} from "../../setup/Approvals.sol";
import {MarketActions} from "../../setup/MarketActions.sol";
import {Market} from "../../setup/Types.sol";
import {
    DeployMarketBase,
    MarketDeploymentResult,
    MarketDeployConfig
} from "../../../script/deployment/DeployMarketBase.s.sol";
import {BundlerAddresses} from "../../../script/deployment/DeployBundlerBase.s.sol";
import {ExitBookAddresses, ProtocolAddresses} from "../../../script/lib/ProtocolDeployer.sol";
import {RecordedProtocol} from "../../../script/lib/RecordedProtocol.sol";

/// @dev The Easy Track EVMScriptExecutor: it runs an EVMScript that Easy Track sends.
interface IEVMScriptExecutor {
    function easyTrack() external view returns (address);
    function executeEVMScript(bytes memory evmScript) external returns (bytes memory);
}

/// @dev Easy Track's motions: a factory's trusted caller creates one, and anyone enacts it once its duration has passed
///      without objection.
interface IEasyTrack {
    struct Motion {
        uint256 id;
        address evmScriptFactory;
        address creator;
        uint256 duration;
        uint256 startDate;
        uint256 snapshotBlock;
        uint256 objectionsThreshold;
        uint256 objectionsAmount;
        bytes32 evmScriptHash;
    }

    function getMotions() external view returns (Motion[] memory);
    function getMotion(uint256 motionId) external view returns (Motion memory);
    function isEVMScriptFactory(address factory) external view returns (bool);
    function createMotion(address factory, bytes calldata motionCalldata) external returns (uint256);
    function enactMotion(uint256 motionId, bytes calldata motionCalldata) external;
}

/// @dev An Easy Track factory: it builds a motion's EVMScript from its calldata.
interface IEVMScriptFactory {
    function trustedCaller() external view returns (address);
    function createEVMScript(address creator, bytes memory motionCalldata) external view returns (bytes memory);
}

/// @notice The base of every fork suite. A target is a market deploy script,
///         `FORK_DEPLOY_SCRIPT`, by default mainnet WETH/wstETH's. `_forkTarget` forks the script's network and sets up
///         its market with the network's deploy scripts: the deployed contracts that they give, else new ones, and
///         the market created when the core lacks it. A suite calls `_setUpTarget()` in `setUp`, which also binds the
///         market into `market`, the handle {MarketActions} drives, and creates `collateralIssuer` for it, which deals
///         the collateral and publishes the price source that the market's oracle reads; `_setOraclePrice` moves the
///         price through it. The helpers act on `market`; those a suite also runs on a second market take it.
/// @dev `market.config.admin` stays zero on purpose, so the `MarketActions` helpers that self-grant a role as that
///      admin fail loudly on a fork; governance goes through the facade helpers below instead.
abstract contract ForkStack is Test {
    using MarketActions for Market;
    using SharesMathLib for uint256;

    string internal constant DEFAULT_DEPLOY_SCRIPT = "script/deployment/mainnet/markets/DeployWethWstethMainnet.s.sol";
    uint256 internal constant MIN_SEED_SHARES = 1e9;
    uint256 internal constant MIN_SEED_ASSETS = 1e6;
    uint256 internal constant CORE_SEED_ASSETS = 1000;
    address internal constant SEED_RECIPIENT = address(0xdead);

    ForkNetwork internal network;
    /// @notice The path of the target's market deploy script, and the script.
    string internal deployScript;
    DeployMarketBase internal script;
    ProtocolAddresses internal protocol;
    ExitBookAddresses internal books;
    BundlerAddresses internal bundler;
    /// @notice The market's parameters, with its oracle and guardian registry.
    MarketDeployConfig internal parameters;
    MarketDeploymentResult internal deployment;
    /// @notice The bound market.
    Market internal market;
    /// @notice The issuer of the bound market's collateral: deals it, allowlists its holders, publishes its price
    ///         source.
    ForkCollateralIssuer internal collateralIssuer;

    /// @dev The standard collateral lot: twice the live activation threshold, so it activates with capacity.
    uint256 internal lot;

    // The shared fixture's actors and positions; suites that build their own actors reuse the names.
    address internal LENDER;
    address internal BORROWER;
    uint256 internal lenderShares;
    uint256 internal borrowShares;

    /// @notice Sets up the target with its market created and binds the market into `market`: the collateral's issuer
    ///         adds the core to the collateral's allowlist where it keeps one and publishes the current price, so the
    ///         test starts from a fresh one, and interest is accrued so the helpers' exact delta assertions hold from
    ///         the first action. A run of a recorded network, `FORK_RUN=<network>`, fails for an unknown network and
    ///         skips the markets of other networks and those their scripts record no deployment of, and with
    ///         `FORK_RUN_PREPARE=false` it leaves an uncreated market as it is and skips it.
    function _setUpTarget() internal {
        string memory run = vm.envOr("FORK_RUN", string(""));
        string memory path = vm.envOr("FORK_DEPLOY_SCRIPT", DEFAULT_DEPLOY_SCRIPT);
        string memory name = ForkNetworks.scriptName(path);
        bool running = bytes(run).length != 0;
        if (running) {
            ForkNetworks.requireKnown(run);
            if (keccak256(bytes(ForkNetworks.networkOf(path))) != keccak256(bytes(run))) {
                vm.skip(true, string.concat("ForkStack: ", name, " is not a market of ", run));
            }
        }
        bool prepare = !running || vm.envOr("FORK_RUN_PREPARE", true);
        _forkTarget(prepare);
        if (!prepare && ILidoLend(protocol.core).market(deployment.id).lastUpdate == 0) {
            vm.skip(
                true, string.concat("ForkStack: ", name, " is not created, and FORK_RUN_PREPARE=false leaves it so")
            );
        }
        market = _marketHandle(deployment);
        collateralIssuer = _collateralIssuerOf(market);
        collateralIssuer.addToAllowlist(address(market.core));
        _setOraclePrice(market.oracle.price());
        _accrueInterest();
        lot = 2 * uint256(_activationConfig(market).minActivationAmount);
    }

    /// @notice Forks the network of the target's deploy script and sets up its market there, over the network's
    ///         protocol: the contracts that the scripts give, else new ones, with the market created when
    ///         `createIfMissing` is set and the core lacks it. Logs where the contracts come from and whether the
    ///         market existed or how it was created.
    function _forkTarget(bool createIfMissing) internal {
        string memory path = vm.envOr("FORK_DEPLOY_SCRIPT", DEFAULT_DEPLOY_SCRIPT);
        _forkNetwork(ForkNetworks.networkOf(path));
        deployScript = path;
        script = DeployMarketBase(vm.deployCode(path));
        // A run of a recorded network tests its recorded markets only, and deploys no other.
        if (bytes(vm.envOr("FORK_RUN", string(""))).length != 0 && !script.isRecorded()) {
            vm.skip(true, string.concat("ForkStack: ", ForkNetworks.scriptName(path), " records no deployment"));
        }
        protocol = network.core.getOrDeploy();
        books = network.books.getOrDeploy(protocol);
        bundler = network.bundler.getOrDeploy(protocol);
        deployment = script.getOrDeploy(protocol);
        parameters = script.getDeployConfig();
        parameters.market.oracle = deployment.params.oracle;
        parameters.market.guardianSignals = deployment.guardianSignals;
        console2.log(
            string.concat(
                "[fork] core ",
                _contractsOrigin(address(network.core)),
                ", exit books ",
                _contractsOrigin(address(network.books)),
                ", bundler ",
                _contractsOrigin(address(network.bundler))
            )
        );
        if (ILidoLend(protocol.core).market(deployment.id).lastUpdate != 0) {
            _logMarket(deployment, "existed at the block");
        } else if (createIfMissing) {
            _createMarket(deployment);
        } else {
            _logMarket(deployment, "not created");
        }
    }

    /// @notice Forks `networkName` (see {ForkNetworks.fork}).
    function _forkNetwork(string memory networkName) internal {
        network = ForkNetworks.fork(networkName);
        console2.log(string.concat("[fork] ", networkName, " at block ", vm.toString(block.number)));
    }

    /// @dev Where the contracts of the deploy script at `scriptContract` come from: its `getDeployment()`, or new ones
    ///      that it deployed, which raised its nonce above a new contract's 1.
    function _contractsOrigin(address scriptContract) private view returns (string memory) {
        return vm.getNonce(scriptContract) > 1 ? "deployed by the test" : "from getDeployment()";
    }

    /// @dev Logs a market of the target's script: its vault, where its contracts come from, and `state`.
    function _logMarket(MarketDeploymentResult memory d, string memory state) private view {
        console2.log(
            string.concat(
                "[fork] ",
                ForkNetworks.scriptName(deployScript),
                " market (vault ",
                vm.toString(d.vault),
                d.deployedBlock != 0 ? ") from getDeployment(); " : ") deployed by the test; ",
                state
            )
        );
    }

    /// @notice Creates the market `d` and allows it on the exit books as their allow-list manager, the executor. Where
    ///         Easy Track registers the network's recorded activation factory, the motion of the script's
    ///         `activationParams` is enacted: the one in flight, else a new one from the factory's trusted caller; its
    ///         preseed seeds the market. Elsewhere Easy Track is impersonated to send the script's `activationScript`
    ///         to the EVMScriptExecutor, and a test account seeds the market.
    function _createMarket(MarketDeploymentResult memory d) internal {
        IEVMScriptExecutor executor = IEVMScriptExecutor(protocol.executor);
        IEasyTrack easyTrack = IEasyTrack(executor.easyTrack());
        IEVMScriptFactory factory = IEVMScriptFactory(RecordedProtocol.activateMarketFactory());
        if (address(factory) != address(0) && easyTrack.isEVMScriptFactory(address(factory))) {
            bytes memory motionCalldata = abi.encode(script.activationParams(d));
            IEasyTrack.Motion[] memory motions = easyTrack.getMotions();
            uint256 motionId;
            for (uint256 i; i < motions.length && motionId == 0; ++i) {
                if (
                    motions[i].evmScriptFactory == address(factory)
                        && keccak256(factory.createEVMScript(motions[i].creator, motionCalldata))
                            == motions[i].evmScriptHash
                ) motionId = motions[i].id;
            }
            if (motionId == 0) {
                vm.prank(factory.trustedCaller());
                motionId = easyTrack.createMotion(address(factory), motionCalldata);
            }
            IEasyTrack.Motion memory motion = easyTrack.getMotion(motionId);
            if (block.timestamp <= motion.startDate + motion.duration) vm.warp(motion.startDate + motion.duration + 1);
            easyTrack.enactMotion(motionId, motionCalldata);
            _logMarket(d, string.concat("created by the test through Easy Track motion ", vm.toString(motionId)));
        } else {
            bytes memory activationScript = script.activationScript(protocol, d);
            vm.prank(address(easyTrack));
            executor.executeEVMScript(activationScript);
            // The motion's preseed, from a test account: at least `MIN_SEED_SHARES` in the core and the vault.
            ILidoLendERC4626 vault = ILidoLendERC4626(d.vault);
            uint256 vaultAssets = vault.previewMint(MIN_SEED_SHARES);
            if (vaultAssets < MIN_SEED_ASSETS) vaultAssets = MIN_SEED_ASSETS;
            address seeder = makeAddr("fork.seeder");
            deal(d.params.loanToken, seeder, CORE_SEED_ASSETS + vaultAssets);
            Approvals.approve(d.params.loanToken, seeder, protocol.core, CORE_SEED_ASSETS);
            Approvals.approve(d.params.loanToken, seeder, d.vault, vaultAssets);
            vm.startPrank(seeder);
            ILidoLend(protocol.core).supply(d.params, CORE_SEED_ASSETS, 0, SEED_RECIPIENT, "");
            vault.deposit(vaultAssets, SEED_RECIPIENT);
            vm.stopPrank();
            _logMarket(d, "created by the test as the executor: Easy Track has no registered activation factory");
        }
        assertTrue(ILidoLend(protocol.core).market(d.id).lastUpdate != 0, "ForkStack: market not created");
        vm.startPrank(protocol.executor);
        if (books.morpho != address(0)) IMorphoExitBook(books.morpho).setMarketAllowed(d.params, true);
        if (books.erc4626 != address(0)) IErc4626ExitBook(books.erc4626).setVaultAllowed(IERC4626(d.vault), true);
        vm.stopPrank();
    }

    /// @notice The issuer of `m`'s collateral: the first whose constructor finds its price source behind the oracle.
    function _collateralIssuerOf(Market storage m) private returns (ForkCollateralIssuer) {
        address oracle = address(m.oracle);
        address collateral = address(m.collateralToken);
        try new ForkCollateralIssuerLido(oracle, collateral) returns (ForkCollateralIssuerLido issuer) {
            return issuer;
        } catch {}
        try new ForkCollateralIssuerOndo(oracle, collateral) returns (ForkCollateralIssuerOndo issuer) {
            return issuer;
        } catch {}
        try new ForkCollateralIssuerCentrifuge(oracle, collateral) returns (ForkCollateralIssuerCentrifuge issuer) {
            return issuer;
        } catch {}
        revert("ForkStack: no known issuer publishes the price source the market's oracle reads");
    }

    /// @notice The collateral's issuer publishes the source value that makes the market's oracle return about
    ///         `price`; returns the price it now returns. A trailing anchor oracle stops past its bounds until its
    ///         price acceptor, the Agent, accepts the move.
    function _setOraclePrice(uint256 price) internal returns (uint256) {
        uint256 value = collateralIssuer.setOraclePrice(price);
        (bool priced,) = address(market.oracle).staticcall(abi.encodeCall(IOracle.price, ()));
        if (!priced) {
            // Only a trailing anchor oracle has a price acceptor; another oracle's revert surfaces below as it is.
            TrailingAnchorOracleBase anchor = TrailingAnchorOracleBase(address(market.oracle));
            try anchor.PRICE_ACCEPTOR_ROLE() returns (bytes32 role) {
                vm.prank(anchor.getRoleMember(role, 0));
                anchor.acceptPrice(value, value);
            } catch {}
        }
        return market.oracle.price();
    }

    /// @notice Moves the market's price so `borrower` lands at `targetLtv` (WAD) and asserts it did; returns the new
    ///         price. The price that does it is `debt * WAD * SCALE / (collateral * target)` off the accrued position.
    function _setPriceForLtv(address borrower, uint256 targetLtv) internal returns (uint256 price) {
        market.core.accrueInterest(market.params);
        Position memory p = market.core.position(market.id, borrower);
        require(p.borrowShares != 0 && p.collateral != 0, "ForkStack: borrower has no position to price");
        MarketState memory mkt = market.core.market(market.id);
        uint256 debt = uint256(p.borrowShares).toAssetsUp(mkt.totalBorrowAssets, mkt.totalBorrowShares);
        price = _setOraclePrice(Math.mulDiv(debt * WAD, ORACLE_PRICE_SCALE, uint256(p.collateral) * targetLtv));
        uint256 collateralValue = Math.mulDiv(p.collateral, price, ORACLE_PRICE_SCALE);
        assertApproxEqRel(Math.mulDiv(debt, WAD, collateralValue), targetLtv, 1e15, "ForkStack: realized LTV");
    }

    /// @notice The handle of the market `d` on the set-up core.
    function _marketHandle(MarketDeploymentResult memory d) internal view returns (Market memory m) {
        m.core = ILidoLend(protocol.core);
        m.params = d.params;
        m.id = d.id;
        m.controller = ILidoLendMarketController(d.controller);
        m.vault = ILidoLendERC4626(d.vault);
        m.oracle = IOracle(d.params.oracle);
        m.guardianSignals = IGuardianSignals(d.guardianSignals);
        m.loanToken = IERC20(d.params.loanToken);
        m.collateralToken = IERC20(d.params.collateralToken);
    }

    /// @notice The shared fixture: a lender funds the vault with twice the borrow plus a non-round tail, a borrower
    ///         posts `lot`, matures it and draws 61% of what it carries. Interest is accrued afterwards so the next
    ///         action's delta assertions are exact.
    function _seedLenderAndBorrower() internal {
        LENDER = _freshActor(market, "fixture.lender");
        BORROWER = _freshActor(market, "fixture.borrower");

        uint256 borrowAssets = _maxBorrow(market, lot, market.oracle.price()) * 61 / 100;
        uint256 deposit = 2 * borrowAssets + 4_321;
        _requireSupplyHeadroom(market, deposit);
        deal(address(market.loanToken), LENDER, deposit);
        lenderShares = market.vaultDeposit(LENDER, deposit);

        collateralIssuer.dealCollateral(BORROWER, lot);
        market.supplyCollateral(BORROWER, lot);
        market.activateCollateral();
        borrowShares = market.borrow(BORROWER, borrowAssets);
        _accrueInterest();
    }

    /// @notice The market's live collateral activation config.
    function _activationConfig(Market storage m) internal view returns (CollateralActivationConfig memory) {
        return m.controller.collateralActivationConfig();
    }

    // ---
    // PRIVILEGED ACTORS AND DEPLOYED SURFACES, AS THE RUN RECORDED THEM
    // ---

    /// @notice The protocol admin (Lido Agent).
    function _admin() internal view returns (address) {
        return protocol.agent;
    }

    /// @notice The EasyTrack EVMScriptExecutor, the owner facade's role holder.
    function _executor() internal view returns (address) {
        return protocol.executor;
    }

    /// @notice The reseal manager (Dual Governance): the controller's `PAUSER_ROLE` and sole `RESUMER_ROLE` holder.
    function _resealManager() internal view returns (address) {
        return protocol.resealManager;
    }

    /// @notice The owner facade (`LidoLendOwner`), the manager of every controller and the core's owner.
    function _facade() internal view returns (ILidoLendOwner) {
        return ILidoLendOwner(protocol.ownerFacade);
    }

    /// @notice The risk-steward dashboard, the controller's `FREEZER_ROLE` holder.
    function _dashboard() internal view returns (IRiskStewardDashboard) {
        return IRiskStewardDashboard(protocol.dashboard);
    }

    /// @notice OZ AccessControl's refusal for `account` lacking `role`, for `vm.expectRevert`.
    function _missingRoleError(address account, bytes32 role) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role);
    }

    // ---
    // GOVERNANCE, THROUGH THE DEPLOYED SURFACES
    // ---

    /// @notice Grant or revoke instant activation for `caller` as the executor through the facade.
    function _setInstantActivation(address caller, bool enabled) internal {
        vm.prank(_executor());
        _facade().setInstantActivation(market.id, caller, enabled);
        require(
            market.controller.hasInstantActivation(caller) == enabled,
            "ForkStack: facade did not change instant activation (does it hold MANAGER_ROLE?)"
        );
    }

    /// @notice Unfreeze the market as the executor through the facade, the only `UNFREEZER_ROLE` holder.
    function _unfreeze() internal {
        vm.prank(_executor());
        _facade().unfreezeMarket(market.id);
        require(!market.controller.isFrozen(), "ForkStack: facade did not unfreeze the market");
    }

    /// @notice Set the market's supply cap as the executor through the facade; 0 lifts the cap.
    function _setSupplyCap(uint256 cap) internal {
        vm.prank(_executor());
        _facade().setMarketSupplyCap(market.id, cap);
        require(
            LidoLendMarketController(address(market.controller)).supplyCap() == cap,
            "ForkStack: facade did not change the supply cap"
        );
    }

    /// @notice Appoint a fresh steward for the market as the executor through the dashboard.
    function _appointSteward(string memory label) internal returns (address steward) {
        steward = makeAddr(label);
        vm.prank(_executor());
        _dashboard().addMarketSteward(market.id, steward);
        require(_dashboard().isMarketSteward(market.id, steward), "ForkStack: dashboard did not appoint the steward");
    }

    /// @notice Freeze the market as `steward` through the dashboard.
    function _freezeViaSteward(address steward) internal {
        vm.prank(steward);
        _dashboard().freezeMarket(market.id);
        require(market.controller.isFrozen(), "ForkStack: dashboard did not freeze the market");
    }

    /// @notice Pause the controller for `duration` as the reseal manager.
    function _pauseViaResealManager(uint256 duration) internal {
        vm.prank(_resealManager());
        market.controller.pauseFor(duration);
        require(IPausableUntil(address(market.controller)).isPaused(), "ForkStack: reseal manager did not pause");
    }

    /// @notice The first `quorum` guardians of the market's live committee: enough distinct flags to latch a ban.
    function _quorumGuardians() internal view returns (address[] memory quorum) {
        (address[] memory guardians,) = market.guardianSignals.getGuardians();
        uint256 n = market.guardianSignals.getQuorum();
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
    function _accrueInterest() internal {
        market.core.accrueInterest(market.params);
    }

    /// @notice Repays the debt of each borrower already in the market's settlement queue on its behalf, so the queue
    ///         holds only the test's borrowers and a price fall leaves no other position underwater.
    function _repayExistingBorrowers() internal {
        (address[] memory borrowers,) =
            market.controller.settlementBorrowers(0, market.controller.settlementBorrowersCount());
        address repayer = makeAddr("fork.repayer");
        for (uint256 i; i < borrowers.length; ++i) {
            uint256 shares = market.core.position(market.id, borrowers[i]).borrowShares;
            if (shares == 0) continue;
            uint256 assets = market.repayAssets(shares);
            deal(address(market.loanToken), repayer, assets);
            _approve(address(market.loanToken), repayer, address(market.core), assets);
            vm.prank(repayer);
            market.core.repay(market.params, 0, shares, borrowers[i], "");
        }
    }

    /// @notice Warp one second past the market's maximum activation delay, so a fresh collateral lot matures. A
    ///         market that also gates on the guardian quorum gets a quorum of heartbeats scanned at the warped time, so
    ///         the frontier covers the unlock the way a live committee would.
    function _warpPastActivation() internal {
        CollateralActivationConfig memory activation = _activationConfig(market);
        vm.warp(block.timestamp + uint256(activation.maxActivationDelay) + 1);
        if (activation.maxGuardiansQuorumDelay == 0) return;
        vm.roll(block.number + 1);
        uint40 pastBlock = uint40(block.number - 1);
        BlockInfoWithHash memory scanned =
            BlockInfoWithHash({hash: blockhash(pastBlock), number: pastBlock, timestamp: uint40(block.timestamp)});
        address[] memory quorum = _quorumGuardians();
        for (uint256 i; i < quorum.length; ++i) {
            vm.prank(quorum[i]);
            market.guardianSignals.heartbeat(quorum[i], scanned, "");
        }
    }

    /// @notice The market's unborrowed liquidity at the last-accrued totals: `totalSupplyAssets - totalBorrowAssets`.
    function _freeLiquidity() internal view returns (uint256) {
        MarketState memory mkt = market.core.market(market.id);
        return uint256(mkt.totalSupplyAssets) - uint256(mkt.totalBorrowAssets);
    }

    /// @notice Assert the controller's supply headroom (what the supply hook enforces) covers `assets`.
    function _requireSupplyHeadroom(Market storage m, uint256 assets) internal view {
        uint256 headroom = m.controller.maxDeposit();
        require(
            headroom >= assets,
            string.concat("ForkStack: supply ", vm.toString(assets), " exceeds market headroom ", vm.toString(headroom))
        );
    }

    /// @notice Borrows the market's free liquidity down to exactly `target` into a fresh, instant-activated,
    ///         over-collateralized borrower.
    function _setFreeLiquidity(uint256 target) internal {
        _accrueInterest(); // same-block borrow moves totals by exactly the borrowed amount

        uint256 free = _freeLiquidity();
        require(
            free >= target,
            string.concat("ForkStack: free liquidity ", vm.toString(free), " below pin target ", vm.toString(target))
        );
        uint256 excess = free - target;
        if (excess == 0) return;

        // Twice the value the borrow needs at the LLTV, and at least twice the dust floor, so the pin stays healthy.
        address pinBorrower = makeAddr("forkstack.pinBorrower");
        uint256 collateral =
            2 * Math.mulDiv(Math.mulDiv(excess, WAD, market.params.lltv), ORACLE_PRICE_SCALE, market.oracle.price());
        if (collateral < lot) collateral = lot;
        _setInstantActivation(pinBorrower, true); // manager-gated, so through the facade as the executor

        collateralIssuer.dealCollateral(pinBorrower, collateral);
        _approve(address(market.collateralToken), pinBorrower, address(market.core), collateral);
        vm.startPrank(pinBorrower);
        market.core.supplyCollateral(market.params, collateral, pinBorrower, "");
        market.core.borrow(market.params, excess, 0, pinBorrower, pinBorrower);
        vm.stopPrank();

        uint256 freeAfter = _freeLiquidity();
        require(
            freeAfter == target,
            string.concat(
                "ForkStack: pin left free liquidity ", vm.toString(freeAfter), " != target ", vm.toString(target)
            )
        );
    }

    // ---
    // LIVE SIZING
    // ---

    /// @notice One whole loan token (`10 ** decimals`).
    function _oneLoanToken() internal view returns (uint256) {
        return 10 ** IERC20Metadata(address(market.loanToken)).decimals();
    }

    /// @notice Largest debt `collateral` carries at `price` and the live LLTV, floored twice like the controller.
    function _maxBorrow(Market storage m, uint256 collateral, uint256 price) internal view returns (uint256) {
        return Math.mulDiv(Math.mulDiv(collateral, price, ORACLE_PRICE_SCALE), m.params.lltv, WAD);
    }

    // ---
    // FUNDING AND ACTORS
    // ---

    /// @notice `owner` approves `spender` for `amount` of `token`, tolerating USDT's no-return, zero-first `approve`.
    function _approve(address token, address owner, address spender, uint256 amount) internal {
        Approvals.approve(token, owner, spender, amount);
    }

    /// @notice A fresh labelled actor on the collateral's allowlist, asserted clean of any position, vault shares and
    ///         market tokens, so its post-action balances read as deltas.
    function _freshActor(Market storage m, string memory label) internal returns (address a) {
        a = makeAddr(label);
        collateralIssuer.addToAllowlist(a);
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
