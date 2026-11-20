// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

import {LIQUIDATION_CURSOR, MAX_LIQUIDATION_INCENTIVE_FACTOR} from "@lido-lend/src/libraries/ConstantsLib.sol";
import {MathLib} from "@lido-lend/src/libraries/MathLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {WAD} from "../../src/libs/Constants.sol";
import {CentrifugeNavOracle} from "../../src/oracle/CentrifugeNavOracle.sol";
import {TrailingAnchorOracleBase} from "../../src/oracle/TrailingAnchorOracleBase.sol";
import {UsdyNavOracle} from "../../src/oracle/UsdyNavOracle.sol";
import {TrailingAnchorKind, TrailingAnchorPriceFeedSpec} from "./DeploymentTypes.sol";

/// @notice Builds the adapter of a trailing anchor oracle and checks a deployed one.
library TrailingAnchorPriceFeed {
    error ParameterMismatch(bytes32 field, uint256 expected, uint256 actual);
    error RoleHolderCountMismatch(bytes32 role, uint256 expected, uint256 actual);
    error RoleHolderUnexpected(bytes32 role, address holder);
    /// @notice A position borrowed at `lltv` against the highest price the oracle returns would not cover its debt
    ///         and the liquidation incentive at the lowest. `largestAboveBase` is the widest `maxAnchorAboveBase`
    ///         that would with this `maxAnchorBelowBase`, zero when none would.
    error CorridorTooWide(
        uint256 maxAnchorBelowBase, uint256 maxAnchorAboveBase, uint256 lltv, uint256 largestAboveBase
    );
    /// @notice The anchor is outside the floor and the ceiling, so the sizing rule does not bound the prices.
    error AnchorOutsideLines(uint256 anchorPrice, uint256 floor, uint256 ceiling);

    /// @notice Deploys the adapter that `spec` describes.
    function implementation(TrailingAnchorPriceFeedSpec memory spec) internal returns (address) {
        if (spec.kind == TrailingAnchorKind.Usdy) {
            return address(new UsdyNavOracle(spec.source, spec.loanToken, spec.collateralToken));
        }
        return address(
            new CentrifugeNavOracle(
                spec.source, spec.poolId, spec.shareClassId, spec.maxPriceAge, spec.loanToken, spec.collateralToken
            )
        );
    }

    /// @notice The price feed kind that a deployment artifact records for `kind`.
    function kindName(TrailingAnchorKind kind) internal pure returns (string memory) {
        return kind == TrailingAnchorKind.Usdy ? "usdy-nav" : "centrifuge-nav";
    }

    /// @notice The oracle runs on `spec`'s parameters, and `agent` alone holds each of its roles.
    function checkLaunch(address oracle, TrailingAnchorPriceFeedSpec memory spec, address agent) internal view {
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(oracle);
        TrailingAnchorOracleBase.Parameters memory expected = spec.parameters;
        TrailingAnchorOracleBase.Parameters memory actual = _parameters(nav);
        _same("maxPriceAboveAnchor", expected.maxPriceAboveAnchor, actual.maxPriceAboveAnchor);
        _same("maxPriceBelowAnchor", expected.maxPriceBelowAnchor, actual.maxPriceBelowAnchor);
        _same("maxAnchorContinuousRiseRate", expected.maxAnchorContinuousRiseRate, actual.maxAnchorContinuousRiseRate);
        _same("maxAnchorContinuousFallRate", expected.maxAnchorContinuousFallRate, actual.maxAnchorContinuousFallRate);
        _same("maxAnchorBelowBase", expected.maxAnchorBelowBase, actual.maxAnchorBelowBase);
        _same("maxAnchorAboveBase", expected.maxAnchorAboveBase, actual.maxAnchorAboveBase);
        _same("reanchorDelay", expected.reanchorDelay, actual.reanchorDelay);
        _same("reanchorWindow", expected.reanchorWindow, actual.reanchorWindow);
        _requireOnlyHolder(nav, nav.DEFAULT_ADMIN_ROLE(), agent);
        _requireOnlyHolder(nav, nav.MANAGER_ROLE(), agent);
        _requireOnlyHolder(nav, nav.PRICE_ACCEPTOR_ROLE(), agent);
    }

    /// @notice The oracle's parameters keep the sizing rule at `lltv`, and its anchor is between the floor and the
    ///         ceiling, with the oracle's rounding. The rule bounds the prices only while the anchor is there.
    function checkLive(address oracle, uint256 lltv) internal view {
        TrailingAnchorOracleBase nav = TrailingAnchorOracleBase(oracle);
        TrailingAnchorOracleBase.Parameters memory p = _parameters(nav);
        requireSizing(p, lltv);
        uint256 base = nav.basePrice();
        uint256 floor = base - Math.mulDiv(base, p.maxAnchorBelowBase, WAD);
        uint256 ceiling = base + Math.mulDiv(base, p.maxAnchorAboveBase, WAD);
        uint256 anchor = nav.anchorPrice();
        if (anchor < floor || anchor > ceiling) revert AnchorOutsideLines(anchor, floor, ceiling);
    }

    /// @notice The sizing rule, which the oracle cannot check because it does not know the market. A position borrowed
    ///         at `lltv` against the highest price the oracle returns, the ceiling × (1 + maxPriceAboveAnchor), must
    ///         still cover its debt and the core's liquidation incentive at the lowest, the floor × (1 −
    ///         maxPriceBelowAnchor): (1 − maxAnchorBelowBase)(1 − maxPriceBelowAnchor) ≥ lltv × LIF × (1 +
    ///         maxAnchorAboveBase)(1 + maxPriceAboveAnchor). LIF has the rounding of the core, and each other step
    ///         rounds against the corridor.
    function requireSizing(TrailingAnchorOracleBase.Parameters memory p, uint256 lltv) internal pure {
        uint256 incentive = Math.min(
            MAX_LIQUIDATION_INCENTIVE_FACTOR,
            MathLib.wDivDown(WAD, WAD - MathLib.wMulDown(LIQUIDATION_CURSOR, WAD - lltv))
        );
        // What the upper bound needs with the ceiling on the base price, and the room the floor's lower bound
        // leaves.
        uint256 needed = Math.mulDiv(
            Math.mulDiv(lltv, incentive, WAD, Math.Rounding.Ceil), WAD + p.maxPriceAboveAnchor, WAD, Math.Rounding.Ceil
        );
        uint256 room = Math.mulDiv(WAD - p.maxAnchorBelowBase, WAD - p.maxPriceBelowAnchor, WAD);
        if (room < Math.mulDiv(needed, WAD + p.maxAnchorAboveBase, WAD, Math.Rounding.Ceil)) {
            uint256 largest = room < needed ? 0 : Math.mulDiv(room, WAD, needed) - WAD;
            revert CorridorTooWide(p.maxAnchorBelowBase, p.maxAnchorAboveBase, lltv, largest);
        }
    }

    function _parameters(TrailingAnchorOracleBase nav)
        private
        view
        returns (TrailingAnchorOracleBase.Parameters memory p)
    {
        p.maxPriceAboveAnchor = nav.maxPriceAboveAnchor();
        p.maxPriceBelowAnchor = nav.maxPriceBelowAnchor();
        p.maxAnchorContinuousRiseRate = nav.maxAnchorContinuousRiseRate();
        p.maxAnchorContinuousFallRate = nav.maxAnchorContinuousFallRate();
        p.maxAnchorBelowBase = nav.maxAnchorBelowBase();
        p.maxAnchorAboveBase = nav.maxAnchorAboveBase();
        p.reanchorDelay = nav.reanchorDelay();
        p.reanchorWindow = nav.reanchorWindow();
    }

    function _requireOnlyHolder(TrailingAnchorOracleBase nav, bytes32 role, address holder) private view {
        uint256 count = nav.getRoleMemberCount(role);
        if (count != 1) revert RoleHolderCountMismatch(role, 1, count);
        address actual = nav.getRoleMember(role, 0);
        if (actual != holder) revert RoleHolderUnexpected(role, actual);
    }

    function _same(bytes32 field, uint256 expected, uint256 actual) private pure {
        if (expected != actual) revert ParameterMismatch(field, expected, actual);
    }
}
