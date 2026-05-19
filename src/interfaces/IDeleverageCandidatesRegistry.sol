// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.0;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";

/// @title IDeleverageCandidatesRegistry
/// @notice Registry used to discover borrower candidates for deleverage.
interface IDeleverageCandidatesRegistry {
    struct DeleverageCut {
        address borrower;
        uint256 debtAssetsToCancel;
        uint256 collateralToSeize;
        uint16 bucket;
        bool optIn;
    }

    function CONTROLLER() external view returns (address);

    function MARKET_ID() external view returns (Id);

    function syncBorrower(address borrower, uint16 bucket, bool active) external;

    function syncBorrowerState(address borrower, uint256 borrowAssets, uint256 rawCollateral)
        external
        returns (bool active, uint16 bucket);

    function refreshBorrower(address borrower) external returns (bool active, uint16 bucket);

    function refreshBorrowers(address[] calldata borrowers) external;

    function setDeleverageOptInTargetRisk(uint256 targetRiskWad) external;

    function deleverageOptInTargetRisk(address borrower) external view returns (uint256);

    function previewDeleverageCuts(uint256 targetDebtAssets, uint256 maxBorrowers, uint256 maxScans, uint256 minDebtCut)
        external
        view
        returns (DeleverageCut[] memory cuts, uint256 coveredDebtAssets, uint256 scannedBorrowers);
}
