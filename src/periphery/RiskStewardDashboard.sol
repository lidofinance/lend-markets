// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IRiskStewardDashboard} from "../interfaces/IRiskStewardDashboard.sol";
import {ILidoLendMarketConfigurator} from "../interfaces/ILidoLendMarketConfigurator.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";

/// @notice Bounded risk-steward levers over the markets of one core, from a single instance. Each lever reads
///         a market's current activation config, enforces a tighten-only change, and writes the full config
///         back. Stewards are appointed per market id, so one dashboard serves every market. The controller
///         still validates bounds and ordering on write, so this only adds the direction (tighten-only) guard.
contract RiskStewardDashboard is AccessControlEnumerable, IRiskStewardDashboard {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ---
    // ROLES
    // ---

    /// @inheritdoc IRiskStewardDashboard
    bytes32 public constant STEWARD_ADMIN_ROLE = keccak256("STEWARD_ADMIN_ROLE");

    // ---
    // IMMUTABLES
    // ---

    /// @dev Core whose markets this dashboard configures. A market's controller is resolved from it by id.
    ILidoLend public immutable LIDO_LEND;

    // ---
    // STORAGE
    // ---

    /// @dev Stewards appointed per market id.
    mapping(Id marketId => EnumerableSet.AddressSet) private _stewards;

    // ---
    // MODIFIERS
    // ---

    modifier onlyMarketSteward(Id marketId) {
        if (!_stewards[marketId].contains(msg.sender)) revert NotMarketSteward();
        _;
    }

    // ---
    // CONSTRUCTOR
    // ---

    constructor(address admin, ILidoLend lidoLend) {
        LIDO_LEND = lidoLend;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ---
    // STEWARDS
    // ---

    /// @inheritdoc IRiskStewardDashboard
    function addMarketSteward(Id marketId, address steward) external onlyRole(STEWARD_ADMIN_ROLE) {
        if (steward == address(0)) revert ZeroSteward();
        if (_stewards[marketId].add(steward)) emit MarketStewardSet(marketId, steward, true);
    }

    /// @inheritdoc IRiskStewardDashboard
    function removeMarketSteward(Id marketId, address steward) external onlyRole(STEWARD_ADMIN_ROLE) {
        if (_stewards[marketId].remove(steward)) emit MarketStewardSet(marketId, steward, false);
    }

    /// @inheritdoc IRiskStewardDashboard
    function marketStewards(Id marketId) external view returns (address[] memory) {
        return _stewards[marketId].values();
    }

    /// @inheritdoc IRiskStewardDashboard
    function isMarketSteward(Id marketId, address steward) external view returns (bool) {
        return _stewards[marketId].contains(steward);
    }

    // ---
    // RISK LEVERS
    // ---

    /// @inheritdoc IRiskStewardDashboard
    function increaseActivationDelays(Id marketId, uint40 newMin, uint40 newMax) external onlyMarketSteward(marketId) {
        ILidoLendMarketConfigurator controller = _configurator(marketId);
        CollateralActivationConfig memory cfg = controller.collateralActivationConfig();
        if (newMin < cfg.minActivationDelay || newMax < cfg.maxActivationDelay) revert NotTightened();

        cfg.minActivationDelay = newMin;
        cfg.maxActivationDelay = newMax;
        controller.setCollateralActivationConfig(cfg);

        emit ActivationDelaysIncreased(marketId, newMin, newMax);
    }

    /// @inheritdoc IRiskStewardDashboard
    function increaseActivatingLock(Id marketId, uint128 newAmount, uint40 newDuration)
        external
        onlyMarketSteward(marketId)
    {
        ILidoLendMarketConfigurator controller = _configurator(marketId);
        CollateralActivationConfig memory cfg = controller.collateralActivationConfig();
        if (newAmount < cfg.activatingLockAmount || newDuration < cfg.activatingLockDuration) revert NotTightened();

        cfg.activatingLockAmount = newAmount;
        cfg.activatingLockDuration = newDuration;
        controller.setCollateralActivationConfig(cfg);

        emit ActivatingLockIncreased(marketId, newAmount, newDuration);
    }

    /// @inheritdoc IRiskStewardDashboard
    function revokeInstantActivation(Id marketId, address caller) external onlyMarketSteward(marketId) {
        _configurator(marketId).revokeInstantActivation(caller);
        emit InstantActivationRevoked(marketId, caller);
    }

    // ---
    // PRIVATE HELPERS
    // ---

    /// @dev Resolve a market id to its controller via the core, reverting if the market has none.
    function _configurator(Id marketId) private view returns (ILidoLendMarketConfigurator) {
        address controller = LIDO_LEND.marketController(marketId);
        if (controller == address(0)) revert UnknownMarket(marketId);
        return ILidoLendMarketConfigurator(controller);
    }
}
