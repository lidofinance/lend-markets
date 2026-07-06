// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILidoLend} from "@lido-lend/src/interfaces/ILidoLend.sol";
import {Id, MarketParams} from "@lido-lend/src/interfaces/IMorpho.sol";
import {IOracle} from "@lido-lend/src/interfaces/IOracle.sol";

import {ILidoLendMarketController} from "../../src/interfaces/ILidoLendMarketController.sol";
import {IGuardianSignals} from "../../src/interfaces/IGuardianSignals.sol";
import {ILidoLendERC4626} from "../../src/interfaces/ILidoLendERC4626.sol";
import {LidoLendDeployer} from "../../script/lib/LidoLendDeployer.sol";

import {IOssifiableProxy} from "./IOssifiableProxy.sol";

/// @notice Which interest-rate model a market is deployed with. Selectable from the test config.
enum IrmKind {
    Adaptive, // AdaptiveCurveIrm — rate follows utilization (realistic, no per-market setup)
    Fixed // FixedRateIrm — constant per-market rate (deterministic)
}

/// @notice One deployed market: its config + identity, its per-market contracts (each proxied contract
///         carries a typed impl handle and an `IOssifiableProxy` admin handle at the same address), and a
///         denormalized handle on the shared `core` so action helpers over a `Market` reach it directly.
///         The core (`LidoLend`) is a singleton — one core hosts many markets — so it lives on `Protocol`,
///         not here; `core` below is a copy of that single handle for ergonomics.
struct Market {
    // identity + config
    LidoLendDeployer.DeployConfig config;
    MarketParams params;
    Id id;
    // shared singleton, copied here so `Market` helpers are self-contained
    ILidoLend core;
    // per-market contracts
    ILidoLendMarketController controller;
    IOssifiableProxy controllerProxy;
    address controllerImpl;
    IGuardianSignals guardianSignals;
    IOssifiableProxy guardianSignalsProxy;
    ILidoLendERC4626 vault;
    IOssifiableProxy vaultProxy;
    IOracle oracle;
    IOssifiableProxy oracleProxy;
    address irm;
    // market tokens
    IERC20 loanToken;
    IERC20 collateralToken;
}

/// @notice The deployed protocol: the deploy config, the singletons (one `LidoLend` core, one
///         guardian-signals registry per project), and every market created on that core. One core hosts
///         many markets, keyed by id; each `Market` also carries its own per-market config.
struct Protocol {
    LidoLendDeployer.DeployConfig config;
    ILidoLend core;
    IOssifiableProxy coreProxy;
    IGuardianSignals guardianSignals;
    IOssifiableProxy guardianSignalsProxy;
    Market[] markets;
}
