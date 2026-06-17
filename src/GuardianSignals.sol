// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-lend/src/interfaces/IMorpho.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";

import {IGuardianSignals} from "./interfaces/IGuardianSignals.sol";

/// @title GuardianSignals
/// @author Lido Lending contributors.
/// @notice Per-market registry where guardians flag suspect accounts and a quorum of flags latches a ban.
///         Guardians are bots run by trusted actors. The market controller reads `getStatus` to scale
///         collateral activation and to hard-block borrowing.
/// @dev Upgradeable behind a proxy (`initialize`, not a constructor), with ERC-7201 namespaced storage.
///      State is per `(market, account)`, where `strikes` is the size of the flagger set `flaggedBy`. The
///      escalation ladder, read through `getStatus`:
///        - strikes == 0           : clean, normal activation.
///        - 0 < strikes < quorum   : the reader scales the activation delay up by the strike count.
///        - strikes >= quorum      : `banned` latches, the reader hard-blocks borrow.
///
///      The ban latches: retracting a flag never lifts it. `unban` lifts it and clears the flagger set, so
///      guardians re-evaluate from scratch and can re-ban an account that is still bad. `immune` is the
///      override for accounts the guardians misjudge: while set, `flag`/`unflag` no-op and `getStatus` reads
///      the account as clean. `ban` clears `immune`.
///
///      The override splits into two opposing pairs by risk direction. The fast risk-reducing side sits at
///      the committee (`ACCESS_LIMITER_ROLE`: `ban`, `revokeImmunity`), the slow risk-increasing side at
///      governance (`ACCESS_RESTORER_ROLE`: `unban`, `grantImmunity`). `DEFAULT_ADMIN_ROLE` manages the
///      guardian set and quorum. The guardian set is a plain enumerable set, not a role.
///
///      Guardians report liveness: `flag`, `unflag`, and `heartbeat` each record a last-scanned block, and
///      `getLastScannedQuorumBlock` returns the highest block a quorum have scanned past (monotonic).
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

    /// @notice Per-account guardian signal. `strikes` is `flaggedBy.length()`.
    /// @param banned    A quorum of flags latched a ban, or `ban` forced one. Held until `unban`.
    /// @param immune    Account is exempt. While set, `flag`/`unflag` no-op and `getStatus` reads it clean.
    /// @param flaggedBy Live set of guardians flagging the account. `unban` clears it in one call.
    struct Signal {
        bool banned;
        bool immune;
        EnumerableSet.AddressSet flaggedBy;
    }

    // ---
    // CONSTANTS
    // ---

    /// @notice Maximum number of guardians. Keeps the quorum in `uint8` and a strike count in `uint16`.
    uint256 public constant MAX_GUARDIANS_COUNT = type(uint8).max;

    // ---
    // ROLES
    // ---

    bytes32 public constant ACCESS_LIMITER_ROLE = keccak256("ACCESS_LIMITER_ROLE");
    bytes32 public constant ACCESS_RESTORER_ROLE = keccak256("ACCESS_RESTORER_ROLE");

    // ---
    // STORAGE
    // ---

    uint8 private _quorum;
    EnumerableSet.AddressSet private _guardians;
    mapping(Id market => mapping(address account => Signal)) private _markets;
    mapping(address guardian => uint256) private _heartbeats;
    uint256 private _lastScannedQuorumBlock;

    // ---
    // MODIFIERS
    // ---

    modifier onlyGuardian() {
        if (!_guardians.contains(msg.sender)) revert NotGuardian();
        _;
    }

    // ---
    // INITIALIZATION
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Set the admin, seed the guardian set, and set the quorum.
    /// @param admin     Holder of `DEFAULT_ADMIN_ROLE`, manager of the guardian set and quorum.
    /// @param guardians Initial guardian set.
    /// @param quorum    Distinct flags that latch a ban. Must satisfy `1 <= quorum <= guardians.length`.
    function initialize(address admin, address[] calldata guardians, uint256 quorum) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        for (uint256 i; i < guardians.length; ++i) {
            _addGuardian(guardians[i]);
        }
        _setQuorum(quorum);
    }

    // ---
    // GUARDIANS & QUORUM
    // ---

    /// @inheritdoc IGuardianSignals
    function getQuorum() external view returns (uint256) {
        return _quorum;
    }

    /// @inheritdoc IGuardianSignals
    function addGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addGuardian(guardian);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Reverts if removal would drop the set below `quorum`, so the quorum stays reachable.
    function removeGuardian(address guardian) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_guardians.remove(guardian)) revert NotGuardian();
        if (_guardians.length() < _quorum) revert WouldBreakQuorum();
        emit GuardianRemoved(guardian);
    }

    /// @inheritdoc IGuardianSignals
    function setQuorum(uint256 newQuorum) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setQuorum(newQuorum);
    }

    /// @inheritdoc IGuardianSignals
    function isGuardian(address account) external view returns (bool) {
        return _guardians.contains(account);
    }

    /// @inheritdoc IGuardianSignals
    function getGuardianCount() external view returns (uint256) {
        return _guardians.length();
    }

    /// @inheritdoc IGuardianSignals
    function getGuardians() external view returns (address[] memory) {
        return _guardians.values();
    }

    // ---
    // LIVENESS
    // ---

    /// @inheritdoc IGuardianSignals
    function heartbeat(uint256 lastScannedBlock) external onlyGuardian {
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeat(address guardian) external view returns (uint256) {
        return _heartbeats[guardian];
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeats() external view returns (address[] memory guardians, uint256[] memory heartbeats) {
        guardians = _guardians.values();
        heartbeats = _getHeartbeats(guardians);
    }

    /// @inheritdoc IGuardianSignals
    function getLastScannedQuorumBlock() external view returns (uint256) {
        return _lastScannedQuorumBlock;
    }

    // ---
    // GUARDIANS SIGNALLING
    // ---

    /// @inheritdoc IGuardianSignals
    function flag(Id market, address[] calldata accounts, uint256 lastScannedBlock) external onlyGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            _flag(market, accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function unflag(Id market, address[] calldata accounts, uint256 lastScannedBlock) external onlyGuardian {
        for (uint256 i; i < accounts.length; ++i) {
            _unflag(market, accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    // ---
    // COMMITTEE / GOVERNANCE OVERRIDE
    // ---

    /// @inheritdoc IGuardianSignals
    /// @dev Clears immunity so the block takes effect even on an exempt account.
    function ban(Id market, address account) external onlyRole(ACCESS_LIMITER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        Signal storage signal = _markets[market][account];
        signal.banned = true;
        signal.immune = false;
        emit Banned(market, account);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Clears the flagger set, so the freshly-unbanned account can be re-flagged and re-banned from
    ///      scratch. Immunity is left to `revokeImmunity`.
    function unban(Id market, address account) external onlyRole(ACCESS_RESTORER_ROLE) {
        Signal storage signal = _markets[market][account];
        signal.banned = false;
        signal.flaggedBy.clear();
        emit Unbanned(market, account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function grantImmunity(Id market, address account) external onlyRole(ACCESS_RESTORER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _markets[market][account].immune = true;
        emit ImmunityGranted(market, account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function revokeImmunity(Id market, address account) external onlyRole(ACCESS_LIMITER_ROLE) {
        _markets[market][account].immune = false;
        emit ImmunityRevoked(market, account, msg.sender);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IGuardianSignals
    /// @dev Effective status with immunity applied: an immune account reads as not banned with zero
    ///      strikes, so a reader needs no immunity logic of its own.
    function getStatus(Id market, address account) external view returns (bool isBanned, uint256 strikes) {
        Signal storage signal = _markets[market][account];
        if (signal.immune) return (false, 0);
        return (signal.banned, signal.flaggedBy.length());
    }

    /// @inheritdoc IGuardianSignals
    function getSignal(Id market, address account)
        external
        view
        returns (bool isImmune, bool isBanned, uint256 strikes)
    {
        Signal storage signal = _markets[market][account];
        return (signal.immune, signal.banned, signal.flaggedBy.length());
    }

    // ---
    // INTERNAL METHODS
    // ---

    /// @dev Record the caller's last-scanned block and refresh the quorum frontier (the quorum-th largest
    ///      heartbeat). The frontier is monotonic: a guardian rotation that adds fresh zero-heartbeat members
    ///      cannot pull it back, since the past quorum's coverage stays valid.
    function _heartbeat(uint256 lastScannedBlock) internal {
        // a guardian cannot have scanned a block that does not exist yet
        if (lastScannedBlock > block.number) lastScannedBlock = block.number;
        _heartbeats[msg.sender] = lastScannedBlock;
        emit Heartbeat(msg.sender);

        uint256[] memory heartbeats = _getHeartbeats(_guardians.values());
        uint256 quorumBlock = Arrays.sort(heartbeats)[_guardians.length() - _quorum];
        if (quorumBlock > _lastScannedQuorumBlock) _lastScannedQuorumBlock = quorumBlock;
    }

    function _getHeartbeats(address[] memory guardians) internal view returns (uint256[] memory heartbeats) {
        heartbeats = new uint256[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            heartbeats[i] = _heartbeats[guardians[i]];
        }
    }

    function _setQuorum(uint256 newQuorum) internal {
        if (newQuorum == 0 || newQuorum > _guardians.length()) revert BadQuorum();
        _quorum = uint8(newQuorum);
        emit QuorumSet(newQuorum);
    }

    function _addGuardian(address guardian) internal {
        if (guardian == address(0)) revert ZeroAddress();
        if (_guardians.length() >= MAX_GUARDIANS_COUNT) revert MaxGuardiansReached();
        if (!_guardians.add(guardian)) revert AlreadyGuardian();
        emit GuardianAdded(guardian);
    }

    /// @dev Single-account flag, looped by `flag`. No-op (no state change, no event) when `account` is immune
    ///      or the caller already flags it, so a batch never reverts on a skip.
    function _flag(Id market, address account) internal {
        if (account == address(0)) revert ZeroAddress();

        Signal storage signal = _markets[market][account];
        if (signal.immune || !signal.flaggedBy.add(msg.sender)) return;

        uint256 strikes = signal.flaggedBy.length();
        if (strikes >= _quorum && !signal.banned) {
            signal.banned = true;
            emit Banned(market, account);
        }
        emit Flagged(market, account, msg.sender, uint16(strikes));
    }

    /// @dev Single-account unflag, looped by `unflag`. No-op when `account` is immune or the caller does not
    ///      flag it. Does not lift a latched ban.
    function _unflag(Id market, address account) internal {
        Signal storage signal = _markets[market][account];
        if (signal.immune || !signal.flaggedBy.remove(msg.sender)) return;

        emit Unflagged(market, account, msg.sender, uint16(signal.flaggedBy.length()));
    }
}
