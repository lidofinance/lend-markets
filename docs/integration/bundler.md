# Bundling transactions — a frontend guide

One user intent is usually several on-chain calls: approve, wrap, post collateral, borrow. Bundler3
executes them as a single transaction, so the user signs once and either the whole intent lands or
nothing does.

This guide is written for the app developer. It covers how a bundle is built, the rules that decide
whether it works, and worked recipes for the flows the UI needs — including the two adapters that
exist only in this protocol.

- [Getting the addresses](#getting-the-addresses)
- [The call model](#the-call-model)
- [Five rules](#five-rules)
- [Recipes](#recipes)
- [Errors](#errors)
- [Action reference](#action-reference)

## Getting the addresses

On the dev dashboard: **protocol → bundler → deploy bundler**. It deploys `Bundler3`, the general
adapter, and the Lido vault adapter against the current core, and (unless you point it at existing
ones) the WETH / stETH / wstETH trio the general adapter needs.

Read them back at any time:

```js
const { state } = await fetch("http://127.0.0.1:8899/api/node/status").then((r) => r.json());
const { bundler3, generalAdapter, vaultAdapter, weth, stEth, wstEth } = state.bundler;
```

> A market only works with the general adapter's Lido legs if it was created **on these token
> addresses**. Deploy the bundler first, then create the market picking its WETH / wstETH.

## The call model

`Bundler3.multicall(Call[])` runs the calls in order, in one transaction.

```solidity
struct Call {
    address to;           // usually an adapter
    bytes   data;         // abi-encoded action
    uint256 value;        // ETH forwarded to this call
    bool    skipRevert;   // true = ignore this call's revert (use sparingly)
    bytes32 callbackHash; // commits to a re-entrant sub-bundle; 0 for plain calls
}
```

While the bundle runs, `Bundler3` records the sender as the **initiator**. Adapters read it to know
whose position they act on, which is why an adapter action never takes an "owner" argument it could be
tricked about: `morphoBorrow`, `morphoWithdraw`, `morphoWithdrawCollateral` and the vault adapter's
`fallbackExit` always act for the initiator.

Adapters are **stateless conduits**, not vaults. They hold tokens only between two calls of the same
bundle. Anything left on an adapter when the transaction ends is claimable by whoever builds the next
bundle — see rule 4.

In JS:

```js
const call = (to, data, value = 0n) => ({ to, data, value, skipRevert: false, callbackHash: ethers.ZeroHash });

const bundler3 = new ethers.Contract(bundler3Addr, [
  "function multicall((address to,bytes data,uint256 value,bool skipRevert,bytes32 callbackHash)[]) payable",
], signer);

await (await bundler3.multicall([ /* calls */ ])).wait();
```

Encode each action against the adapter's ABI:

```js
const general = new ethers.Interface([
  "function erc20TransferFrom(address,address,uint256)",
  "function erc20Transfer(address,address,uint256)",
  "function morphoSupplyCollateral((address,address,address,address,uint256),uint256,address,bytes)",
  "function morphoBorrow((address,address,address,address,uint256),uint256,uint256,uint256,address)",
  "function morphoRepay((address,address,address,address,uint256),uint256,uint256,uint256,address,bytes)",
  "function morphoWithdrawCollateral((address,address,address,address,uint256),uint256,address)",
  "function morphoWithdraw((address,address,address,address,uint256),uint256,uint256,uint256,address)",
  "function morphoSupply((address,address,address,address,uint256),uint256,uint256,uint256,address,bytes)",
  "function erc4626Deposit(address,uint256,uint256,address)",
  "function erc4626Redeem(address,uint256,uint256,address,address)",
  "function wrapNative(uint256,address)",
  "function unwrapNative(uint256,address)",
  "function stakeEth(uint256,uint256,address,address)",
  "function wrapStEth(uint256,address)",
  "function unwrapStEth(uint256,address)",
]);
```

`marketParams` is a 5-tuple, in this order:

```js
const params = [loanToken, collateralToken, oracle, irm, lltv];
```

The dashboard returns all five on the market object (`irm` is the router address, not `adaptive`).

## Five rules

**1 · The user approves the adapter, not Bundler3.** `Bundler3` is a public dispatcher that anyone can
call with arbitrary calldata — never give it an allowance. Allowances go to the adapter that will pull
the tokens: the general adapter for ERC-20 legs, the vault adapter for vault shares.

**2 · An adapter can only spend tokens it already holds.** Actions like `morphoRepay` and
`morphoSupplyCollateral` consume the adapter's own balance, so a bundle must first move the tokens in
with `erc20TransferFrom`. The order inside the bundle is the order of execution.

```js
call(generalAdapter, general.encodeFunctionData("erc20TransferFrom", [token, generalAdapter, amount])),
call(generalAdapter, general.encodeFunctionData("morphoSupplyCollateral", [params, MAX, user, "0x"])),
```

**3 · Anything that moves the user's position on the core needs an authorization.** `morphoBorrow`,
`morphoWithdraw` and `morphoWithdrawCollateral` call the core on the initiator's behalf, so the user
must have run `core.setAuthorization(generalAdapter, true)` once. Do it as a separate transaction the
first time, and skip it afterwards:

```js
if (!(await core.isAuthorized(user, generalAdapter))) {
  await (await core.connect(signer).setAuthorization(generalAdapter, true)).wait();
}
```

Calling `setAuthorization` again with the value it already has reverts `already set` — always read
first. (The core also accepts an EIP-712 `setAuthorizationWithSig`, which can ride inside the bundle
so even the first-time flow is one signature; the tests use it.)

**4 · Sweep the adapter at the end of the bundle.** Overshoot is normal — you size a repay with
headroom for the interest that accrues before the transaction lands. Whatever is left sits on the
adapter and the next bundle by anyone can take it. End with an explicit sweep:

```js
call(generalAdapter, general.encodeFunctionData("erc20Transfer", [token, user, MAX])),
```

**5 · `type(uint256).max` means "whatever is there now", resolved on-chain.** It is how you avoid
racing a state change between the quote and the transaction:

| action | `max` means |
|---|---|
| `erc20Transfer(token, to, max)` | the adapter's whole balance |
| `morphoSupplyCollateral(params, max, …)` | the adapter's whole collateral balance |
| `morphoRepay(params, 0, max, …)` | the initiator's whole debt, in shares |
| `morphoWithdrawCollateral(params, max, …)` | the initiator's whole collateral |
| `fallbackExit(vault, max, …)` | the initiator's whole vault-share balance |

Repaying **all** debt means passing `shares = max`, not `assets = max` — a debt quoted in assets grows
between your read and the transaction, and an asset-sized repay would leave dust behind.

## Recipes

Every recipe below was executed against the dev dashboard's devnet; the amounts are what actually came
out.

### Close a position: repay all debt and take the collateral back

The flow the UI's "close" button should send. Four calls, one signature.

```js
const MAX = ethers.MaxUint256;

// once, if not authorized yet
if (!(await core.isAuthorized(user, generalAdapter))) {
  await (await core.connect(signer).setAuthorization(generalAdapter, true)).wait();
}
// the user approves the adapter for the loan token (once, can be max)
await (await weth.connect(signer).approve(generalAdapter, MAX)).wait();

const budget = debtAssets + headroom; // read debt, add a margin for interest

await bundler3.multicall([
  // 1 · pull the repay budget in
  call(generalAdapter, general.encodeFunctionData("erc20TransferFrom", [weth, generalAdapter, budget])),
  // 2 · repay ALL debt (shares = max), maxSharePriceE27 = max disables the price rail
  call(generalAdapter, general.encodeFunctionData("morphoRepay", [params, 0n, MAX, MAX, user, "0x"])),
  // 3 · with the debt gone the whole collateral is free
  call(generalAdapter, general.encodeFunctionData("morphoWithdrawCollateral", [params, MAX, user])),
  // 4 · return the unused budget (rule 4)
  call(generalAdapter, general.encodeFunctionData("erc20Transfer", [weth, user, MAX])),
]);
```

Result on a 10 WETH debt against 40 wstETH, with an 11 WETH budget: `borrowShares 0`, `collateral 0`,
40 wstETH back to the user, **0 residue on the adapter**.

Set `maxSharePriceE27` to a real bound if you want protection: it caps assets paid per borrow share
burned, scaled by `1e27`.

### Withdraw collateral only

Same shape without the repay legs. Needs the authorization from rule 3.

```js
await bundler3.multicall([
  call(generalAdapter, general.encodeFunctionData("morphoWithdrawCollateral", [params, amount, user])),
]);
```

Pass an explicit `amount` for a partial withdrawal, `MAX` for everything — but `MAX` only goes through
on a position with no debt left. With debt open the health check runs against the *activated* collateral
that remains, so emptying the position reverts `InsufficientActiveCollateral()` (measured: a 10-unit
partial withdrawal on a 113.9-collateral position succeeded, `MAX` on the same position reverted). The
controller also rejects debt-bearing withdrawals while the market is frozen (`MarketIsFrozen()`).

### Post collateral

```js
await (await wsteth.connect(signer).approve(generalAdapter, MAX)).wait();

await bundler3.multicall([
  call(generalAdapter, general.encodeFunctionData("erc20TransferFrom", [wstEth, generalAdapter, amount])),
  call(generalAdapter, general.encodeFunctionData("morphoSupplyCollateral", [params, MAX, user, "0x"])),
]);
```

No authorization needed — supplying *to* someone's position is permissionless. Fresh collateral is not
borrowable until it matures through the activation delay (2 hours on the devnet).

### Borrow straight to native ETH

```js
await bundler3.multicall([
  call(generalAdapter, general.encodeFunctionData("morphoBorrow", [params, amount, 0n, minSharePriceE27, generalAdapter])),
  call(generalAdapter, general.encodeFunctionData("unwrapNative", [MAX, user])),
]);
```

The borrow sends WETH to the adapter, which unwraps and forwards ETH. `minSharePriceE27` is the floor
on assets received per borrow share, scaled by `1e27`; pass `0` to disable.

### Enter from ETH — stake, wrap, post as collateral

This is the first of the two Lido-specific surfaces. `stakeEth` is **not payable**: fund the adapter
with a value-bearing empty-data call first, then act on its balance.

```js
await bundler3.multicall([
  call(generalAdapter, "0x", ethers.parseEther("5")),                                    // ETH → adapter
  call(generalAdapter, general.encodeFunctionData("stakeEth", [MAX, maxSharePriceE27, referral, generalAdapter])),
  call(generalAdapter, general.encodeFunctionData("wrapStEth", [MAX, generalAdapter])),
  call(generalAdapter, general.encodeFunctionData("morphoSupplyCollateral", [params, MAX, user, "0x"])),
], { value: ethers.parseEther("5") });
```

Measured on the devnet mocks: 5 ETH → 4.166666666666666666 wstETH.

`maxSharePriceE27` caps wei paid per stETH share minted, scaled by `1e27`; `referral` is the Lido
Rewards-Share Program address (`ZeroAddress` if none). The reverse leg is `unwrapStEth(amount,
receiver)` — 1 wstETH → 1.2 stETH at the devnet rate.

> This adapter is upstream's `EthereumGeneralAdapter1` vendored with the MORPHO token surface removed.
> Everything else behaves exactly as documented upstream.

### Exit an illiquid market — `fallbackExit`

The second Lido-specific surface, on `LidoLendVaultAdapter`. When borrowers have drawn the market down,
a plain `redeem` can only pay what free liquidity covers. `fallbackExit` pays that part in loan tokens
and settles the rest against borrower collateral, so the lender exits in one transaction.

```js
const vaultAdapterAbi = new ethers.Interface([
  "function fallbackExit(address vault,uint256 shares,uint256 maxIterations,address receiver,uint256 minExitAssets,uint256 minSharesBurned)",
]);

// the user approves their VAULT SHARES to the vault adapter
await (await vault.connect(signer).approve(vaultAdapter, MAX)).wait();

await bundler3.multicall([
  call(vaultAdapter, vaultAdapterAbi.encodeFunctionData("fallbackExit", [
    vaultAddr,
    MAX,        // shares: the initiator's whole balance
    0n,         // maxIterations: 0 = the vault default
    user,       // receiver of BOTH payout tokens
    minExit,    // floor on loanAssets + debtCanceled, in loan tokens
    minBurned,  // floor on shares burned; pass `shares` for all-or-nothing
  ])),
]);
```

Measured on a market with 99 of 100 WETH borrowed out: the lender's 100 shares burned to **1 WETH**
(all the free liquidity) plus **86.086956921163440225 wstETH** of seized collateral.

Two things the UI must handle:

- **The payout is two tokens.** Show both legs. `minExitAssets` is one floor over the *sum* (loan tokens
  paid plus debt cancelled), valued in loan tokens, so it does not matter how the payout splits.
- **The exit may burn fewer shares than requested** when the settlement runs out of eligible borrowers.
  Pass `minSharesBurned = shares` if a partial exit is not acceptable; otherwise read the burn back from
  the receipt and refresh the position.

The adapter always exits the **initiator's** position, so a share approval given to it can only ever be
spent by a bundle that user started themselves.

## Errors

Bundle reverts surface as the failing call's own error. The ones you will actually see:

| error | meaning |
|---|---|
| `UnauthorizedSender()` | an adapter action was called directly instead of through `Bundler3` |
| `EmptyBundle()` | `multicall` with a zero-length array |
| `ZeroAmount()` / `ZeroShares()` | a `max`-resolved amount came out 0 — the adapter's balance, or the position, is empty |
| `SlippageExceeded()` | a `maxSharePriceE27` / `minSharePriceE27` rail was breached |
| `AdapterAddress()` | `onBehalf` was set to the adapter itself |
| `MissingExpectedReenter()` | a call promised a callback via `callbackHash` and never made it |
| `ExitBelowMinimum(exitAssets, minExitAssets)` | `fallbackExit` paid less than the floor |
| `BurnBelowMinimum(sharesBurned, minSharesBurned)` | `fallbackExit` burned fewer shares than the floor |
| `already set` (string) | `setAuthorization` called with the value already stored |

Protocol-level rejections come from the controller and read the same as outside a bundle —
`InsufficientActiveCollateral()` when the collateral has not matured yet, `SupplyCapExceeded(cap,
attempted)`, `MarketIsFrozen()`. The dashboard's log decodes all of them.

## Action reference

**`Bundler3`** — `multicall(Call[])`, `reenter(Call[])`, `initiator()`, `reenterHash()`.

**General adapter** (upstream, vendored) — token plumbing `erc20TransferFrom`, `erc20Transfer`,
`nativeTransfer`, `permit2TransferFrom`, `wrapNative`, `unwrapNative`; core actions `morphoSupply`,
`morphoSupplyCollateral`, `morphoBorrow`, `morphoRepay`, `morphoWithdraw`, `morphoWithdrawCollateral`,
`morphoFlashLoan`; ERC-4626 `erc4626Deposit`, `erc4626Mint`, `erc4626Withdraw`, `erc4626Redeem`; Lido
`stakeEth`, `wrapStEth`, `unwrapStEth`.

**`LidoLendVaultAdapter`** (Lido-specific) — `fallbackExit`, plus `erc20Transfer` / `nativeTransfer`
inherited from `CoreAdapter`.

Full per-function NatSpec lives with the contracts: `src/adapters/` for the two Lido ones,
`lib/bundler3/src/adapters/` for the upstream surface.
