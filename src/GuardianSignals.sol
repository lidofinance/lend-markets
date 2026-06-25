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
import {
    BlockInfo,
    BlockInfoWithHash,
    GuardiansSignal,
    GuardiansOpinion,
    Status
} from "./types/GuardianSignalsTypes.sol";

/// @title GuardianSignals
/// @author Lido
/// @notice Per-market registry where guardians flag suspect accounts and a quorum of flags latches a ban.
///         Guardians are bots run by trusted actors. The market controller reads `getOpinion` to scale
///         collateral activation and to hard-block borrowing.
/// @dev Upgradeable behind a proxy (`initialize`, not a constructor), with ERC-7201 namespaced storage.
///      State is per `(market, account)`, where `strikes` is the size of the flagger set `flaggedBy`. The
///      escalation ladder, read through `getOpinion`:
///        - strikes == 0           : clean, normal activation.
///        - 0 < strikes < quorum   : the reader scales the activation delay up by the strike count.
///        - strikes >= quorum      : the status latches to `Banned`, the reader hard-blocks borrow.
///
///      The ban latches: retracting a flag never lifts it. `unban` lifts it and clears the flagger set, so
///      guardians re-evaluate from scratch and can re-ban an account that is still bad. `Immune` is the
///      override for accounts the guardians misjudge: while set, `flag`/`unflag` no-op and `getOpinion` reads
///      the account as clean. `ban` clears it.
///
///      The override splits into two opposing pairs by risk direction. The fast risk-reducing side sits at
///      the committee (`ACCESS_LIMITER_ROLE`: `ban`, `revokeImmunity`), the slow risk-increasing side at
///      governance (`ACCESS_RESTORER_ROLE`: `unban`, `grantImmunity`). `DEFAULT_ADMIN_ROLE` manages the
///      guardian set and quorum. The guardian set is a plain enumerable set, not a role.
///
///      Guardians report liveness: `flag`, `unflag`, and `heartbeat` each record a last-scanned block (O(1)).
///      `syncQuorumBlock` recomputes the quorum frontier that `getLastScannedQuorumBlock` returns — the highest
///      block a quorum have scanned past (monotonic) — decoupled from the heartbeat so heartbeats stay cheap.
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
    // CONSTANTS
    // ---

    /// @notice Maximum number of guardians. Capped low because every `heartbeat` (and the heartbeat inside
    ///         `flag` / `unflag`) re-sorts all guardians' last-scanned blocks to recompute the quorum frontier,
    ///         an O(n²)-worst-case cost. 32 keeps that bounded and still fits the quorum in `uint8` and a
    ///         strike count in `uint16`.
    uint256 public constant MAX_GUARDIANS_COUNT = 32;

    // ---
    // ROLES
    // ---

    bytes32 public constant ACCESS_LIMITER_ROLE = keccak256("ACCESS_LIMITER_ROLE");
    bytes32 public constant ACCESS_RESTORER_ROLE = keccak256("ACCESS_RESTORER_ROLE");

    // ---
    // STORAGE
    // ---

    uint8 private _quorum;
    BlockInfo private _quorumBlock;
    EnumerableSet.AddressSet private _guardians;
    mapping(address guardian => BlockInfo) private _heartbeats;
    mapping(Id market => mapping(address account => GuardiansSignal)) private _signalsByMarket;

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
    function heartbeat(BlockInfoWithHash calldata lastScannedBlock) external onlyGuardian {
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function syncQuorumBlock() external {
        _syncQuorumBlock();
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeat(address guardian) external view returns (BlockInfo memory) {
        return _heartbeats[guardian];
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeats() external view returns (address[] memory guardians, BlockInfo[] memory heartbeats) {
        guardians = _guardians.values();
        heartbeats = _getHeartbeats(guardians);
    }

    /// @inheritdoc IGuardianSignals
    function getLastScannedQuorumBlock() external view returns (BlockInfo memory) {
        return _quorumBlock;
    }

    // ---
    // GUARDIANS SIGNALLING
    // ---

    /// @inheritdoc IGuardianSignals
    function flag(Id market, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian
    {
        for (uint256 i; i < accounts.length; ++i) {
            _flag(market, accounts[i]);
        }
        _heartbeat(lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function unflag(Id market, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian
    {
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
        GuardiansSignal storage signal = _signalsByMarket[market][account];
        signal.status = Status.Banned;
        emit Banned(market, account);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Clears the flagger set, so the freshly-unbanned account can be re-flagged and re-banned from
    ///      scratch. Immunity is left to `revokeImmunity`.
    function unban(Id market, address account) external onlyRole(ACCESS_RESTORER_ROLE) {
        GuardiansSignal storage signal = _signalsByMarket[market][account];
        signal.status = Status.Normal;
        signal.flaggedBy.clear();
        emit Unbanned(market, account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function grantImmunity(Id market, address account) external onlyRole(ACCESS_RESTORER_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signalsByMarket[market][account];
        signal.status = Status.Immune;

        emit ImmunityGranted(market, account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function revokeImmunity(Id market, address account) external onlyRole(ACCESS_LIMITER_ROLE) {
        GuardiansSignal storage signal = _signalsByMarket[market][account];
        signal.status = Status.Normal;

        emit ImmunityRevoked(market, account, msg.sender);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IGuardianSignals
    function getOpinion(Id market, address account) external view returns (GuardiansOpinion memory opinion) {
        GuardiansSignal storage signal = _signalsByMarket[market][account];

        opinion.status = signal.status;
        opinion.quorumBlock = _quorumBlock;
        opinion.flagCount = signal.flaggedBy.length();
        // `Immune` exempts the account from guardian signals: zero its effective strikes so the surcharge and
        // every reader treat it as clean, while `flagCount` keeps the raw flag activity visible.
        opinion.strikes = signal.status == Status.Immune ? 0 : opinion.flagCount;
    }

    /// @inheritdoc IGuardianSignals
    function getFlaggedBy(Id market, address account) external view returns (address[] memory) {
        return _signalsByMarket[market][account].flaggedBy.values();
    }

    // ---
    // INTERNAL METHODS
    // ---

    /// @dev Record the caller's last-scanned block. O(1): the quorum frontier is recomputed separately by
    ///      `_syncQuorumBlock`, so a heartbeat (and the heartbeat inside `flag`/`unflag`) does not pay the
    ///      whole-set read and sort.
    function _heartbeat(BlockInfoWithHash calldata lastScannedBlock) internal {
        // a guardian cannot have scanned a block that does not exist yet
        if (lastScannedBlock.number > block.number) {
            revert BlockInTheFuture();
        }

        if (blockhash(lastScannedBlock.number) != lastScannedBlock.hash) {
            revert InvalidBlockHash();
        }

        _heartbeats[msg.sender] = BlockInfo(lastScannedBlock.number, lastScannedBlock.timestamp);
        emit Heartbeat(msg.sender);
    }

    /// @dev Recompute the quorum frontier (the quorum-th largest heartbeat) and ratchet it up. Monotonic: a
    ///      guardian rotation that adds fresh zero-heartbeat members cannot pull it back, since the past
    ///      quorum's coverage stays valid.
    function _syncQuorumBlock() internal {
        uint256 n = _guardians.length();
        if (n < _quorum) return;
        address[] memory guardians = _guardians.values();
        // Pack each heartbeat as (number << 40 | timestamp) so a uint256 sort orders by block number, with
        // the timestamp carried alongside. The quorum-th largest is the frontier.
        uint256[] memory packed = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            BlockInfo storage hb = _heartbeats[guardians[i]];
            packed[i] = (uint256(hb.number) << 40) | uint256(hb.timestamp);
        }
        uint256 frontier = Arrays.sort(packed)[n - _quorum];
        if (uint40(frontier >> 40) > _quorumBlock.number) {
            _quorumBlock = BlockInfo(uint40(frontier >> 40), uint40(frontier));
        }
    }

    function _getHeartbeats(address[] memory guardians) internal view returns (BlockInfo[] memory heartbeats) {
        heartbeats = new BlockInfo[](guardians.length);
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

        GuardiansSignal storage signal = _signalsByMarket[market][account];
        if (signal.status == Status.Immune || !signal.flaggedBy.add(msg.sender)) return;

        uint256 strikes = signal.flaggedBy.length();
        if (strikes >= _quorum && signal.status != Status.Banned) {
            signal.status = Status.Banned;
            emit Banned(market, account);
        }
        emit Flagged(market, account, msg.sender, uint16(strikes));
    }

    /// @dev Single-account unflag, looped by `unflag`. No-op when `account` is immune or the caller does not
    ///      flag it. Does not lift a latched ban.
    function _unflag(Id market, address account) internal {
        GuardiansSignal storage signal = _signalsByMarket[market][account];
        if (signal.status == Status.Immune || !signal.flaggedBy.remove(msg.sender)) return;

        emit Unflagged(market, account, msg.sender, uint16(signal.flaggedBy.length()));
    }
}
