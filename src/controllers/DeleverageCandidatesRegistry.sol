// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Id, IMorphoStaticTyping} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/src/interfaces/IOracle.sol";
import "@morpho-blue/src/libraries/ConstantsLib.sol";
import {MathLib, WAD} from "@morpho-blue/src/libraries/MathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IDeleverageCandidatesRegistry} from "../interfaces/IDeleverageCandidatesRegistry.sol";
import {IMarketController} from "../interfaces/IMarketController.sol";

interface IDeleverageCandidatesController {
    function MARKET() external view returns (address);

    function MARKET_ID() external view returns (Id);

    function deleverageBucketConfig(Id id) external view returns (IMarketController.DeleverageBucketConfig memory);

    function previewDeleverageBucket(Id id, address borrower)
        external
        view
        returns (
            uint256 riskWad,
            uint16 bucket,
            bool eligible,
            uint256 maxDebtAssetsToCancel,
            uint256 maxCollateralToSeize
        );
}

/// @title DeleverageCandidatesRegistry
/// @notice Borrower candidate registry for deleverage.
/// @dev The controller still validates every deleverage execution. This registry only helps build calldata.
contract DeleverageCandidatesRegistry is IDeleverageCandidatesRegistry {
    using MathLib for uint256;

    struct CandidateSlot {
        uint16 bucket;
        uint32 slotPlusOne;
    }

    error Unauthorized();
    error ZeroAddress();
    error TargetRiskOutOfBounds();
    error BucketOutOfBounds();
    error BucketFull();

    event DeleverageCandidateUpdated(address indexed borrower, uint16 bucket, bool active);
    event DeleverageOptInTargetRiskSet(address indexed borrower, uint256 targetRiskWad);

    uint16 internal constant MAX_BUCKETS = 200;

    address public immutable CONTROLLER;
    Id public immutable MARKET_ID;

    uint256 public nonEmptyBucketBitmap;
    mapping(uint16 bucket => address[] borrowers) internal _bucketBorrowers;
    mapping(address borrower => CandidateSlot slot) internal _candidateSlots;
    mapping(address borrower => uint256 targetRiskWad) public override deleverageOptInTargetRisk;

    modifier onlyController() {
        if (msg.sender != CONTROLLER) revert Unauthorized();
        _;
    }

    constructor(address controller) {
        if (controller == address(0)) revert ZeroAddress();
        CONTROLLER = controller;
        MARKET_ID = IDeleverageCandidatesController(controller).MARKET_ID();
    }

    function bucketBorrowers(uint16 bucket) external view returns (address[] memory) {
        return _bucketBorrowers[bucket];
    }

    function borrowerBucket(address borrower) external view returns (uint16 bucket, bool active) {
        CandidateSlot memory slot = _candidateSlots[borrower];
        return (slot.bucket, slot.slotPlusOne != 0);
    }

    function syncBorrower(address borrower, uint16 bucket, bool active) external override onlyController {
        _syncBorrower(borrower, bucket, active);
    }

    function syncBorrowerState(address borrower, uint256 borrowAssets, uint256 rawCollateral)
        external
        override
        onlyController
        returns (bool active, uint16 bucket)
    {
        return _syncBorrowerState(borrower, borrowAssets, rawCollateral);
    }

    function refreshBorrower(address borrower) public override returns (bool active, uint16 bucket) {
        if (borrower == address(0)) revert ZeroAddress();

        IDeleverageCandidatesController controller = IDeleverageCandidatesController(CONTROLLER);
        (, uint128 borrowShares,) = IMorphoStaticTyping(controller.MARKET()).position(MARKET_ID, borrower);
        if (borrowShares == 0) {
            _syncBorrower(borrower, 0, false);
            return (false, 0);
        }

        (uint256 riskWad, uint16 liveBucket,,,) = controller.previewDeleverageBucket(MARKET_ID, borrower);
        if (riskWad >= WAD) {
            _syncBorrower(borrower, 0, false);
            return (false, 0);
        }

        _syncBorrower(borrower, liveBucket, true);
        return (true, liveBucket);
    }

    function refreshBorrowers(address[] calldata borrowers) external override {
        for (uint256 i = 0; i < borrowers.length; ++i) {
            refreshBorrower(borrowers[i]);
        }
    }

    function setDeleverageOptInTargetRisk(uint256 targetRiskWad) external override {
        if (targetRiskWad >= WAD) revert TargetRiskOutOfBounds();

        uint256 oldTarget = deleverageOptInTargetRisk[msg.sender];
        if (oldTarget == targetRiskWad) return;

        deleverageOptInTargetRisk[msg.sender] = targetRiskWad;
        emit DeleverageOptInTargetRiskSet(msg.sender, targetRiskWad);
    }

    function previewDeleverageCuts(uint256 targetDebtAssets, uint256 maxBorrowers, uint256 maxScans, uint256 minDebtCut)
        external
        view
        override
        returns (DeleverageCut[] memory cuts, uint256 coveredDebtAssets, uint256 scannedBorrowers)
    {
        cuts = new DeleverageCut[](maxBorrowers);
        if (targetDebtAssets == 0 || maxBorrowers == 0 || maxScans == 0) return (cuts, 0, 0);

        IDeleverageCandidatesController controller = IDeleverageCandidatesController(CONTROLLER);
        uint256 bitmap = nonEmptyBucketBitmap;
        uint256 remaining = targetDebtAssets;
        uint256 count;

        while (bitmap != 0 && remaining != 0 && count < maxBorrowers && scannedBorrowers < maxScans) {
            uint16 bucket = _highestSetBucket(bitmap);
            address[] storage borrowers = _bucketBorrowers[bucket];

            for (uint256 i = 0; i < borrowers.length && remaining != 0 && count < maxBorrowers; ++i) {
                if (scannedBorrowers == maxScans) break;
                ++scannedBorrowers;

                address borrower = borrowers[i];
                (, uint16 liveBucket, bool eligible, uint256 maxDebt, uint256 maxCollateral) =
                    controller.previewDeleverageBucket(MARKET_ID, borrower);
                if (!eligible || maxDebt == 0) continue;
                if (maxDebt < minDebtCut && maxDebt < remaining) continue;

                uint256 debt = maxDebt < remaining ? maxDebt : remaining;
                cuts[count] = DeleverageCut({
                    borrower: borrower,
                    debtAssetsToCancel: debt,
                    collateralToSeize: _collateralForDebt(debt, maxDebt, maxCollateral),
                    bucket: liveBucket,
                    optIn: deleverageOptInTargetRisk[borrower] != 0
                });
                coveredDebtAssets += debt;
                remaining -= debt;
                ++count;
            }

            bitmap &= ~(uint256(1) << bucket);
        }
    }

    function _highestSetBucket(uint256 bitmap) internal pure returns (uint16) {
        // casting to `uint16` is safe because the registry never sets buckets >= MAX_BUCKETS.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(Math.log2(bitmap));
    }

    function _syncBorrowerState(address borrower, uint256 borrowAssets, uint256 rawCollateral)
        internal
        returns (bool active, uint16 bucket)
    {
        if (borrowAssets == 0 || rawCollateral == 0) {
            _syncBorrower(borrower, 0, false);
            return (false, 0);
        }

        IDeleverageCandidatesController controller = IDeleverageCandidatesController(CONTROLLER);
        IMarketController.DeleverageBucketConfig memory cfg = controller.deleverageBucketConfig(MARKET_ID);
        (,, address oracle,, uint256 lltv) = IMorphoStaticTyping(controller.MARKET()).idToMarketParams(MARKET_ID);
        uint256 riskWad = _riskWad(borrowAssets, rawCollateral, IOracle(oracle).price(), lltv);
        if (riskWad >= WAD) {
            _syncBorrower(borrower, 0, false);
            return (false, 0);
        }

        bucket = _riskBucket(riskWad, cfg.bucketCount);
        _syncBorrower(borrower, bucket, true);
        return (true, bucket);
    }

    function _riskWad(uint256 borrowed, uint256 collateral, uint256 price, uint256 lltv)
        internal
        pure
        returns (uint256)
    {
        uint256 collateralValue = collateral.mulDivDown(price, ORACLE_PRICE_SCALE);
        if (collateralValue == 0) return type(uint256).max;
        uint256 maxBorrow = collateralValue.wMulDown(lltv);
        if (maxBorrow == 0) return type(uint256).max;
        return borrowed.wDivUp(maxBorrow);
    }

    function _riskBucket(uint256 riskWad, uint16 bucketCount) internal pure returns (uint16) {
        if (riskWad >= WAD) return bucketCount - 1;
        // casting to `uint16` is safe because bucketCount is bounded by controller config.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16((riskWad * bucketCount) / WAD);
    }

    function _collateralForDebt(uint256 debt, uint256 maxDebt, uint256 maxCollateral) internal pure returns (uint256) {
        if (debt == maxDebt) return maxCollateral;
        return debt.mulDivDown(maxCollateral, maxDebt);
    }

    function _syncBorrower(address borrower, uint16 bucket, bool active) internal {
        if (borrower == address(0)) revert ZeroAddress();
        if (!active) {
            _remove(borrower);
            emit DeleverageCandidateUpdated(borrower, 0, false);
            return;
        }
        if (bucket >= MAX_BUCKETS) revert BucketOutOfBounds();

        CandidateSlot memory current = _candidateSlots[borrower];
        if (current.slotPlusOne != 0 && current.bucket == bucket) return;
        if (current.slotPlusOne != 0) _remove(borrower);

        address[] storage borrowers = _bucketBorrowers[bucket];
        if (borrowers.length >= type(uint32).max) revert BucketFull();
        borrowers.push(borrower);
        _candidateSlots[borrower] = CandidateSlot({bucket: bucket, slotPlusOne: uint32(borrowers.length)});
        nonEmptyBucketBitmap |= uint256(1) << bucket;

        emit DeleverageCandidateUpdated(borrower, bucket, true);
    }

    function _remove(address borrower) internal {
        CandidateSlot memory slot = _candidateSlots[borrower];
        if (slot.slotPlusOne == 0) return;

        uint16 bucket = slot.bucket;
        address[] storage borrowers = _bucketBorrowers[bucket];
        uint256 removeOffset = uint256(slot.slotPlusOne) - 1;
        uint256 lastOffset = borrowers.length - 1;

        if (removeOffset != lastOffset) {
            address moved = borrowers[lastOffset];
            borrowers[removeOffset] = moved;
            // casting to `uint32` is safe because bucket length is capped before insert.
            // forge-lint: disable-next-line(unsafe-typecast)
            _candidateSlots[moved].slotPlusOne = uint32(removeOffset + 1);
        }
        borrowers.pop();
        if (borrowers.length == 0) nonEmptyBucketBitmap &= ~(uint256(1) << bucket);

        delete _candidateSlots[borrower];
    }
}
