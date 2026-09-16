# Proposed Yahoo Finance and MOEX wallet FX acquisition

Status: this design now has bounded implementations of the
[MOEX dated-history planner](provider-onchain-moex-fx.md) and
[Yahoo private-prefix acquisition](provider-onchain-yahoo-fx.md) in the working
tree, with unrun tests. MOEX current-quote date semantics are still unproved;
undated current quotes are deliberately unsupported. The native
wallet also supports the existing [Twelve Data and Frankfurter slice](provider-onchain-fx-acquisition.md).
FX policy and runtime acceptance remain migration gates; no provider activation
is authorized. The detailed implementation reports above supersede proposed
integration steps below; unfinished transport-attempt and current-date policies
remain proposals.

## Boundary and existing behavior

The existing wallet [Assembly](../../app/models/provider/account_data/onchain_wallet/assembly.rb)
is a deterministic consumer of captured operations. Its
[Feeder](../../app/models/provider/account_data/onchain_wallet/feeder.rb) obtains
one missing input and retains it through an encrypted inventory batch. The
[CaptureArchive](../../app/models/provider/account_data/onchain_wallet/capture_archive.rb)
binds that response chain to the original family, connection, Sync, observed
time, configuration and ordered prefix. These mechanisms should also own FX
continuations.

Calling the legacy FX providers from the native reader would hide several
physical requests, retry middleware and mutable caches. Instead, add a pure
provider-specific acquisition planner behind Assembly's existing `read` seam,
and separate transport actions for every GET. Planning and replay perform no
HTTP. Each transport action performs at most one GET, outside a database
transaction, with redirects disabled and bounded response bytes.

The existing captured database-rate lookup remains first. Its nearest-prior
window is five days. Both legacy remote providers use a ten-day lookback for a
single requested date. The proposal preserves that distinction through an
explicit, versioned remote-date policy; it must not silently broaden the
existing Twelve Data or Frankfurter policy.

## Yahoo Finance state machine

The behavior below comes from the repository's
[YahooFinance implementation](../../app/models/provider/yahoo_finance.rb),
including `fetch_exchange_rate`, `fetch_chart_data`,
`fetch_authenticated_chart` and `request_cookie_and_crumb`.

| State | Request step or explicit branch | Captured result and next decision |
| --- | --- | --- |
| Cookie | GET `https://fc.yahoo.com` | Retain a bounded selected cookie and its lifetime. A 404 may still set a usable cookie. A missing cookie is an authentication failure. |
| Crumb | GET `/v1/test/getcrumb` with the captured cookie | Retain a bounded crumb. Empty content is invalid; the known `Too Many Requests` body is a rate-limit result. |
| Direct chart | GET `/v8/finance/chart/FROMTO=X` with the captured cookie/crumb | Retain requested symbol, response symbol, timestamps, closes and bounded error code. Resolve the direct quote or take an explicit fallback branch. |
| Direct refresh | New cookie GET, new crumb GET, then the same direct chart GET | Allowed once for the embedded chart `Unauthorized` condition. A second authentication denial terminates acquisition. |
| Inverse chart | GET `/v8/finance/chart/TOFROM=X` with the selected captured session | Allowed only by the recorded direct-result disposition. Retain inversion as part of quote provenance. |
| Inverse refresh | New cookie GET, new crumb GET, then the same inverse chart GET | The legacy wrapper also permits one refresh for this separate chart call. A second authentication denial terminates acquisition. |

Each refresh row represents three separately captured transitions, never three
requests hidden inside a single reader call.

The chart interval is the requested date minus ten days through the requested
date, with `interval=1d`. Compute Unix boundaries from explicit UTC calendar
components, not the worker's timezone. Select the exact requested day or the
latest earlier eligible timestamp. Require a positive finite decimal and keep
the actual rate date. For an inverse quote, calculate `1 / rate` using decimal
arithmetic and the legacy twelve-place rounding, recording the original pair,
value and direction. There is no Yahoo FX current-quote shortcut for a missing
historical rate.

