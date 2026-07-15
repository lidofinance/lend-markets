# Deployed-address maps

One JSON address map per network, read at runtime by the fork tests (`test/fork/helpers/ForkTest.sol`) and
by the deploy tooling. This is the single source of addresses for a network — fork tests hold no hardcoded
addresses.

## Running the fork tests

The suites are network-blind: give them an RPC to fork and a path to the address map. Nothing else selects a
network.

```sh
ETH_RPC_URL=<rpc>  DEPLOYMENT=deployments/deployed-mainnet.json  make fork-test
```

`ForkTest._fork()` forks `ETH_RPC_URL` (latest block) and loads the `DEPLOYMENT` JSON. It self-skips (no
failure) when either is unset or the RPC is unreachable, so a plain `forge test` / `make test` stays green.

## Adding a network

Config only — no Solidity or `foundry.toml` changes. Drop a `deployments/deployed-<network>.json` (schema
below) and point the two env vars at it:

```sh
ETH_RPC_URL=<network-rpc>  DEPLOYMENT=deployments/deployed-<network>.json  make fork-test
```

A suite that needs an address the map does not define self-skips (guard with `_hasAddr`), so e.g. a
USDY-market suite runs against a mainnet map but skips against a map with no `external.usdy`.

## Schema

```jsonc
{
  "external": {          // addresses this network already hosts (not deployed by us)
    "weth": "0x…",
    "stEth": "0x…",
    "wstEth": "0x…",
    "usdy": "0x…",       // omit on networks without it — dependent suites skip
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
