// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Easy Track's factories over the Hoodi protocol, written by hand: the easy-track repository deploys them
///         after the core, and a vote registers them.
library EasyTrackHoodi {
    /// @notice `LidoLendActivateMarket`, whose motions activate markets; zero until it is deployed.
    address internal constant ACTIVATE_MARKET_FACTORY = 0xC4F75E3Da78230Ff9235A2E5Cf6F1962C56A4C69;
}
