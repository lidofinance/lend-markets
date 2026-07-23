// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Vm} from "forge-std/Vm.sol";

import {ConfigToml} from "./ConfigToml.sol";
import {ArtifactMetadata} from "./ArtifactMetadata.sol";

import {AdaptiveCurveParams} from "@lido-lend-irm/src/adaptive-curve-irm/interfaces/IAdaptiveCurveTypes.sol";

import {LidoLendMarketBuilder, MarketRoles} from "../../src/periphery/LidoLendMarketBuilder.sol";
import {CollateralActivationConfig} from "../../src/types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../../src/types/SettlementTypes.sol";
import {OracleConfigFile} from "./OracleConfigFile.sol";
import {GuardianSignalsConfigFile} from "./GuardianSignalsConfigFile.sol";

/// @notice Reads a per-market config from `script/config/markets/<name>.toml`.
library MarketConfigFile {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct ArtifactRefs {
        string oracle;
        string guardianGroup;
    }

    /// @notice Read `script/config/markets/<name>.toml`, resolving the oracle and guardian from their
    ///         recorded artifacts when left zero. Reverts if no oracle can be resolved.
    function read(string memory name, ArtifactMetadata memory artifacts)
        internal
        view
        returns (
            address builder,
            LidoLendMarketBuilder.MarketSpec memory market,
            MarketRoles memory roles,
            AdaptiveCurveParams memory curveParams
        )
    {
        string memory toml = vm.readFile(marketPath(name));
        builder = vm.parseTomlAddress(toml, ".builder");
        (market, roles, curveParams) = parse(toml);
        ArtifactRefs memory refs = _parseArtifactRefs(toml);

        if (market.oracle == address(0)) market.oracle = OracleConfigFile.readDeployed(refs.oracle, artifacts);
        if (market.oracle == address(0)) revert ConfigToml.MissingConfigValue(".market.oracle");

        // A zero guardian is not an error: it still means "deploy a fresh per-market instance".
        if (market.guardianSignals == address(0)) {
            market.guardianSignals = GuardianSignalsConfigFile.readDeployed(refs.guardianGroup, artifacts);
        }
    }

    function parse(string memory toml)
        internal
        pure
        returns (
            LidoLendMarketBuilder.MarketSpec memory market,
            MarketRoles memory roles,
            AdaptiveCurveParams memory curveParams
        )
    {
        market = _parseMarket(toml);
        roles = _parseRoles(toml);
        curveParams = _parseCurve(toml);
    }

    function marketPath(string memory name) internal pure returns (string memory) {
        return string.concat("script/config/markets/", name, ".toml");
    }

    /// @notice Guardian deployment group selected by a market config.
    function guardianGroup(string memory name) internal view returns (string memory) {
        return _parseArtifactRefs(vm.readFile(marketPath(name))).guardianGroup;
    }

    /// @notice Oracle artifact selected by a market config.
    function oracleArtifact(string memory name) internal view returns (string memory) {
        return _parseArtifactRefs(vm.readFile(marketPath(name))).oracle;
    }

    function _parseArtifactRefs(string memory toml) private view returns (ArtifactRefs memory) {
        return ArtifactRefs({
            oracle: ConfigToml.requireString(toml, ".market.oracle_artifact"),
            guardianGroup: ConfigToml.requireString(toml, ".market.guardian_group")
        });
    }

    // ---
    // PRIVATE — one struct per helper to keep each frame under the `via_ir = false` stack limit
    // ---

    function _parseMarket(string memory toml) private pure returns (LidoLendMarketBuilder.MarketSpec memory) {
        return LidoLendMarketBuilder.MarketSpec({
            loanToken: ConfigToml.requireAddress(toml, ".market.loan_token"),
            collateralToken: ConfigToml.requireAddress(toml, ".market.collateral_token"),
            // Oracle and guardian may be zero here; `read` resolves them.
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
            minActivationDelay: uint40(vm.parseTomlUint(toml, ".activation.min_activation_delay")),
            maxActivationDelay: uint40(vm.parseTomlUint(toml, ".activation.max_activation_delay")),
            maxDelayInflow: uint128(vm.parseTomlUint(toml, ".activation.max_delay_inflow")),
            activatingLockAmount: uint128(vm.parseTomlUint(toml, ".activation.activating_lock_amount")),
            activatingLockDuration: uint40(vm.parseTomlUint(toml, ".activation.activating_lock_duration")),
            minActivationAmount: uint128(vm.parseTomlUint(toml, ".activation.min_activation_amount")),
            maxGuardiansQuorumDelay: uint40(vm.parseTomlUint(toml, ".activation.max_guardians_quorum_delay")),
            delayPerStrike: uint40(vm.parseTomlUint(toml, ".activation.delay_per_strike")),
            delayPerSuspect: uint40(vm.parseTomlUint(toml, ".activation.delay_per_suspect"))
        });
    }

    function _parseSettlement(string memory toml) private pure returns (SettlementConfig memory) {
        return SettlementConfig({
            sliceFloorBps: uint16(vm.parseTomlUint(toml, ".settlement.slice_floor_bps")),
            sliceFloorAssets: uint96(vm.parseTomlUint(toml, ".settlement.slice_floor_assets")),
            fullCutBelowCollateral: uint96(vm.parseTomlUint(toml, ".settlement.full_cut_below_collateral")),
            ltvStepBps: uint16(vm.parseTomlUint(toml, ".settlement.ltv_step_bps"))
        });
    }

    function _parseRoles(string memory toml) private pure returns (MarketRoles memory) {
        return MarketRoles({
            admin: ConfigToml.requireAddress(toml, ".roles.admin"),
            proxyAdmin: ConfigToml.requireAddress(toml, ".roles.proxy_admin"),
            managers: vm.parseTomlAddressArray(toml, ".roles.managers"),
            // `pausers` is not read from the market config: the CircuitBreaker is one instance for all markets
            // (deploy config), injected by the orchestrator.
            pausers: new address[](0),
            freezers: vm.parseTomlAddressArray(toml, ".roles.freezers"),
            unfreezers: vm.parseTomlAddressArray(toml, ".roles.unfreezers"),
            resumers: vm.parseTomlAddressArray(toml, ".roles.resumers")
        });
    }

    function _parseCurve(string memory toml) private pure returns (AdaptiveCurveParams memory) {
        return AdaptiveCurveParams({
            curveSteepness: vm.parseTomlInt(toml, ".curve.curve_steepness"),
            adjustmentSpeed: vm.parseTomlInt(toml, ".curve.adjustment_speed"),
            targetUtilization: vm.parseTomlInt(toml, ".curve.target_utilization"),
            initialRateAtTarget: vm.parseTomlInt(toml, ".curve.initial_rate_at_target"),
            minRateAtTarget: vm.parseTomlInt(toml, ".curve.min_rate_at_target"),
            maxRateAtTarget: vm.parseTomlInt(toml, ".curve.max_rate_at_target"),
            maxBorrowRate: vm.parseTomlUint(toml, ".curve.max_borrow_rate")
        });
    }
}
