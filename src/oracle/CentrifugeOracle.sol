// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {NavOracleBase} from "./NavOracleBase.sol";

interface ICentrifugeSpoke {
    /// @notice Share price in the pool currency, 18-decimal fixed point.
    function pricePoolPerShare(uint64 poolId, bytes16 scId, bool checkValidity) external view returns (uint128);
}

/// @title CentrifugeOracle
/// @author Lido
/// @notice NAV oracle for a Centrifuge share class, reading the Spoke's share price.
/// @dev The Spoke's own validity check is not requested, since its maximum age is unbounded on the deployed pools.
contract CentrifugeOracle layout at erc7201("lido.lend.storage.NavOracle") is NavOracleBase {
    /// @dev Centrifuge Spoke holding the price registry.
    ICentrifugeSpoke public immutable SPOKE;
    /// @dev Pool and share class the collateral token belongs to.
    uint64 public immutable POOL_ID;
    bytes16 public immutable SHARE_CLASS_ID;

    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(
        address spoke,
        uint64 poolId,
        bytes16 scId,
        address loanToken,
        address collateralToken,
        address loanTokenFeed
    ) NavOracleBase(loanToken, collateralToken, loanTokenFeed) {
        if (spoke == address(0)) revert ZeroAddress();
        SPOKE = ICentrifugeSpoke(spoke);
        POOL_ID = poolId;
        SHARE_CLASS_ID = scId;
    }

    /// @inheritdoc NavOracleBase
    function _readSource() internal view override returns (uint256 nav) {
        return SPOKE.pricePoolPerShare(POOL_ID, SHARE_CLASS_ID, false);
    }
}
