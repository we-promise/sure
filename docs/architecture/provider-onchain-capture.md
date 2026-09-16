# Onchain wallet capture and assembly

This describes the current working tree. The native adapter remains disabled.
The tests described here have been authored but not run because Ruby is not
available in this workspace. No migration or provider cutover has been executed.

The [native factory](../../app/models/provider/account_data/onchain_wallet.rb)
now constructs a
[feeder](../../app/models/provider/account_data/onchain_wallet/feeder.rb), instead
of expecting a separately installed `sensitive_details.onchain_snapshot` or
`onchain_prices`. The production factory never reads those old fields.
Only copied, explicitly tracked source descriptors become accounts. A wallet's
other discovered tokens do not create accounts. Original external identities and
the legacy `onchain_<source UUID>` ingestion namespace remain intact.

## Request and replay boundary

1. Under the existing ordered runtime locks, the read-only
   [CaptureArchive](../../app/models/provider/account_data/onchain_wallet/capture_archive.rb)
   loads provider inventory batches from this exact family, connection and
   logical Sync. It verifies their original request grants against current
   mutable inputs. It never reads another Sync or legacy cached wallet data.
2. The factory receives the declared wallet descriptors, current linked-account
   identity/currency, frozen capture prefix and live
   [Configuration](../../app/models/provider/account_data/onchain_wallet/configuration.rb).
   Configuration includes explorer endpoints, registry routing, configured
   history/asset budgets and the effective crypto pricing preference. Request
   evidence contains keyed runtime fingerprints, not configuration values or
   credentials. Optional Etherscan credentials remain in the connection grant.
3. Outside database transactions, each inventory call performs at most one
   physical explorer, token-list or price request. A cached FX lookup is a
   separate operation. Even empty responses and disabled/unavailable pricing
   decisions become encrypted inventory evidence with a durable progress cursor.
4. The shared Syncer captures and applies the page before requesting the next
   operation. The pure
   [Assembly](../../app/models/provider/account_data/onchain_wallet/assembly.rb)
   replays the command/response chain and eventually exposes one immutable wallet
   snapshot to every selected asset at that address. Final inventory pages are
   emitted only after capture and quote decisions are complete.
5. Balances, holdings and activities consume that same snapshot and captured
   quotes. Missing prices or uncertain token absence remain incomplete; they do
   not replace financial values with guessed zeros.

Fragments have a global index, exact command, previous-fragment digest, response
and physical fetch time. Sequence numbers may restart across attempts; the
collector deduplicates only an identical fragment at the same index. Conflicting
responses, missing prefix slots and a final inventory pointing at another prefix
fail closed. A captured but unapplied response is restored before Syncer replays
its existing page. No HTTP is repeated merely because publication was interrupted.

The fixed Sync observation time is distinct from each physical fetch time. A
delayed continuation can collect later physical responses while preserving its
original logical scope; it does not claim that all remote endpoints supplied an
atomic historical snapshot. Account and activity progress cursors are scoped to
that logical Sync. A new Sync begins new physical capture; it cannot inherit a
failed older snapshot's cursor or relabel old raw payloads as fresh.

## Chain and price semantics

| Source | Captured operations | Completeness limits |
| --- | --- | --- |
| Bitcoin | Address summary; explicit transaction pages | Configured page cap remains history truncation. Bech32 comparison uses canonical spelling without changing retained source identity. Missing chain dates remain unknown. |
| Every configured EVM chain | Blockscout summary/token pages; Blockscout native/token history or configured keyed Etherscan history | Exact continuation and event/log identities retained. History and asset page caps are explicit; observed tracked tokens survive the surfaced-token cap. |
| Solana | Balance; each token program; verified Jupiter metadata batches; wallet and selected token-account signature reads; individual transactions | Omitted held signature sources, full signature pages, transaction cap and unavailable transactions all prevent complete-history claims. Same-signature confirmation changes can enrich an unknown block time; conflicting stable slot/time/error observations reject. |
| Crypto prices | One exact-day Binance kline per required ticker/day; explicit existing stablecoin USD-one policy | Missing/invalid symbols remain unpriced. Historical quotes must be for the exact movement day. The current day's kline close field is a value observed during that physical request, not a claim that the day's candle has closed. |
| FX | Existing exact/nearest prior rate within five days; captured Twelve Data/Frankfurter requests, MOEX history pages or Yahoo authentication/chart steps after a cache miss | Original currency, price, actual FX date and rate are retained. MOEX/Yahoo remote history has a ten-day window; undated MOEX current quotes remain unsupported. No implicit 1:1 conversion. Missing FX or unsupported native FX providers leave valuation incomplete. |

SPL metadata is trusted only for known mints or responses explicitly marked
verified. Unknown tokens retain an unpriceable placeholder rather than inheriting
a copied ticker that might name an unrelated asset. Explorer quantities and
captured prices use exact decimal/integer conversion. Raw observations remain
available even when their derived financial records are incomplete.

## Bounds and remaining acceptance

The collector admits at most 8,192 inventory batches, 96 MiB of stored encrypted
payload and 64 MiB of decoded aggregate evidence. The feeder leaves room for
inventory pages and caps response operations at 8,092. Individual transport
responses are limited to 32 MiB; snapshot limits remain 10,000 assets and 100,000
movements. Configured history/asset budgets are bounded by their existing helpers.
The client refuses HTTP from a database transaction, disables redirects and does
not hide retries or page loops. Live request pacing is at least 0.4 seconds per
client operation; endpoint throttling still fails the request for normal retry.

These are correctness bounds, not a performance result. Assembly replays the
captured prefix, and the runtime verifies its account union for each request;
large wallets have repeated CPU, memory and lock work. Benchmarks and a reviewed
incremental accumulator remain necessary before growth/performance acceptance.

The [bounded FX acquisition](provider-onchain-fx-acquisition.md) supports Twelve
Data and Frankfurter, plus [MOEX dated-history pages](provider-onchain-moex-fx.md)
and [Yahoo authentication/chart steps](provider-onchain-yahoo-fx.md). Undated MOEX
current quotes remain deliberately unsupported. Migration acceptance still
requires empirical explorer/FX response fixtures, rate-limit/retry acceptance
and end-to-end financial migration verification. The existing Transaction-to-Trade conflict quarantine
must preserve legacy Entry UUIDs. This capture implementation does not authorize
activation, accept upstream history coverage, migrate user accounts, or replace
the separate source-policy and identity-bootstrap checks.

Focused tests exercise all configured chain families, exact units/event identity,
verified metadata, quote/FX dates, truncation, real Syncer capture/reconstruction,
an interruption after capture but before apply, live-input drift, separate new
Sync snapshots, capture bounds and native activity pagination. They are unrun.
