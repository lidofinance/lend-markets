// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";

/// @dev Minimal configurator surface of the controller used to seed the deploy-time policy.
///      `LidoLendDeployer.SettlementConfigParams` mirrors the controller's struct, so the call ABI matches.
interface IControllerConfigurator {
    function MANAGER_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function setSettlementConfig(LidoLendDeployer.SettlementConfigParams calldata policy) external;
}

/// @dev Minimal surface of the owner facade used at deploy: create the market through it. Local interface
///      (no concrete import), mirroring `IControllerConfigurator`.
interface IOwnerFacade {
    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement) external;
}

/// @dev Minimal surface of the guardian registry used at deploy: grant the manager role and set the delay
///      parameters (the guardian set and quorum are seeded in `initialize`).
interface IGuardianRegistry {
    function GUARDIANS_MANAGER_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function setDelayParams(LidoLendDeployer.GuardianConfigParams calldata params) external;
}

/// @title LidoLendDeployer
/// @notice Shared deploy steps for a Lido Lending market: core, guardian-signals registry, oracle, IRM,
///         controller (behind a proxy), the market, and the ERC-4626 vault.
/// @dev Inherited by `script/DeployMarket.s.sol` (broadcasts the deploys) and by scenario/integration
///      tests in `test/` (drive it inside `setUp`). Single-source so script and tests cannot drift.
abstract contract LidoLendDeployer {
    using MarketParamsLib for MarketParams;

    /// @dev forge-std cheatcode singleton, inlined so this contract need not inherit `Test` / `Script`.
    Vm internal constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Mirror of `SettlementTypes.SettlementConfig` (same field order/types); see
    /// `CollateralActivationConfigParams` for why the deployer mirrors instead of importing.
    struct SettlementConfigParams {
        uint16 sliceFloorBps;
        uint96 sliceFloorAssets;
        uint96 fullCutBelowCollateral;
        uint16 ltvStepBps;
    }

    /// @dev Mirror of `CollateralActivationConfig` (`types/CollateralActivationTypes.sol`) so the controller
    /// initializer can be abi-encoded without coupling the deployer to the controller's libraries. Field order must
    ///      match the hardcoded tuple in `_deployController`'s `encodeWithSignature`.
    struct CollateralActivationConfigParams {
        // delay ramp
        uint64 minActivationDelay;
        uint64 maxActivationDelay;
        uint128 maxDelayInflow;
        // sybil lock on activating collateral
        uint128 activatingLockAmount;
        uint64 activatingLockDuration;
        // dust threshold (anti-griefing)
        uint128 minActivationAmount;
        // quorum-scan liveness fallback: mature past this from the lot's start even if the quorum stalls
        uint64 maxGuardiansQuorumDelay;
    }

    /// @dev Guardian-signals delay parameters seeded post-deploy via `setDelayParams`. `guardians`/`quorum` live
    ///      on `DeployConfig`; these are the activation-delay knobs owned by the registry.
    struct GuardianConfigParams {
        uint256 delayPerStrike;
        uint256 delayPerSuspect;
        uint256 maxDelay;
        uint256 suspectWindow;
    }

    struct Deployed {
        address core;
        address ownerFacade;
        address guardianSignals;
        address oracle;
        address irm;
        address controllerProxy;
        address controllerImpl;
        address vault;
        MarketParams params;
        Id marketId;
    }

    struct DeployConfig {
        address admin;
        address loanToken;
        address collateralToken;
        // Underlying source for the default oracle (e.g. wstETH for `WstEthRateOracle`). Ignored if a
        // consumer overrides `_deployOracle`.
        address oracleSource;
        uint256 lltv;
        bool enableSettlement;
        CollateralActivationConfigParams activation;
        SettlementConfigParams settlementConfig;
        // Guardian-signals registry bootstrap, seeded in `initialize`. The registry rejects `quorum` 0, so pass at
        // least one guardian and `1 <= quorum <= guardians.length`; rotate to the real set post-deploy via
        // `addGuardian` / `removeGuardian`.
        address[] guardians;
        uint256 quorum;
        GuardianConfigParams guardianConfig;
        string vaultName;
        string vaultSymbol;
    }

    /// @notice One-shot deploy of the whole market stack.
    function _deployForkStack(DeployConfig memory cfg) internal returns (Deployed memory d) {
        d.core = _deployCore(cfg.admin);

        // Hand the core's ownership to the role-gated facade: from here every owner-only call (market
        // creation, fees, ownership transfer) is gated behind a role on the facade rather than a single EOA.
        // The deploy needs to create the market, so `admin` gets MARKET_CREATOR_ROLE at construction (a
        // placeholder it keeps and can rotate post-deploy); FEE_MANAGER_ROLE is left for governance to grant.
        // `setOwner` runs in the deploy context, which is the current core owner (`admin`).
        d.ownerFacade = _deployOwnerFacade(d.core, cfg.admin, cfg.admin, address(0));
        ILidoLend(d.core).setOwner(d.ownerFacade);

        d.guardianSignals = _deployGuardianSignals(cfg.admin, cfg.guardians, cfg.quorum);
        d.oracle = _deployOracle(cfg.oracleSource, cfg.admin);
        d.irm = _deployIrm(d.core, cfg.admin);

        d.params = MarketParams({
            loanToken: cfg.loanToken, collateralToken: cfg.collateralToken, oracle: d.oracle, irm: d.irm, lltv: cfg.lltv
        });
        d.marketId = d.params.id();

        // The adaptive IRM reads per-market curve params from an immutable MarketConfig the owner points it at.
        _configureAdaptiveIrm(d.irm, d.marketId);

        (d.controllerProxy, d.controllerImpl) =
            _deployController(d.core, d.marketId, d.guardianSignals, cfg.admin, cfg.activation, cfg.settlementConfig);

        // Market creation is owner-gated on the core (it auto-enables the IRM and LLTV — standalone
        // enableIrm/enableLltv were removed) and the bool gates whether settle is enabled. The facade owns
        // the core now and `admin` (the deploy context) holds MARKET_CREATOR_ROLE, so create through it.
        IOwnerFacade(d.ownerFacade).createMarket(d.params, d.controllerProxy, cfg.enableSettlement);

        d.vault = _deployVault(d.core, d.params, d.controllerProxy, cfg.admin, cfg.vaultName, cfg.vaultSymbol);

        // The settlement config is set in `initialize`. Grant `admin` MANAGER_ROLE as a placeholder holder for
        // later policy changes; `admin` holds DEFAULT_ADMIN_ROLE (the MANAGER_ROLE admin), so it self-grants.
        IControllerConfigurator controller = IControllerConfigurator(d.controllerProxy);
        controller.grantRole(controller.MANAGER_ROLE(), cfg.admin);

        // The guardian set and quorum are seeded in `initialize`. Grant `admin` GUARDIANS_MANAGER_ROLE for later
        // roster/quorum changes (it holds DEFAULT_ADMIN_ROLE, so it self-grants), then set the delay parameters.
        IGuardianRegistry guardian = IGuardianRegistry(d.guardianSignals);
        guardian.grantRole(guardian.GUARDIANS_MANAGER_ROLE(), cfg.admin);
        guardian.setDelayParams(cfg.guardianConfig);
    }

    /// @dev Deploys impl + `OssifiableProxy`. Proxy admin is `admin`; init calls `initialize(admin)` so
    ///      `admin` becomes the core's owner.
    function _deployCore(address admin) internal virtual returns (address) {
        address impl = _deployArtifact("lib/lido-lend/src/LidoLend.sol:LidoLend", "");
        bytes memory initData = abi.encodeWithSignature("initialize(address)", admin);
        return _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData));
    }

    /// @dev Immutable role-gated owner facade for the core (no proxy). `admin` gets `DEFAULT_ADMIN_ROLE`;
    ///      `marketCreator`/`feeManager` get their capability roles (`address(0)` grants none).
    function _deployOwnerFacade(address core, address admin, address marketCreator, address feeManager)
        internal
        virtual
        returns (address)
    {
        return _deployArtifact(
            "src/periphery/LidoLendOwner.sol:LidoLendOwner", abi.encode(core, admin, marketCreator, feeManager)
        );
    }

    /// @dev Guardian-signals registry behind a proxy. `initialize` seeds the admin, guardian set, and quorum; the
    ///      delay parameters are set via `setDelayParams` after deploy.
    function _deployGuardianSignals(address admin, address[] memory guardians, uint256 quorum)
        internal
        virtual
        returns (address)
    {
        address impl = _deployArtifact("src/GuardianSignals.sol:GuardianSignals", "");
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address[],uint256)", admin, guardians, quorum);
        return _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData));
    }

    /// @dev Default oracle: `WstEthRateOracle(wstETH)` behind an `OssifiableProxy` for a stable, upgradeable
    ///      address. The feed config is immutable in the impl, so the proxy is deployed with no init call.
    ///      Override for swap-in mock oracles.
    function _deployOracle(address oracleSource, address admin) internal virtual returns (address) {
        address impl = _deployArtifact("src/oracle/WstEthRateOracle.sol:WstEthRateOracle", abi.encode(oracleSource));
        return _behindProxy(impl, admin, "");
    }

    /// @dev Wraps an already-deployed implementation in an `OssifiableProxy`, optionally running `initData`.
    ///      The oracles carry their config in immutables, so they pass empty init data. Proxy admin is `admin`.
    function _behindProxy(address impl, address admin, bytes memory initData) internal returns (address) {
        return _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData));
    }

    function _deployIrm(address core, address owner) internal virtual returns (address) {
        return _deployArtifact(
            "lib/lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol:AdaptiveCurveIrm", abi.encode(core, owner)
        );
    }

    /// @dev Morpho mainnet-like adaptive curve params, ABI-encoded as the `IMarketConfig.Config` tuple. The IRM
    ///      and its config are pinned to an older solc, so they are reached through artifacts and a low-level
    ///      call rather than a typed import.
    function _encodedCurveConfig() internal pure virtual returns (bytes memory) {
        return abi.encode(
            int256(4e18), // curveSteepness
            int256(50e18) / int256(365 days), // adjustmentSpeed
            int256(9e17), // targetUtilization
            int256(4e16) / int256(365 days), // initialRateAtTarget
            int256(1e15) / int256(365 days), // minRateAtTarget
            int256(2e18) / int256(365 days), // maxRateAtTarget
            uint256(0) // maxBorrowRate (0 disables the ceiling)
        );
    }

    /// @dev Deploy an immutable per-market `MarketConfig` and point the adaptive IRM at it (owner-only, run in
    ///      the deploy context which owns the IRM).
    function _configureAdaptiveIrm(address irm, Id marketId) internal virtual {
        address marketConfig = _deployArtifact(
            "lib/lido-lend-irm/src/adaptive-curve-irm/MarketConfig.sol:MarketConfig", _encodedCurveConfig()
        );
        (bool ok,) = irm.call(abi.encodeWithSignature("setConfig(bytes32,address)", Id.unwrap(marketId), marketConfig));
        require(ok, "LidoLendDeployer: irm setConfig failed");
    }

    /// @dev Controller behind a proxy. The impl bakes `lidoLend` into an immutable; `initialize(marketId,
    ///      admin, guardianSignals, activationConfig, settlementConfig)` runs through the proxy.
    function _deployController(
        address core,
        Id marketId,
        address guardianSignals,
        address admin,
        CollateralActivationConfigParams memory activation,
        SettlementConfigParams memory settlement
    ) internal virtual returns (address proxy, address impl) {
        impl = _deployArtifact(
            "src/controllers/LidoLendMarketController.sol:LidoLendMarketController", abi.encode(core)
        );
        bytes memory initData = abi.encodeWithSignature(
            "initialize(bytes32,address,address,(uint40,uint40,uint128,uint128,uint40,uint128,uint40),(uint16,uint96,uint96,uint16))",
            Id.unwrap(marketId),
            admin,
            guardianSignals,
            activation,
            settlement
        );
        proxy = _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData));
    }

    /// @dev Single-market ERC-4626 wrapper behind `OssifiableProxy`. Impl is empty-constructor;
    ///      `initialize` runs through the proxy. The proxy admin is the controller's admin (`admin`).
    function _deployVault(
        address core,
        MarketParams memory params,
        address controller,
        address admin,
        string memory name_,
        string memory symbol_
    ) internal virtual returns (address) {
        address impl = _deployArtifact("src/LidoLendERC4626.sol:LidoLendERC4626", abi.encode(core));
        bytes memory initData = abi.encodeWithSignature(
            "initialize((address,address,address,address,uint256),address,string,string)",
            params,
            controller,
            name_,
            symbol_
        );
        return _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData));
    }

    /// @dev Deploys an artifact by full path so multi-version compilation in this repo doesn't ambiguify
    ///      the lookup.
    function _deployArtifact(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory bytecode = _vm.getCode(artifact);
        bytes memory creationCode = bytes.concat(bytecode, args);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "LidoLendDeployer: artifact deploy failed");
    }
}
