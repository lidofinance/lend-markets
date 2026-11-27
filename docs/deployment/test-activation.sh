#!/usr/bin/env bash
# Local Anvil fixture only; never a production funding or governance transaction tool.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit

p = argparse.ArgumentParser(prog='test-activation.sh', description="Replay WETH/wstETH activation on an existing local Anvil fork. "
    "Reproduces only seven factory registrations if absent; does not replay the whole prerequisite vote. "
    "Requires cast and Python 3. Output directory must not exist. Never updates deployment records.")
p.add_argument('--rpc-url', required=True, help='http://127.0.0.1:PORT or http://[::1]:PORT; no credentials/path/query')
p.add_argument('--calldata', required=True, help='exact ABI-encoded ActivationParams bytes (no function selector)')
p.add_argument('--factories', required=True, help='reviewed lido-lend-factories-mainnet.json')
p.add_argument('--output', required=True, help='new directory for fork-only receipts and summary.json')
p.add_argument('--motion-id', type=int, help='enact an existing motion; preserve funding, permissions and Guardian state')
a = p.parse_args()

def require(ok, message):
    if not ok:
        raise RuntimeError(message)

def same(left, right):
    return str(left).lower() == str(right).lower()

def num(value):
    return int(value, 16 if value.startswith('0x') else 10) if isinstance(value, str) else int(value)

def tup(values):
    return '(' + ','.join(tup(v) if isinstance(v, list) else
        str(v).lower() if isinstance(v, bool) else str(v) for v in values) + ')'

out = None
impersonated = set()
# Strip inherited signer choices; every send explicitly uses a fork-impersonated sender.
env = {k: v for k, v in os.environ.items() if k not in
       ('ETH_PRIVATE_KEY', 'PRIVATE_KEY', 'ETH_KEYSTORE', 'ETH_PASSWORD', 'ETH_FROM', 'ETH_RPC_URL')}
env['NO_PROXY'] = env['no_proxy'] = '127.0.0.1,::1'

def cast(*args):
    r = subprocess.run(['cast', *map(str, args)], text=True, capture_output=True, env=env, timeout=90)
    # Do not print provider errors: a local node can include its secret upstream URL.
    require(r.returncode == 0, 'cast ' + str(args[0]) + ' failed; inspect the local fork separately')
    return r.stdout.strip()

def rpc(method, *args):
    return json.loads(cast('rpc', '--rpc-url', a.rpc_url, method, *args))

def call(target, signature, *args):
    raw = cast('call', target, signature, *args, '--rpc-url', a.rpc_url, '--json')
    if raw == '0x':  # cast prints raw empty bytes for a no-return ABI, even with --json.
        return []
    values = json.loads(raw)
    return values[0] if len(values) == 1 else values

def save(name, value):
    (out / (name + '.json')).write_text(json.dumps(value, indent=2) + '\n')

def actor(address, balance=10**20):
    rpc('anvil_setBalance', address, hex(balance))
    if address.lower() not in impersonated:
        rpc('anvil_impersonateAccount', address)
        impersonated.add(address.lower())

def send(name, sender, target, *args):
    receipt = json.loads(cast('send', target, *args, '--from', sender, '--unlocked',
                             '--rpc-url', a.rpc_url, '--json', '--timeout', '60'))
    save(name, receipt)
    require(num(receipt['status']) == 1, name + ' transaction reverted; receipt preserved')
    return receipt