The legacy direct/inverse distinction is significant: `fetch_chart_data`
returns `nil` for missing/error chart data and certain transport/parse failures,
which permits inverse lookup. A present chart with no usable points returns
`[]`, which is truthy in Ruby and prevents inverse lookup. Preserve empty data
as a distinct disposition. Do not silently broaden inverse fallback to every
authentication, rate-limit or malformed-response failure. Transient failure
classification should follow the explicit native transport policy, rather than
copying the legacy wrapper's broad rescue into hidden fallback requests.

With a cold session, both direct and inverse attempts, and one authentication
refresh for each chart call, the branch graph contains at most ten GETs. This
does not include transport retries; those require the separate finite attempt
accounting described below.

## Private Yahoo authentication and replay

Cookie and crumb responses are credentials, even though this integration has no
configured API key. The current FX response scrubber intentionally discards
headers, so a new, tightly validated private authentication envelope is needed.
Retain only the selected cookie value, crumb, acquisition time and bounded
expiry information in encrypted capture evidence. Do not retain arbitrary
headers, HTML, provider error messages or request URLs containing the crumb.

Keep operation descriptors secret-free. A crumb or chart operation should
reference the exact earlier authentication fragment by its index/digest and
session generation. Client/Feeder resolves the private values only from the
verified same-Sync prefix. Do not put cookie/crumb values in cursors, diagnostics,
canonical records or ordinary quote metadata. Do not read or mutate the legacy
global Rails authentication cache.

An accepted authentication fragment must be committed before a later operation
uses it. A failed response capture cannot create a durable session elsewhere.
Replay uses the original fragment rather than refetching authentication. A new
Sync begins its own session; it cannot select a previous Sync's latest cookie.

Expiry must also be explicit. Bound the selected lifetime to the legacy
one-hour maximum and retain its derivation from `Max-Age`. If a live request
needs an expired session, capture a typed local expiry disposition and follow
the bounded refresh branch. Never make replay depend on today's clock or
silently replace credentials inside a chart request. Missing or contradictory
expiry information needs a declared conservative policy and tests before this
branch is implemented.

## MOEX state machine

The repository's [MoexPublic implementation](../../app/models/provider/moex_public.rb)
supports RUB crossed with USD, EUR or CNY through these instruments:

| Foreign currency | Instrument | Direction |
| --- | --- | --- |
| USD | `USD000UTSTOM` | Foreign currency to RUB is direct; RUB to foreign currency is inverse. |
| EUR | `EUR_RUB__TOM` | Same direction rule. |
| CNY | `CNYRUB_TOM` | Same direction rule. |

Other pairs produce an explicit unsupported-pair disposition without HTTP. This
proposal does not introduce a two-leg cross-currency conversion.

1. Request `/history/engines/currency/markets/selt/boards/CETS/securities/INSTRUMENT.json`
   with fixed `from`, `till`, `start=0` and `iss.meta=off`.
2. Capture each history page independently. Continue after a full 100-row page
   with `start` advanced by the captured physical row count. The legacy ceiling
   is 500 history pages. Hitting a ceiling with possible remaining data is
   incomplete, not proof of terminal history.
3. For a request at the original Sync's frozen current date, a separate GET to
   `/engines/currency/markets/selt/boards/CETS/securities/INSTRUMENT.json` may
   obtain current marketdata. A historical request must never substitute a
   current quote.
4. Normalize ISS column arrays by column name, retaining exact instrument/board
   identity and the date/value fields used. Reject ambiguous duplicate columns
   or conflicting same-date observations. History prefers `CLOSE`, then
   `WAPRICE`, as the legacy implementation does.
5. Choose the exact requested date or nearest eligible prior date, and apply
   decimal inversion when required. A usable current quote replaces history on
   the same proven date. A valid empty current response leaves the dated history
   candidate available; a failed request remains a separate error disposition.

