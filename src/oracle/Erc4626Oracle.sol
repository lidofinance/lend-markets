// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {NavOracleBase} from "./NavOracleBase.sol";

/// @title Erc4626Oracle
/// @author Lido
/// @notice NAV oracle for a vault share, reading the vault's exchange rate into its asset.
/// @dev The vault share is the collateral itself, so the source doubles as the collateral token. The asset is
///      taken as one loan token per unit, so the vault's asset is the currency the market prices in.
contract Erc4626Oracle layout at erc7201("lido.lend.storage.NavOracle") is NavOracleBase {
    /// @notice The vault's asset has more than 18 decimals.
    error UnsupportedAssetDecimals(uint8 decimals);

    /// @dev Vault whose share is the collateral.
    IERC4626 public immutable SOURCE;
    /// @dev One share in the vault's share decimals.
    uint256 public immutable ONE_SHARE;
    /// @dev 10^(18 - asset decimals): the scaling of the exchange rate to 18 decimals.
    uint256 public immutable SOURCE_SCALE;

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(address source, address loanToken, address loanTokenFeed)
        NavOracleBase(loanToken, source, loanTokenFeed)
    {
        uint8 assetDecimals = IERC20Metadata(IERC4626(source).asset()).decimals();
        if (assetDecimals > 18) revert UnsupportedAssetDecimals(assetDecimals);
        SOURCE = IERC4626(source);
        ONE_SHARE = 10 ** IERC20Metadata(source).decimals();
        SOURCE_SCALE = 10 ** (18 - assetDecimals);
    }

    /// @inheritdoc NavOracleBase
    function _readSource() internal view override returns (uint256 nav) {
        return SOURCE.convertToAssets(ONE_SHARE) * SOURCE_SCALE;
    }
}
