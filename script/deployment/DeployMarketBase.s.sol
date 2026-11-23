// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {IIrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/interfaces/IIrmConfigFactory.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {ProtocolAddresses} from "../lib/ProtocolDeployer.sol";
import {RecordedProtocol} from "../lib/RecordedProtocol.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

/// @dev A market's deploy config.
struct MarketDeployConfig {
    bytes32 guardianGroup;
    LidoLendMarketFactory.MarketSpec market;
    LidoLendMarketFactory.ERC4626WrapperSpec wrapper;
    LidoLendMarketFactory.GuardianSpec committee;
    AdaptiveCurveParams curve;
}

/// @dev A market's contracts and the block of their deployment, zero for a market deployed in this run.
struct MarketDeploymentResult {
    uint256 deployedBlock;
    Id id;
    MarketParams params;
    address controller;
    address vault;
    address guardianSignals;
    address irmConfig;
}

/// @dev The choices of the Easy Track motion that activates the market: the CircuitBreaker pauser committee, the market
///      steward, settlement and the fee.
struct ActivationMotionConfig {
    address pauser;
    address steward;
    bool enableSettlement;
    uint256 fee;
}

/// @dev The calldata of the Easy Track activation motion is `abi.encode` of this struct. `preseedVault` is the market's
///      vault.
struct ActivationParams {
    MarketParams marketParams;
    address irmConfig;
    address controller;
    bool enableSettlement;
    address steward;
    address pauserCommittee;
    address preseedVault;
    uint256 fee;
}

/// @dev A deployed market's addresses and `deployedBlock`, the block of its first deployment transaction, from which
///      the controller's logs are complete; zero until the market is deployed.
struct MarketDeploymentRecord {
    uint256 deployedBlock;
    address oracle;
    address guardianSignals;
    address controller;
    address vault;
    address irmConfig;
}

/// @dev What the Safe transaction of an activation motion reads on chain: the executor's Easy Track and whether it
///      registers the factory, the factory's trusted caller, and that Safe's nonce and transaction hash.
interface IActivationMotionChain {
    function easyTrack() external view returns (address);
    function isEVMScriptFactory(address factory) external view returns (bool);
    function trustedCaller() external view returns (address);
    function createMotion(address factory, bytes calldata motionData) external returns (uint256);
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
}

/// @dev The calls of a market's activation motion, each on its own contract: the adaptive curve IRM, the IRM router,
///      the owner facade, the risk-steward dashboard and the CircuitBreaker.
interface IMarketActivation {
    function applyIrmConfig(MarketParams calldata params, address config) external;
    function setMarketIrm(MarketParams calldata params, address irm) external;
    function createMarket(MarketParams calldata params, address controller, bool enableSettlement) external;
    function setFee(MarketParams calldata params, uint256 fee) external;
    function addMarketSteward(Id id, address steward) external;
    function registerPauser(address pausable, address pauser) external;
}

interface IDeploymentManager {
    function manager() external view returns (address);
}

interface IDeploymentCircuitBreaker {
    function ADMIN() external view returns (address);
}

interface IPriceFeedProxyView {
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
}

