// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.36;

/// @notice Easy Track's factories over the Mainnet protocol, written by hand: the easy-track repository deploys them
///         after the core, and a vote registers them.
library EasyTrackMainnet {
    /// @notice `LidoLendActivateMarket`, whose motions activate markets; zero until it is deployed.
    address internal constant ACTIVATE_MARKET_FACTORY = 0x17bb2A2B5983D29392A5d31D627D4C8B13383fe6;
}
