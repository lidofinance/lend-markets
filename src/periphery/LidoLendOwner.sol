// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

import {IGuardianSignals} from "../interfaces/IGuardianSignals.sol";
import {ILidoLendMarketController} from "../interfaces/ILidoLendMarketController.sol";
import {ILidoLendOwner} from "../interfaces/ILidoLendOwner.sol";
import {CollateralActivationConfig} from "../types/CollateralActivationTypes.sol";
import {SettlementConfig} from "../types/SettlementTypes.sol";

/// @title LidoLendOwner
/// @author Lido Lending contributors.
/// @notice Stable role-gated governance facade over a `LidoLend` core and all its markets. Core-owner calls and
///         per-market controller and guardian-registry calls sit behind independent capability roles.
contract LidoLendOwner is AccessControlEnumerable, ILidoLendOwner {
    // ---
    // ROLES
    // ---

    /// @dev Creates markets on the core (controller-less and controlled). A market's controller and settle
    ///      opt-in are bound at creation and immutable thereafter, so this is a high-trust capability.
    bytes32 public constant MARKET_CREATOR_ROLE = keccak256("MARKET_CREATOR_ROLE");
    /// @dev Sets per-market fees and the global fee recipient on the core.
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    /// @dev Manages controller policy and unfreezes markets resolved from the core by id.
    bytes32 public constant MARKET_MANAGER_ROLE = keccak256("MARKET_MANAGER_ROLE");
    /// @dev Manages guardian registries and restores access, resolving each registry from its market controller.
    bytes32 public constant GUARDIAN_MANAGER_ROLE = keccak256("GUARDIAN_MANAGER_ROLE");

    // ---
    // IMMUTABLES
    // ---

    /// @inheritdoc ILidoLendOwner
    ILidoLend public immutable LIDO_LEND;

    // ---
    // CONSTRUCTOR
    // ---

    /// @param core          The `LidoLend` core this facade will own. The deploy must hand the core's `owner`
    ///                      to this facade after construction; the facade cannot do it itself.
    /// @param admin         Holder of `DEFAULT_ADMIN_ROLE`, which manages the capability roles and core
    ///                      ownership. Required.
    /// @param marketCreator Initial `MARKET_CREATOR_ROLE` holder; `address(0)` grants none (admin can later).
    /// @param feeManager    Initial `FEE_MANAGER_ROLE` holder; `address(0)` grants none (admin can later).
    constructor(ILidoLend core, address admin, address marketCreator, address feeManager) {
        if (address(core) == address(0) || admin == address(0)) revert ZeroAddress();
        LIDO_LEND = core;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (marketCreator != address(0)) _grantRole(MARKET_CREATOR_ROLE, marketCreator);
        if (feeManager != address(0)) _grantRole(FEE_MANAGER_ROLE, feeManager);
    }

    // ---
    // MARKET CREATION
    // ---

    /// @inheritdoc ILidoLendOwner
    function createMarket(MarketParams calldata marketParams) external onlyRole(MARKET_CREATOR_ROLE) {
        LIDO_LEND.createMarket(marketParams);
    }

    /// @inheritdoc ILidoLendOwner
    function createMarket(MarketParams calldata marketParams, address controller, bool enableSettlement)
        external
        onlyRole(MARKET_CREATOR_ROLE)
    {
        LIDO_LEND.createMarket(marketParams, controller, enableSettlement);
    }

    // ---
    // FEES
    // ---

    /// @inheritdoc ILidoLendOwner
    function setFee(MarketParams calldata marketParams, uint256 newFee) external onlyRole(FEE_MANAGER_ROLE) {
        LIDO_LEND.setFee(marketParams, newFee);
    }

    /// @inheritdoc ILidoLendOwner
    function setFeeRecipient(address newFeeRecipient) external onlyRole(FEE_MANAGER_ROLE) {
        LIDO_LEND.setFeeRecipient(newFeeRecipient);
    }

    // ---
    // MARKET MANAGEMENT
    // ---

    /// @inheritdoc ILidoLendOwner
    function setMarketSupplyCap(Id marketId, uint256 cap) external onlyRole(MARKET_MANAGER_ROLE) {
        _controller(marketId).setSupplyCap(cap);
    }

    /// @inheritdoc ILidoLendOwner
    function unfreezeMarket(Id marketId) external onlyRole(MARKET_MANAGER_ROLE) {
        _controller(marketId).unfreeze();
    }

    /// @inheritdoc ILidoLendOwner
    function setMarketCollateralActivationConfig(Id marketId, CollateralActivationConfig calldata config)
        external
        onlyRole(MARKET_MANAGER_ROLE)
    {
        _controller(marketId).setCollateralActivationConfig(config);
    }

    /// @inheritdoc ILidoLendOwner
    function setMarketSettlementConfig(Id marketId, SettlementConfig calldata config)
        external
        onlyRole(MARKET_MANAGER_ROLE)
    {
        _controller(marketId).setSettlementConfig(config);
    }

    /// @inheritdoc ILidoLendOwner
    function grantMarketInstantActivation(Id marketId, address caller) external onlyRole(MARKET_MANAGER_ROLE) {
        _controller(marketId).grantInstantActivation(caller);
    }

    // ---
    // GUARDIAN MANAGEMENT
    // ---

    /// @inheritdoc ILidoLendOwner
    function addGuardian(Id marketId, address guardian) external onlyRole(GUARDIAN_MANAGER_ROLE) {
        _guardians(marketId).addGuardian(guardian);
    }

    /// @inheritdoc ILidoLendOwner
    function replaceGuardian(Id marketId, address oldGuardian, address newGuardian)
        external
        onlyRole(GUARDIAN_MANAGER_ROLE)
    {
        IGuardianSignals guardians = _guardians(marketId);
        uint256 guardianCount = guardians.getGuardianCount();

        if (guardianCount < guardians.MAX_GUARDIANS_COUNT()) {
            guardians.addGuardian(newGuardian);
            guardians.removeGuardian(oldGuardian);
            return;
        }

        uint256 quorum = guardians.getQuorum();
        bool restoreQuorum = quorum == guardianCount;
        if (restoreQuorum) guardians.setQuorum(quorum - 1);
        guardians.removeGuardian(oldGuardian);
        guardians.addGuardian(newGuardian);
        if (restoreQuorum) guardians.setQuorum(quorum);
    }

    /// @inheritdoc ILidoLendOwner
    function removeGuardian(Id marketId, address guardian) external onlyRole(GUARDIAN_MANAGER_ROLE) {
        _guardians(marketId).removeGuardian(guardian);
    }

    /// @inheritdoc ILidoLendOwner
    function setGuardiansQuorum(Id marketId, uint256 quorum) external onlyRole(GUARDIAN_MANAGER_ROLE) {
        _guardians(marketId).setQuorum(quorum);
    }

    /// @inheritdoc ILidoLendOwner
    function setGuardiansSuspectWindow(Id marketId, uint256 suspectWindow) external onlyRole(GUARDIAN_MANAGER_ROLE) {
        _guardians(marketId).setSuspectWindow(suspectWindow);
    }

    /// @inheritdoc ILidoLendOwner
    function unbanGuardianSignals(Id[] calldata marketIds, address account) external onlyRole(GUARDIAN_MANAGER_ROLE) {
        for (uint256 i; i < marketIds.length; ++i) {
            Id marketId = marketIds[i];
            _guardians(marketId).unban(marketId, account);
        }
    }

    // ---
    // OWNERSHIP
    // ---

    /// @inheritdoc ILidoLendOwner
    function transferLidoLendOwnership(address newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOwner == address(0)) revert ZeroAddress();
        LIDO_LEND.setOwner(newOwner);
    }

    // ---
    // PRIVATE HELPERS
    // ---

    /// @dev Resolve a market id to its controller via the core, reverting if the market has none.
    function _controller(Id marketId) private view returns (ILidoLendMarketController) {
        address controller = LIDO_LEND.marketController(marketId);
        if (controller == address(0)) revert UnknownMarket(marketId);
        return ILidoLendMarketController(controller);
    }

    /// @dev Resolve the guardian registry used by a market through its controller.
    function _guardians(Id marketId) private view returns (IGuardianSignals) {
        return IGuardianSignals(_controller(marketId).guardianSignals());
    }
}
