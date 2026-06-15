// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IGuardianSignals} from "./interfaces/IGuardianSignals.sol";

/// @title GuardianSignals
/// @author Lido Lending contributors.
/// @notice Guardian committee that flags addresses per market. Guardians (bots run by trusted actors)
///         flag accounts they detect as malicious. The market controller reads `statusOf` to
///         scale collateral activation and to hard-block borrowing.
/// @dev Upgradeable, deployed behind a proxy (`initialize`, not a constructor), with ERC-7201
///      namespaced storage. Strike ladder, per `(market, account)`:
///        - strikes == 0           : clean, normal activation.
///        - 0 < strikes < quorum   : reader scales the activation delay up by the strike count.
///        - strikes >= quorum      : `banned` LATCHES (reader hard-blocks borrow).
///
///      The ban latches: it survives flag retraction and is cleared only by `amnesty`. `amnesty` marks an
///      account so readers treat its strikes and ban as inert until `revokeAmnesty`, and a re-gathered quorum
///      cannot auto-ban an amnestied account. State is per `(market, account)`; `signalOf` reports it raw
///      (amnesty flagged, not applied) and `statusOf` applies amnesty for the reader.
///
///      Roles are minimal: `DEFAULT_ADMIN_ROLE` manages the guardian set and the quorum, `BAN_MANAGER_ROLE`
///      can ban an account, `AMNESTY_MANAGER_ROLE` can amnesty it or revoke that. The guardian committee is
///      a plain enumerable set, not a role.
///
///      Events and errors are declared in {IGuardianSignals}.
contract GuardianSignals layout at erc7201("lido.lending.storage.GuardianSignals")
    is
    Initializable,
    AccessControlEnumerableUpgradeable,
    IGuardianSignals
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // ---
    // DATA TYPES
    // ---

    struct MarketSignals {
        mapping(address account => Signal) byAccount;
        mapping(address guardian => mapping(address account => bool)) flagged;
    }

    // ---
    // CONSTANTS
    // ---

    uint256 public constant MAX_GUARDIANS_COUNT = type(uint8).max;

    // ---
    // ROLES
    // ---

    bytes32 public constant BAN_MANAGER_ROLE = keccak256("BAN_MANAGER_ROLE");
    bytes32 public constant AMNESTY_MANAGER_ROLE = keccak256("AMNESTY_MANAGER_ROLE");

    // ---
    // STORAGE
    // ---

    uint8 private _quorum;
    EnumerableSet.AddressSet private _guardians;
    mapping(Id market => MarketSignals) private _markets;

    // ---
    // MODIFIERS
    // ---

    modifier onlyGuardian() {
        if (!_guardians.contains(msg.sender)) revert NotGuardian();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address[] memory guardians_, uint256 quorum_) external initializer {
        __AccessControlEnumerable_init();
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        for (uint256 i; i < guardians_.length; ++i) {
            if (guardians_[i] == address(0)) revert ZeroAddress();
            if (_guardians.length() >= MAX_GUARDIANS_COUNT) revert MaxGuardiansReached();
            _guardians.add(guardians_[i]);
        }
        _setQuorum(quorum_);
    }

    // ---
    // GUARDIANS & QUORUM
    // ---

    /// @inheritdoc IGuardianSignals
    function getQuorum() external view override returns (uint256) {
        return _quorum;
    }

    /// @inheritdoc IGuardianSignals
    function addGuardian(address guardian) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (guardian == address(0)) revert ZeroAddress();
        if (_guardians.length() >= MAX_GUARDIANS_COUNT) revert MaxGuardiansReached();
        if (!_guardians.add(guardian)) revert AlreadyGuardian();
        emit GuardianAdded(guardian);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Reverts if removal would drop the set below `quorum`, so the quorum stays reachable.
    function removeGuardian(address guardian) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_guardians.remove(guardian)) revert NotGuardian();
        if (_guardians.length() < _quorum) revert WouldBreakQuorum();
        emit GuardianRemoved(guardian);
    }

    /// @inheritdoc IGuardianSignals
    function setQuorum(uint256 newQuorum) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setQuorum(newQuorum);
    }

    /// @inheritdoc IGuardianSignals
    function isGuardian(address account) external view override returns (bool) {
        return _guardians.contains(account);
    }

    /// @inheritdoc IGuardianSignals
    function getGuardianCount() external view override returns (uint256) {
        return _guardians.length();
    }

    /// @inheritdoc IGuardianSignals
    function getGuardians() external view override returns (address[] memory) {
        return _guardians.values();
    }

    // ---
    // GUARDIANS SIGNALLING
    // ---

    /// @inheritdoc IGuardianSignals
    function flag(Id market, address account) external override onlyGuardian {
        _flag(market, account);
    }

    /// @inheritdoc IGuardianSignals
    function flagMany(Id market, address[] calldata accounts) external override onlyGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            _flag(market, accounts[i]);
        }
    }

    /// @inheritdoc IGuardianSignals
    function unflag(Id market, address account) external override onlyGuardian {
        _unflag(market, account);
    }

    /// @inheritdoc IGuardianSignals
    function unflagMany(Id market, address[] calldata accounts) external override onlyGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            _unflag(market, accounts[i]);
        }
    }

    /// @dev Single-account flag, shared by the one-shot and batch entrypoints. Idempotent: a no-op (no state
    ///      change, no event) when the caller already flags `account`, so a batch never reverts on an overlap.
    function _flag(Id market, address account) internal {
        if (account == address(0)) revert ZeroAddress();
        MarketSignals storage m = _markets[market];
        if (m.flagged[msg.sender][account]) return;

        m.flagged[msg.sender][account] = true;
        Signal storage sig = m.byAccount[account];
        uint16 strikes = ++sig.strikes;

        if (strikes >= _quorum && !sig.banned && !sig.amnestied) {
            sig.banned = true;
            emit Banned(market, account);
        }
        emit Flagged(market, account, msg.sender, strikes);
    }

    /// @dev Single-account unflag, shared by the one-shot and batch entrypoints. Idempotent: a no-op (no
    ///      event) when the caller does not flag `account`. Does not lift a latched ban.
    function _unflag(Id market, address account) internal {
        MarketSignals storage m = _markets[market];
        if (!m.flagged[msg.sender][account]) return;

        delete m.flagged[msg.sender][account];
        // the flag bit was set, so the count is >= 1: safe to decrement.
        uint16 strikes = --m.byAccount[account].strikes;
        emit Unflagged(market, account, msg.sender, strikes);
    }

    // ---
    // COMMITTEE OVERRIDE
    // ---

    /// @inheritdoc IGuardianSignals
    function ban(Id market, address account) external override onlyRole(BAN_MANAGER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _markets[market].byAccount[account].banned = true;
        emit Banned(market, account);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Sets the amnesty flag only; `signalOf` reports it and the reader applies it. A standing ban is
    ///      preserved (suppressed by the reader, restored on `revokeAmnesty`).
    function amnesty(Id market, address account) external override onlyRole(AMNESTY_MANAGER_ROLE) {
        _markets[market].byAccount[account].amnestied = true;
        emit Amnestied(market, account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function revokeAmnesty(Id market, address account) external override onlyRole(AMNESTY_MANAGER_ROLE) {
        _markets[market].byAccount[account].amnestied = false;
        emit AmnestyRevoked(market, account, msg.sender);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IGuardianSignals
    /// @dev Reports the stored entry raw — amnesty is flagged, not applied. `statusOf` is the
    ///      effective view.
    function signalOf(Id market, address account) external view override returns (Signal memory) {
        return _markets[market].byAccount[account];
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Effective status with amnesty applied: an amnestied account reads as not banned with zero
    ///      strikes (the committee vouched), so a reader needs no amnesty logic of its own.
    function statusOf(Id market, address account) external view override returns (bool isBanned, uint256 strikes) {
        Signal storage sig = _markets[market].byAccount[account];
        if (sig.amnestied) return (false, 0);
        return (sig.banned, sig.strikes);
    }

    // ---
    // INTERNAL METHODS
    // ---

    function _setQuorum(uint256 newQuorum) internal {
        if (newQuorum == 0 || newQuorum > _guardians.length()) {
            revert BadQuorum();
        }
        _quorum = uint8(newQuorum);
        emit QuorumSet(newQuorum);
    }
}
