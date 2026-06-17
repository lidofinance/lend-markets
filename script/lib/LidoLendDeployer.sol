// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";

/// @dev Minimal configurator surface of the controller used to seed the deploy-time policy.
///      `LidoLendDeployer.SlicePolicyConfig` mirrors the controller's struct, so the call ABI matches.
interface IControllerConfigurator {
    function MANAGER_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function setSlicePolicy(LidoLendDeployer.SlicePolicyConfig calldata policy) external;
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

    /// @dev Mirror of `SettlementTypes.SlicePolicy` (same field order/types); see `ActivationConfig`
    ///      for why the deployer mirrors instead of importing.
    struct SlicePolicyConfig {
        uint16 sliceFloorBps;
        uint96 sliceFloorAssets;
        uint96 fallbackMinRequest;
        uint96 fullCutBelowCollateral;
    }

    /// @dev Mirror of `CollateralActivationLib.Config` (same field order/types) so the controller initializer can
    ///      be abi-encoded without coupling the deployer to the controller's libraries. Field order must
    ///      match the hardcoded tuple in `_deployController`'s `encodeWithSignature`.
    struct ActivationConfig {
        // delay ramp
        uint64 minActivationDelay;
        uint64 maxActivationDelay;
        uint128 maxDelayInflow;
        // strike surcharge
        uint64 delayPerStrike;
        // sybil hold on activating collateral
        uint128 activatingHold;
        // dust threshold (anti-griefing)
        uint128 minActivationAmount;
    }

    struct Deployed {
        address core;
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
        ActivationConfig activation;
        SlicePolicyConfig slicePolicy;
        // Guardian-signals registry bootstrap. The registry rejects `quorum` 0, so pass at least one guardian and
        // `1 <= quorum <= guardians.length`; swap in the real guardian set post-deploy.
        address[] guardians;
        uint256 quorum;
        string vaultName;
        string vaultSymbol;
    }

    /// @notice One-shot deploy of the whole market stack.
    function _deployForkStack(DeployConfig memory cfg) internal returns (Deployed memory d) {
        d.core = _deployCore(cfg.admin);
        d.guardianSignals = _deployGuardianSignals(cfg.admin, cfg.guardians, cfg.quorum);
        d.oracle = _deployOracle(cfg.oracleSource);
        d.irm = _deployIrm(d.core);

        d.params = MarketParams({
            loanToken: cfg.loanToken, collateralToken: cfg.collateralToken, oracle: d.oracle, irm: d.irm, lltv: cfg.lltv
        });
        d.marketId = d.params.id();

        (d.controllerProxy, d.controllerImpl) =
            _deployController(d.core, d.marketId, d.guardianSignals, cfg.admin, cfg.activation);

        // New core: createMarket is owner-gated and auto-enables the IRM and LLTV (standalone
        // enableIrm/enableLltv were removed). The bool gates whether settle is enabled for the market.
        ILidoLend(d.core).createMarket(d.params, d.controllerProxy, cfg.enableSettlement);

        d.vault = _deployVault(d.core, d.params, d.controllerProxy, cfg.admin, cfg.vaultName, cfg.vaultSymbol);

        // Seed the slice policy. `admin` holds DEFAULT_ADMIN_ROLE from the controller initializer;
        // grant it MANAGER_ROLE (a placeholder, rotated to the EasyTrack factory post-deploy)
        // so it can set the policy now and tune it later.
        IControllerConfigurator controller = IControllerConfigurator(d.controllerProxy);
        controller.grantRole(controller.MANAGER_ROLE(), cfg.admin);
        controller.setSlicePolicy(cfg.slicePolicy);
    }

    /// @dev Deploys impl + `OssifiableProxy`. Proxy admin is `admin`; init calls `initialize(admin)` so
    ///      `admin` becomes the core's owner.
    function _deployCore(address admin) internal virtual returns (address) {
        address impl = _deployArtifact("lib/lido-lend/src/LidoLend.sol:LidoLend", "");
        bytes memory initData = abi.encodeWithSignature("initialize(address)", admin);
        return _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData));
    }

    /// @dev Guardian-signals registry behind a proxy. `initialize(admin, guardians, quorum)`.
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

    /// @dev Default oracle: `WstEthRateOracle(wstETH)`. Override for swap-in mock oracles.
    function _deployOracle(address oracleSource) internal virtual returns (address) {
        return _deployArtifact("src/oracle/WstEthRateOracle.sol:WstEthRateOracle", abi.encode(oracleSource));
    }

    function _deployIrm(address core) internal virtual returns (address) {
        return _deployArtifact(
            "lib/lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol:AdaptiveCurveIrm", abi.encode(core)
        );
    }

    /// @dev Controller behind a proxy. The impl bakes `(lidoLend, marketId)` into immutables at deploy,
    ///      then `initialize(admin, guardianSignals, activationConfig)` runs through the proxy.
    function _deployController(
        address core,
        Id marketId,
        address guardianSignals,
        address admin,
        ActivationConfig memory activation
    ) internal virtual returns (address proxy, address impl) {
        impl = _deployArtifact(
            "src/controllers/LidoLendMarketController.sol:LidoLendMarketController", abi.encode(core, marketId)
        );
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,(uint64,uint64,uint128,uint64,uint128,uint128))",
            admin,
            guardianSignals,
            activation
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
        address impl = _deployArtifact("src/LidoLendERC4626.sol:LidoLendERC4626", "");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,(address,address,address,address,uint256),address,string,string)",
            core,
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
