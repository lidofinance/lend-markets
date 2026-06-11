// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {Id} from "@lido-blue/src/interfaces/IMorpho.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    AccessControlEnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ISuspectsRegistry} from "./interfaces/ISuspectsRegistry.sol";

/// @title SuspectsRegistry
/// @author Lido Lending contributors.
/// @notice Guardian committee that scores suspect addresses, per market or globally. Guardians
///         (bots run by trusted actors) flag addresses they detect as malicious. The market
///         controller reads `suspicion` and `isBanned` to scale collateral maturation and to
///         hard-block borrowing.
/// @dev Upgradeable, deployed behind a proxy (`initialize`, not a constructor), with ERC-7201
///      namespaced storage. Severity ladder, per `(market, suspect)`:
///        - flags == 0           : suspicion 0, clean, normal maturation.
///        - 0 < flags < quorum   : suspicion in (0,100), controller scales the maturation delay up.
///        - flags >= quorum      : suspicion 100 and `banned` LATCHES (controller hard-blocks borrow).
///
///      The ban latches: it survives flag retraction, is cleared only by `unban`, and pins suspicion
///      at 100 while it holds. The graded (0,100) range is driven only by live sub-quorum flags.
///      `EVERY_MARKET` flags apply to every market. A suspect's effective state is the dirtier of its
///      per-market and global state.
///
///      Roles are minimal: `DEFAULT_ADMIN_ROLE` manages the guardian set and the quorum,
///      `OVERRIDE_ROLE` can ban or unban any suspect single-handedly. The guardian committee is a
///      plain enumerable set, not a role.
///
///      Events and errors are declared in {ISuspectsRegistry}.
contract SuspectsRegistry layout at erc7201("lido.lending.storage.SuspectsRegistry")
    is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ISuspectsRegistry
{
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice May ban or unban any suspect single-handedly. Hold with a multisig / governance.
    bytes32 public constant OVERRIDE_ROLE = keccak256("OVERRIDE_ROLE");

    /// @notice Sentinel market whose flags apply to every market.
    Id public constant EVERY_MARKET = Id.wrap(bytes32(0));

    /// @notice Full-scale suspicion: the value at (and above) which an address counts as banned, and
    ///         the scale the graded score `flags * SUSPICION_SCALE / quorum` is reported on. Must match
    ///         `ActivationLib.SUSPICION_SCALE`, which consumes this value.
    uint256 public constant SUSPICION_SCALE = 100;

    struct SuspectState {
        uint16 flags; // live count of distinct guardian flags on this (market, suspect)
        bool banned; // latched hard block, set at quorum or by `ban`, cleared only by `unban`
    }

    struct MarketSuspects {
        mapping(address suspect => SuspectState) state;
        mapping(address guardian => mapping(address suspect => bool)) flagged;
    }

    EnumerableSet.AddressSet private _guardians;
    /// @dev Flags that take suspicion to `SUSPICION_SCALE` and latch a ban.
    uint256 private _quorum;
    mapping(Id market => MarketSuspects) private _markets;

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
            _guardians.add(guardians_[i]);
        }
        // Quorum must be reachable by the initial set.
        if (quorum_ == 0 || quorum_ > _guardians.length()) revert BadQuorum();
        _quorum = quorum_;
        emit QuorumSet(quorum_);
    }

    /// @inheritdoc ISuspectsRegistry
    function quorum() external view override returns (uint256) {
        return _quorum;
    }

    /* MEMBERSHIP (admin) */

    /// @inheritdoc ISuspectsRegistry
    function addGuardian(address guardian) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (guardian == address(0)) revert ZeroAddress();
        if (!_guardians.add(guardian)) revert AlreadyGuardian();
        emit GuardianAdded(guardian);
    }

    /// @inheritdoc ISuspectsRegistry
    /// @dev Reverts if removal would drop the set below `quorum`, so the quorum stays reachable.
    function removeGuardian(address guardian) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_guardians.remove(guardian)) revert NotGuardian();
        if (_guardians.length() < _quorum) revert WouldBreakQuorum();
        emit GuardianRemoved(guardian);
    }

    /// @inheritdoc ISuspectsRegistry
    function setQuorum(uint256 newQuorum) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Cannot set a quorum the current guardian set can never reach.
        if (newQuorum == 0 || newQuorum > _guardians.length()) revert BadQuorum();
        _quorum = newQuorum;
        emit QuorumSet(newQuorum);
    }

    /// @inheritdoc ISuspectsRegistry
    function isGuardian(address account) external view override returns (bool) {
        return _guardians.contains(account);
    }

    /// @inheritdoc ISuspectsRegistry
    function guardianCount() external view override returns (uint256) {
        return _guardians.length();
    }

    /// @inheritdoc ISuspectsRegistry
    function guardians() external view override returns (address[] memory) {
        return _guardians.values();
    }

    /* FLAGGING (guardians) */

    /// @inheritdoc ISuspectsRegistry
    function flag(Id market, address suspect) external override onlyGuardian {
        if (suspect == address(0)) revert ZeroAddress();
        MarketSuspects storage m = _markets[market];
        if (m.flagged[msg.sender][suspect]) revert AlreadyFlagged();

        m.flagged[msg.sender][suspect] = true;
        SuspectState storage s = m.state[suspect];
        uint16 flags = ++s.flags;

        if (flags >= _quorum && !s.banned) {
            s.banned = true;
            emit Banned(market, suspect);
        }
        emit Flagged(market, suspect, msg.sender, flags);
    }

    /// @inheritdoc ISuspectsRegistry
    function unflag(Id market, address suspect) external override onlyGuardian {
        MarketSuspects storage m = _markets[market];
        if (!m.flagged[msg.sender][suspect]) revert NotFlagged();

        delete m.flagged[msg.sender][suspect];
        SuspectState storage s = m.state[suspect];
        // Guard underflow for the rare case where `unban` already zeroed the count.
        uint16 flags = s.flags;
        if (flags != 0) {
            flags -= 1;
            s.flags = flags;
        }
        emit Unflagged(market, suspect, msg.sender, flags);
    }

    /* OVERRIDE (single-handed ban / unban) */

    /// @inheritdoc ISuspectsRegistry
    function ban(Id market, address suspect) external override onlyRole(OVERRIDE_ROLE) {
        if (suspect == address(0)) revert ZeroAddress();
        _markets[market].state[suspect].banned = true;
        emit Banned(market, suspect);
    }

    /// @inheritdoc ISuspectsRegistry
    /// @dev O(N) over guardians, but this is a rare escape-hatch call.
    function unban(Id market, address suspect) external override onlyRole(OVERRIDE_ROLE) {
        MarketSuspects storage m = _markets[market];
        uint256 n = _guardians.length();
        for (uint256 i; i < n; ++i) {
            delete m.flagged[_guardians.at(i)][suspect];
        }
        delete m.state[suspect];
        emit Unbanned(market, suspect, msg.sender);
    }

    /* VIEWS (read by the controller) */

    /// @inheritdoc ISuspectsRegistry
    /// @dev Controller use: `maturationDelay = base + suspicion * base / SUSPICION_SCALE`. A ban pins
    ///      this at SUSPICION_SCALE (the latch survives flag retraction), so the controller reads
    ///      suspicion alone.
    function suspicion(Id market, address suspect) external view override returns (uint256) {
        if (isBanned(market, suspect)) return SUSPICION_SCALE;
        uint256 local = _suspicion(market, suspect);
        uint256 global = _suspicion(EVERY_MARKET, suspect);
        return local > global ? local : global;
    }

    /// @inheritdoc ISuspectsRegistry
    function isBanned(Id market, address suspect) public view override returns (bool) {
        return _markets[market].state[suspect].banned || _markets[EVERY_MARKET].state[suspect].banned;
    }

    /// @inheritdoc ISuspectsRegistry
    function flagsOf(Id market, address suspect) external view override returns (uint16) {
        return _markets[market].state[suspect].flags;
    }

    function _suspicion(Id market, address suspect) internal view returns (uint256) {
        uint256 score = uint256(_markets[market].state[suspect].flags) * SUSPICION_SCALE / _quorum;
        return score > SUSPICION_SCALE ? SUSPICION_SCALE : score;
    }
}
