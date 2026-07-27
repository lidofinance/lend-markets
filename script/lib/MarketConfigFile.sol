// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ConfigToml} from "./ConfigToml.sol";
import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";
import {LinearKinkParams} from "@lido-lend-irm/src/linear-kink-irm/interfaces/ILinearKinkTypes.sol";

import {LidoLendMarketBuilder, MarketRoles} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {BPS} from "../../src/libs/Constants.sol";
import {OracleConfigFile} from "./OracleConfigFile.sol";
import {GuardianSignalsConfigFile} from "./GuardianSignalsConfigFile.sol";
import {CircuitBreakerConfigFile} from "./CircuitBreakerConfigFile.sol";
import {IrmConfigFile} from "./IrmConfigFile.sol";

/// @notice The IRM a market is routed to at activation, with the params for that model — the two travel
///         together, so a config can never name one model and carry the other's params.
/// @param artifact The `market.irm_artifact` reference: `IrmConfigFile.ADAPTIVE_CURVE` for the backbone
///        instance in `protocol.toml`, otherwise an `irms/<name>.toml` artifact in the run.
/// @param kinked True when `artifact` names a `LinearKinkIrm`, i.e. `kink` is set and `curve` is unset.
/// @param curve The adaptive-curve params, set when `!kinked`.
/// @param kink The linear-kink params, set when `kinked`.
struct IrmSelection {
    string artifact;
    bool kinked;
    AdaptiveCurveParams curve;
    LinearKinkParams kink;
}

