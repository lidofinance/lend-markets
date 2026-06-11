// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoBlueMarketController} from "@lido-blue/src/interfaces/ILidoBlueMarketController.sol";

/// @notice Test-only typed view of `WethWstEthController`. Inherits the controller's canonical
///         interface (`nextDeleverageCut`, `allowedSliceFor`, hooks) and adds the admin + dashboard
///         surface the tests need. `PositionView` and `SlicePolicy` mirror the controller's structs
///         field-for-field so calls decode.
interface IWethWstEthController is ILidoBlueMarketController {
    struct PositionView {
        uint256 rawCollateral;
        uint256 active;
        uint256 activating;
        uint256 dust;
        uint256 unlockAt;
        bool readyToSettle;
        uint256 suspicion;
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

    // Views (single-market: no id). nextDeleverageCut / allowedSliceFor come from the parent.
    function deleverageQueueSize() external view returns (uint256);
    function rootHasBadDebt() external view returns (bool);
    function watermarkInfo(address borrower) external view returns (uint256 watermarkLtv, uint256 sliceAssets);
    function positionOf(address borrower) external view returns (PositionView memory);
    function currentLoad() external view returns (uint256);
}
