# On-chain (self-custody) wallets

Sure can track wallets you hold the keys to — Bitcoin, six EVM networks and
Solana — from their **public addresses only**. Nothing is signed, no key or seed
phrase is ever entered, and no API key is required for any chain.

This document covers where the data comes from, what needs configuring, the
limits you will hit, and how to diagnose a wallet that looks wrong.

## What gets tracked

One Sure account is created per **asset**, per **address**, per **network**. A
wallet holding ETH and USDC on Ethereum becomes two accounts, both Crypto
accounts with the "wallet" subtype.

For each asset Sure records:

- the **quantity** held, read from the chain;
- a **holding** valued at the current price, or at zero when no price is
  available;
- the **transfers** in and out, as investment trades when the price for that day
  is known, so cost basis and the value chart reconstruct back to acquisition.
  When that day's price is not known, the transfer still appears as an excluded,
  zero-amount entry so you can see it happened without a made-up value entering
  your history — and it is upgraded to a trade on the first sync after the price
  becomes available.

Balances are read-only and always derived from the chain. Editing them by hand is
pointless: the next sync overwrites them.

## Prices need two settings, not one (read this first)

On-chain data sources report **quantities, not values**. Prices come from Sure's
market data providers, and the only provider that can quote bare crypto symbols
is **Binance public** (keyless).

If no crypto-capable market data provider is enabled, every on-chain wallet is
tracked by quantity and **valued at zero**. This is by far the most common
support report for this feature, and it is a settings issue rather than a sync
failure.

The settings panel and the linking modal both warn you before you link
anything, and on a self-hosted instance an admin can fix it from the warning
itself with **Enable crypto prices** — that adds `binance_public` to the
enabled providers and leaves the others alone. Otherwise, enable it under
**Settings → Self hosting → Market data providers**, or set
`SECURITIES_PROVIDERS` to a comma-separated list including `binance_public`.
On a managed instance this is the operator's setting, so the button is not
offered.

### And an exchange rate, if your currency is not USD

The crypto provider quotes in USD, so valuing a wallet in any other family
currency needs one conversion — and Sure's default exchange rate provider
(`twelve_data`) requires an API key. With no key and a non-USD family, there is no
FX at all and every on-chain wallet is valued at zero for that second, separate
reason.

Set `EXCHANGE_RATE_PROVIDER` (or **Settings → Self hosting**) to a provider you
can actually use; `frankfurter` needs no API key. The linking UI warns about this
gap specifically, naming your currency, and a USD family never sees the warning
because it needs no conversion.

When an asset ends up valued at zero for either reason, it is recorded in
**Settings → Debug logs** under the `onchain_wallet` provider, with the reasons
listed, so the cause is visible without having to reproduce it.

## Data sources

