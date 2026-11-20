// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {TrailingAnchorOracleBase} from "./TrailingAnchorOracleBase.sol";

/// @title LidoLendTrailingAnchorOracleAdapter
/// @author Lido
/// @notice Forwards the manager calls of the Easy Track EVMScriptExecutor to the Trailing Anchor Oracles. Each oracle
///         that Easy Track manages grants `MANAGER_ROLE` to this adapter. The Easy Track permissions name the adapter,
///         so a new oracle needs no new permission.
/// @dev The oracle checks the role, so the adapter can change only an oracle that granted it the role.
contract LidoLendTrailingAnchorOracleAdapter {
    /// @notice The only caller of the adapter.
    address public immutable EVM_SCRIPT_EXECUTOR;

    error ZeroAddress();
    error Unauthorized(address caller);

    modifier onlyEvmScriptExecutor() {
        if (msg.sender != EVM_SCRIPT_EXECUTOR) revert Unauthorized(msg.sender);
        _;
    }

    /// @param evmScriptExecutor The Easy Track EVMScriptExecutor.
    constructor(address evmScriptExecutor) {
        if (evmScriptExecutor == address(0)) revert ZeroAddress();
        EVM_SCRIPT_EXECUTOR = evmScriptExecutor;
    }

    /// @notice Sets the parameters of an oracle.
    /// @param oracle     The Trailing Anchor Oracle.
    /// @param parameters The new parameters of the oracle.
    function setParameters(address oracle, TrailingAnchorOracleBase.Parameters calldata parameters)
        external
        onlyEvmScriptExecutor
    {
        TrailingAnchorOracleBase(oracle).setParameters(parameters);
    }

    /// @notice Sets the time at which the pricing of an oracle resumes.
    /// @param oracle    The Trailing Anchor Oracle.
    /// @param resumesAt The time at which pricing resumes.
    function setPricingResumesAt(address oracle, uint40 resumesAt) external onlyEvmScriptExecutor {
        TrailingAnchorOracleBase(oracle).setPricingResumesAt(resumesAt);
    }
}
