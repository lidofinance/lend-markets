// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {CallsScriptBuilder} from "./CallsScriptBuilder.sol";

interface IVoting {
    function getVote(uint256 voteId)
        external
        view
        returns (
            bool open,
            bool executed,
            uint64 startDate,
            uint64 snapshotBlock,
            uint64 supportRequired,
            uint64 minAcceptQuorum,
            uint256 yea,
            uint256 nay,
            uint256 votingPower,
            bytes memory script,
            uint8 phase
        );
}

/// @notice Base for on-chain vote descriptions: a concrete omnibus lists its items, and anyone can rebuild
///         the exact EVM script and check a live vote against it before voting.
abstract contract OmnibusBase {
    using CallsScriptBuilder for CallsScriptBuilder.Context;

    struct ScriptCall {
        address to;
        bytes data;
    }

    struct VoteItem {
        string description;
        ScriptCall call;
    }

    IVoting private immutable VOTING;

    constructor(address voting) {
        VOTING = IVoting(voting);
    }

    function getVoteItems() public view virtual returns (VoteItem[] memory);

    function getEVMScript() public view returns (bytes memory) {
        CallsScriptBuilder.Context memory scriptBuilder = CallsScriptBuilder.create();
        VoteItem[] memory voteItems = getVoteItems();
        for (uint256 i = 0; i < voteItems.length; ++i) {
            scriptBuilder.addCall(voteItems[i].call.to, voteItems[i].call.data);
        }
        return scriptBuilder.getResult();
    }

    function isValidVoteScript(uint256 voteId) external view returns (bool) {
        (,,,,,,,,, bytes memory script,) = VOTING.getVote(voteId);
        return keccak256(script) == keccak256(getEVMScript());
    }

    function _votingCall(address target, bytes memory data) internal pure returns (ScriptCall memory) {
        return ScriptCall(target, data);
    }
}