library MarketConfigFile {
    using SafeCast for uint256;

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    int256 private constant WAD_INT = 1 ether;
    int256 private constant MAX_CURVE_STEEPNESS = 100 ether;
    int256 private constant MAX_ADJUSTMENT_SPEED = 10_000 ether / int256(365 days);
    int256 private constant MAX_RATE_AT_TARGET = 10_000 ether / int256(365 days);
    uint256 private constant MAX_BORROW_RATE = (10_000 ether / uint256(365 days)) * 100;
    /// @dev `LinearKinkIrm.MAX_BORROW_RATE` — 800%/year, per second, WAD-scaled.
    uint256 private constant MAX_KINK_BORROW_RATE = 8.0 ether / uint256(365 days);

    error InvalidConfigValue(string key);

    struct ArtifactRefs {
        string oracle;
        string guardianGroup;
        string circuitBreaker;
        string irm;
    }

    /// @dev Resolves zero oracle and guardian addresses from run artifacts.
    function read(string memory name)
        internal
        view
        returns (
            address builder,
            LidoLendMarketBuilder.MarketSpec memory market,
            MarketRoles memory roles,
            IrmSelection memory irm
        )
    {
        string memory toml = vm.readFile(marketPath(name));
        builder = vm.parseTomlAddress(toml, ".builder");
        (market, roles, irm) = parse(toml);
        ArtifactRefs memory refs = _parseArtifactRefs(toml);

        if (market.oracle == address(0)) market.oracle = OracleConfigFile.readDeployed(refs.oracle);
        if (market.oracle == address(0)) revert ConfigToml.MissingConfigValue(".market.oracle");

        if (market.guardianSignals == address(0)) {
            market.guardianSignals = GuardianSignalsConfigFile.readDeployed(refs.guardianGroup);
        }

        address circuitBreaker = CircuitBreakerConfigFile.readDeployed(refs.circuitBreaker);
        if (circuitBreaker == address(0)) revert ConfigToml.MissingConfigValue(".market.circuit_breaker_artifact");
        roles.pausers = _prepend(circuitBreaker, roles.pausers);

        // The activation motion resolves the reference; catch a typo here, at deploy time, rather than there.
        // The backbone instance lives in `protocol.toml` and has no `irms/` artifact.
        if (irm.kinked && IrmConfigFile.readDeployed(irm.artifact) == address(0)) {
            revert ConfigToml.MissingConfigValue(".market.irm_artifact");
        }
    }

    function parse(string memory toml)
        internal
        view
        returns (LidoLendMarketBuilder.MarketSpec memory market, MarketRoles memory roles, IrmSelection memory irm)
    {
        market = _parseMarket(toml);
        roles = _parseRoles(toml);
        irm = _parseIrm(toml);
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

    function circuitBreakerArtifact(string memory name) internal view returns (string memory) {
        return _parseArtifactRefs(vm.readFile(marketPath(name))).circuitBreaker;
    }

    function irmArtifact(string memory name) internal view returns (string memory) {
        return _parseArtifactRefs(vm.readFile(marketPath(name))).irm;
    }

    function _parseArtifactRefs(string memory toml) private view returns (ArtifactRefs memory) {
        return ArtifactRefs({
            oracle: ConfigToml.requireString(toml, ".market.oracle_artifact"),
            guardianGroup: ConfigToml.requireString(toml, ".market.guardian_group"),
            circuitBreaker: ConfigToml.requireString(toml, ".market.circuit_breaker_artifact"),
            irm: _irmArtifactRef(toml)
        });
    }

    /// @dev `market.irm_artifact`, defaulting to the backbone adaptive-curve IRM when the key is absent — the
    ///      overwhelmingly common case, so an existing market config needs no new key to keep its behaviour.
    function _irmArtifactRef(string memory toml) private view returns (string memory) {
        if (!vm.keyExistsToml(toml, ".market.irm_artifact")) return IrmConfigFile.ADAPTIVE_CURVE;
        return ConfigToml.requireString(toml, ".market.irm_artifact");
    }

    function _prepend(address first, address[] memory values) private pure returns (address[] memory result) {
        result = new address[](values.length + 1);
        result[0] = first;
        for (uint256 i; i < values.length; ++i) {
            result[i + 1] = values[i];
        }
    }

    function _parseMarket(string memory toml) private pure returns (LidoLendMarketBuilder.MarketSpec memory) {
        return LidoLendMarketBuilder.MarketSpec({
            loanToken: ConfigToml.requireAddress(toml, ".market.loan_token"),
            collateralToken: ConfigToml.requireAddress(toml, ".market.collateral_token"),
            oracle: vm.parseTomlAddress(toml, ".market.oracle"),
            lltv: vm.parseTomlUint(toml, ".market.lltv"),
            guardianSignals: vm.parseTomlAddress(toml, ".market.guardian_signals"),
            activationConfig: _parseActivation(toml),
            settlementConfig: _parseSettlement(toml),
            vaultName: vm.parseTomlString(toml, ".market.vault_name"),
            vaultSymbol: vm.parseTomlString(toml, ".market.vault_symbol")
        });
    }

    function _parseActivation(string memory toml) private pure returns (CollateralActivationConfig memory) {
        return CollateralActivationConfig({
            minActivationDelay: _uint40(toml, ".activation.min_activation_delay"),
            maxActivationDelay: _uint40(toml, ".activation.max_activation_delay"),
            maxDelayInflow: _uint128(toml, ".activation.max_delay_inflow"),
            activatingLockAmount: _uint128(toml, ".activation.activating_lock_amount"),
            activatingLockDuration: _uint40(toml, ".activation.activating_lock_duration"),
            minActivationAmount: _uint128(toml, ".activation.min_activation_amount"),
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

    function _parseRoles(string memory toml) private pure returns (MarketRoles memory) {
        return MarketRoles({
            admin: ConfigToml.requireAddress(toml, ".roles.admin"),
            proxyAdmin: ConfigToml.requireAddress(toml, ".roles.proxy_admin"),
            managers: vm.parseTomlAddressArray(toml, ".roles.managers"),
            pausers: vm.parseTomlAddressArray(toml, ".roles.pausers"),
            freezers: vm.parseTomlAddressArray(toml, ".roles.freezers"),
            unfreezers: vm.parseTomlAddressArray(toml, ".roles.unfreezers"),
            resumers: vm.parseTomlAddressArray(toml, ".roles.resumers")
        });
    }

    /// @dev The market's IRM choice and the params for exactly that model. A kinked market must carry `[kink]`
    ///      and must NOT carry `[curve]` (and the reverse), so a config can never name one model and be
    ///      activated with the other's params.
    function _parseIrm(string memory toml) private view returns (IrmSelection memory irm) {
        irm.artifact = _irmArtifactRef(toml);
        irm.kinked = !IrmConfigFile.isAdaptiveCurve(irm.artifact);

        bool hasCurve = vm.keyExistsToml(toml, ".curve");
        bool hasKink = vm.keyExistsToml(toml, ".kink");
        if (irm.kinked) {
            if (!hasKink || hasCurve) revert InvalidConfigValue(".kink");
            irm.kink = _parseKink(toml);
        } else {
            if (!hasCurve || hasKink) revert InvalidConfigValue(".curve");
            irm.curve = _parseCurve(toml);
        }
    }

    /// @dev Linear-kink params. Rates are per-second WAD and pack into `uint64`; the model's own setter caps the
    ///      peak (`baseRate + slope1 + slope2`), so validate only what narrowing would silently corrupt.
    function _parseKink(string memory toml) private pure returns (LinearKinkParams memory params) {
        params = LinearKinkParams({
            optimalUtilization: _uint64(toml, ".kink.optimal_utilization"),
            baseRate: _uint64(toml, ".kink.base_rate"),
            slope1: _uint64(toml, ".kink.slope1"),
            slope2: _uint64(toml, ".kink.slope2")
        });

        // Mirrors `LinearKinkIrm.setMarketKinkParams`: zero marks an unset market, WAD is full utilization.
        if (params.optimalUtilization == 0 || params.optimalUtilization >= uint256(WAD_INT)) {
            revert InvalidConfigValue(".kink.optimal_utilization");
        }
        if (uint256(params.baseRate) + params.slope1 + params.slope2 > MAX_KINK_BORROW_RATE) {
            revert InvalidConfigValue(".kink.peak_rate");
        }
    }

    function _uint64(string memory toml, string memory key) private pure returns (uint64) {
        uint256 value = vm.parseTomlUint(toml, key);
        if (value > type(uint64).max) revert InvalidConfigValue(key);
        return value.toUint64();
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
