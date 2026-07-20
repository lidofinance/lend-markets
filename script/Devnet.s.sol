// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Script, console2} from "forge-std/Script.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@lido-lend/src/libraries/MarketParamsLib.sol";

import {GuardianSignals} from "../src/GuardianSignals.sol";
import {LidoLendMarketController} from "../src/controllers/LidoLendMarketController.sol";
import {CollateralActivationConfig} from "../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../src/types/SettlementTypes.sol";
import {LidoLendDeployer} from "./lib/LidoLendDeployer.sol";
import {MockERC20, MockPriceOracle} from "../test/setup/Mocks.sol";

/// @notice Split, broadcastable devnet actions for the dev-UI dashboard, composed from the shared
///         `LidoLendDeployer` steps (mock oracle and role wiring are the devnet-only parts). Three
///         independent steps the panel drives via `forge script --sig`:
///           - `deployCore()`        — the singleton `LidoLend` core (one core hosts many markets),
///           - `deployToken(sym,dec)` — a standalone mock ERC-20 (loan or collateral, reusable),
///           - `createMarket(core,loan,collateral,price,lltv,minActivation)` — the per-market stack
///             (settable `MockPriceOracle`, IRM route, guardian, controller, `createMarket`, vault).
///         The broadcast key is `admin`, so no `vm.prank`. `console2.log("<label> :", <addr>)` lines are
///         parsed by the backend. No owner facade: devnet does not exercise the governance path, so the
///         broadcast key owns the core and calls `createMarket` on it directly.
contract Devnet is Script, LidoLendDeployer {
    using MarketParamsLib for MarketParams;

    struct Mkt {
        address oracle;
        address guardianSignals;
        address irm;
        address adaptive;
        address controller;
        address vault;
        bytes32 id;
    }

    function deployCore() external {
        address admin = msg.sender;
        vm.startBroadcast();
        address core = _deployCore(admin);
        // The guardian registry is a project-level singleton (keyed by market Id), shared across every market.
        address guardianSignals = _deployGuardian(admin);
        vm.stopBroadcast();
        console2.log("core               :", core);
        console2.log("guardianSignals    :", guardianSignals);
    }

    function deployToken(string calldata symbol, uint8 decimals) external {
        vm.startBroadcast();
        address token = address(new MockERC20(symbol, symbol, decimals));
        vm.stopBroadcast();
        console2.log("token              :", token);
    }

    function createMarket(
        address core,
        address guardianSignals,
        address loan,
        address collateral,
        uint256 oraclePrice,
        uint256 lltv,
        uint128 minActivation
    ) external {
        address admin = msg.sender;
        vm.startBroadcast();
        Mkt memory m = _createMarket(core, guardianSignals, loan, collateral, oraclePrice, lltv, minActivation, admin);
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
        address guardianSignals,
        address loan,
        address collateral,
        uint256 oraclePrice,
        uint256 lltv,
        uint128 minActivation,
        address admin
    ) private returns (Mkt memory m) {
        // Settable mock oracle — the devnet-only piece (the panel moves the price to trigger flows).
        m.oracle = _behindProxy(
            address(new MockPriceOracle()), admin, abi.encodeCall(MockPriceOracle.initialize, (oraclePrice))
        );
        m.irm = _deployIrm(core, admin);

        MarketParams memory params =
            MarketParams({loanToken: loan, collateralToken: collateral, oracle: m.oracle, irm: m.irm, lltv: lltv});
        m.id = Id.unwrap(params.id());

        m.adaptive = _configureAdaptiveIrm(m.irm, params, admin);
        m.guardianSignals = guardianSignals;
        m.controller = _deployDevnetController(core, params.id(), guardianSignals, admin, minActivation);
        ILidoLend(core).createMarket(params, m.controller, true);
        m.vault = _deployVault(core, params, m.controller, admin, "Lido Devnet Vault", "devVAULT");
    }

    /// @dev Shared registry deploy + devnet convenience: every guardian role goes to `admin`.
    function _deployGuardian(address admin) private returns (address guardianSignals) {
        address[] memory guardians = new address[](1);
        guardians[0] = admin;
        guardianSignals = _deployGuardianSignals(address(new GuardianSignals()), admin, admin, guardians, 1);
        GuardianSignals gs = GuardianSignals(guardianSignals);
        gs.grantRole(gs.MANAGER_ROLE(), admin);
        gs.grantRole(gs.ACCESS_LIMITER_ROLE(), admin);
        gs.grantRole(gs.ACCESS_RESTORER_ROLE(), admin);
        gs.setSuspectWindow(0);
    }

    /// @dev Shared controller deploy with devnet policy values + devnet convenience: every operational role
    ///      goes to `admin`.
    function _deployDevnetController(address core, Id id, address guardianSignals, address admin, uint128 minActivation)
        private
        returns (address controller)
    {
        CollateralActivationConfig memory activation = CollateralActivationConfig({
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
        SettlementConfig memory settlement = SettlementConfig({
            sliceFloorBps: 100, sliceFloorAssets: 10 ether, fullCutBelowCollateral: 10 ether, ltvStepBps: 100
        });
        (controller,) = _deployController(core, id, guardianSignals, admin, activation, settlement);

        LidoLendMarketController c = LidoLendMarketController(controller);
        c.grantRole(c.MANAGER_ROLE(), admin);
        c.grantRole(c.FREEZER_ROLE(), admin);
        c.grantRole(c.UNFREEZER_ROLE(), admin);
        c.grantRole(c.PAUSER_ROLE(), admin);
        c.grantRole(c.RESUMER_ROLE(), admin);
    }
}
