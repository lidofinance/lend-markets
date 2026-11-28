// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

// An oracle whose price reverts while down is set, so a rule can take the oracle offline.
contract RevertingOracleMock is IOracle {
    bool public down;
    uint256 public quote;

    error OracleDown();

    function price() external view returns (uint256) {
        if (down) revert OracleDown();
        return quote;
    }
}
