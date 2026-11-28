/* ──── MUTATION IrmConfigFactory #3011 ────────────────────────────────────────────
 * @desc:   Reads the adaptive registry in the linear kink view getter.
 * @rules:  utIcfGetLinearConfigMatchesTheRegistry
 * @conf:   certora/confs/IrmConfigFactory/properties.conf
 * @target: lib/lend-irm/src/irm-config-factory/IrmConfigFactory.sol
 * Was:     return _linearKinkConfigByParamsHash[keccak256(abi.encode(params))];
 * Now:     return _adaptiveCurveConfigByParamsHash[keccak256(abi.encode(params))];
 * ────────────────────────────────────────────────────────────────────*/

// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IIrmConfigFactory} from "./interfaces/IIrmConfigFactory.sol";
import {AdaptiveCurveConfig} from "../adaptive-curve-irm/AdaptiveCurveConfig.sol";
import {AdaptiveCurveParams} from "../adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {LinearKinkConfig} from "../linear-kink-irm/LinearKinkConfig.sol";
import {LinearKinkParams} from "../linear-kink-irm/interfaces/ILinearKinkTypes.sol";

/// @title IrmConfigFactory
/// @author Lido.
/// @notice Permissionless factory that returns an existing immutable IRM config for a parameter set or deploys one
/// if absent.
contract IrmConfigFactory is IIrmConfigFactory {
    mapping(bytes32 paramsHash => address config) private _adaptiveCurveConfigByParamsHash;

    mapping(bytes32 paramsHash => address config) private _linearKinkConfigByParamsHash;

    /// @inheritdoc IIrmConfigFactory
    function getAdaptiveCurveConfig(AdaptiveCurveParams calldata params) external view returns (address config) {
        return _adaptiveCurveConfigByParamsHash[keccak256(abi.encode(params))];
    }

    /// @inheritdoc IIrmConfigFactory
    function getLinearKinkConfig(LinearKinkParams calldata params) external view returns (address config) {
        return _adaptiveCurveConfigByParamsHash[keccak256(abi.encode(params))];
    }

    /// @inheritdoc IIrmConfigFactory
    function getOrDeployAdaptiveCurveConfig(AdaptiveCurveParams calldata params) external returns (address config) {
        bytes32 paramsHash = keccak256(abi.encode(params));
        config = _adaptiveCurveConfigByParamsHash[paramsHash];

        if (config == address(0)) {
            config = address(new AdaptiveCurveConfig(params));
            _adaptiveCurveConfigByParamsHash[paramsHash] = config;
            emit AdaptiveCurveConfigDeployed(paramsHash, config);
        }
    }

    /// @inheritdoc IIrmConfigFactory
    function getOrDeployLinearKinkConfig(LinearKinkParams calldata params) external returns (address config) {
        bytes32 paramsHash = keccak256(abi.encode(params));
        config = _linearKinkConfigByParamsHash[paramsHash];

        if (config == address(0)) {
            config = address(new LinearKinkConfig(params));
            _linearKinkConfigByParamsHash[paramsHash] = config;
            emit LinearKinkConfigDeployed(paramsHash, config);
        }
    }
}
