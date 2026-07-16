# Deployed-address maps

One JSON address map per network, read at runtime by the fork tests (`test/fork/helpers/ForkTest.sol`) and
by the deploy tooling. This is the single source of addresses for a network — fork tests hold no hardcoded
addresses.

## Running the fork tests

The suites are network-blind: give them an RPC to fork and a path to the address map. Nothing else selects a
network.

```sh
make test-fork ETH_RPC_URL=<rpc> DEPLOYMENT=deployments/deployed-mainnet.json
```

Pass the variables as make command-line assignments, as above: they override a `.env`, whereas plain
`VAR=x make test-fork` is silently beaten by `.env` values loaded by the Makefile.

`ForkTest._fork()` forks `ETH_RPC_URL` (latest block) and loads the `DEPLOYMENT` JSON. It reverts when
either env var is unset, the map file is missing, or the RPC does not answer, and `_addr` reverts on a key
the map does not define — a fork suite runs or it fails, it never skips.

## Adding a network

Config only — no Solidity or `foundry.toml` changes. Drop a `deployments/deployed-<network>.json` (schema
below) and point the two env vars at it:

```sh
make test-fork ETH_RPC_URL=<network-rpc> DEPLOYMENT=deployments/deployed-<network>.json
```

A suite that needs an address the map does not define fails (`_addr` reverts naming the missing key), so
a network's map must define every key the suites read — e.g. a map without `external.usdy` fails the
USDY-market suite.

## Schema

```jsonc
{
  "external": {          // addresses this network already hosts (not deployed by us)
    "weth": "0x…",
    "stEth": "0x…",
    "wstEth": "0x…",
    "usdy": "0x…",       // the USDY suite reads it — a map without it fails that suite
    "usdt": "0x…",
    "ondoOracle": "0x…",
    "usdtUsdFeed": "0x…",
    "usdyBlocklist": "0x…"
  },
  "protocol": {          // Lido Lend contracts, filled after deploying to this network
    // "core": "0x…", "controller": "0x…", "vault": "0x…", …
  }
}
```

Addresses are looked up by dotted key: `_addr("external.wstEth")`, `_addr("protocol.core")`.
JSON has no comments — record deploy date / governance / audit refs in the deploy log.
```
