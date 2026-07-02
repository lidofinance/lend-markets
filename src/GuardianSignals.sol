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
import {IGuardianSignalsView} from "./interfaces/IGuardianSignalsView.sol";
import {
    BlockInfo,
    BlockInfoWithHash,
    GuardianMarketConfig,
    GuardiansSignal,
    GuardiansOpinion,
    Status
} from "./types/GuardianSignalsTypes.sol";

/// @title GuardianSignals
/// @author Lido
/// @notice Per-market registry where guardians flag suspect accounts and a quorum of flags latches a ban. Each
///         market carries its own guardian committee: its guardian set, quorum, liveness frontier, and
///         per-guardian heartbeats are all keyed by market, configured per market rather than globally.
///         Guardians are bots run by trusted actors. The market controller reads `getOpinion` to scale
///         collateral activation and to hard-block borrowing.
/// @dev Upgradeable behind a proxy (`initialize`, not a constructor), with ERC-7201 namespaced storage.
///      Signal state is per `(market, account)`, where `strikes` is the size of the flagger set `flaggedBy`. The
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
///      Each override action carries its own role, split by concern (ban vs immunity) and risk direction. The
///      fast risk-reducing side sits at the committee (`BAN_ROLE`: `ban`; `IMMUNITY_REVOKER_ROLE`:
///      `revokeImmunity`), the slow risk-increasing side at governance (`UNBAN_ROLE`: `unban`;
///      `IMMUNITY_GRANTER_ROLE`: `grantImmunity`). `GUARDIANS_MANAGER_ROLE` manages each market's guardian set
///      and config. Every role is granted globally or per market (`marketRole(base, marketId)`); a guardian set
///      is a plain enumerable set, not a role.
///
///      Guardians report liveness per market: `flag`, `unflag`, and `heartbeat` each record a last-scanned
///      block (O(1)). `syncQuorumBlock` recomputes the market's quorum frontier that `getLastScannedQuorumBlock`
///      returns — the highest block a quorum have scanned past (monotonic) — decoupled from the heartbeat so
///      heartbeats stay cheap.
///
///      Events and errors are declared in {IGuardianSignals}.
contract GuardianSignals layout at erc7201("lido.lend.storage.GuardianSignals")
    is
    Initializable,
    AccessControlEnumerableUpgradeable,
    IGuardianSignals
{
    using EnumerableSet for EnumerableSet.AddressSet;

    // ---
    // CONSTANTS
    // ---

    /// @notice Maximum number of guardians per market. Capped low because every `heartbeat` (and the heartbeat
    ///         inside `flag` / `unflag`) re-sorts the market's guardians' last-scanned blocks to recompute the
    ///         quorum frontier, an O(n²)-worst-case cost. 32 keeps that bounded and still fits the quorum in
    ///         `uint8` and a strike count in `uint16`.
    uint256 public constant MAX_GUARDIANS_COUNT = 32;

    /// @notice Ceiling on a market's per-flag activation-delay surcharge, so a single misfired flag cannot pin
    ///         an account's collateral for an unreasonable time.
    uint256 public constant MAX_DELAY_PER_STRIKE = 7 days;

    /// @notice Ceiling on a market's suspect window: the horizon within which a suspect report still counts
    ///         toward the activation delay. Reports older than the window are ignored.
    uint256 public constant MAX_SUSPECT_WINDOW = 30 days;

    // ---
    // ROLES
    // ---

    /// @dev Base of the `ban` role (fast, risk-reducing). Granted globally (acts on every market) or per market
    ///      via `marketRole(BAN_ROLE, marketId)`.
    bytes32 public constant BAN_ROLE = keccak256("BAN_ROLE");

    /// @dev Base of the `unban` role (slow, risk-increasing). Global or per market.
    bytes32 public constant UNBAN_ROLE = keccak256("UNBAN_ROLE");

    /// @dev Base of the `revokeImmunity` role (fast, risk-reducing). Global or per market.
    bytes32 public constant IMMUNITY_REVOKER_ROLE = keccak256("IMMUNITY_REVOKER_ROLE");

    /// @dev Base of the `grantImmunity` role (slow, risk-increasing). Global or per market.
    bytes32 public constant IMMUNITY_GRANTER_ROLE = keccak256("IMMUNITY_GRANTER_ROLE");

    /// @dev Base of the guardian-config role (`setMarketConfig`, `addGuardian`, `removeGuardian`). Global or
    ///      per market.
    bytes32 public constant GUARDIANS_MANAGER_ROLE = keccak256("GUARDIANS_MANAGER_ROLE");

    // ---
    // STORAGE
    // ---

    /// @dev A market's guardian committee: its guardian set, ban quorum, quorum-scan liveness frontier, and the
    ///      per-guardian last-scanned blocks. One instance per market.
    struct MarketGuardians {
        uint8 quorum;
        uint40 delayPerStrike;
        uint40 delayPerSuspect;
        uint40 maxDelay;
        uint40 suspectWindow;
        BlockInfo quorumBlock;
        EnumerableSet.AddressSet guardians;
        mapping(address guardian => BlockInfo) heartbeats;
    }

    mapping(Id marketId => MarketGuardians) private _marketGuardians;
    mapping(Id marketId => mapping(address account => GuardiansSignal)) private _signalsByMarket;

    // ---
    // MODIFIERS
    // ---

    modifier onlyGuardian(Id marketId) {
        if (!_marketGuardians[marketId].guardians.contains(msg.sender)) revert NotGuardian();
        _;
    }

    /// @dev Passes when the caller holds the global `baseRole` or its per-market instance for `marketId`.
    modifier onlyMarketRole(bytes32 baseRole, Id marketId) {
        _checkMarketRole(baseRole, marketId);
        _;
    }

    // ---
    // INITIALIZATION
    // ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Set the admin. Guardian sets and per-market config are configured per market via `setMarketConfig`.
    /// @param admin Holder of `DEFAULT_ADMIN_ROLE`, the default admin of the guardian and override roles.
    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAddress();

        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IGuardianSignals
    function marketRole(bytes32 baseRole, Id marketId) public pure returns (bytes32) {
        return keccak256(abi.encode(baseRole, marketId));
    }

    // ---
    // GUARDIANS & QUORUM (per market)
    // ---

    /// @inheritdoc IGuardianSignals
    function setMarketConfig(Id marketId, GuardianMarketConfig calldata config)
        external
        onlyMarketRole(GUARDIANS_MANAGER_ROLE, marketId)
    {
        if (config.delayPerStrike > MAX_DELAY_PER_STRIKE) revert DelayPerStrikeTooHigh();
        if (config.delayPerSuspect > MAX_DELAY_PER_STRIKE) revert DelayPerSuspectTooHigh();
        if (config.suspectWindow > MAX_SUSPECT_WINDOW) revert SuspectWindowTooHigh();

        MarketGuardians storage marketGuardians = _marketGuardians[marketId];

        // Reset the set to the new roster. Zero the quorum first so re-seeding does not transiently trip the
        // quorum-reachability check while the set is smaller than the old quorum.
        marketGuardians.quorum = 0;
        address[] memory existing = marketGuardians.guardians.values();
        for (uint256 i; i < existing.length; ++i) {
            marketGuardians.guardians.remove(existing[i]);
            emit GuardianRemoved(marketId, existing[i]);
        }
        for (uint256 i; i < config.guardians.length; ++i) {
            _addGuardian(marketId, config.guardians[i]);
        }
        _setQuorum(marketId, config.quorum);

        marketGuardians.delayPerStrike = uint40(config.delayPerStrike);
        marketGuardians.delayPerSuspect = uint40(config.delayPerSuspect);
        marketGuardians.maxDelay = uint40(config.maxDelay);
        marketGuardians.suspectWindow = uint40(config.suspectWindow);
        emit MarketConfigSet(
            marketId,
            config.quorum,
            config.delayPerStrike,
            config.delayPerSuspect,
            config.maxDelay,
            config.suspectWindow
        );
    }

    /// @inheritdoc IGuardianSignals
    function addGuardian(Id marketId, address guardian) external onlyMarketRole(GUARDIANS_MANAGER_ROLE, marketId) {
        _addGuardian(marketId, guardian);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Reverts if removal would drop the set below the market's `quorum`, so the quorum stays reachable.
    function removeGuardian(Id marketId, address guardian) external onlyMarketRole(GUARDIANS_MANAGER_ROLE, marketId) {
        MarketGuardians storage marketGuardians = _marketGuardians[marketId];
        if (!marketGuardians.guardians.remove(guardian)) revert NotGuardian();
        if (marketGuardians.guardians.length() < marketGuardians.quorum) revert WouldBreakQuorum();
        emit GuardianRemoved(marketId, guardian);
    }

    /// @inheritdoc IGuardianSignals
    function getMarketConfig(Id marketId) external view returns (GuardianMarketConfig memory) {
        MarketGuardians storage marketGuardians = _marketGuardians[marketId];
        return GuardianMarketConfig({
            guardians: marketGuardians.guardians.values(),
            quorum: marketGuardians.quorum,
            delayPerStrike: marketGuardians.delayPerStrike,
            delayPerSuspect: marketGuardians.delayPerSuspect,
            maxDelay: marketGuardians.maxDelay,
            suspectWindow: marketGuardians.suspectWindow
        });
    }

    /// @inheritdoc IGuardianSignals
    function isGuardian(Id marketId, address account) external view returns (bool) {
        return _marketGuardians[marketId].guardians.contains(account);
    }

    /// @inheritdoc IGuardianSignals
    function getGuardianCount(Id marketId) external view returns (uint256) {
        return _marketGuardians[marketId].guardians.length();
    }

    /// @inheritdoc IGuardianSignals
    function getGuardians(Id marketId) external view returns (address[] memory) {
        return _marketGuardians[marketId].guardians.values();
    }

    // ---
    // LIVENESS (per market)
    // ---

    /// @inheritdoc IGuardianSignals
    function heartbeat(Id marketId, BlockInfoWithHash calldata lastScannedBlock) external onlyGuardian(marketId) {
        _heartbeat(marketId, lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function syncQuorumBlock(Id marketId) external {
        _syncQuorumBlock(marketId);
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeat(Id marketId, address guardian) external view returns (BlockInfo memory) {
        return _marketGuardians[marketId].heartbeats[guardian];
    }

    /// @inheritdoc IGuardianSignals
    function getHeartbeats(Id marketId)
        external
        view
        returns (address[] memory guardians, BlockInfo[] memory heartbeats)
    {
        guardians = _marketGuardians[marketId].guardians.values();
        heartbeats = _getHeartbeats(marketId, guardians);
    }

    /// @inheritdoc IGuardianSignals
    function getLastScannedQuorumBlock(Id marketId) external view returns (BlockInfo memory) {
        return _marketGuardians[marketId].quorumBlock;
    }

    // ---
    // GUARDIANS SIGNALLING
    // ---

    /// @inheritdoc IGuardianSignals
    function flag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian(marketId)
    {
        for (uint256 i; i < accounts.length; ++i) {
            _flag(marketId, accounts[i]);
        }
        _heartbeat(marketId, lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function unflag(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian(marketId)
    {
        for (uint256 i; i < accounts.length; ++i) {
            _unflag(marketId, accounts[i]);
        }
        _heartbeat(marketId, lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function reportSuspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian(marketId)
    {
        for (uint256 i; i < accounts.length; ++i) {
            _reportSuspect(marketId, accounts[i]);
        }
        _heartbeat(marketId, lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    function clearSuspect(Id marketId, address[] calldata accounts, BlockInfoWithHash calldata lastScannedBlock)
        external
        onlyGuardian(marketId)
    {
        for (uint256 i; i < accounts.length; ++i) {
            _clearSuspect(marketId, accounts[i]);
        }
        _heartbeat(marketId, lastScannedBlock);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Permissionless cleanup: removes flags left behind by removed guardians. Status is never touched —
    ///      the ban latch means a permissionless caller can lower the flag count but cannot unban. Runs on any
    ///      status, Immune included, so stale flags can be cleared before `revokeImmunity` re-derives status.
    function prune(Id marketId, address account) external {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        EnumerableSet.AddressSet storage guardians = _marketGuardians[marketId].guardians;

        // Iterate a snapshot: removing from the live set (swap-and-pop) while looping the memory copy is safe.
        address[] memory flaggers = signal.flaggedBy.values();
        for (uint256 i; i < flaggers.length; ++i) {
            address flagger = flaggers[i];
            if (!guardians.contains(flagger)) {
                signal.flaggedBy.remove(flagger);
                emit FlagPruned(marketId, account, flagger, uint16(signal.flaggedBy.length()));
            }
        }

        // Same cleanup for suspect reports left behind by removed guardians.
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (!guardians.contains(suspects[i])) _pruneSuspect(marketId, account, signal, suspects[i]);
        }
    }

    // ---
    // COMMITTEE / GOVERNANCE OVERRIDE
    // ---

    /// @inheritdoc IGuardianSignals
    /// @dev Clears immunity so the block takes effect even on an exempt account.
    function ban(Id marketId, address account) external onlyMarketRole(BAN_ROLE, marketId) {
        if (account == address(0)) revert ZeroAddress();
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        signal.status = Status.Banned;
        emit Banned(marketId, account);
    }

    /// @inheritdoc IGuardianSignals
    /// @dev Clears the flagger set, so the freshly-unbanned account can be re-flagged and re-banned from
    ///      scratch. Immunity is left to `revokeImmunity`.
    function unban(Id marketId, address account) external onlyMarketRole(UNBAN_ROLE, marketId) {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        signal.status = Status.Normal;
        signal.flaggedBy.clear();
        emit Unbanned(marketId, account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function grantImmunity(Id marketId, address account) external onlyMarketRole(IMMUNITY_GRANTER_ROLE, marketId) {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        signal.status = Status.Immune;

        emit ImmunityGranted(marketId, account, msg.sender);
    }

    /// @inheritdoc IGuardianSignals
    function revokeImmunity(Id marketId, address account) external onlyMarketRole(IMMUNITY_REVOKER_ROLE, marketId) {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        // Only act on an actually-immune account: revoking is a no-op otherwise, so this never clears a
        // committee `ban` (a forced `Banned` carries no flags) nor disturbs a `Normal` account.
        if (signal.status != Status.Immune) return;
        // Restore the status the flag set implies rather than forcing `Normal`: an account still carrying a
        // quorum of flags re-latches to `Banned`, so revoking immunity never silently unbans it.
        signal.status = signal.flaggedBy.length() >= _marketGuardians[marketId].quorum ? Status.Banned : Status.Normal;

        emit ImmunityRevoked(marketId, account, msg.sender);
    }

    // ---
    // VIEWS
    // ---

    /// @inheritdoc IGuardianSignals
    function getOpinion(Id marketId, address account) external view returns (GuardiansOpinion memory opinion) {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];

        opinion.status = signal.status;
        opinion.quorumBlock = _marketGuardians[marketId].quorumBlock;
        opinion.flagCount = signal.flaggedBy.length();
        // `Immune` exempts the account from guardian signals: zero its effective strikes so the surcharge and
        // every reader treat it as clean, while `flagCount` keeps the raw flag activity visible.
        opinion.strikes = signal.status == Status.Immune ? 0 : opinion.flagCount;
    }

    /// @inheritdoc IGuardianSignalsView
    function getActivationDelay(Id marketId, address account) external view returns (uint256) {
        return _activationDelay(marketId, account);
    }

    /// @inheritdoc IGuardianSignalsView
    function getActivationSyncInputs(Id marketId, address account)
        external
        view
        returns (uint256 activationDelay, uint256 quorumBlockTimestamp)
    {
        activationDelay = _activationDelay(marketId, account);
        quorumBlockTimestamp = _marketGuardians[marketId].quorumBlock.timestamp;
    }

    /// @inheritdoc IGuardianSignalsView
    function isBanned(Id marketId, address account) external view returns (bool) {
        return _signalsByMarket[marketId][account].status == Status.Banned;
    }

    /// @inheritdoc IGuardianSignalsView
    function getFlagCount(Id marketId, address account) external view returns (uint256) {
        return _signalsByMarket[marketId][account].flaggedBy.length();
    }

    /// @inheritdoc IGuardianSignals
    function getFlaggedBy(Id marketId, address account) external view returns (address[] memory) {
        return _signalsByMarket[marketId][account].flaggedBy.values();
    }

    /// @inheritdoc IGuardianSignals
    function getSuspectedBy(Id marketId, address account)
        external
        view
        returns (address[] memory guardians, uint40[] memory reportedAt)
    {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        guardians = signal.suspectedBy.values();
        reportedAt = new uint40[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            reportedAt[i] = signal.suspectedAt[guardians[i]];
        }
    }

    // ---
    // INTERNAL METHODS
    // ---

    /// @dev Record the caller's last-scanned block for `marketId`. O(1): the quorum frontier is recomputed
    ///      separately by `_syncQuorumBlock`, so a heartbeat (and the heartbeat inside `flag`/`unflag`) does not
    ///      pay the whole-set read and sort.
    function _heartbeat(Id marketId, BlockInfoWithHash calldata lastScannedBlock) internal {
        // a guardian cannot have scanned a block that does not exist yet
        if (lastScannedBlock.number > block.number) revert BlockInTheFuture();
        // The chain cannot attest an arbitrary block's timestamp by number, so the frontier trusts the
        // guardian-reported timestamp. Bound it to the past and force it non-decreasing per guardian, so a
        // guardian cannot backdate or fast-forward the quorum-scan frontier it feeds.
        if (lastScannedBlock.timestamp > block.timestamp) revert TimestampInTheFuture();

        mapping(address => BlockInfo) storage heartbeats = _marketGuardians[marketId].heartbeats;
        if (lastScannedBlock.timestamp < heartbeats[msg.sender].timestamp) revert HeartbeatTimestampRegressed();
        // number + hash only prove the reported block is real and un-reorged; the frontier orders by timestamp.
        if (blockhash(lastScannedBlock.number) != lastScannedBlock.hash) revert InvalidBlockHash();

        heartbeats[msg.sender] = BlockInfo(lastScannedBlock.number, lastScannedBlock.timestamp);
        emit Heartbeat(marketId, msg.sender, lastScannedBlock.number, lastScannedBlock.timestamp);
    }

    /// @dev Recompute the market's quorum frontier (the quorum-th largest heartbeat) and ratchet it up.
    ///      Monotonic: a guardian rotation that adds fresh zero-heartbeat members cannot pull it back, since the
    ///      past quorum's coverage stays valid.
    function _syncQuorumBlock(Id marketId) internal {
        MarketGuardians storage marketGuardians = _marketGuardians[marketId];
        uint256 quorum = marketGuardians.quorum;
        uint256 n = marketGuardians.guardians.length();
        if (quorum == 0 || n < quorum) return;
        address[] memory guardians = marketGuardians.guardians.values();
        // Pack each heartbeat as (timestamp << 40 | number) so a uint256 sort orders by timestamp — the value
        // the frontier gates on — carrying the block number alongside for off-chain tooling. The quorum-th
        // largest is the frontier.
        uint256[] memory packed = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            BlockInfo storage hb = marketGuardians.heartbeats[guardians[i]];
            packed[i] = (uint256(hb.timestamp) << 40) | uint256(hb.number);
        }
        uint256 frontier = Arrays.sort(packed)[n - quorum];
        uint40 frontierTimestamp = uint40(frontier >> 40);
        if (frontierTimestamp > marketGuardians.quorumBlock.timestamp) {
            marketGuardians.quorumBlock = BlockInfo(uint40(frontier), frontierTimestamp);
        }
    }

    function _getHeartbeats(Id marketId, address[] memory guardians)
        internal
        view
        returns (BlockInfo[] memory heartbeats)
    {
        mapping(address => BlockInfo) storage marketHeartbeats = _marketGuardians[marketId].heartbeats;
        heartbeats = new BlockInfo[](guardians.length);
        for (uint256 i; i < guardians.length; ++i) {
            heartbeats[i] = marketHeartbeats[guardians[i]];
        }
    }

    function _setQuorum(Id marketId, uint256 newQuorum) internal {
        MarketGuardians storage marketGuardians = _marketGuardians[marketId];
        if (newQuorum == 0 || newQuorum > marketGuardians.guardians.length()) revert BadQuorum();
        marketGuardians.quorum = uint8(newQuorum);
    }

    /// @dev Revert unless the caller holds the global `baseRole` or its per-market instance for `marketId`.
    function _checkMarketRole(bytes32 baseRole, Id marketId) internal view {
        if (hasRole(baseRole, msg.sender) || hasRole(marketRole(baseRole, marketId), msg.sender)) return;
        revert AccessControlUnauthorizedAccount(msg.sender, marketRole(baseRole, marketId));
    }

    function _addGuardian(Id marketId, address guardian) internal {
        if (guardian == address(0)) revert ZeroAddress();
        EnumerableSet.AddressSet storage guardians = _marketGuardians[marketId].guardians;
        if (guardians.length() >= MAX_GUARDIANS_COUNT) revert MaxGuardiansReached();
        if (!guardians.add(guardian)) revert AlreadyGuardian();
        emit GuardianAdded(marketId, guardian);
    }

    /// @dev Single-account flag, looped by `flag`. No-op (no state change, no event) when `account` is immune
    ///      or the caller already flags it, so a batch never reverts on a skip.
    function _flag(Id marketId, address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        if (signal.status == Status.Immune || !signal.flaggedBy.add(msg.sender)) return;

        uint256 strikes = signal.flaggedBy.length();
        if (strikes >= _marketGuardians[marketId].quorum && signal.status != Status.Banned) {
            signal.status = Status.Banned;
            emit Banned(marketId, account);
        }
        emit Flagged(marketId, account, msg.sender, uint16(strikes));
    }

    /// @dev Single-account unflag, looped by `unflag`. No-op when `account` is immune or the caller does not
    ///      flag it. Does not lift a latched ban.
    function _unflag(Id marketId, address account) internal {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        if (signal.status == Status.Immune || !signal.flaggedBy.remove(msg.sender)) return;

        emit Unflagged(marketId, account, msg.sender, uint16(signal.flaggedBy.length()));
    }

    /// @dev Single-account suspect report, looped by `reportSuspect`. No-op while `account` is immune. Records
    ///      (or refreshes) the caller's report timestamp, so a re-report keeps the suspicion inside the window.
    ///      Never latches a ban.
    function _reportSuspect(Id marketId, address account) internal {
        if (account == address(0)) revert ZeroAddress();

        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        if (signal.status == Status.Immune) return;

        _pruneExpiredSuspects(marketId, account);
        signal.suspectedBy.add(msg.sender);
        signal.suspectedAt[msg.sender] = uint40(block.timestamp);
        emit Suspected(marketId, account, msg.sender, block.timestamp);
    }

    /// @dev Single-account suspect retraction, looped by `clearSuspect`. No-op when the caller has no live
    ///      suspect report on the account.
    function _clearSuspect(Id marketId, address account) internal {
        _pruneExpiredSuspects(marketId, account);
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        if (!signal.suspectedBy.remove(msg.sender)) return;

        signal.suspectedAt[msg.sender] = 0;
        emit SuspectCleared(marketId, account, msg.sender);
    }

    /// @dev Count the market's live suspect reports on `account` that still fall inside the suspect window. A
    ///      report at `t` counts while `t + window >= block.timestamp`; older ones are ignored (but stay in the
    ///      set until retracted or pruned).
    /// @dev The collateral-activation delay surcharge for `account`: `type(uint256).max` when banned, 0 when
    ///      immune, else `min(flags * delayPerStrike + freshSuspects * delayPerSuspect, maxDelay)` (0 = uncapped).
    function _activationDelay(Id marketId, address account) internal view returns (uint256) {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        if (signal.status == Status.Banned) return type(uint256).max;
        if (signal.status == Status.Immune) return 0;
        MarketGuardians storage marketGuardians = _marketGuardians[marketId];
        uint256 delay = signal.flaggedBy.length() * marketGuardians.delayPerStrike
            + _activeSuspectCount(marketId, account) * marketGuardians.delayPerSuspect;
        uint256 maxDelay = marketGuardians.maxDelay;
        return maxDelay != 0 && delay > maxDelay ? maxDelay : delay;
    }

    function _activeSuspectCount(Id marketId, address account) internal view returns (uint256 count) {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        uint256 window = _marketGuardians[marketId].suspectWindow;
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (uint256(signal.suspectedAt[suspects[i]]) + window >= block.timestamp) ++count;
        }
    }

    /// @dev Drop suspect reports on `account` whose window has lapsed, so the live set stays bounded and only
    ///      carries reports that still count. Run opportunistically on report/clear. A lapsed report already
    ///      stopped counting toward the delay, so removing it changes nothing but the set size.
    function _pruneExpiredSuspects(Id marketId, address account) internal {
        GuardiansSignal storage signal = _signalsByMarket[marketId][account];
        uint256 window = _marketGuardians[marketId].suspectWindow;
        address[] memory suspects = signal.suspectedBy.values();
        for (uint256 i; i < suspects.length; ++i) {
            if (uint256(signal.suspectedAt[suspects[i]]) + window < block.timestamp) {
                _pruneSuspect(marketId, account, signal, suspects[i]);
            }
        }
    }

    /// @dev Remove one guardian's suspect report on `account` and log it. Shared by the removed-guardian sweep
    ///      in `prune` and the window-expiry sweep in `_pruneExpiredSuspects`.
    function _pruneSuspect(Id marketId, address account, GuardiansSignal storage signal, address suspect) private {
        signal.suspectedBy.remove(suspect);
        signal.suspectedAt[suspect] = 0;
        emit SuspectPruned(marketId, account, suspect);
    }
}
