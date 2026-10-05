// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Builds an Aragon CallsScript: the spec id followed by packed `(target, calldataLength, calldata)`
///         entries. The format the Aragon Voting contract executes on enactment.
library CallsScriptBuilder {
    bytes4 internal constant SPEC_ID = 0x00000001;

    struct Context {
        bytes result;
    }

    function create() internal pure returns (Context memory context) {
        context.result = bytes.concat(SPEC_ID);
    }

    function create(address target, bytes memory data) internal pure returns (Context memory context) {
        context = addCall(create(), target, data);
    }

    function addCall(Context memory self, address target, bytes memory data) internal pure returns (Context memory) {
        self.result = bytes.concat(self.result, bytes20(target), bytes4(uint32(data.length)), data);
        return self;
    }

    function getResult(Context memory self) internal pure returns (bytes memory) {
        return self.result;
    }
}
