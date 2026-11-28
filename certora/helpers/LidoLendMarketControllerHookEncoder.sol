// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ILidoLendMarketController} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";

// Encodes a typed hook payload into the bytes the core passes to on(), so a rule can name payload fields.
contract LidoLendMarketControllerHookEncoder {
    function encodeSupply(ILidoLendMarketController.SupplyHookData memory d)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(d);
    }

    function encodeWithdraw(ILidoLendMarketController.WithdrawHookData memory d)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(d);
    }

    function encodeSupplyCollateral(ILidoLendMarketController.SupplyCollateralHookData memory d)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(d);
    }

    function encodeWithdrawCollateral(ILidoLendMarketController.WithdrawCollateralHookData memory d)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(d);
    }

    function encodeBorrow(ILidoLendMarketController.BorrowHookData memory d)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(d);
    }

    function encodeRepay(ILidoLendMarketController.RepayHookData memory d)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(d);
    }

    function encodeLiquidate(ILidoLendMarketController.LiquidateHookData memory d)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(d);
    }

    function encodeSettle(ILidoLendMarketController.SettleHookData memory d)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(d);
    }
}
