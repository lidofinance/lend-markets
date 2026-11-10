// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Erc4626ExitBook} from "../../src/periphery/Erc4626ExitBook.sol";

// Exposes the internal Dutch-auction rate, otherwise observable only inside a fill.
contract Erc4626ExitBookHarness is Erc4626ExitBook {
    constructor(address owner, uint256 maxLifetime_) Erc4626ExitBook(owner, maxLifetime_) {}

    function priorityFeeRateExt(uint256 id) external view returns (uint256) {
        return _priorityFeeRate(_book.requests[id]);
    }
}
