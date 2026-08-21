// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {Vm} from "forge-std/Vm.sol";

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {LidoLendMarketFactory} from "../../src/periphery/LidoLendMarketFactory.sol";
import {BPS} from "../../src/libs/Constants.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {ConfigToml} from "./ConfigToml.sol";
import {GuardianSignalsConfigFile} from "./GuardianSignalsConfigFile.sol";
import {OracleConfigFile} from "./OracleConfigFile.sol";

library MarketConfigFile {
    using SafeCast for uint256;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    int256 private constant WAD_INT = 1 ether;
    int256 private constant MAX_CURVE_STEEPNESS = 100 ether;
    int256 private constant MAX_ADJUSTMENT_SPEED = 10_000 ether / int256(365 days);
    int256 private constant MAX_RATE_AT_TARGET = 10_000 ether / int256(365 days);
    uint256 private constant MAX_BORROW_RATE = (10_000 ether / uint256(365 days)) * 100;

    error InvalidConfigValue(string key);

    struct ArtifactRefs {
        string oracle;
        string guardianGroup;
    }

    /// @dev Resolves zero oracle and guardian addresses from run artifacts.
    function read(string memory name)
        internal
        view
        returns (
            LidoLendMarketFactory.MarketSpec memory market,
            LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec,
            AdaptiveCurveParams memory curveParams
        )
    {
        string memory toml = vm.readFile(marketPath(name));
        (market, erc4626WrapperSpec, curveParams) = parse(toml);
        ArtifactRefs memory refs = _parseArtifactRefs(toml);

        if (market.oracle == address(0)) market.oracle = OracleConfigFile.readDeployed(refs.oracle);
        if (market.oracle == address(0)) revert ConfigToml.MissingConfigValue(".market.oracle");

        if (market.guardianSignals == address(0)) {
            market.guardianSignals = GuardianSignalsConfigFile.readDeployed(refs.guardianGroup);
        }
    }

    function parse(string memory toml)
        internal
        pure
        returns (
            LidoLendMarketFactory.MarketSpec memory market,
            LidoLendMarketFactory.ERC4626WrapperSpec memory erc4626WrapperSpec,
            AdaptiveCurveParams memory curveParams
        )
    {
        market = _parseMarket(toml);
        erc4626WrapperSpec = LidoLendMarketFactory.ERC4626WrapperSpec({
            name: vm.parseTomlString(toml, ".market.vault_name"),
            symbol: vm.parseTomlString(toml, ".market.vault_symbol")
        });
        curveParams = _parseCurve(toml);
    }

    function marketPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/markets/", name, ".toml");
    }

    function guardianGroup(string memory name) internal view returns (string memory) {
        return _parseArtifactRefs(vm.readFile(marketPath(name))).guardianGroup;
    }

    function oracleArtifact(string memory name) internal view returns (string memory) {
        return _parseArtifactRefs(vm.readFile(marketPath(name))).oracle;
    }

    /// @notice The part this market plays in a deployment, e.g. `"weth-wsteth"`. Markets on different networks
    ///         share a role, so a consumer can name what it needs without naming a network's market.
    function role(string memory name) internal view returns (string memory) {
        return ConfigToml.requireString(vm.readFile(marketPath(name)), ".market.role");
    }

    function _parseArtifactRefs(string memory toml) private view returns (ArtifactRefs memory) {
        return ArtifactRefs({
            oracle: ConfigToml.requireString(toml, ".market.oracle_artifact"),
            guardianGroup: ConfigToml.requireString(toml, ".market.guardian_group")
        });
    }

    function _parseMarket(string memory toml) private pure returns (LidoLendMarketFactory.MarketSpec memory) {
        return LidoLendMarketFactory.MarketSpec({
            loanToken: ConfigToml.requireAddress(toml, ".market.loan_token"),
            collateralToken: ConfigToml.requireAddress(toml, ".market.collateral_token"),
            oracle: vm.parseTomlAddress(toml, ".market.oracle"),
            lltv: vm.parseTomlUint(toml, ".market.lltv"),
            guardianSignals: vm.parseTomlAddress(toml, ".market.guardian_signals"),
            activationConfig: _parseActivation(toml),
            settlementConfig: _parseSettlement(toml)
        });
    }

    function _parseActivation(string memory toml) private pure returns (CollateralActivationConfig memory) {
        return CollateralActivationConfig({
            minActivationDelay: _uint40(toml, ".activation.min_activation_delay"),
            maxActivationDelay: _uint40(toml, ".activation.max_activation_delay"),
            maxDelayInflow: _uint128(toml, ".activation.max_delay_inflow"),
            activatingLockDuration: _uint40(toml, ".activation.activating_lock_duration"),
            minActivationAmount: _uint128(toml, ".activation.min_activation_amount"),
            minDepositAmount: _uint128(toml, ".activation.min_deposit_amount"),
            maxGuardiansQuorumDelay: _uint40(toml, ".activation.max_guardians_quorum_delay"),
            delayPerStrike: _uint40(toml, ".activation.delay_per_strike"),
            delayPerSuspect: _uint40(toml, ".activation.delay_per_suspect")
        });
    }

    function _parseSettlement(string memory toml) private pure returns (SettlementConfig memory) {
        uint256 sliceFloorBps = vm.parseTomlUint(toml, ".settlement.slice_floor_bps");
        if (sliceFloorBps > BPS) revert InvalidConfigValue(".settlement.slice_floor_bps");
        uint256 ltvStepBps = vm.parseTomlUint(toml, ".settlement.ltv_step_bps");
        if (ltvStepBps > BPS) revert InvalidConfigValue(".settlement.ltv_step_bps");

        return SettlementConfig({
            sliceFloorBps: sliceFloorBps.toUint16(),
            sliceFloorAssets: _uint96(toml, ".settlement.slice_floor_assets"),
            fullCutBelowCollateral: _uint96(toml, ".settlement.full_cut_below_collateral"),
            ltvStepBps: ltvStepBps.toUint16()
        });
    }

    function _uint40(string memory toml, string memory key) private pure returns (uint40) {
        uint256 value = vm.parseTomlUint(toml, key);
        if (value > type(uint40).max) revert InvalidConfigValue(key);
        return value.toUint40();
    }

    function _uint96(string memory toml, string memory key) private pure returns (uint96) {
        uint256 value = vm.parseTomlUint(toml, key);
        if (value > type(uint96).max) revert InvalidConfigValue(key);
        return value.toUint96();
    }

    function _uint128(string memory toml, string memory key) private pure returns (uint128) {
        uint256 value = vm.parseTomlUint(toml, key);
        if (value > type(uint128).max) revert InvalidConfigValue(key);
        return value.toUint128();
    }

    function _parseCurve(string memory toml) private pure returns (AdaptiveCurveParams memory params) {
        params = AdaptiveCurveParams({
            curveSteepness: vm.parseTomlInt(toml, ".curve.curve_steepness"),
            adjustmentSpeed: vm.parseTomlInt(toml, ".curve.adjustment_speed"),
            targetUtilization: vm.parseTomlInt(toml, ".curve.target_utilization"),
            initialRateAtTarget: vm.parseTomlInt(toml, ".curve.initial_rate_at_target"),
            minRateAtTarget: vm.parseTomlInt(toml, ".curve.min_rate_at_target"),
            maxRateAtTarget: vm.parseTomlInt(toml, ".curve.max_rate_at_target"),
            maxBorrowRate: vm.parseTomlUint(toml, ".curve.max_borrow_rate")
        });

        if (params.curveSteepness < WAD_INT || params.curveSteepness > MAX_CURVE_STEEPNESS) {
            revert InvalidConfigValue(".curve.curve_steepness");
        }
        if (params.adjustmentSpeed < 0 || params.adjustmentSpeed > MAX_ADJUSTMENT_SPEED) {
            revert InvalidConfigValue(".curve.adjustment_speed");
        }
        if (params.targetUtilization <= 0 || params.targetUtilization >= WAD_INT) {
            revert InvalidConfigValue(".curve.target_utilization");
        }
        if (params.minRateAtTarget <= 0 || params.maxRateAtTarget < params.minRateAtTarget) {
            revert InvalidConfigValue(".curve.rate_bounds");
        }
        if (params.maxRateAtTarget > MAX_RATE_AT_TARGET) revert InvalidConfigValue(".curve.max_rate_at_target");
        if (params.initialRateAtTarget < params.minRateAtTarget || params.initialRateAtTarget > params.maxRateAtTarget) revert InvalidConfigValue(".curve.initial_rate_at_target");
        if (params.maxBorrowRate > MAX_BORROW_RATE) revert InvalidConfigValue(".curve.max_borrow_rate");
    }
}
