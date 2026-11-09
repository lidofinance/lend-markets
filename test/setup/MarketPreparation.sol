// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {IRiskStewardDashboard} from "../../src/interfaces/IRiskStewardDashboard.sol";
import {MarketDeployment} from "../../script/deployment/MarketDeployment.sol";
import {
    ProtocolAddresses,
    MarketPlan,
    MarketDeploymentResult,
    MarketActivation,
    ExitBookAddresses
} from "../../script/deployment/DeploymentTypes.sol";

interface IPreparationIrm {
    function applyIrmConfig(MarketParams calldata params, address config) external;
    function marketCurveConfig(bytes32 id) external view returns (address);
}

interface IPreparationRouter {
    function setMarketIrm(MarketParams calldata params, address irm) external;
    function marketIrm(bytes32 id) external view returns (address);
}

interface IPreparationOwner {
    function createMarket(MarketParams calldata params, address controller, bool enableSettlement) external;
}

interface IPreparationPauser {
    function getPauser(address pausable) external view returns (address);
    function registerPauser(address pausable, address pauser) external;
}

interface IPreparationMorphoBook {
    function MORPHO() external view returns (address);
    function setMarketAllowed(MarketParams calldata params, bool allowed) external;
}

interface IPreparationVaultBook {
    function setVaultAllowed(address vault, bool allowed) external;
}

/// @notice Prepares lending state locally. Easy Track motions and their permissions are exercised separately.
abstract contract MarketPreparation is Test, MarketDeployment {
    uint256 internal constant MIN_SEED_SHARES = 1e9;
    uint256 internal constant MIN_SEED_ASSETS = 1e6;
    uint256 internal constant CORE_SEED_ASSETS = 1000;
    address internal constant SEED_RECIPIENT = address(0xdead);

    function _prepareMarket(
        ProtocolAddresses memory p,
        MarketPlan memory plan,
        MarketDeploymentResult memory existing,
        MarketActivation memory activation
    ) internal returns (MarketDeploymentResult memory d) {
        d = existing;
        if (d.controller == address(0)) {
            // A partially supplied record is broken input, not permission to deploy a replacement.
            require(keccak256(abi.encode(d)) == keccak256(abi.encode(_emptyMarket())), "Partial market record");
            d = _deployMarket(p, plan);
        } else {
            _checkMarket(p, d);
            _same("market.loanToken", plan.market.loanToken, d.params.loanToken);
            _same("market.collateralToken", plan.market.collateralToken, d.params.collateralToken);
            require(plan.market.lltv == d.params.lltv, "Market LLTV differs from plan");
            if (plan.market.oracle != address(0)) _same("market.priceFeed", plan.market.oracle, d.params.oracle);
            if (plan.market.guardianSignals != address(0)) {
                _same("market.guardians", plan.market.guardianSignals, d.guardianSignals);
            }
            plan.market.oracle = d.params.oracle;
            _checkPriceFeed(p, plan);
        }
        if (ILidoLend(p.core).market(d.id).lastUpdate != 0) {
            // Market creation alone is not a completed activation. Never repair an existing active market.
            require(
                ILidoLend(p.core).position(d.id, SEED_RECIPIENT).supplyShares >= MIN_SEED_SHARES, "Missing core seed"
            );
            require(ILidoLendERC4626(d.vault).balanceOf(SEED_RECIPIENT) >= MIN_SEED_SHARES, "Missing vault seed");
            require(IPreparationRouter(p.irmRouter).marketIrm(Id.unwrap(d.id)) != address(0), "Missing IRM route");
            require(IPreparationPauser(p.circuitBreaker).getPauser(d.controller) != address(0), "Missing pauser");
            return d;
        }
        _checkInertMarket(p, plan, d);
        _activatePreparedMarket(p, d, activation);
    }

    function _activatePreparedMarket(
        ProtocolAddresses memory p,
        MarketDeploymentResult memory d,
        MarketActivation memory activation
    ) internal {
        require(activation.pauser != address(0) && activation.steward != address(0), "Missing activation actors");
        ExitBookAddresses memory books = activation.exitBooks;
        if (books.morpho != address(0) || books.erc4626 != address(0)) {
            require(books.chainId == p.chainId, "Exit books belong to another chain");
        }
        if (books.morpho != address(0)) {
            _requireCode(books.morpho);
            _same("exitBook.core", p.core, IPreparationMorphoBook(books.morpho).MORPHO());
        }
        if (books.erc4626 != address(0)) _requireCode(books.erc4626);
        address config = IPreparationIrm(p.adaptiveCurveIrm).marketCurveConfig(Id.unwrap(d.id));
        address route = IPreparationRouter(p.irmRouter).marketIrm(Id.unwrap(d.id));
        address pauser = IPreparationPauser(p.circuitBreaker).getPauser(d.controller);
        if (config != address(0)) _same("irm.config", d.irmConfig, config);
        if (route != address(0)) _same("irm.route", p.adaptiveCurveIrm, route);
        if (pauser != address(0)) _same("pauser", activation.pauser, pauser);

        vm.startPrank(p.executor);
        if (config == address(0)) IPreparationIrm(p.adaptiveCurveIrm).applyIrmConfig(d.params, d.irmConfig);
        if (route == address(0)) IPreparationRouter(p.irmRouter).setMarketIrm(d.params, p.adaptiveCurveIrm);
        IPreparationOwner(p.ownerFacade).createMarket(d.params, d.controller, activation.enableSettlement);
        if (pauser == address(0)) IPreparationPauser(p.circuitBreaker).registerPauser(d.controller, activation.pauser);
        IRiskStewardDashboard dashboard = IRiskStewardDashboard(p.dashboard);
        if (!dashboard.isMarketSteward(d.id, activation.steward)) dashboard.addMarketSteward(d.id, activation.steward);
        if (books.morpho != address(0)) IPreparationMorphoBook(books.morpho).setMarketAllowed(d.params, true);
        if (books.erc4626 != address(0)) IPreparationVaultBook(books.erc4626).setVaultAllowed(d.vault, true);
        vm.stopPrank();
        _seedPreparedMarket(p, d);
        assertTrue(ILidoLend(p.core).market(d.id).lastUpdate != 0, "Market must be active");
    }

    function _seedPreparedMarket(ProtocolAddresses memory p, MarketDeploymentResult memory d) private {
        ILidoLendERC4626 vault = ILidoLendERC4626(d.vault);
        uint256 vaultAssets = vault.previewMint(MIN_SEED_SHARES);
        if (vaultAssets < MIN_SEED_ASSETS) vaultAssets = MIN_SEED_ASSETS;
        address seedActor = makeAddr("deployment.seed");
        deal(d.params.loanToken, seedActor, CORE_SEED_ASSETS + vaultAssets);
        vm.startPrank(seedActor);
        IERC20(d.params.loanToken).approve(p.core, CORE_SEED_ASSETS);
        (, uint256 shares) = ILidoLend(p.core).supply(d.params, CORE_SEED_ASSETS, 0, SEED_RECIPIENT, "");
        IERC20(d.params.loanToken).approve(d.vault, vaultAssets);
        uint256 vaultShares = vault.deposit(vaultAssets, SEED_RECIPIENT);
        vm.stopPrank();
        assertGe(shares, MIN_SEED_SHARES, "Core seed shares");
        assertGe(vaultShares, MIN_SEED_SHARES, "Vault seed shares");
    }

    function _emptyMarket() private pure returns (MarketDeploymentResult memory d) {}
}
