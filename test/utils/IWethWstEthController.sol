// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {ILidoBlueMarketController} from "@lido-blue/src/interfaces/ILidoBlueMarketController.sol";

/// @notice Test-only typed view of `WethWstEthController`. The controller compiles under 0.8.24; the
///         0.8.19 scenario tests drive it through this floating-pragma interface so they don't import
///         the controller directly. Inherits the controller's canonical interface (`nextDeleverageCut`,
///         `allowedSliceFor`, hooks) and adds the admin + dashboard surface the tests need.
///         `PositionView` mirrors the controller's struct field-for-field so `positionOf` decodes.
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

    // AccessControl
    function CONFIGURATOR_ROLE() external view returns (bytes32);
    function RISK_STEWARD_ROLE() external view returns (bytes32);
    function COMMITTEE_ROLE() external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;

    // Policy mutations (single-market: no id)
    function setSliceFloor(uint128 sliceFloorAssets) external;
    function setFallbackMinRequest(uint128 fallbackMinRequest) external;
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
