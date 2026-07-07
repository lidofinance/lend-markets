// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {IMorpho, Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";
import {LidoLend} from "@lido-lend/src/LidoLend.sol";

import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {IrmRouter} from "@lido-lend-irm/src/irm-router/IrmRouter.sol";
import {IIrm} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IIrm.sol";
import {MarketParams as IrmMarketParams} from "@lido-lend-irm/lib/lido-lend/src/interfaces/IMorpho.sol";

import {GuardianSignals} from "../src/GuardianSignals.sol";
import {LidoLendMarketController} from "../src/controllers/LidoLendMarketController.sol";
import {LidoLendERC4626} from "../src/LidoLendERC4626.sol";
import {OssifiableProxy} from "../src/proxy/OssifiableProxy.sol";
import {LidoLendDeployer} from "./lib/LidoLendDeployer.sol";
import {MockERC20, MockPriceOracle} from "../test/setup/Mocks.sol";

/// @notice Split, broadcastable devnet actions for the dev-UI dashboard, built from direct `new` (no
///         `vm.getCode`). Three independent steps the panel drives via `forge script --sig`:
///           - `deployCore()`        — the singleton `LidoLend` core (one core hosts many markets),
///           - `deployToken(sym,dec)` — a standalone mock ERC-20 (loan or collateral, reusable),
///           - `createMarket(core,loan,collateral,price,lltv,minActivation)` — the per-market stack
///             (settable `MockPriceOracle`, IRM route, guardian, controller, `createMarket`, vault).
///         The broadcast key is `admin`, so no `vm.prank`. `console2.log("<label> :", <addr>)` lines are
///         parsed by the backend.
contract Devnet is Script {
    using MarketParamsLib for MarketParams;

    struct Mkt {
        address oracle;
        address guardian;
        address irm;
        address adaptive;
        address controller;
        address vault;
        bytes32 id;
    }

    function deployCore() external {
        address admin = msg.sender;
        vm.startBroadcast();
        address core = address(
            new OssifiableProxy(address(new LidoLend()), admin, abi.encodeWithSignature("initialize(address)", admin))
        );
        // The guardian registry is a project-level singleton (keyed by market Id), shared across every market.
        address guardian = _deployGuardian(admin);
        vm.stopBroadcast();
        console2.log("core               :", core);
        console2.log("guardianSignals    :", guardian);
    }

    function deployToken(string calldata symbol, uint8 decimals) external {
        vm.startBroadcast();
        address token = address(new MockERC20(symbol, symbol, decimals));
        vm.stopBroadcast();
        console2.log("token              :", token);
    }

    function createMarket(
        address core,
        address guardian,
        address loan,
        address collateral,
        uint256 oraclePrice,
        uint256 lltv,
        uint128 minActivation
    ) external {
        address admin = msg.sender;
        vm.startBroadcast();
        Mkt memory m = _createMarket(core, guardian, loan, collateral, oraclePrice, lltv, minActivation, admin);
        vm.stopBroadcast();

        console2.log("oracle             :", m.oracle);
        console2.log("irm                :", m.irm);
        console2.log("adaptive           :", m.adaptive);
        console2.log("controller         :", m.controller);
        console2.log("vault              :", m.vault);
        console2.log("marketId           :");
        console2.logBytes32(m.id);
    }

    function _createMarket(
        address core,
        address guardian,
        address loan,
        address collateral,
        uint256 oraclePrice,
        uint256 lltv,
        uint128 minActivation,
        address admin
    ) private returns (Mkt memory m) {
        m.oracle = address(
            new OssifiableProxy(
                address(new MockPriceOracle()), admin, abi.encodeWithSignature("initialize(uint256)", oraclePrice)
            )
        );
        m.irm = address(
            new OssifiableProxy(
                address(new IrmRouter(core)), admin, abi.encodeWithSignature("initialize(address,address)", admin, admin)
            )
        );

        MarketParams memory params =
            MarketParams({loanToken: loan, collateralToken: collateral, oracle: m.oracle, irm: m.irm, lltv: lltv});
        m.id = Id.unwrap(params.id());

        m.adaptive = _routeAdaptiveIrm(m.irm, params, admin);
        m.guardian = guardian;
        m.controller = _deployController(core, params.id(), guardian, admin, minActivation);
        ILidoLend(core).createMarket(params, m.controller, true);
        m.vault = _deployVault(core, params, m.controller, admin);
    }

    function _routeAdaptiveIrm(address router, MarketParams memory params, address admin)
        private
        returns (address)
    {
        IrmMarketParams memory irmParams = IrmMarketParams({
            loanToken: params.loanToken,
            collateralToken: params.collateralToken,
            oracle: params.oracle,
            irm: params.irm,
            lltv: params.lltv
        });
        AdaptiveCurveIrm adaptive = new AdaptiveCurveIrm(router, admin, admin);
        adaptive.setMarketCurveParams(irmParams, _curveConfig());
        IrmRouter(router).setMarketIrm(irmParams, IIrm(address(adaptive)));
        return address(adaptive);
    }

    function _deployGuardian(address admin) private returns (address guardian) {
        address[] memory guardians = new address[](1);
        guardians[0] = admin;
        guardian = address(
            new OssifiableProxy(
                address(new GuardianSignals()),
                admin,
                abi.encodeWithSignature("initialize(address,address[],uint256)", admin, guardians, uint256(1))
            )
        );
        GuardianSignals gs = GuardianSignals(guardian);
        gs.grantRole(gs.MANAGER_ROLE(), admin);
        gs.grantRole(gs.ACCESS_LIMITER_ROLE(), admin);
        gs.grantRole(gs.ACCESS_RESTORER_ROLE(), admin);
        gs.setSuspectWindow(0);
    }

    function _deployController(address core, Id id, address guardian, address admin, uint128 minActivation)
        private
        returns (address controller)
    {
        LidoLendDeployer.CollateralActivationConfigParams memory activation = LidoLendDeployer
            .CollateralActivationConfigParams({
            minActivationDelay: 10 minutes,
            maxActivationDelay: 2 hours,
            activatingLockAmount: 0,
            activatingLockDuration: 0,
            maxDelayInflow: 10_000 ether,
            minActivationAmount: minActivation,
            maxGuardiansQuorumDelay: 0,
            delayPerStrike: 2 hours,
            delayPerSuspect: 0
        });
        LidoLendDeployer.SettlementConfigParams memory settlement = LidoLendDeployer.SettlementConfigParams({
            sliceFloorBps: 100,
            sliceFloorAssets: 10 ether,
            fullCutBelowCollateral: 10 ether,
            ltvStepBps: 100
        });
        controller = address(
            new OssifiableProxy(
                address(new LidoLendMarketController(IMorpho(core))),
                admin,
                abi.encodeWithSignature(
                    "initialize(bytes32,address,address,(uint40,uint40,uint128,uint128,uint40,uint128,uint40,uint40,uint40),(uint16,uint96,uint96,uint16))",
                    Id.unwrap(id),
                    admin,
                    guardian,
                    activation,
                    settlement
                )
            )
        );
        LidoLendMarketController c = LidoLendMarketController(controller);
        c.grantRole(c.MANAGER_ROLE(), admin);
        c.grantRole(c.FREEZER_ROLE(), admin);
        c.grantRole(c.UNFREEZER_ROLE(), admin);
        c.grantRole(c.PAUSER_ROLE(), admin);
        c.grantRole(c.RESUMER_ROLE(), admin);
    }

    function _deployVault(address core, MarketParams memory params, address controller, address admin)
        private
        returns (address vault)
    {
        vault = address(
            new OssifiableProxy(
                address(new LidoLendERC4626(core)),
                admin,
                abi.encodeWithSignature(
                    "initialize((address,address,address,address,uint256),address,string,string)",
                    params,
                    controller,
                    "Lido Devnet Vault",
                    "devVAULT"
                )
            )
        );
    }

    function _curveConfig() private pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: 4e18,
            adjustmentSpeed: int256(50e18) / int256(365 days),
            targetUtilization: 9e17,
            initialRateAtTarget: int256(4e16) / int256(365 days),
            minRateAtTarget: int256(1e15) / int256(365 days),
            maxRateAtTarget: int256(2e18) / int256(365 days),
            maxBorrowRate: 0
        });
    }
}
