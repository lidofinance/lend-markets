// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

// Compile anchor for the stock Bundler3 dispatcher. Forge only compiles lib files that something
// imports: with no import anywhere, the contract would never be built and no artifact would
// appear in `out/` for the tests to deploy. But none of our files may import it either - it
// accepts solc 0.8.28 and nothing else, while the rest of this repo is 0.8.35, and no compiler
// version satisfies both sides of such an import.
//
// This file is the way through: it accepts 0.8.28 itself and does nothing but import the
// contract, so forge compiles it in its own 0.8.28 group and writes its artifact to `out/`.
// From there `BundlerSetup` deploys it with `deployCode`. The general adapter needs no anchor:
// its vendored copy lives in `src/adapters/`, which forge always compiles.
import {Bundler3} from "@bundler3/src/Bundler3.sol";
