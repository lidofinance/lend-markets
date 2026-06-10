// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {Id, MarketParams} from "@lido-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-blue/src/libraries/MarketParamsLib.sol";

import {ILidoBlue} from "@lido-blue/src/interfaces/ILidoBlue.sol";
import {AdaptiveCurveIrm} from "../../src/irm/AdaptiveCurveIrm.sol";

/// @title LidoBlueDeployer
/// @notice Shared deploy steps for a Lido Lending market: core, suspects registry, oracle, IRM,
///         controller (behind a proxy), the market, and the ERC-4626 vault.
/// @dev Inherited by `script/DeployMarket.s.sol` (broadcasts the deploys) and by scenario/integration
///      tests in `test/` (drive it inside `setUp`). Single-source so script and tests cannot drift.
abstract contract LidoBlueDeployer {
    using MarketParamsLib for MarketParams;

    /// @dev forge-std cheatcode singleton, inlined so this contract need not inherit `Test` / `Script`.
    Vm internal constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Mirror of `ActivationLib.Config` (same field order/types) so the controller initializer can
    ///      be abi-encoded without importing the 0.8.24 library into this solc-agnostic deployer.
    struct ActivationConfig {
        uint64 minActivationDelay;
        uint64 maxActivationDelay;
        uint64 maxSuspicionDelay;
        uint64 maxDecayDuration;
        uint128 maxDelayLoad;
        uint128 minActivationAmount;
        uint128 minDecayAmount;
    }

    struct Deployed {
        address core;
        address suspectsRegistry;
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
        bool deleverageEnabled;
        ActivationConfig activation;
        // Suspects registry bootstrap. The registry rejects `quorum` 0, so pass at least one guardian and
        // `1 <= quorum <= guardians.length`; swap in the real guardian set post-deploy.
        address[] guardians;
        uint256 quorum;
        string vaultName;
        string vaultSymbol;
    }

    /// @notice One-shot deploy of the whole market stack.
    function _deployForkStack(DeployConfig memory cfg) internal returns (Deployed memory d) {
        d.core = _deployCore(cfg.admin);
        d.suspectsRegistry = _deploySuspectsRegistry(cfg.admin, cfg.guardians, cfg.quorum);
        d.oracle = _deployOracle(cfg.oracleSource);
        d.irm = _deployIrm(d.core);

        d.params = MarketParams({
            loanToken: cfg.loanToken, collateralToken: cfg.collateralToken, oracle: d.oracle, irm: d.irm, lltv: cfg.lltv
        });
        d.marketId = d.params.id();

        (d.controllerProxy, d.controllerImpl) =
            _deployController(d.core, d.marketId, d.suspectsRegistry, cfg.admin, cfg.activation);

        ILidoBlue(d.core).enableIrm(d.irm);
        ILidoBlue(d.core).enableLltv(cfg.lltv);
        ILidoBlue(d.core).createMarket(d.params, d.controllerProxy, cfg.deleverageEnabled);

        d.vault = _deployVault(d.core, d.params, d.controllerProxy, cfg.admin, cfg.vaultName, cfg.vaultSymbol);
    }

    /// @dev Deploys impl + `OssifiableProxy`. Proxy admin is `admin`; init calls `initialize(admin)` so
    ///      `admin` becomes the core's owner.
    function _deployCore(address admin) internal virtual returns (address) {
        address impl = _deployArtifact("lib/lido-blue/src/LidoBlue.sol:LidoBlue", "");
        bytes memory initData = abi.encodeWithSignature("initialize(address)", admin);
        return _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData));
    }

    /// @dev Suspects registry behind a proxy. `initialize(admin, guardians, quorum)`.
    function _deploySuspectsRegistry(address admin, address[] memory guardians, uint256 quorum)
        internal
        virtual
        returns (address)
    {
        address impl = _deployArtifact("src/SuspectsRegistry.sol:SuspectsRegistry", "");
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address[],uint256)", admin, guardians, quorum);
        return _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData));
    }

    /// @dev Default oracle: `WstEthRateOracle(wstETH)`. Override for swap-in mock oracles.
    function _deployOracle(address oracleSource) internal virtual returns (address) {
        return _deployArtifact("src/oracle/WstEthRateOracle.sol:WstEthRateOracle", abi.encode(oracleSource));
    }

    /// @dev IRM impl + `OssifiableProxy`. Defaults match upstream `morpho-blue-irm` `ConstantsLib`;
    ///      override `_defaultIrmCurveParams` to pin a different curve per market.
    function _deployIrm(address core) internal virtual returns (address) {
        AdaptiveCurveIrm.CurveParams memory params = _defaultIrmCurveParams();
        address impl = _deployArtifact("src/irm/AdaptiveCurveIrm.sol:AdaptiveCurveIrm", abi.encode(core, params));
        return _deployArtifact("src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, core, ""));
    }

    /// @dev Curve defaults inherited from upstream `morpho-blue-irm` `ConstantsLib`. Override to
    ///      customise per-market.
    function _defaultIrmCurveParams() internal pure virtual returns (AdaptiveCurveIrm.CurveParams memory) {
        return AdaptiveCurveIrm.CurveParams({
            curveSteepness: 4 ether,
            adjustmentSpeed: 50 ether / int256(365 days),
            targetUtilization: 0.9 ether,
            initialRateAtTarget: 0.04 ether / int256(365 days),
            minRateAtTarget: 0.001 ether / int256(365 days),
            maxRateAtTarget: 2 ether / int256(365 days)
        });
    }

    /// @dev Controller behind a proxy. The impl bakes `(lidoBlue, marketId)` into immutables at deploy,
    ///      then `initialize(admin, suspects, activationConfig)` runs through the proxy.
    function _deployController(
        address core,
        Id marketId,
        address suspects,
        address admin,
        ActivationConfig memory activation
    ) internal virtual returns (address proxy, address impl) {
        impl = _deployArtifact(
            "src/controllers/WethWstEthController.sol:WethWstEthController", abi.encode(core, marketId)
        );
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,(uint64,uint64,uint64,uint64,uint128,uint128,uint128))",
            admin,
            suspects,
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
        address impl = _deployArtifact("src/LidoBlueERC4626.sol:LidoBlueERC4626", "");
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
        require(deployed != address(0) && deployed.code.length != 0, "LidoBlueDeployer: artifact deploy failed");
    }
}
