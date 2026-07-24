// SPDX-License-Identifier: GPL-2.0-or-later
// Trigger: forces Forge to emit the `LidoLend` artifact under `out/` for TEST runs, so tests that
// deploy the core via `vm.getCode` (`test/scenario/LidoLendOwner.t.sol`) can resolve it. A full
// `forge test` compiles the core anyway; this keeps the artifact present under sparse (filtered,
// `--match-*`) compilation too. The deploy scripts use a direct `new LidoLend()`, so they need no trigger.
pragma solidity >=0.8.19;

// solhint-disable-next-line no-unused-import
import {LidoLend} from "@lido-lend/src/LidoLend.sol";
