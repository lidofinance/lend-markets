# State Mate on the market fork test

After the activation replay, copy the reviewed market YAML into its result directory:

```bash
cd "$LENDING_DIR"
: "${REPLAY_DIR:?Set the completed replay directory}"
mkdir -p "$REPLAY_DIR/state-mate"
FORK_STATE_CONFIG="$REPLAY_DIR/state-mate/weth-wsteth.yaml"
cp "$MARKET_STATE_CONFIG" "$FORK_STATE_CONFIG"
GUARDIAN_REGISTRY=$(cast call "$CONTROLLER" 'guardianSignals()(address)' --rpc-url "$FORK_RPC")
PRICE_FEED_IMPL=$(cast call "$PRICE_FEED" 'proxy__getImplementation()(address)' --rpc-url "$FORK_RPC")
GUARDIAN_IMPL=$(cast call "$GUARDIAN_REGISTRY" 'proxy__getImplementation()(address)' --rpc-url "$FORK_RPC")
CONTROLLER_IMPL=$(cast call "$CONTROLLER" 'proxy__getImplementation()(address)' --rpc-url "$FORK_RPC")
VAULT_IMPL=$(cast call "$VAULT" 'proxy__getImplementation()(address)' --rpc-url "$FORK_RPC")
```

Fill `$FORK_STATE_CONFIG` with the fork addresses and approved expectations. For the full-cycle replay, use its synthetic delegate/heartbeat; for existing-motion replay, preserve the actual guardian state.

Fresh fork addresses have no explorer ABI. Add their ABIs from the reviewed build to the archive beside the fork YAML; existing mainnet entries can be reused.

```bash
python3 - "$LENDING_DIR/out" "$FORK_STATE_CONFIG" "$MARKET_STATE_CONFIG" \
  "$PRICE_FEED:OssifiableProxy" "$PRICE_FEED_IMPL:WstEthRateOracle" \
  "$GUARDIAN_REGISTRY:OssifiableProxy" "$GUARDIAN_IMPL:GuardianSignals" \
  "$CONTROLLER:OssifiableProxy" "$CONTROLLER_IMPL:LidoLendMarketController" \
  "$VAULT:OssifiableProxy" "$VAULT_IMPL:LidoLendERC4626" \
  "$IRM_CONFIG:AdaptiveCurveConfig" <<'PY'
import gzip, json, pathlib, re, sys
build, config, original = map(pathlib.Path, sys.argv[1:4])
archive = config.parent / 'abis.json.gz'
entries = {}
for source in (original.parent.parent / 'abis.json.gz', original.parent / 'abis.json.gz', archive):
    if source.exists():
        entries.update(json.loads(gzip.decompress(source.read_bytes())))
for binding in sys.argv[4:]:
    address, name = binding.split(':', 1)
    if not re.fullmatch(r'0x[0-9a-fA-F]{40}', address):
        raise SystemExit('Invalid fork ABI address: ' + name)
    artifact = build / (name + '.sol') / (name + '.json')
    abi = json.loads(artifact.read_text())['abi']
    entries['1:' + address.lower()] = {'name': name, 'abi': abi}
archive.write_bytes(gzip.compress(json.dumps(entries).encode(), mtime=0))
print('Fork ABI archive prepared:', archive)
PY
MAINNET_RPC_URL="$FORK_RPC" ETHERSCAN_EXPLORER_TOKEN="$ETHERSCAN_API_KEY" \
  yarn --cwd "$STATE_MATE_DIR" start "$FORK_STATE_CONFIG" --block "$POST_BLOCK"
```

Require the selected market, all participating Safes and expected role sets to pass. Keep the YAML, ABI archive and report with the fork receipts. For a later fork of verified production addresses, State Mate can use the production ABI archive or obtain missing ABIs from the explorer.