| Network | Source | Key required | Override |
|---|---|---|---|
| Bitcoin | [mempool.space](https://mempool.space) REST API | No | `MEMPOOL_SPACE_URL` |
| Ethereum | Blockscout (`eth.blockscout.com`) | No | `BLOCKSCOUT_ETHEREUM_URL` |
| Base | Blockscout (`base.blockscout.com`) | No | `BLOCKSCOUT_BASE_URL` |
| Arbitrum | Blockscout (`arbitrum.blockscout.com`) | No | `BLOCKSCOUT_ARBITRUM_URL` |
| Optimism | Blockscout (`optimism.blockscout.com`) | No | `BLOCKSCOUT_OPTIMISM_URL` |
| Polygon | Blockscout (`polygon.blockscout.com`) | No | `BLOCKSCOUT_POLYGON_URL` |
| Gnosis | Blockscout (`gnosis.blockscout.com`) | No | `BLOCKSCOUT_GNOSIS_URL` |
| Solana | Public JSON-RPC (`api.mainnet-beta.solana.com`) | No | `SOLANA_RPC_URL` |
| Solana token names | Jupiter token search (`lite-api.jup.ag`) | No | `SOLANA_TOKEN_LIST_URL` |

Every override expects the base URL of a compatible instance, without a trailing
slash — useful if you run your own indexer or node, or if a public endpoint rate
limits you.

### Optional Etherscan key

Ethereum, and only Ethereum, can be read through Etherscan instead of
Blockscout. A key buys nothing except a higher rate limit. Add it under
**Settings → Providers → On-chain wallets → Advanced**; it is stored encrypted,
per family.

A key only moves **transfer history** onto Etherscan. Balances and network
detection always come from the keyless indexer, because Etherscan has no free
endpoint that lists an address's tokens and summing transfer history would be
wrong for a rebasing token — and wrong outright for anything older than the
history cap. History is the paginated, rate-limited half of the work, so that is
where a key actually helps. Leave the field empty unless you are being rate
limited.

## Rate limits and request cost

All the default endpoints are free and shared, so they throttle. Each client
paces its own requests and retries a 429 with exponential backoff. Per sync, per
address, the cost is roughly:

| Network | Requests per sync |
|---|---|
| Bitcoin | 1 + up to 10 history pages |
| EVM | 1 summary + up to 10 pages of transfers + up to 10 pages of token transfers |
| Solana | ~2 + up to 25 transaction reads |

History is capped by default at 10 pages per source — 250 transactions for
Bitcoin, 10 pages per EVM collection — and at 25 transactions for Solana, which
spends one request per transaction rather than per page. Wallets with more
history than that keep their **current balance correct** — balances come from an
address summary, never from history — but their oldest transfers are not
imported.

Raise both caps with `ONCHAIN_HISTORY_MAX_PAGES` (default 10, maximum 200); the
Solana budget scales with it proportionally. The request cost in the table above
scales too, so raise it if you run your own node or indexer rather than against a
public endpoint.

**History is best effort; balances are not.** If a source refuses or times out
on the paginated history, the balances are still recorded and the history is
marked incomplete, rather than the whole read failing. This matters on the free
Solana endpoint, which routinely throttles `getTransaction`: without it a Solana
wallet would show nothing at all instead of showing what it holds.

When a cap is hit, the affected address says so in **Manage wallets**, and the
event is recorded in **Settings → Debug logs** under the `onchain_wallet`
provider — once per address per sync, not once per night forever.

### How many tokens one address surfaces

Real addresses are airdrop dumping grounds: a well-known Ethereum address holds
close to 8,000 ERC-20 tokens, and a comparable Solana one nearly 3,000 token
accounts. Listing all of them would make the review screen unusable, so one read
surfaces at most **200 tokens** per address, settable with
`ONCHAIN_MAX_TOKENS_PER_ADDRESS` (maximum 5,000).

The native coin is never affected, and anything already tracked keeps syncing
regardless. On EVM networks the tokens kept are ranked by the market cap the
indexer reports, so real assets survive the cap and airdrops fall off the end.
Solana RPC offers no such signal, so there the order is by mint address —
arbitrary, but identical between syncs, which is what stops the cap from
reshuffling a wallet every night. The cap is stated in the review screen and in
Manage wallets whenever it applies.

Detecting which network an address belongs to costs **exactly one request per
candidate network**, and never reads history. If an explorer is down during
detection, that network simply reports "nothing found" instead of failing the
whole flow; you can still pick it by hand.

## Linking a wallet

**Settings → Providers → On-chain wallets → Add wallet.**

1. Paste the public address. Leave the network on "Detect automatically" unless
   you know which one you want.
2. If the address format belongs to several networks — every `0x` address is
   valid on all six EVM networks, and Bitcoin's Base58 shape overlaps Solana's —
   Sure probes each and asks you to choose, marking the ones where it found
   activity.
3. Pick the assets to track. The native coin and assets the data source treats
   as notable are ticked; everything else is listed unticked. "Notable" means a
   priced holding worth more than a dollar on EVM networks, or a place on
   Solana's verified token list — because airdrops use perfectly plausible
   symbols, so the symbol alone says nothing. On a heavily airdropped address
   this is the difference between a handful of pre-ticked assets and two hundred.
   You can still track anything listed; unpriceable assets show a quantity and a
   value of zero.

Nothing is imported that you did not tick.

## Managing a wallet

**Settings → Providers → On-chain wallets → Manage wallets.**

- **Review tokens** — reopens the asset selection with the address unchanged.
  This is how you start tracking a token that arrived later, or stop tracking one
  you no longer want.
- **Stop tracking** (per asset) — drops one asset.
- **Change address** — corrects the address while keeping the accounts, holdings
  and balance history attached to it.
- **Disconnect wallet** — drops every asset at one address.

Disconnecting never deletes an account. The provider link is removed, holdings
are detached, and what you can see stays as a manual account that no longer
updates. Delete the account itself if you want it gone.

An address can only be tracked once per network. To change which assets are
tracked, use Review tokens rather than adding the address again.

## Limitations

**Only tokens the crypto price provider quotes get a value, and it quotes by
symbol.** This is the largest limitation of the feature, so read it before
judging a number you disagree with. Valuation goes through a `CRYPTO:<SYMBOL>`
ticker, and a symbol is not a token's identity — its contract is. In practice the
provider covers major assets and little else: measured on a real Ethereum
address, of its ten largest token positions it quoted two. The other eight —
including holdings worth roughly $406,000, $141,000 and $74,000 — showed a value
of zero while their quantities were tracked correctly.

So: **a zero next to a token you know is worth something almost always means the
provider does not list that token, not that the balance is wrong.** Check the
quantity, which is read straight from the chain. Native coins (BTC, ETH, SOL,
POL, XDAI) and large-cap tokens are the well-covered case.

Pricing by contract address instead of by symbol would close most of the gap, and
the data is already close at hand — the EVM indexer returns an exchange rate per
token and Jupiter returns a USD price per mint, neither of which this version
uses for valuation. That change belongs to how crypto enters Sure's price
pipeline rather than to this feature, so it is not something you can configure
your way out of today.

**DeFi positions are not seen at all.** Staked ETH, liquidity-pool tokens,
lending positions and Solana stake accounts are invisible: only natively-held
coins and fungible tokens sitting at the address are read. A wallet holding most
of its value in a staking or lending protocol will report a fraction of it. This
is a scope limit, not a bug — nothing in the UI claims those positions were
checked.

**Bitcoin is one address at a time.** Extended keys (`xpub`, `ypub`, `zpub`) are
not supported and are rejected as addresses. This matters: most Bitcoin wallets
are HD wallets, where one extended key derives thousands of addresses and change
is sent to derived ones. Tracking a single address of such a wallet reports only
that address's balance, which is usually a fraction of the wallet. Supporting
extended keys would require BIP32 derivation — a dependency this codebase
deliberately avoids — or a descriptor-indexing backend. If you use a single-address
setup, or want to follow one specific address, this works exactly as expected.

**Solana token names depend on a token list.** RPC returns mints, not names, so
names come from Jupiter's token search — and only for mints it reports as
*verified*. Anyone can mint a token calling itself USDC, so an unverified or
unknown mint keeps a label built from its mint address and is tracked by quantity
only, rather than being handed the real asset's price. A handful of major mints
resolve without the list, so they keep working if it is unreachable. Names are
cached for 24 hours per mint, misses included.

**Fees are not itemised.** Network fees are included in the net effect of each
transfer rather than recorded separately. On Solana, native balance changes below
0.0001 SOL are treated as fees and ignored.

**Bridged assets are normalised.** USDC.e, USDbC, USDT0, WETH and similar
1:1-redeemable forms are tracked as their canonical asset, so the same asset held
on two networks is one Security rather than two.

**Prices are daily and USD-quoted.** Values are converted into your family
currency using Sure's exchange rates. A transfer whose day has no price becomes a
zero-amount excluded entry rather than a trade.

**NFTs are not tracked.** They are filtered out by token standard, so an NFT is
never mistaken for a balance of one fungible token.

## Troubleshooting

**Every wallet shows a value of zero.** Either no crypto-capable market data
provider is enabled, or your family currency is not USD and no exchange rate
provider is configured. Both are covered above, and the linking UI says which one
applies.

**One token shows zero while the others in the same wallet are fine.** Different
cause: the price provider does not quote that token. Pricing is by symbol and
covers major assets, so long-tail tokens are tracked by quantity and valued at
zero. See "Limitations" — there is no setting that changes this.

**A Bitcoin balance is much lower than my wallet app shows.** You are tracking one
address of an HD wallet. See "Limitations".

**Sync says the explorer could not be reached.** The public endpoint is down,
throttling you, or too slow to answer. Retry later, or point the relevant
`*_URL` override at your own instance. This is the message for any transport
failure — a refused connection, a timeout, a TLS error — as opposed to the
generic "something went wrong", which means a bug worth reporting.

**Solana shows balances but no transfers.** The free endpoint throttles the
history methods; balances are kept and the history is marked incomplete. Set
`SOLANA_RPC_URL` to your own node or a paid endpoint to get the transfers.

**Solana times out entirely on a very large wallet.** `getTokenAccountsByOwner`
returns every token account in one response, and the public endpoint struggles
with wallets holding thousands of them (a well-known one has ~2,800). Same fix:
point `SOLANA_RPC_URL` at a real node.

**A token I received is not showing up.** New assets are never imported
automatically. Use **Review tokens** and tick it.

**A Solana token shows as `SPL:abcd…wxyz`.** The token list does not vouch for
that mint, so Sure will not name or price it. Tick it anyway to track the
quantity.

**Transfers appear with a value of 0 and are excluded from totals.** No price was
available for that date yet. Once market data covers the range, the next sync
upgrades those entries to trades automatically — they keep their identity, so
nothing is duplicated. If they stay at zero, the date is outside what your market
data provider can serve.

**Manage wallets says the history is incomplete.** The address has more transfers
than one sync reads. Balances are unaffected. Raise
`ONCHAIN_HISTORY_MAX_PAGES` if you need the full history and can afford the extra
requests.

**Balances are correct but nothing updates.** Syncs only rewrite an account when
the chain actually changed — an idle wallet is meant to produce no writes at all.
Check **Settings → Providers** for the last sync time, and
**Settings → Debug logs** (super admin), filtered to the `onchain_wallet`
provider, for recorded failures.