The base branch graph is at most 500 history GETs plus one current GET per
conversion. The ten-day date interval should normally require far fewer pages;
unexpected rows still need explicit validation and bounds. The
[official ISS reference](https://iss.moex.com/iss/reference/) lists separate
history and current instrument endpoints. It does not by itself establish the
quote-date policy below.

### Unresolved current-quote date proof

Legacy `fx_current` chooses `LAST`, `WAPRICE`, `MARKETPRICE` or `LCLOSEPRICE` and
stamps the value with `Date.current`. It does not establish the remote quote's
date. The repository's current FX tests do not supply that missing proof.

Before implementing current valuation, obtain representative provider responses
and authoritative field semantics for each accepted price field. Establish
which date describes a last trade, weighted average, market price or previous
close. A response publication timestamp or a time-of-day field alone must not
turn a previous close into today's quote. Requesting the additional securities
block may be necessary, but its sufficiency is not established here. The JSON
endpoint/schema responses could not be retrieved during this investigation.

Until the date mapping is proved, retain the current response as unavailable for
valuation and use an eligible explicitly dated history quote. Do not fabricate
a date from the request, worker time, frozen Sync date or HTTP response time.
This is a remaining parity requirement, not a completed current-price port.

## Bounds, configuration and failure handling

Pin provider choice, endpoints, pacing, header profile, date policy, response
schema version and operation limits through FxConfiguration and the existing
RuntimeInputs/RequestGrant proof. Yahoo's configured base URL comes from
`YAHOO_FINANCE_URL`; its cookie endpoint is separately fixed. MOEX uses
`MOEX_ISS_URL`. Provider data must not supply either endpoint. A live change
invalidates the captured request context; it must not rebuild a reader in the
middle of the chain.

Keep the current one-MiB per-response and cumulative capture budgets, with
smaller dedicated limits for cookies, crumbs, symbols and selected chart fields.
Each response must prove the requested pair/instrument and contain only bounded
arrays. Both accepted rates and reciprocal inputs must be positive finite exact
decimals. Eligible remote rate dates are within `[requested_date - 10,
requested_date]`; future dates are never accepted. Requested dates themselves
are bounded by the original Sync's frozen observation date.

The branch limits above are not retry limits. Do not claim finite physical
attempts from the successful-fragment count alone. A proposed maximum of three
transport attempts per step needs durable reservation before dispatch, so a
worker crash consumes an attempt and cannot reset the budget. Implementation
must first identify or add that exact execution seam; until then, automatic
transport retries for these new actions remain disabled. Authentication refresh
also consumes its declared branch budget. No reader-level retry middleware is
permitted. Installation-wide throttling remains separate from per-reader pacing.

Successful and terminal unavailable results can be replayed immutably. Transient
errors must leave the operation pending rather than seal missing valuation as a
successful result. An ownership/configuration denial must propagate unchanged.
None of these operations writes the shared ExchangeRate table or changes a
financial account before the ordinary admitted publication phase.

## Implementation and verification sequence

First introduce the pure acquisition planner and typed actions behind the
existing Assembly continuation, preserving Twelve Data and Frankfurter behavior.
MOEX dated history is the smaller independent transport slice. Yahoo then needs
the private authentication-reference seam. MOEX current valuation stays gated on
the field/date evidence above.

Behavioral coverage must include interruption after every physical step;
same-Sync replay without HTTP; exact authentication-prefix ownership; expiry and
bounded refresh; direct/inverse/empty-data distinctions; reordered ISS columns;
full-page truncation; absent/future/contradictory dates; previous-close handling;
midnight resume; endpoint/configuration drift; secret redaction; and finite retry
accounting. Follow with production Syncer tests showing missing valuation does
not replace a known balance or claim complete holdings. All of this coverage is
proposed, not a report of tests that have run.
