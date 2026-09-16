# Bounded Onchain FX acquisition

This is an implementation in the current working tree, with tests authored but
unrun. It adds native acquisition for **Twelve Data and Frankfurter**. A subsequent
[MOEX dated-history slice](provider-onchain-moex-fx.md) uses separately captured
pages. [Yahoo acquisition](provider-onchain-yahoo-fx.md) now integrates separately
captured authentication and chart steps. Undated current MOEX quotes remain
unsupported. No provider has been activated and no migration has been executed.

The [wallet assembly](../../app/models/provider/account_data/onchain_wallet/assembly.rb)
first captures the existing `fx` cache lookup. An exact rate or the nearest prior
rate within five days remains usable with its database row ID, original rate,
actual date and `cached_exchange_rate` provenance. A cache miss now produces a
separate `fx_remote` operation, which is persisted through the same encrypted
inventory batch and capture-prefix protocol as explorer and price responses.
Neither operation writes to the shared ExchangeRate table.

## Configuration and request admission

[FxConfiguration](../../app/models/provider/account_data/onchain_wallet/fx_configuration.rb)
resolves the effective `EXCHANGE_RATE_PROVIDER`/Setting selection and, for Twelve
Data, the existing ENV-over-encrypted-Setting API key precedence. Settings are
read freshly under the runtime settings lock; the worker's RailsSettings request
cache does not authorize a request. The existing Setting decryption method is
used after the declared field's deserialization.

RuntimeContext exposes the credentials as a separate live application input.
The nonsecret wallet configuration contains the provider, selected endpoint,
bounded pacing interval and a keyed credential fingerprint. The purpose is
`onchain-fx-credentials/v1`, using the existing RuntimeInputs key derivation.
Changing the application's signing secret therefore invalidates retained request
proof, consistently with other runtime inputs. API keys are not included in
feeder cursors, commands, configuration digests, public metadata or captures.

The factory constructs [FxReader](../../app/models/provider/account_data/onchain_wallet/fx_reader.rb)
once from those captured values and checks their agreement. RequestGrant
revalidates the complete configuration/credential input before the request and
before publication. A key, endpoint or provider change rejects stale work; it
does not rebuild the reader with new credentials in the middle of a capture.

Each remote operation executes at most one HTTP GET outside any database
transaction, with redirects disabled, a 20-second timeout and a one-MiB body
bound. It does not call the mutable provider registry, legacy retry middleware,
cross-rate fallback or hidden pagination. Pacing uses the captured setting and
per-reader clock. Shared, cross-worker credit coordination remains a rate-limit
acceptance requirement; local pacing does not claim to enforce an installation's
global Twelve Data quota.

## Evidence and dates

| Provider | Single request | Required identity/date proof |
| --- | --- | --- |
| Twelve Data | `/exchange_rate?symbol=FROM/TO&date=YYYY-MM-DD&timezone=UTC`, captured key in Authorization header | Exact returned pair and an explicit returned date or Unix timestamp. If both are present, their UTC days must agree. |
| Frankfurter | `/rate/FROM/TO?date=YYYY-MM-DD` | Exact returned base/quote and canonical returned calendar date. |

The request contracts follow the [Twelve Data exchange-rate documentation](https://twelvedata.com/docs)
and [Frankfurter v2 documentation](https://frankfurter.dev/). Twelve Data requests
explicit UTC interpretation; Frankfurter's returned observation day stays intact.

Only identity, rate, date/timestamp and bounded response status fields are
retained. Request headers, credentials and provider error messages are omitted.
Authentication, other terminal request failures and malformed responses are
retained as typed unavailable results. HTTP 429/5xx, Twelve Data JSON 429/5xx and
transport failures raise sanitized reader errors before appending a fragment.
They leave that operation pending for execution retry. A new adapter for the same
Sync replays its successful prefix and retries only the still-missing operation;
it does not replace earlier responses. The reader performs no hidden retries.

A usable rate is a positive finite exact decimal. Its actual date must be on or
before the requested day and at most five days earlier. Missing, contradictory,
future or older dates remain unavailable. A request for a date does not prove
that the response describes that date. Currency is never relabeled and no 1:1
fallback is generated. The derived quote preserves original price/currency,
actual FX date, rate and converted price; the inventory fragment identifies the
provider response used to derive it.

Unavailable responses remain immutable within their logical Sync. A later Sync
may make a fresh attempt. Replay consumes the original captured cache result and
provider response without consulting today's cache or issuing another request.

## Remaining provider work

The [Yahoo/MOEX protocol proposal](provider-onchain-remaining-fx.md) records the
separate request states, private authentication references, bounds and unresolved
current-quote date evidence needed for the next ports. It is not implemented.

The [native Yahoo integration](provider-onchain-yahoo-fx.md) now captures cookie,
crumb and dated chart steps independently, with exact durable-prefix ownership,
bounded refresh and explicit inverse-rate evidence. It uses no global session
cache or legacy wrapper. Runtime acceptance remains unverified.

The existing [MOEX implementation](../../app/models/provider/moex_public.rb)
supports RUB crosses with USD/EUR/CNY. Native dated history now has a bounded
[captured-page planner](provider-onchain-moex-fx.md) with exact pair/inversion
proof and a ten-day remote window. The legacy current branch uses Date.current;
that must not be copied as proof of a remote quote's historical date. Current
marketdata remains deliberately unsupported without that date proof. Accepting
history-only valuation is an explicit migration parity decision.

Unsupported MOEX currency pairs emit `unsupported_pair`. Unknown provider
selections remain `unsupported_provider`. There is no silent switch to Frankfurter
or Twelve Data. FX policy acceptance, endpoint
fixtures, credit/retry acceptance and financial migration verification remain
gates. The native Onchain readiness flag stays false.

Tests cover exact decimal/date parsing, unavailable/error responses, bounded
transport, no-transaction HTTP, missing/changed credentials, a real other-session
encrypted Setting change, admission/publication rejection despite stale request
cache, production Syncer capture/replay with both remote and cached rates, and
same-Sync retry after 429 then 503 with an unchanged successful capture prefix.
All remain unrun in this workspace.
