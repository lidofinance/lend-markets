// SPDX-License-Identifier: GPL-2.0-or-later
// Flexible pragma trigger: forces Forge to emit the `AdaptiveCurveIrm` artifact under `out/` so
// `LidoLendDeployer._deployIrm` can pick it up via `vm.getCode`. The IRM source is pinned to strict
// 0.8.19, which cannot share a compilation unit with our 0.8.36-strict tests; this trigger isolates
// the import so each side compiles under its own solc version.
pragma solidity >=0.8.19;

// solhint-disable-next-line no-unused-import
import {AdaptiveCurveIrm} from "@lido-lend-irm/src/adaptive-curve-irm/AdaptiveCurveIrm.sol";
