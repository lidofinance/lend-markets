// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {ORACLE_PRICE_SCALE} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {SharesMathLib} from "@lido-lend/src/libraries/SharesMathLib.sol";
import {SettlementQueueLib} from "../../src/libs/SettlementQueueLib.sol";
import {MarketView, PositionView, SettlementConfig} from "../../src/types/SettlementTypes.sol";

// SettlementQueueLib alone, with identity borrow-share and oracle conversions so rules name loan-asset values.
contract SettlementSliceHarness {
    using SettlementQueueLib for SettlementQueueLib.State;

    // With totalBorrowShares at zero, this makes toAssetsUp the identity.
    uint256 private constant IDENTITY_TOTAL_BORROW_ASSETS = SharesMathLib.VIRTUAL_SHARES - SharesMathLib.VIRTUAL_ASSETS;

    SettlementQueueLib.State internal _queue;

    constructor() {
        _queue.init();
    }

    function setSettlementConfig(SettlementConfig memory config) external {
        _queue.setSettlementConfig(config);
    }

    function setSettlementLtv(address borrower, uint256 ltv) external {
        _queue.setSettlementLtv(borrower, ltv);
    }

    function sync(address borrower, PositionView memory position) external {
        _queue.sync(borrower, position);
    }

    function queueSize() external view returns (uint256) {
        return _queue.size();
    }

    function queueSlotOf(address borrower) external view returns (uint256) {
        return _queue.heap.slot[borrower];
    }

    function peekRoot() external view returns (address) {
        return _queue.peekRoot();
    }

    function settlementLtvOf(address borrower) external view returns (uint256) {
        return _queue.settlementLtvOf(borrower);
    }

    // The larger of allowedSliceAssets' two slices, as the controller takes it.
    function allowedSliceAtValues(address borrower, uint256 debtAssets, uint256 collateralValue)
        external
        view
        returns (uint256)
    {
        PositionView memory position = PositionView({borrowShares: debtAssets, collateral: collateralValue});
        (uint256 personalSliceAssets, uint256 queueRootSliceAssets) =
            _queue.allowedSliceAssets(_identityMarketView(), borrower, position);
        return personalSliceAssets > queueRootSliceAssets ? personalSliceAssets : queueRootSliceAssets;
    }

    function sliceToLtv(uint256 debtAssets, uint256 collateralValue, uint256 targetLtv)
        external
        pure
        returns (uint256)
    {
        return SettlementQueueLib.sliceToLtv(debtAssets, collateralValue, targetLtv);
    }

    function _identityMarketView() private pure returns (MarketView memory) {
        return MarketView({
            totalSupplyAssets: 0,
            totalSupplyShares: 0,
            totalBorrowAssets: IDENTITY_TOTAL_BORROW_ASSETS,
            totalBorrowShares: 0,
            price: ORACLE_PRICE_SCALE,
            lltv: 0
        });
    }
}
