// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CommonBase} from "forge-std/Base.sol";
import {console2} from "forge-std/console2.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {IIrmConfigFactory} from "@lido-lend-irm/src/irm-config-factory/interfaces/IIrmConfigFactory.sol";
import {IAdaptiveCurveConfig} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveConfig.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {OssifiableProxy} from "../../src/proxy/OssifiableProxy.sol";
import {DeploymentOutput} from "./DeploymentOutput.sol";
import {ProtocolAddresses, MarketParameters, MarketDeploymentResult} from "./DeploymentTypes.sol";

interface IDeploymentManager {
    function manager() external view returns (address);
}

interface IDeploymentCircuitBreaker {
    function ADMIN() external view returns (address);
}

interface IDeploymentController {
    function LIDO_LEND() external view returns (address);
    function marketId() external view returns (Id);
    function supplyCap() external view returns (uint256);
}

interface IPriceFeedProxyView {
    function proxy__getAdmin() external view returns (address);
    function proxy__getImplementation() external view returns (address);
}

abstract contract MarketDeployment is CommonBase {
    using MarketParamsLib for MarketParams;

    error WrongChain(uint256 expected, uint256 actual);
    error MissingCode(address account);
    error IncompatibleDependency(bytes32 field, address expected, address actual);
    error MissingCommittee();
    error InvalidMarketRecord();
    error PriceFeedCodeMismatch(address component);

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

    function _checkParameters(ProtocolAddresses memory p, MarketParameters memory parameters) internal view {
        _checkProtocol(p);
        _requireCode(parameters.market.loanToken);
        _requireCode(parameters.market.collateralToken);
        if (parameters.committee.guardians.length == 0 || parameters.committee.quorum == 0) revert MissingCommittee();
        if (parameters.market.oracle != address(0)) _checkPriceFeed(p, parameters);
        if (parameters.market.guardianSignals != address(0)) {
            LidoLendMarketFactory(p.factory)
                .validateGuardianSignals(parameters.market.guardianSignals, parameters.committee);
        }
    }

    function _deployMarket(ProtocolAddresses memory p, MarketParameters memory parameters)
        internal
        returns (MarketDeploymentResult memory d)
    {
        _checkParameters(p, parameters);
        if (parameters.market.oracle == address(0)) parameters.market.oracle = _deployPriceFeed(p, parameters);
        _checkPriceFeed(p, parameters);
        LidoLendMarketFactory f = LidoLendMarketFactory(p.factory);
        if (parameters.market.guardianSignals == address(0)) {
            parameters.market.guardianSignals = f.deployGuardianSignals(parameters.committee, parameters.guardianGroup);
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
        _checkMarket(p, d);
    }

    /// @dev Existing deployments are checked for identity, without resetting governance-controlled parameters.
    function _checkMarket(ProtocolAddresses memory p, MarketDeploymentResult memory d) internal view {
        _checkProtocol(p);
        _requireCode(d.controller);
        _requireCode(d.vault);
        _requireCode(d.guardianSignals);
        _requireCode(d.params.oracle);
        _requireCode(d.irmConfig);
        if (Id.unwrap(d.id) != Id.unwrap(d.params.id()) || d.params.irm != p.irmRouter) revert InvalidMarketRecord();
        ILidoLendERC4626 vault = ILidoLendERC4626(d.vault);
        _same("vault.core", p.core, address(vault.LIDO_LEND()));
        _same("vault.controller", d.controller, address(vault.controller()));
        _same("vault.asset", d.params.loanToken, vault.asset());
        if (Id.unwrap(vault.marketId()) != Id.unwrap(d.id)) revert InvalidMarketRecord();
        ILidoLendMarketController controller = ILidoLendMarketController(d.controller);
        _same("controller.core", p.core, IDeploymentController(d.controller).LIDO_LEND());
        if (Id.unwrap(IDeploymentController(d.controller).marketId()) != Id.unwrap(d.id)) revert InvalidMarketRecord();
        _same("controller.guardians", d.guardianSignals, address(controller.guardianSignals()));
        address registered = ILidoLend(p.core).marketController(d.id);
        if (registered != address(0) || ILidoLend(p.core).market(d.id).lastUpdate != 0) {
            _same("core.controller", d.controller, registered);
        }
    }

    /// @dev Enforces launch parameters and roles before activation.
    function _checkInertMarket(
        ProtocolAddresses memory p,
        MarketParameters memory parameters,
        MarketDeploymentResult memory d
    ) internal view {
        LidoLendMarketFactory factory = LidoLendMarketFactory(p.factory);
        factory.validateGuardianSignals(d.guardianSignals, parameters.committee);
        factory.validateMarketController(d.controller, d.id, d.guardianSignals);
        factory.validateERC4626Wrapper(d.vault, d.controller, d.params);
        ILidoLendMarketController controller = ILidoLendMarketController(d.controller);
        require(
            keccak256(abi.encode(controller.collateralActivationConfig()))
                == keccak256(abi.encode(parameters.market.activationConfig)),
            "Inert activation differs from parameters"
        );
        require(
            keccak256(abi.encode(controller.settlementConfig()))
                == keccak256(abi.encode(parameters.market.settlementConfig)),
            "Inert settlement differs from parameters"
        );
        require(
            IDeploymentController(d.controller).supplyCap() == parameters.market.supplyCap,
            "Inert cap differs from parameters"
        );
        require(
            keccak256(abi.encode(IAdaptiveCurveConfig(d.irmConfig).getCurveParams()))
                == keccak256(abi.encode(parameters.curve)),
            "Inert curve differs from parameters"
        );
        IERC20Metadata vault = IERC20Metadata(d.vault);
        require(
            keccak256(bytes(vault.name())) == keccak256(bytes(parameters.wrapper.name)),
            "Inert vault name differs from parameters"
        );
        require(
            keccak256(bytes(vault.symbol())) == keccak256(bytes(parameters.wrapper.symbol)),
            "Inert vault symbol differs from parameters"
        );
    }

    function _deployPriceFeed(ProtocolAddresses memory p, MarketParameters memory parameters)
        internal
        virtual
        returns (address)
    {
        return address(new OssifiableProxy(_deployPriceFeedImplementation(parameters), p.agent, ""));
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

    function _reportMarket(string memory directory, address core, string memory name, MarketDeploymentResult memory d)
        internal
    {
        vm.serializeBytes32(name, "market_id", Id.unwrap(d.id));
        vm.serializeAddress(name, "core", core);
        vm.serializeAddress(name, "loan_token", d.params.loanToken);
        vm.serializeAddress(name, "collateral_token", d.params.collateralToken);
        vm.serializeAddress(name, "irm", d.params.irm);
        vm.serializeAddress(name, "controller", d.controller);
        vm.serializeAddress(name, "vault", d.vault);
        vm.serializeAddress(name, "price_feed", d.params.oracle);
        vm.serializeAddress(name, "guardian_signals", d.guardianSignals);
        DeploymentOutput.write(directory, name, vm.serializeAddress(name, "irm_config", d.irmConfig));

        console2.log("market:", name);
        console2.logBytes32(Id.unwrap(d.id));
        console2.log("controller:", d.controller);
        console2.log("vault:", d.vault);
        console2.log("price feed:", d.params.oracle);
        console2.log("guardian registry:", d.guardianSignals);
        console2.log("IRM config:", d.irmConfig);
    }

    function _deployPriceFeedImplementation(MarketParameters memory parameters) internal virtual returns (address);
    function _checkPriceFeed(ProtocolAddresses memory p, MarketParameters memory parameters) internal view virtual;

    function _requireCode(address account) internal view {
        if (account.code.length == 0) revert MissingCode(account);
    }

    function _same(bytes32 field, address expected, address actual) internal pure {
        if (expected != actual) revert IncompatibleDependency(field, expected, actual);
    }
}