try:
    u = urlsplit(a.rpc_url)
    require(u.scheme == 'http' and u.hostname in ('127.0.0.1', '::1') and u.port
            and not u.username and not u.password and u.path in ('', '/')
            and not u.query and not u.fragment, 'RPC must be a literal loopback HTTP URL with an explicit port')
    require(re.fullmatch(r'0x(?:[0-9a-fA-F]{2})+', a.calldata), 'calldata must be nonempty hex bytes')
    require(a.motion_id is None or a.motion_id > 0, 'motion ID must be positive')
    require(not Path(a.output).exists(), 'output directory already exists; use a fresh fork/run directory')
    require('anvil' in rpc('web3_clientVersion').lower(), 'RPC is not Anvil')
    require(num(rpc('eth_chainId')) == 1, 'Anvil chain ID must be 1')
    info = rpc('anvil_nodeInfo')
    require(isinstance(info, dict), 'Anvil node-info check failed')
    # Never persist nodeInfo: it may contain the upstream RPC URL.
    easy = '0xF0211b7660680B49De1A7E9f25C65660F0a13Fea'
    voting = '0x2e59A20f205bB85a89c53f1936454680651e618E'
    core_expected = '0x026a770badc7126c7252Ef8d407E5b9C56147491'
    weth = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
    guardian = '0x1011E8a0668da8bbED925cB5A6DA5aa128C2BB5E'
    funder = '0x000000000000000000000000000000000000f002'
    expected = dict(zip(('ActivateMarket', 'CircuitBreakerActions', 'GuardianActions',
        'MarketManagerActions', 'RiskStewardActions', 'ApplyIrmConfig', 'ExitBookActions'), (
        '0x17bb2A2B5983D29392A5d31D627D4C8B13383fe6', '0x4e89cc970F0DBAE2f8C38C083D5D345B4F9e76b8',
        '0x9fE41afb2114bF9430D7f9B1Fb65f0a4B9DeF779', '0x9D75EaE321976e85e472847AFD21246F1f87dC43',
        '0x7276CE5f92911216d41C7b0A9C3575DE873763E9', '0x5795E73C0c2007ceD7D65cE4FC21c0C09F14C668',
        '0xA30b212c3657fa745feaE4b48B7Eb0A8F429C604')))
    records = json.loads(Path(a.factories).read_text())
    factory = expected['ActivateMarket']
    pending = []
    for suffix, address in expected.items():
        if a.motion_id is not None and suffix != 'ActivateMarket':
            continue
        record = records['LidoLend' + suffix]
        require(same(record['address'], address), 'unexpected recorded factory address: ' + suffix)
        permissions = record['permissions']
        require(re.fullmatch(r'0x(?:[0-9a-fA-F]{48})+', permissions), 'invalid permissions: ' + suffix)
        require(cast('code', address, '--rpc-url', a.rpc_url) != '0x', 'missing factory: ' + suffix)
        registered = call(easy, 'isEVMScriptFactory(address)(bool)', address)
        current = call(easy, 'evmScriptFactoryPermissions(address)(bytes)', address)
        require(same(current, permissions) if registered else current == '0x',
                'existing permissions differ: ' + suffix)
        if not registered:
            pending.append((suffix, address, permissions))
    getters = ('trustedCaller', 'lidoLendOwner', 'irmRouter', 'configurableIrm',
               'lidoLendMarketFactory', 'circuitBreaker', 'riskStewardDashboard', 'lidoLendPreseeder')
    bindings = {g: call(factory, g + '()(address)') for g in getters}
    require(all(same(bindings[g], v) for g, v in zip(getters,
        records['LidoLendActivateMarket']['constructorArgs'])), 'factory bindings differ from reviewed JSON')
    require(len(records['LidoLendActivateMarket']['constructorArgs']) == len(getters), 'wrong constructor record')
    core = call(factory, 'lidoLend()(address)')
    preseeder, caller = bindings['lidoLendPreseeder'], bindings['trustedCaller']
    require(same(core, core_expected) and same(call(preseeder, 'lidoLend()(address)'), core), 'core binding differs')
    activation_type = '((address,address,address,address,uint256),address,address,bool,address,address,address,uint256)'
    params = call(factory, 'decodeEVMScriptCallData(bytes)(' + activation_type + ')', a.calldata)
    market, controller, vault = params[0], params[2], params[6]
    require(same(market[0], weth) and same(market[1], '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0')
            and same(market[3], bindings['irmRouter']), 'payload is not the recorded WETH/wstETH/router market')
    for address in (core, preseeder, caller, controller, vault, market[2], params[1], *bindings.values()):
        require(cast('code', address, '--rpc-url', a.rpc_url) != '0x', 'expected contract has no code: ' + address)
    market_id = cast('keccak', cast('abi-encode', 'f((address,address,address,address,uint256))', tup(market)))
    require(same(call(vault, 'LIDO_LEND()(address)'), core)
            and same(call(vault, 'asset()(address)'), weth)
            and same(call(vault, 'marketId()(bytes32)'), market_id)
            and same(call(controller, 'marketId()(bytes32)'), market_id), 'new market bindings differ')
    require(num(call(vault, 'totalSupply()(uint256)')) == 0, 'vault is not inert')
    market_sig = 'market(bytes32)((uint128,uint128,uint128,uint128,uint128,uint128))'
    require(all(num(v) == 0 for v in call(core, market_sig, market_id)), 'core market is not inert')
    require(same(call(easy, 'evmScriptExecutor()(address)'),
                 '0xFE5986E06210aC1eCC1aDCafc0cc7f8D63B3F977'), 'unexpected Easy Track executor')
    registry = call(controller, 'guardianSignals()(address)')
    guardians = call(registry, 'getGuardians()(address[],address[])')
    require(len(guardians[0]) == 1 and same(guardians[0][0], guardian)
            and num(call(registry, 'getQuorum()(uint256)')) == 1, 'expected one-of-one Guardian Safe')
    require(not call(easy, 'paused()(bool)'), 'Easy Track is paused')
    require(cast('code', funder, '--rpc-url', a.rpc_url) == '0x', 'fork funder address has code')
    require(a.motion_id is None or not pending, 'existing motion factory is not registered')
    if pending:
        require(call(easy, 'hasRole(bytes32,address)(bool)', '0x' + '00'*32, voting), 'Voting lacks registration role')
    motion_type = '(uint256,address,address,uint256,uint256,uint256,uint256,uint256,bytes32)'
    amounts = call(preseeder, 'previewPreseed(address)(uint256,uint256)', vault)
    balance = num(call(weth, 'balanceOf(address)(uint256)', preseeder))
    shortfall = max(0, sum(map(num, amounts)) - balance)
    topic = cast('keccak', 'MotionCreated(uint256,address,address,bytes,bytes)')
    receipt = None
    if a.motion_id is not None:
        # Authenticate the existing motion and its original bytes BEFORE any fork mutation.
        require(shortfall == 0, 'existing motion Preseeder is underfunded; no funding repair in this mode')
        motion_id = a.motion_id
        motion = call(easy, 'getMotion(uint256)(' + motion_type + ')', motion_id)
        require(num(motion[0]) == motion_id and same(motion[1], factory) and same(motion[2], caller),
                'stored motion identity differs')
        script = call(factory, 'createEVMScript(address,bytes)(bytes)', caller, a.calldata)
        script_hash = cast('keccak', script)
        require(same(motion[8], script_hash), 'stored script hash differs')
        # EasyTrack sets snapshotBlock = block.number when creating this motion.
        logs = rpc('eth_getLogs', json.dumps({'address': easy, 'fromBlock': hex(num(motion[5])),
            'toBlock': hex(num(motion[5])), 'topics': [topic, '0x' + format(motion_id, '064x')]}))
    # All endpoint/identity checks above are read-only. Mutations below stay on this Anvil.
    out = Path(a.output)
    out.mkdir(parents=True)
    save('inputs', {'forkOnly': True, 'calldata': a.calldata, 'decoded': params,
                    'marketId': market_id, 'registry': registry, 'factoryRecords': records,
                    'existingMotionId': a.motion_id})
    if a.motion_id is None:
        if pending:
            actor(voting)
            for suffix, address, permissions in pending:
                send('register-' + suffix, voting, easy, 'addEVMScriptFactory(address,bytes)', address, permissions)
                require(same(call(easy, 'evmScriptFactoryPermissions(address)(bytes)', address), permissions), 'registration mismatch')
        actor(funder, shortfall + 10**20)
        if shortfall:
            send('wrap', funder, weth, 'deposit()', '--value', shortfall)
            send('fund-preseeder', funder, weth, 'transfer(address,uint256)', preseeder, shortfall)
        call(preseeder, 'validatePreseed((address,address,address,address,uint256),address)', tup(market), vault)
        actor(caller)
        script = call(factory, 'createEVMScript(address,bytes)(bytes)', caller, a.calldata)
        script_hash = cast('keccak', script)
        receipt = send('create-motion', caller, easy, 'createMotion(address,bytes)', factory, a.calldata)
        logs = [l for l in receipt['logs'] if same(l['address'], easy) and l['topics'] and same(l['topics'][0], topic)]
    require(len(logs) == 1 and len(logs[0]['topics']) == 3, 'expected one MotionCreated')
    log = logs[0]
    motion_id = num(log['topics'][1])
    require(a.motion_id is None or motion_id == a.motion_id, 'creation event ID differs')
    require(same(log['address'], easy) and same(log['topics'][0], topic)
            and same('0x' + log['topics'][2][-40:], factory), 'creation event factory differs')
    event = json.loads(cast('abi-decode', 'f()(address,bytes,bytes)', log['data'], '--json'))
    require(same(event[0], caller) and same(event[1], a.calldata) and same(event[2], script), 'creation event differs')
    motion = call(easy, 'getMotion(uint256)(' + motion_type + ')', motion_id)
    require(num(motion[0]) == motion_id and same(motion[1], factory) and same(motion[2], caller)
            and same(motion[8], script_hash), 'stored motion differs')
    save('script', {'bytes': script, 'hash': script_hash})
    save('creation-event', log)
    save('stored-motion', motion)
    block = rpc('eth_getBlockByNumber', 'latest', 'false')
    earliest = num(motion[4]) + num(motion[3])
    if num(block['timestamp']) < earliest:
        rpc('evm_setNextBlockTimestamp', str(earliest + 1))
        rpc('evm_mine')
    if a.motion_id is None:
        # Synthetic fixture only: no screening claim. Existing-motion mode preserves Guardian state.
        delegate = guardians[1][0]
        if num(delegate) == 0:
            delegate = '0x000000000000000000000000000000000000f001'
            actor(guardian)
            send('set-fork-delegate', guardian, registry, 'setDelegate(address)', delegate)
        actor(delegate)
        block = rpc('eth_getBlockByNumber', 'latest', 'false')
        scanned = tup([block['hash'], num(block['number']), num(block['timestamp'])])
        send('fork-heartbeat', delegate, registry, 'heartbeat(address,(bytes32,uint40,uint40),bytes)', guardian, scanned, '0x')
        require(num(call(registry, 'getHeartbeat(address)(uint40)', guardian)) == num(block['timestamp']), 'heartbeat differs')
    else:
        actor(funder)  # Synthetic enactment-sender gas only; never wraps/transfers WETH in this mode.
    require(same(cast('keccak', call(factory, 'createEVMScript(address,bytes)(bytes)', caller, a.calldata)), script_hash), 'script changed')
    enacted = send('enact-motion', funder, easy, 'enactMotion(uint256,bytes)', motion_id, a.calldata)
    topic = cast('keccak', 'MotionEnacted(uint256)')
    require(any(same(l['address'], easy) and len(l['topics']) == 2 and same(l['topics'][0], topic)
                and num(l['topics'][1]) == motion_id for l in enacted['logs']), 'MotionEnacted missing')
    remaining = call(easy, 'getMotions()(' + motion_type + '[])')
    require(all(num(m[0]) != motion_id for m in remaining), 'enacted motion remains active')
    state = call(core, market_sig, market_id)
    require(num(state[4]) > 0 and num(state[5]) == num(params[7]), 'activated market state differs')
    save('summary', {'forkOnly': True, 'marketId': market_id, 'motionId': motion_id,
        'scriptHash': script_hash, 'preseedAmounts': amounts, 'fundingShortfall': str(shortfall),
        'registeredFactories': [v[0] for v in pending], 'createBlock': hex(num(motion[5])),
        'mode': 'existing-motion' if a.motion_id is not None else 'full-cycle',
        'enactBlock': enacted['blockNumber'], 'postBlock': rpc('eth_blockNumber'),
        'note': ('Existing motion: only enactment gas/time changed before enactment; Guardian/funding/permissions preserved.'
                 if a.motion_id is not None else 'Synthetic fork funding/delegate/heartbeat; seven registrations only, not the complete vote.')
                + ' Run acceptance/State Mate separately.'})
    print('Fork activation replay passed; receipts and summary saved.')
except (RuntimeError, ValueError, KeyError, IndexError, TypeError, OSError, subprocess.TimeoutExpired) as e:
    print('Replay failed: ' + (str(e) if isinstance(e, RuntimeError) else type(e).__name__), file=sys.stderr)
    sys.exit(1)
finally:
    for address in impersonated:
        try:
            rpc('anvil_stopImpersonatingAccount', address)
        except Exception:
            print('Could not stop fork impersonation; discard this local fork.', file=sys.stderr)
PY
