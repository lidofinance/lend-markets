// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";

import {MorphoExitBook} from "../../src/periphery/MorphoExitBook.sol";

// Exposes the Dutch-auction rate and share quote, otherwise observable only inside a fill or placement.
contract MorphoExitBookHarness is MorphoExitBook {
    constructor(address morpho, address admin, uint256 maxLifetime_)
        MorphoExitBook(morpho, admin, maxLifetime_)
    {}

    function priorityFeeRateExt(uint256 id) external view returns (uint256) {
        return _priorityFeeRate(_book.requests[id]);
    }

    function supplyAssetsToSharesExt(Id marketId, uint256 assets) external view returns (uint256) {
        return _supplyAssetsToShares(_marketParams[marketId], assets);
    }
}
