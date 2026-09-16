# Captured Onchain Yahoo FX

Yahoo FX acquisition is integrated in the current working tree; all associated
tests are authored but unrun. No provider has been activated and no migration or
live market-data request has been executed.

After the existing five-day cache lookup misses, the pure
[FxAcquisition planner](../../app/models/provider/account_data/onchain_wallet/fx_acquisition.rb)
requests a cookie, a crumb and a dated chart as separate captured steps. Yahoo's
remote lookback is ten days, without broadening cache, Twelve Data or Frankfurter
date policies. A supported direct chart with no usable points ends acquisition;
only a captured `pair_unavailable` result permits an inverse chart. Inversion
uses exact decimal arithmetic and twelve-place rounding, with its original
symbol, rate and date retained in the derived fact and capture evidence.

The [configuration](../../app/models/provider/account_data/onchain_wallet/fx_configuration.rb)
pins `YAHOO_FINANCE_URL`, the first existing browser header profile, bounded
`YAHOO_FINANCE_MIN_REQUEST_INTERVAL` and `yahoo-captured-fx/v1`. The cookie endpoint
is fixed by the reader. Provider data cannot redirect a request or select a new
endpoint. Live configuration proof rejects changes before request admission and
publication rather than recapturing a changed baseline.

## Private authentication boundary

The [Feeder](../../app/models/provider/account_data/onchain_wallet/feeder.rb)
records authentication references as a fragment index and its full SHA-256
digest, including the preceding capture prefix. Descriptors contain no cookie
or crumb. Before a crumb or chart step, it calls the existing validated
[CaptureArchive](../../app/models/provider/account_data/onchain_wallet/capture_archive.rb)
reader and requires exactly its original family, connection, Sync, input digest
and complete in-memory prefix. Only a matching committed archive may supply the
private response envelopes to Client. Accepting a response into Feeder memory
before publication does not authorize a dependent request.

The referenced fragment must have the expected cookie or crumb action. The
[Yahoo reader](../../app/models/provider/account_data/onchain_wallet/yahoo_fx_reader.rb)
then validates pair, original rate date, authentication generation, configuration,
cookie-to-crumb digest, expiry and chronology. Authentication envelopes are
encrypted batch evidence, never operation arguments, cursors, ordinary quote
metadata, logs or the legacy global authentication cache. Page and reader
inspection redact private payloads. A replaced, foreign, missing or uncommitted
prefix fails before HTTP.

CaptureArchive finishes its database and grant locks before the HTTP call.
Rechecking the complete archive for each crumb/chart is deliberately conservative:
it can cause quadratic verification work as captures grow. This implementation
does not establish acceptable performance for large wallets; benchmarks and a
reviewed incremental proof mechanism remain separate work.

## Request time and deterministic replay

The requested rate date belongs to the original Sync. Authentication uses the
actual request clock. Client omits its generic delay for Yahoo, and YahooFxReader
samples an explicit production clock after its own final pacing delay. Expiry
is checked immediately before dispatch; a cookie that expires while waiting is
not sent. A local `auth_expired` disposition is itself captured, including that
actual clock, with no HTTP status or invented network response.

Replay uses those saved dispositions and timestamps, without consulting today's
clock to reinterpret an earlier chart. A successful captured-but-unapplied step
is revalidated and applied before its next dependent request. A completed chart
remains usable after its authentication later expires because it describes the
original captured observation, not permission for a fresh request.

One refresh is permitted per direct/inverse direction, with at most three
authentication generations and ten physical GETs on the longest branch. A
captured local expiry or an embedded HTTP-200 `Unauthorized` chart response can
consume that refresh. Terminal HTTP authentication errors, malformed data and
other request failures do not silently trigger inverse lookup. An additional
failure after the direction's refresh budget leaves valuation unavailable.

Each action performs at most one physical GET, outside database transactions,
with redirects and underlying Net::HTTP retries disabled. HTTP 429/5xx and
transport errors raise sanitized failures before a fragment is appended, leaving
the operation pending. These branch bounds do not limit repeated failed transport
attempts across worker invocations; durable attempt reservation and installation-
wide quota acceptance remain explicit gates. Cookie/crumb field limits and the
one-MiB chart bound supplement the aggregate wallet capture budget.

## Verification still required

Eight planner tests cover direct/inverse distinctions, empty responses, bounded
refresh, captured expiry, replay and configuration changes. Five production
Syncer tests cover interruption after each physical step, denial before durable
publication, wrong private references, expiry across days and live input drift.
The isolated reader suite also checks that expiry is evaluated after pacing.
All tests remain unrun. Provider response acceptance, rate-limit operation,
performance and end-to-end financial migration verification are still required;
the native readiness gate remains false.
