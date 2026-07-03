// SPDX-License-Identifier: GPL-2.0-or-later
// Flexible pragma trigger: this file exists ONLY to force Forge to emit the `VaultV2` and
// `MorphoMarketV1AdapterV2` artifacts under `out/` so the integration test can `vm.deployCode`
// them. Both contracts are pinned to strict 0.8.28 and cannot share a compilation unit with our
// 0.8.35 tests; this trigger isolates that import so each side compiles under its own solc.
pragma solidity >=0.8.28;

// solhint-disable no-unused-import
import {VaultV2} from "@vault-v2/src/VaultV2.sol";
import {MorphoMarketV1AdapterV2} from "@vault-v2/src/adapters/MorphoMarketV1AdapterV2.sol";
// solhint-enable no-unused-import
