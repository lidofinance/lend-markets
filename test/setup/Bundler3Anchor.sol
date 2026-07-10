// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

// Compile anchor for the stock bundler3 contracts. Forge only compiles files that something
// imports: with no import anywhere, these contracts would never be built and no artifact would
// appear in `out/` for the tests to deploy. But none of our files may import them either - they
// accept solc 0.8.28 and nothing else, while the rest of this repo is 0.8.35, and no compiler
// version satisfies both sides of such an import.
//
// This file is the way through: it accepts 0.8.28 itself and does nothing but import the two
// contracts, so forge compiles them in their own 0.8.28 group and writes their artifacts to
// `out/`. From there `BundlerSetup` deploys them with `deployCode` and the tests call them
// through `IGeneralAdapter1`, an interface with matching signatures that 0.8.35 code may import.
import {Bundler3} from "@bundler3/src/Bundler3.sol";
import {EthereumGeneralAdapter1} from "@bundler3/src/adapters/EthereumGeneralAdapter1.sol";
