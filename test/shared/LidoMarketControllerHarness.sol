// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

import {IMarketController} from "../../src/interfaces/IMarketController.sol";
import {LidoMarketController} from "../../src/controllers/LidoMarketController.sol";

/// @dev Test harness exposing internal helpers of LidoMarketController. Not for production use.
contract LidoMarketControllerHarness is LidoMarketController {
    function exposed_computeMaturationDelay(Id id, uint256 depositSize) external view returns (uint64) {
        return _computeMaturationDelay(id, depositSize);
    }

    function exposed_syncMaturation(Id id, address borrower) external {
        _syncMaturation(id, borrower);
    }

    function exposed_handleSupply(Id id, address caller, address onBehalf, uint256 assets) external view {
        _handleSupply(
            id, IMarketController.SupplyHookData({caller: caller, onBehalf: onBehalf, assets: assets, shares: 0})
        );
    }

    function exposed_handleSupplyCollateral(Id id, address caller, address onBehalf, uint256 assets) external {
        _handleSupplyCollateral(
            id, IMarketController.SupplyCollateralHookData({caller: caller, onBehalf: onBehalf, assets: assets})
        );
    }

    function exposed_handleBorrow(Id id, address caller, address onBehalf, address receiver, uint256 assets) external {
        _handleBorrow(
            id,
            IMarketController.BorrowHookData({
                caller: caller, onBehalf: onBehalf, receiver: receiver, assets: assets, shares: 0
            })
        );
    }

    function exposed_handleLiquidate(
        Id id,
        address caller,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares
    ) external {
        _handleLiquidate(
            id,
            IMarketController.LiquidateHookData({
                caller: caller, borrower: borrower, seizedAssets: seizedAssets, repaidShares: repaidShares
            })
        );
    }

    function exposed_handleWithdrawCollateral(
        Id id,
        address caller,
        address onBehalf,
        address receiver,
        uint256 assets,
        uint256 borrowerBorrowShares
    ) external {
        _handleWithdrawCollateral(
            id,
            IMarketController.WithdrawCollateralHookData({
                caller: caller,
                onBehalf: onBehalf,
                receiver: receiver,
                assets: assets,
                borrowerBorrowShares: borrowerBorrowShares
            })
        );
    }
}
