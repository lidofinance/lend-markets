// SPDX-License-Identifier: GPL-2.0-or-later
// Permissive pragma so deploy script (0.8.24), legacy fork tests (0.8.19) and vault-v2 tests
// (0.8.28) can all inherit. All deploys go through `vm.getCode` to stay Solc-agnostic.
pragma solidity >=0.8.19;

import {Vm} from "forge-std/Vm.sol";

import {Id, MarketParams} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue/src/libraries/MarketParamsLib.sol";

/// @dev Local interface for `MorphoBlueFork.createMarket(params, controller, fallbackEnabled)`.
///      The fork-added 3-arg overload isn't on upstream `IMorphoBase`.
interface IMorphoForkLike {
    function enableIrm(address irm) external;
    function enableLltv(uint256 lltv) external;
    function createMarket(MarketParams memory marketParams, address controller, bool fallbackEnabled) external;
}

/// @title MorphoForkDeployer
/// @notice Shared deploy steps for a Lido Lending fork market.
/// @dev Inherited by `script/DeployFork.s.sol` (broadcasts the deploys) and by scenario/integration
///      tests in `test/` (drives them inside `setUp`). Keeps the deploy logic single-source so
///      script and tests can't drift.
abstract contract MorphoForkDeployer {
    using MarketParamsLib for MarketParams;

    /// @dev Address of forge-std cheatcode singleton. Inlined so this contract doesn't have to
    ///      inherit from `Test` / `Script` directly — those base contracts can be added by the
    ///      consumer.
    Vm internal constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Deployed {
        address core;
        address accessRegistry;
        address oracle;
        address irm;
        address controllerProxy;
        address controllerImpl;
        MarketParams params;
        Id marketId;
    }

    struct DeployConfig {
        address admin;
        address loanToken;
        address collateralToken;
        // Underlying source for the default oracle (e.g. wstETH for `WstEthRateOracle`). Ignored if
        // a consumer overrides `_deployOracle`.
        address oracleSource;
        uint256 lltv;
        bool fallbackEnabled;
    }

    /// @notice One-shot deploy: core, access registry, oracle, IRM, controller (behind proxy),
    ///         and the market itself.
    function _deployForkStack(DeployConfig memory cfg) internal returns (Deployed memory d) {
        d.core = _deployCore(cfg.admin);
        d.accessRegistry = _deployAccessRegistry(cfg.admin);
        d.oracle = _deployOracle(cfg.oracleSource);
        d.irm = _deployIrm(d.core);

        d.params = MarketParams({
            loanToken: cfg.loanToken,
            collateralToken: cfg.collateralToken,
            oracle: d.oracle,
            irm: d.irm,
            lltv: cfg.lltv
        });
        d.marketId = d.params.id();

        (d.controllerProxy, d.controllerImpl) = _deployController(d.core, d.marketId, d.accessRegistry, cfg.admin);

        IMorphoForkLike(d.core).enableIrm(d.irm);
        IMorphoForkLike(d.core).enableLltv(cfg.lltv);
        IMorphoForkLike(d.core).createMarket(d.params, d.controllerProxy, cfg.fallbackEnabled);
    }

    /// @dev Deploys impl + `OssifiableProxy`. Proxy admin is `admin`; init calls `initialize(admin)`
    ///      so `admin` becomes the core's owner.
    function _deployCore(address admin) internal virtual returns (address) {
        address impl = _deployArtifact("src/MorphoBlueFork.sol:MorphoBlueFork", "");
        bytes memory initData = abi.encodeWithSignature("initialize(address)", admin);
        return _deployArtifact(
            "src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData)
        );
    }

    function _deployAccessRegistry(address admin) internal virtual returns (address) {
        return _deployArtifact("src/controllers/MarketAccessRegistry.sol:MarketAccessRegistry", abi.encode(admin));
    }

    /// @dev Default oracle: `WstEthRateOracle(wstETH)`. Override for swap-in mock oracles.
    function _deployOracle(address oracleSource) internal virtual returns (address) {
        return _deployArtifact("src/oracle/WstEthRateOracle.sol:WstEthRateOracle", abi.encode(oracleSource));
    }

    function _deployIrm(address core) internal virtual returns (address) {
        return _deployArtifact(
            "lib/morpho-blue-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol:AdaptiveCurveIrm", abi.encode(core)
        );
    }

    function _deployController(address core, Id marketId, address accessRegistry, address admin)
        internal
        virtual
        returns (address proxy, address impl)
    {
        impl = _deployArtifact("src/controllers/LidoMarketController.sol:LidoMarketController", "");
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,bytes32,address,address)", core, Id.unwrap(marketId), accessRegistry, admin
        );
        proxy = _deployArtifact(
            "src/proxy/OssifiableProxy.sol:OssifiableProxy", abi.encode(impl, admin, initData)
        );
    }

    /// @dev Deploys an artifact by full path so multi-version compilation (controller compiled
    ///      under both 0.8.24 and 0.8.28 in this repo) doesn't ambiguify the lookup.
    function _deployArtifact(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory bytecode = _vm.getCode(artifact);
        bytes memory creationCode = bytes.concat(bytecode, args);
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(deployed != address(0) && deployed.code.length != 0, "MorphoForkDeployer: artifact deploy failed");
    }
}
