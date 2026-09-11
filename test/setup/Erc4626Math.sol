// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice OZ's ERC-4626 conversions recomputed from a vault's live totals and its virtual-share offset
///         (`vault.decimals() - asset.decimals()`), so a test never grades the vault against its own preview.
library Erc4626Math {
    function toShares(IERC4626 vault, uint256 assetAmount, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(assetAmount, vault.totalSupply() + 10 ** _offset(vault), vault.totalAssets() + 1, rounding);
    }

    function toAssets(IERC4626 vault, uint256 shareAmount, Math.Rounding rounding) internal view returns (uint256) {
        return Math.mulDiv(shareAmount, vault.totalAssets() + 1, vault.totalSupply() + 10 ** _offset(vault), rounding);
    }

    function _offset(IERC4626 vault) private view returns (uint8) {
        return vault.decimals() - IERC20Metadata(vault.asset()).decimals();
    }
}
