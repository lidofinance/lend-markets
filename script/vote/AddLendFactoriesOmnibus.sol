// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {OmnibusBase} from "./OmnibusBase.sol";

interface IEasyTrack {
    function addEVMScriptFactory(address evmScriptFactory, bytes calldata permissions) external;
}

/// @notice The Aragon vote that wires the Lend EasyTrack motion factories: one `addEVMScriptFactory`
///         item per factory, each bounded to exactly its `(target, selector)` permissions. Every item is
///         a plain Voting call — the Agent is not involved, so no Dual Governance proposal is created.
contract AddLendFactoriesOmnibus is OmnibusBase {
    error ArrayLengthMismatch();
    error NoFactories();

    address public immutable EASY_TRACK;

    address[] private _factories;
    bytes[] private _permissions;
    string[] private _descriptions;

    constructor(
        address voting,
        address easyTrack,
        address[] memory factories,
        bytes[] memory permissions,
        string[] memory descriptions
    ) OmnibusBase(voting) {
        if (factories.length != permissions.length) revert ArrayLengthMismatch();
        if (factories.length != descriptions.length) revert ArrayLengthMismatch();
        if (factories.length == 0) revert NoFactories();
        EASY_TRACK = easyTrack;
        _factories = factories;
        _permissions = permissions;
        _descriptions = descriptions;
    }

    function getVoteItems() public view override returns (VoteItem[] memory voteItems) {
        voteItems = new VoteItem[](_factories.length);
        for (uint256 i = 0; i < _factories.length; ++i) {
            voteItems[i] = VoteItem({
                description: _descriptions[i],
                call: _votingCall(
                    EASY_TRACK, abi.encodeCall(IEasyTrack.addEVMScriptFactory, (_factories[i], _permissions[i]))
                )
            });
        }
    }
}
