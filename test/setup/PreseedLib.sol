// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";

/// @notice The dead-share preseed of the Easy Track activation motion: the two calls of
///         `LidoLendPreseeder.preseedMarket`, with its constants, amounts and vault-share check.
/// @dev This library copies code from another repository, and this repository cannot check it against the source.
library PreseedLib {
    using SafeERC20 for IERC20;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant RECIPIENT = address(0xdead);
    uint256 internal constant MARKET_VIRTUAL_SHARES = 1e6;
    uint256 internal constant MIN_DEAD_DEPOSIT_SHARES = 1e9;
    uint256 internal constant MIN_VAULT_ASSET_UNITS = 1e6;

    /// @notice Loan assets that the core supply of `MIN_DEAD_DEPOSIT_SHARES` pulls on an empty market.
    function marketAssets() internal pure returns (uint256) {
        return (MIN_DEAD_DEPOSIT_SHARES - 1) / MARKET_VIRTUAL_SHARES + 1;
    }

    /// @notice Loan assets that the vault deposit pulls.
    function vaultAssets(IERC4626 vault) internal view returns (uint256) {
        return Math.max(vault.previewMint(MIN_DEAD_DEPOSIT_SHARES), MIN_VAULT_ASSET_UNITS);
    }

    /// @notice Makes both preseed calls as `preseeder`, which must hold `marketAssets() + vaultAssets(vault)`.
    ///         The market shares and the vault shares go to `RECIPIENT`.
    /// @return requiredVaultShares The fewest vault shares that the preseeder accepts for `RECIPIENT`.
    function preseed(IMorpho core, MarketParams memory params, IERC4626 vault, address preseeder)
        internal
        returns (uint256 requiredVaultShares)
    {
        IERC20 loanToken = IERC20(params.loanToken);
        uint256 vaultDeposit = vaultAssets(vault);

        vm.startPrank(preseeder);
        loanToken.forceApprove(address(core), marketAssets());
        core.supply(params, 0, MIN_DEAD_DEPOSIT_SHARES, RECIPIENT, "");
        requiredVaultShares = Math.max(vault.previewDeposit(MIN_VAULT_ASSET_UNITS), MIN_DEAD_DEPOSIT_SHARES);
        loanToken.forceApprove(address(vault), vaultDeposit);
        uint256 vaultShares = vault.deposit(vaultDeposit, RECIPIENT);
        vm.stopPrank();

        vm.assertGe(vaultShares, requiredVaultShares, "preseed: vault shares too low");
    }
}
