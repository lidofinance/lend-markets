// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id, IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";

import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {IIrm} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IIrm.sol";
// The IRM dependency uses its own otherwise identical MarketParams type.
import {MarketParams as IrmMarketParams} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../../src/GuardianSignals.sol";
import {LidoLendERC4626} from "../../src/LidoLendERC4626.sol";
import {LidoLendMarketController} from "../../src/controllers/LidoLendMarketController.sol";
import {IGuardianSignalsView} from "../../src/interfaces/IGuardianSignalsView.sol";
import {LidoLendOwner} from "../../src/periphery/LidoLendOwner.sol";
import {WstEthRateOracle} from "../../src/oracle/WstEthRateOracle.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";

import {LidoLendPrimitives} from "./LidoLendPrimitives.sol";

/// @notice One-shot live market deployment for devnet and scenario tests.
abstract contract LidoLendDeployer is LidoLendPrimitives {
    using MarketParamsLib for MarketParams;

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
        address oracleSource;
        uint256 lltv;
        bool enableSettlement;
        CollateralActivationConfig activation;
        SettlementConfig settlementConfig;
        address[] guardians;
        uint256 quorum;
        uint256 suspectWindow;
        string vaultName;
        string vaultSymbol;
    }

    function _deployForkStack(DeployConfig memory cfg) internal returns (Deployed memory d) {
        d.core = _deployCore(cfg.admin);

        d.ownerFacade = _deployOwnerFacade(d.core, cfg.admin, cfg.admin, address(0));
        ILidoLend(d.core).setOwner(d.ownerFacade);
        LidoLendOwner(d.ownerFacade).grantRole(LidoLendOwner(d.ownerFacade).MARKET_MANAGER_ROLE(), cfg.admin);
        LidoLendOwner(d.ownerFacade).grantRole(LidoLendOwner(d.ownerFacade).GUARDIAN_MANAGER_ROLE(), cfg.admin);

        d.guardianSignals =
            _deployGuardianSignals(address(new GuardianSignals()), cfg.admin, cfg.admin, cfg.guardians, cfg.quorum);
        d.oracle = _deployOracle(cfg.oracleSource, cfg.admin);
        d.irm = _deployIrm(d.core, cfg.admin);

        d.params = MarketParams({
            loanToken: cfg.loanToken, collateralToken: cfg.collateralToken, oracle: d.oracle, irm: d.irm, lltv: cfg.lltv
        });
        d.marketId = d.params.id();

        _configureAdaptiveIrm(d.irm, d.params, cfg.admin);

        (d.controllerProxy, d.controllerImpl) =
            _deployController(d.core, d.marketId, d.guardianSignals, cfg.admin, cfg.activation, cfg.settlementConfig);

        LidoLendOwner(d.ownerFacade).createMarket(d.params, d.controllerProxy, cfg.enableSettlement);

        d.vault = _deployVault(d.core, d.params, d.controllerProxy, cfg.admin, cfg.vaultName, cfg.vaultSymbol);

        LidoLendMarketController controller = LidoLendMarketController(d.controllerProxy);
        controller.grantRole(controller.MANAGER_ROLE(), cfg.admin);
        controller.grantRole(controller.MANAGER_ROLE(), d.ownerFacade);
        controller.grantRole(controller.UNFREEZER_ROLE(), d.ownerFacade);

        GuardianSignals guardianSignals = GuardianSignals(d.guardianSignals);
        guardianSignals.grantRole(guardianSignals.MANAGER_ROLE(), cfg.admin);
        guardianSignals.grantRole(guardianSignals.MANAGER_ROLE(), d.ownerFacade);
        guardianSignals.grantRole(guardianSignals.ACCESS_RESTORER_ROLE(), d.ownerFacade);
        guardianSignals.setSuspectWindow(cfg.suspectWindow);
    }

    function _deployOracle(address oracleSource, address admin) internal virtual returns (address) {
        address impl = address(new WstEthRateOracle(oracleSource));
        return _behindProxy(impl, admin, "");
    }

    function _curveConfig() internal pure virtual returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: int256(50e18) / int256(365 days),
            targetUtilization: 9e17,
            initialRateAtTarget: int256(4e16) / int256(365 days),
            minRateAtTarget: int256(1e15) / int256(365 days),
            maxRateAtTarget: int256(2e18) / int256(365 days),
            maxBorrowRate: 0 // 0 disables the ceiling
        });
    }

    /// @dev The router probes the model, so curve parameters must be set first.
    function _configureAdaptiveIrm(address router, MarketParams memory params, address owner)
        internal
        virtual
        returns (address)
    {
        IrmMarketParams memory irmParams = IrmMarketParams({
            loanToken: params.loanToken,
            collateralToken: params.collateralToken,
            oracle: params.oracle,
            irm: params.irm, // == router
            lltv: params.lltv
        });

        AdaptiveCurveIrm irm = new AdaptiveCurveIrm(router, owner, owner);
        irm.setMarketCurveParams(irmParams, _curveConfig());
        IrmRouter(router).setMarketIrm(irmParams, IIrm(address(irm)));
        return address(irm);
    }

    function _deployController(
        address core,
        Id marketId,
        address guardianSignals,
        address admin,
        CollateralActivationConfig memory activation,
        SettlementConfig memory settlement
    ) internal virtual returns (address proxy, address impl) {
        impl = address(new LidoLendMarketController(IMorpho(core)));
        bytes memory initData = abi.encodeCall(
            LidoLendMarketController.initialize,
            (marketId, admin, IGuardianSignalsView(guardianSignals), activation, settlement)
        );
        proxy = _behindProxy(impl, admin, initData);
    }

    function _deployVault(
        address core,
        MarketParams memory params,
        address controller,
        address admin,
        string memory name_,
        string memory symbol_
    ) internal virtual returns (address) {
        address impl = address(new LidoLendERC4626(core));
        bytes memory initData = abi.encodeCall(LidoLendERC4626.initialize, (params, controller, name_, symbol_));
        return _behindProxy(impl, admin, initData);
    }
}
