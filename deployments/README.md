# Legacy deployed-address maps

Fork tests no longer read this directory. External network addresses live in
`script/config/<network>.toml`, selected with `NETWORK`. An optional per-run
`deployed/<run>/protocol.toml`, selected with `FORK_REGISTRY`, supplies deployed protocol addresses.

## Running the fork tests

Select the committed network config and provide its RPC:

```sh
make test-fork ETH_RPC_URL=<rpc> NETWORK=mainnet
```

Pass the variables as make command-line assignments, as above: they override a `.env`, whereas plain
`VAR=x make test-fork` is silently beaten by `.env` values loaded by the Makefile.

`ForkTest._fork()` forks `ETH_RPC_URL` and loads `script/config/<NETWORK>.toml`. It verifies the network
chain ID. When `FORK_REGISTRY` is set, it loads that registry and verifies its chain ID too.

## Adding a network

Add `script/config/<network>.toml` with `chain_id` and an `[external]` table, then select it:

```sh
make test-fork ETH_RPC_URL=<network-rpc> NETWORK=<network>
```

A suite fails when its external key is absent. Existing deployment addresses are read with
`_deployed("protocol.core")` and require `FORK_REGISTRY`.