/// @notice Deploys one market. A market script gives `getDeployConfig()`, `getActivationMotionConfig()`, its price
///         oracle and, once the market is deployed, `getDeployment()` with its addresses; this contract does the
///         rest. `run()` deploys inside a broadcast; `getOrDeploy` is the market, and `deploy` deploys one for other
///         parameters without a broadcast. `activationParams` and `activationScript` are the calldata and the calls
///         of the motion that creates it.
abstract contract DeployMarketBase is Script {
    using MarketParamsLib for MarketParams;

    /// @notice `getDeployment()` gives a deployed market.
    error AlreadyDeployed();

    error MissingActivationActor();
    /// @notice The market has no deployment to activate.
    error NothingToActivate();
    /// @notice Easy Track does not register `factory` as an activation factory; zero where the network has none.
    error ActivationFactoryNotRegistered(address factory);
    error WrongChain(uint256 expected, uint256 actual);
    error MissingCode(address account);
    error IncompatibleDependency(bytes32 field, address expected, address actual);
    error MissingCommittee();
    error PriceFeedCodeMismatch(address component);

    /// @notice The protocol that the market is deployed to, for the hooks.
    ProtocolAddresses internal protocol;
    /// @notice The account that sends the calls, which an oracle may take as its first admin.
    address internal deployer;

    /// @notice Whether `getDeployment()` records the market.
    function isRecorded() external pure returns (bool) {
        return getDeployment().deployedBlock != 0;
    }

    /// @notice The market's deploy config. A zero `market.guardianSignals` deploys a new registry with
    ///         `guardianGroup` as the salt, and a zero `market.oracle` takes the oracle from `getOrDeployPriceOracle`;
    ///         an address reuses that contract after its checks.
    function getDeployConfig() public pure virtual returns (MarketDeployConfig memory);

    /// @notice The choices of the Easy Track motion that activates the market.
    function getActivationMotionConfig() public pure virtual returns (ActivationMotionConfig memory);

    /// @notice The market's price oracle: an existing one, or a new one from `_deployProxy`.
    function getOrDeployPriceOracle() internal virtual returns (address);

    /// @notice The deployed market, written by hand; empty until it is deployed.
    function getDeployment() internal pure virtual returns (MarketDeploymentRecord memory) {}

    function run() external returns (MarketDeploymentResult memory deployed) {
        if (getDeployment().deployedBlock != 0) revert AlreadyDeployed();
        ProtocolAddresses memory p = RecordedProtocol.current();
        MarketDeployConfig memory parameters = getDeployConfig();
        if (parameters.market.oracle != address(0)) _checkReusedOracle(p, parameters);
        vm.startBroadcast();
        deployed = _deploy(p, parameters, msg.sender);
        vm.stopBroadcast();
    }

    /// @notice The market over `p`: the one that `getDeployment()` gives, whose vault must have code, with its params
    ///         from the deploy config, else a new one from the deploy config as `run()` deploys it, without the
    ///         broadcast.
    function getOrDeploy(ProtocolAddresses memory p) external returns (MarketDeploymentResult memory d) {
        if (getDeployment().deployedBlock == 0) return _deploy(p, getDeployConfig(), address(this));
        d = _recorded(p);
        if (d.vault.code.length == 0) revert MissingCode(d.vault);
    }

    /// @dev The market that `getDeployment()` records over `p`, with its params from the deploy config.
    function _recorded(ProtocolAddresses memory p) private pure returns (MarketDeploymentResult memory d) {
        MarketDeploymentRecord memory r = getDeployment();
        MarketDeployConfig memory parameters = getDeployConfig();
        d.deployedBlock = r.deployedBlock;
        d.params = MarketParams({
            loanToken: parameters.market.loanToken,
            collateralToken: parameters.market.collateralToken,
            oracle: r.oracle,
            irm: p.irmRouter,
            lltv: parameters.market.lltv
        });
        d.id = d.params.id();
        d.controller = r.controller;
        d.vault = r.vault;
        d.guardianSignals = r.guardianSignals;
        d.irmConfig = r.irmConfig;
    }

    /// @notice `run()` without the broadcast, for `parameters` derived from the config. A reused oracle is checked
    ///         first against a new build from `getOrDeployPriceOracle`, and the tokens against the config's.
    function deploy(ProtocolAddresses memory p, MarketDeployConfig memory parameters)
        external
        returns (MarketDeploymentResult memory)
    {
        if (parameters.market.oracle != address(0)) _checkReusedOracle(p, parameters);
        return _deploy(p, parameters, address(this));
    }

    /// @dev Checks the reused `parameters.market.oracle` against a new build from `getOrDeployPriceOracle`, made by
    ///      this contract outside any broadcast, and the tokens of `parameters` against the config's.
    function _checkReusedOracle(ProtocolAddresses memory p, MarketDeployConfig memory parameters) private {
        _checkTokens(parameters);
        protocol = p;
        deployer = address(this);
        address built = getOrDeployPriceOracle();
        bytes32 codehash = IPriceFeedProxyView(built).proxy__getImplementation().codehash;
        _checkPriceFeedProxy(parameters.market.oracle, p.agent, codehash);
    }

    /// @notice The activation motion's calldata for the market `d`, with the config's activation choices.
    function activationParams(MarketDeploymentResult memory d) external pure returns (ActivationParams memory) {
        return _activationParams(d);
    }

    /// @notice The EVMScript of the activation motion's calls for the market `d` over `p`, without the preseed: the IRM
    ///         config and route, the creation, a non-zero fee, the steward and the pauser. An EVMScript is its spec id,
    ///         then each call as its target, its calldata length and its calldata.
    function activationScript(ProtocolAddresses memory p, MarketDeploymentResult memory d)
        external
        pure
        returns (bytes memory script)
    {
        ActivationParams memory a = _activationParams(d);
        script = bytes.concat(
            bytes4(0x00000001),
            _call(p.adaptiveCurveIrm, abi.encodeCall(IMarketActivation.applyIrmConfig, (d.params, d.irmConfig))),
            _call(p.irmRouter, abi.encodeCall(IMarketActivation.setMarketIrm, (d.params, p.adaptiveCurveIrm))),
            _call(
                p.ownerFacade,
                abi.encodeCall(IMarketActivation.createMarket, (d.params, d.controller, a.enableSettlement))
            )
        );
        if (a.fee != 0) {
            script =
                bytes.concat(script, _call(p.ownerFacade, abi.encodeCall(IMarketActivation.setFee, (d.params, a.fee))));
        }
        script = bytes.concat(
            script,
            _call(p.dashboard, abi.encodeCall(IMarketActivation.addMarketSteward, (d.id, a.steward))),
            _call(p.circuitBreaker, abi.encodeCall(IMarketActivation.registerPauser, (d.controller, a.pauserCommittee)))
        );
    }

    /// @notice Prints the Safe transaction of the factory's trusted caller that creates the recorded market's
    ///         activation motion: a Safe Transaction Builder batch to import, and the transaction's safeTxHash at the
    ///         Safe's current nonce, for the signer to match on the hardware wallet. Run it with `--sig` against the
    ///         network's RPC; it sends nothing.
    function printActivationSafeTransaction() external {
        if (getDeployment().deployedBlock == 0) revert NothingToActivate();
        ProtocolAddresses memory p = RecordedProtocol.current();
        address factory = RecordedProtocol.activateMarketFactory();
        address easyTrack = IActivationMotionChain(p.executor).easyTrack();
        if (factory == address(0) || !IActivationMotionChain(easyTrack).isEVMScriptFactory(factory)) {
            revert ActivationFactoryNotRegistered(factory);
        }
        MarketDeploymentResult memory d = _recorded(p);
        address safe = IActivationMotionChain(factory).trustedCaller();
        bytes memory data =
            abi.encodeCall(IActivationMotionChain.createMotion, (factory, abi.encode(_activationParams(d))));
        uint256 nonce = IActivationMotionChain(safe).nonce();
        bytes32 safeTxHash = IActivationMotionChain(safe)
            .getTransactionHash(easyTrack, 0, data, 0, 0, 0, 0, address(0), address(0), nonce);
        console2.log(
            string.concat(
                '{"version":"1.0","chainId":"',
                vm.toString(block.chainid),
                '","meta":{"name":"Lido Lend market activation motion","createdFromSafeAddress":"',
                vm.toString(safe),
                '"},"transactions":[{"to":"',
                vm.toString(easyTrack),
                '","value":"0","data":"',
                vm.toString(data),
                '","contractMethod":null,"contractInputsValues":null}]}'
            )
        );
        console2.log("Safe:", safe);
        console2.log("Safe nonce:", nonce);
        console2.log("safeTxHash:", vm.toString(safeTxHash));
    }

    /// @notice A new proxy over `implementation` that the Agent administers, initialized in its constructor.
    function _deployProxy(address implementation, bytes memory initialize) internal returns (address) {
        return address(new OssifiableProxy(implementation, protocol.agent, initialize));
    }

    function _deploy(ProtocolAddresses memory p, MarketDeployConfig memory parameters, address sender)
        private
        returns (MarketDeploymentResult memory d)
    {
        _checkProtocol(p);
        _checkTokens(parameters);
        protocol = p;
        deployer = sender;
        _requireCode(parameters.market.loanToken);
        _requireCode(parameters.market.collateralToken);
        if (parameters.committee.guardians.length == 0 || parameters.committee.quorum == 0) revert MissingCommittee();

        if (parameters.market.oracle == address(0)) parameters.market.oracle = getOrDeployPriceOracle();
        address implementation = IPriceFeedProxyView(parameters.market.oracle).proxy__getImplementation();
        _checkPriceFeedProxy(parameters.market.oracle, p.agent, implementation.codehash);

        LidoLendMarketFactory f = LidoLendMarketFactory(p.factory);
        if (parameters.market.guardianSignals == address(0)) {
            parameters.market.guardianSignals = f.deployGuardianSignals(parameters.committee, parameters.guardianGroup);
        } else {
            f.validateGuardianSignals(parameters.market.guardianSignals, parameters.committee);
        }

        d.guardianSignals = parameters.market.guardianSignals;
        d.irmConfig = IIrmConfigFactory(p.irmConfigFactory).getOrDeployAdaptiveCurveConfig(parameters.curve);
        d.params = MarketParams({
            loanToken: parameters.market.loanToken,
            collateralToken: parameters.market.collateralToken,
            oracle: parameters.market.oracle,
            irm: p.irmRouter,
            lltv: parameters.market.lltv
        });
        (d.id, d.controller, d.vault) = f.deployMarketComponents(parameters.market, parameters.wrapper);
    }

    function _activationParams(MarketDeploymentResult memory d) private pure returns (ActivationParams memory) {
        ActivationMotionConfig memory a = getActivationMotionConfig();
        if (a.pauser == address(0) || a.steward == address(0)) revert MissingActivationActor();
        return ActivationParams({
            marketParams: d.params,
            irmConfig: d.irmConfig,
            controller: d.controller,
            enableSettlement: a.enableSettlement,
            steward: a.steward,
            pauserCommittee: a.pauser,
            preseedVault: d.vault,
            fee: a.fee
        });
    }

    function _call(address target, bytes memory data) private pure returns (bytes memory) {
        return abi.encodePacked(target, uint32(data.length), data);
    }

    /// @dev The oracle prices the config's tokens, so the market must have them.
    function _checkTokens(MarketDeployConfig memory parameters) private pure {
        MarketDeployConfig memory expected = getDeployConfig();
        _same("loanToken", expected.market.loanToken, parameters.market.loanToken);
        _same("collateralToken", expected.market.collateralToken, parameters.market.collateralToken);
    }

    function _checkProtocol(ProtocolAddresses memory p) internal view {
        if (block.chainid != p.chainId) revert WrongChain(p.chainId, block.chainid);
        _requireCode(p.core);
        _requireCode(p.factory);
        _requireCode(p.ownerFacade);
        _requireCode(p.irmRouter);
        _requireCode(p.adaptiveCurveIrm);
        _requireCode(p.irmConfigFactory);
        _requireCode(p.dashboard);
        _requireCode(p.circuitBreaker);
        LidoLendMarketFactory f = LidoLendMarketFactory(p.factory);
        _same("core", p.core, f.LIDO_LEND());
        _same("facade", p.ownerFacade, address(f.LIDO_LEND_OWNER()));
        _same("router", p.irmRouter, address(f.IRM_ROUTER()));
        _same("dashboard", p.dashboard, f.RISK_STEWARD_DASHBOARD());
        _same("circuitBreaker", p.circuitBreaker, f.CIRCUIT_BREAKER());
        _same("resealManager", p.resealManager, f.RESEAL_MANAGER());
        _same("agent", p.agent, f.ADMIN());
        _same("core.owner", p.ownerFacade, ILidoLend(p.core).owner());
        _same("router.manager", p.executor, IDeploymentManager(p.irmRouter).manager());
        _same("circuitBreaker.admin", p.executor, IDeploymentCircuitBreaker(p.circuitBreaker).ADMIN());
    }

    function _checkPriceFeedProxy(address priceFeed, address admin, bytes32 implementationCodeHash) internal view {
        _requireCode(priceFeed);
        IPriceFeedProxyView proxy = IPriceFeedProxyView(priceFeed);
        _same("priceFeed.admin", admin, proxy.proxy__getAdmin());
        if (priceFeed.codehash != keccak256(type(OssifiableProxy).runtimeCode)) {
            revert PriceFeedCodeMismatch(priceFeed);
        }
        address implementation = proxy.proxy__getImplementation();
        if (implementation.codehash != implementationCodeHash) revert PriceFeedCodeMismatch(implementation);
        require(IOracle(priceFeed).price() != 0, "Price feed is zero");
    }

    function _requireCode(address account) internal view {
        if (account.code.length == 0) revert MissingCode(account);
    }

    function _same(bytes32 field, address expected, address actual) internal pure {
        if (expected != actual) revert IncompatibleDependency(field, expected, actual);
    }
}
