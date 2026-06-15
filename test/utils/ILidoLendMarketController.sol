// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {
    ILidoLendMarketController as ILidoLendBaseMarketController
} from "@lido-lend/src/interfaces/ILidoLendMarketController.sol";

/// @notice Test-only typed view of `LidoLendMarketController`. Inherits the core hook interface and adds the
///         admin, dashboard, and settle-queue surface the tests need. `nextSettlementCut` and
///         `allowedSliceFor` are the controller's own views (no longer on the core hook interface), so
///         they are declared here. `PositionView` and `SlicePolicy` mirror the controller's structs
///         field-for-field so calls decode.
interface ILidoLendMarketController is ILidoLendBaseMarketController {
    struct PositionView {
        uint256 rawCollateral;
        uint256 active;
        uint256 activating;
        uint256 dust;
        uint256 unlockTime;
        bool readyToSettle;
        uint256 strikes;
        bool banned;
        uint256 debtAssets;
        uint256 watermarkLtv;
        bool isQueueRoot;
        uint256 allowedSlice;
    }

    struct SlicePolicy {
        uint16 sliceFloorBps;
        uint96 sliceFloorAssets;
        uint96 fallbackMinRequest;
    }

    // AccessControl
    function CONFIGURATOR_ROLE() external view returns (bytes32);
    function RISK_STEWARD_ROLE() external view returns (bytes32);
    function COMMITTEE_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;

    // Policy mutations (single-market: no id)
    function setSlicePolicy(SlicePolicy calldata policy) external;
    function slicePolicy() external view returns (SlicePolicy memory);
    function setActivatingHold(uint128 activatingHold) external;
    function setBorrowerWatermark(uint256 ltv) external;
    function freeze() external;
    function unfreeze() external;

    // Views (single-market: no id). Controller-own settle views (not on the core hook interface).
    function nextSettlementCut() external view returns (address borrower, uint256 sliceAssets);
    function allowedSliceFor(address borrower) external view returns (uint256);
    function settlementQueueSize() external view returns (uint256);
    function rootHasBadDebt() external view returns (bool);
    function watermarkInfo(address borrower) external view returns (uint256 watermarkLtv, uint256 sliceAssets);
    function positionOf(address borrower) external view returns (PositionView memory);
    function currentInflow() external view returns (uint256);
}
