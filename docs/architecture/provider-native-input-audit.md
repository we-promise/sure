# Provider native input migration inventory

As of the working tree on 2026-09-15. This read-only inventory compares all 23
legacy item/account manifests with native factory inputs and retained-input
handoffs. Plaid US and EU share one manifest, making 24 offerings. It records work
to complete; it is not a readiness flag or permission to activate a provider.
Runtime tests remain unrun. No migrations or cutovers were executed for this audit.

The distinctions matter:

- **Archived** means the typed value is retained by the copier. It does not mean
  an adapter receives that value or that it proves upstream history coverage.
- **Executable** means a production construction/read path consumes the input.
  Code on disk is not a claim of tested runtime parity.
- **Accepted** requires the relevant retained-context, identity, history and
  ownership checks. Preparation now integrates logos for all 20 declared scopes
  and additionally Binance history; all 20 contracts remain explicitly partial.
  Onchain wallets, Trade Republic and Wise remain `not_integrated`.

Sources: [column catalog](../../app/models/provider/account_data/migration_manifest_catalog.rb),
[manifest identities](../../app/models/provider/account_data/migration_manifest.rb),
[copier projections](../../app/models/provider/account_data/migration_copier.rb),
[runtime collectors](../../app/models/provider/account_data/runtime_context.rb), and
[preparation input contracts](../../app/models/provider/account_data/migration_preparation.rb).
Declared source columns are retained; ActiveStorage, cache-only hints, deployment
configuration and missing historical upstream evidence require separate treatment.
Shared family preferences, merchants and ledger rows already exist outside these
provider archives. Their continued presence is not another provider export.

## Ranked provider inventory

Priority 1 identifies a concrete missing input or incompatible routing convention.
Priority 2 identifies retained inputs requiring acceptance, fallback or continuation
handling. Priority 3 means this bounded review found no additional required factory
input gap; it does not establish complete migration coverage. The logo scope below
applies in addition to these rows.

| Priority | Provider | Archived/projected | Executable native input | Remaining acceptance or primitive |
| --- | --- | --- | --- | --- |
| 1 | Onchain wallets | Asset descriptors, quantities, movements and raw payloads; copier constructs `source_descriptor`. | [Native capture and assembly](provider-onchain-capture.md) obtains bounded physical responses for the current logical Sync and replays an immutable wallet/quote chain. [Pinned FX acquisition](provider-onchain-fx-acquisition.md) supports Twelve Data, Frankfurter, captured MOEX dated history and separately captured Yahoo cookie/crumb/chart requests. Yahoo secrets resolve only from the exact durable same-Sync prefix; authentication expiry uses the dispatch clock while rate dates stay frozen. | Run the unexecuted interruption, replay, chain and financial migration tests. Quota coordination, lifecycle, performance and the legacy Transaction-to-Trade transition remain gates. Undated MOEX current quotes remain deliberately unsupported; the dated-history policy needs parity acceptance. |
| 1 | Plaid US/EU | Token, region, item/account identity, account caches and `next_cursor`. New quiesced archives also retain an explicit deployment/application binding. | [Deployment binding](provider-plaid-deployment-binding.md) reaches the actual factory and request admission; the [cached-change journal](plaid-cached-change-journal.md) now captures and verifies every ordered planner page through migration preparation. | Run journal/binding/copy/retry/drift regressions, then resolve financial replay/dispositions and coordinated cursor acceptance. Journal completion does not prove changes applied. Historical generation and unassigned-removal coverage were not retained; older unbound copies need explicit reconciliation. |
| 2 | Wise | Profile, token/SCA credentials, settings and transaction caches. | [Retained account-history collector](provider-wise-retained-history.md) supplies verified overlap policy; an atomically retained native statement posting can disable legacy fallback in a later factory snapshot. | Run publication/replay/promotion regressions. Connection-wide fallback authorization, confirmed transfer linking and coverage remain gates. Resetting an entire promotion checkpoint needs an explicit protocol. |
| 2 | Trade Republic | Session, positions, timelines, remote account ID and `newest_event_id`; current copier delta projects item currency. | [Retained portfolio collector](trade-republic-native-port.md) maps exact remote ownership onto copied local kind IDs and supplies bounded prior quotes with archive provenance to the actual factory. | Run topology/fanout/quote regressions. Timeline-cache reprocessing, financial relocation and complete holdings/lifecycle acceptance remain. One newest-event ID is not the native multi-topic cursor. |
| 2 | Trading212 | Instruments, positions, orders, dividends and transactions; current copier delta projects item currency. | [Retained instrument collector](provider-retained-runtime-inputs.md) supplies the declared frozen factory input; failed fresh requests retain copied names. | Run fallback, drift and malformed-input regressions; accept history/activity/holding parity and lifecycle. History timestamps still need explicit disposition. |
| 2 | SimpleFIN | Account/transaction/holding caches and classifier metadata. New quiesced archives also retain the typed cache hint, expiry and explicit absence. | [Retained classifier hint](simplefin-retained-classifier-hint.md) replaces live legacy-cache reads; frozen classifier snapshots and fresh transaction balance inputs consume the retained evidence. | Run copy/factory/expiry/replay regressions, reconcile older archives without the hint, and accept history/classifier/lifecycle parity. Cache absence is only an observation at capture time. |
| 2 | Monobank | `history_synced_from`, `statement_synced_through`, dates and raw transactions. | [Retained-history collector](monobank-retained-history.md) supplies exact archived boundary values and derives oldest-held time with verified source/account binding. | Run request/replay, pending and drift regressions. Expiry policy, full history/lifecycle acceptance and cutover remain; archived timestamps do not prove complete upstream coverage. |
| 2 | IBKR | Parsed item/account financial caches, report dates and history timestamps. Auxiliary logo receipt is integrated. | [Archive](../../app/models/provider/account_data/ibkr/archive.rb) consumes this Sync's captured provider export; selected historical handoff uses explicit sealed sources. | Accept retained parsed history separately from fresh Flex capture. Original legacy Flex XML was not retained and cannot be supplied as original evidence. Logo acceptance does not accept financial history. |
| 2 | Sophtron | Customer/institution IDs, manual flags, current job/account/status and raw job payload. | [Factory](../../app/models/provider/account_data/sophtron.rb) consumes IDs and manual settings. | Explicit outstanding-job disposition: drain, validated continuation or reviewed restart. Archived job fields do not establish native job/MFA ownership. |
| 2 | Kraken | Keys, combined-account caches and `last_nonce`. | [Nonce generator](../../app/models/provider/account_data/nonce_generator.rb) already seeds from copied `legacy_state`; adapter consumes account context and FX. | Accepted nonce/credential handover across all same-key writers; partial/cached valuation disposition. No second nonce export is needed. |
| 2 | SnapTrade | OAuth/SDK credentials, expiry, account caches and history timestamps. Current copier delta places expiry/scope/type with live credentials. | [Session reader](../../app/models/provider/snaptrade/ingestion_client.rb) reads expiry from credentials; [adapter](../../app/models/provider/account_data/snaptrade.rb) fetches remote authorization inventory. | OAuth application/token acceptance; SDK-only connections require reconnection. Archived timestamps are not native coverage. Absence of copied authorization rows alone is not proof of a missing input, because inventory is fetched. |
| 2 | Binance | Retained history seed is installed/verified and integrated with preparation; other raw portfolio caches remain archived. | [Factory](../../app/models/provider/account_data/binance.rb) consumes the installed seed; normal activity progress overrides it. | Non-combined topology reconciliation and partial portfolio fallback acceptance. Legacy `extra` preservation does not itself populate native `portfolio_sources`; history seed acceptance is not complete upstream coverage. |
| 2 | Coinbase | Crypto units and account fiat valuations remain distinct; retained derived projection preserves the copy-time baseline. | [Factory](../../app/models/provider/account_data/coinbase.rb) consumes linked-account context. | Cached valuation fallback and old buy/sell identity reconciliation. No additional raw export identified. |
| 2 | Indexa Capital | Token, balances and holdings/activity caches. | [Factory](../../app/models/provider/account_data/indexa_capital.rb) consumes external accounts and pinned application-token fallback; definition supports holdings. | Holdings/security/price acceptance. Archived activities do not establish a supported live activity capability. |
| 2 | Questrade | Refresh token, API server, account caches and history timestamps. | [Session reader](../../app/models/provider/questrade/ingestion_client.rb) deliberately refreshes when no access token is available. | Cached fallback, history/identity acceptance and all-consumer token handover. A separate access-token export is not required by this factory. |
| 3 | CoinStats | Typed source descriptors plus account/transaction caches. | [Factory](../../app/models/provider/account_data/coinstats.rb) consumes copied descriptors, external accounts and FX. | Descriptor/topology and valuation acceptance; no additional required retained collector identified. |
| 3 | Enable Banking | Application/consent credentials, expiry, membership and account identifiers are projected. | [Factory](../../app/models/provider/account_data/enable_banking.rb) consumes grants/accounts/shared merchants. [Inventory publication](enable-banking-authorization-inventory.md) binds fresh API UIDs and membership additions to captured consent evidence before rebuilding subsequent request inputs. [Direct admission](enable-banking-legacy-admission.md) and [consent lifecycle](enable-banking-consent-lifecycle.md) preserve original legacy ownership. [History verification](enable-banking-cutover-history.md) checks signed cached dispositions, the copied consent and memberships; absent explicit dates request all accessible history without treating cache or successful Syncs as coverage. | Native grant status/renewal/revocation management, signed legacy setup/linking, uncertain revocation reconciliation, authorization-aware retirement and full routing/history/performance acceptance remain. Written tests are unrun and readiness is false. Merchants already exist in shared tables. |
| 3 | Akahu | Credentials, dates and raw account/transaction data. | [Factory](../../app/models/provider/account_data/akahu.rb) needs credentials/timezone; [retained-history verification](akahu-cutover-history.md) preserves stable financial identities and collision-free signed idless pending originals, explicit dates and full accessible history when unset. Mapped idless observations reject monetary-unit changes. [Legacy lifecycle admission](akahu-legacy-admission.md) guards discovery, credentials, selection, unlink and sync routing. [Native lifecycle](akahu-native-lifecycle.md) adds shared configuration/setup, saved routes and reviewed retirement. | Ambiguous idless suffix/occurrence disposition and executable currency/pending/history/lifecycle acceptance remain; parity suites are authored but unrun and readiness is false. No further factory cache transfer identified. |
| 3 | Brex | Token/base URL, routing metadata and raw caches. | [Factory](../../app/models/provider/account_data/brex.rb) obtains fresh cash/card inventory. | Inventory/history acceptance; no further factory collector identified. |
| 3 | Lunch Flow | Credentials/settings, holdings capability metadata and raw holdings/transactions. | [Factory](../../app/models/provider/account_data/lunchflow.rb) reads fresh data plus configured pending preference. | Holdings/history acceptance; no required retained factory cache identified. |
| 3 | Mercury | Credentials/base URL, account attributes and raw caches. | [Factory](../../app/models/provider/account_data/mercury.rb) reads fresh provider data. | History acceptance; no additional factory collector identified. |
| 3 | Redbark | Credentials, connection/account IDs, ignored state and raw caches. | [Factory](../../app/models/provider/account_data/redbark.rb) obtains routing through fresh inventory. | Inventory/history acceptance; no additional factory collector identified. |
| 3 | Up | Token, ignored/ownership settings, dates and raw caches. | [Factory](../../app/models/provider/account_data/up.rb) reads fresh provider data. | History/lifecycle acceptance; no additional factory collector identified. |

The currency and SnapTrade expiry rows include the current working-tree
`MigrationCopier#connection_settings` and `#connection_credentials` changes. These
are projection fixes, not accepted history receipts. See also
[application credential resolution](../../app/models/provider/account_data/application_credentials.rb)
for the distinct deployment configuration used by Plaid, SnapTrade and Indexa.

## Auxiliary attachment scope

Twenty legacy item models declare an ActiveStorage `logo`. The original audit
found 19 scopes beyond IBKR without a transfer. The [shared auxiliary copier](../../app/models/provider/account_data/auxiliary_copier.rb)
and preparation now integrate those **19 additional logo scopes**:

Akahu, Binance, Brex, Coinbase, CoinStats, Enable Banking, Indexa Capital, Kraken,
Lunch Flow, Mercury, Monobank, Plaid, Questrade, Redbark, SimpleFIN, SnapTrade,
Sophtron, Trading212 and Up. Onchain wallets, Trade Republic and Wise have no logo
attachment declaration in their current item models.

These attachment/blob bytes are not column payloads. The shared receipt retains
exact association/blob metadata and bytes, explicit absence, original copy context
and receipt IDs; it verifies without replacing the original blob. Existing IBKR
formats are preserved. Implementation/tests are unrun, and old non-IBKR preparation
contracts require explicit reconciliation. See [logo transfer](provider-logo-transfer.md).
This does not authorize activation or prove that no other auxiliary inputs exist.

## Next concrete input primitives

The retained-input follow-ons below have implementation with unrun tests. Plaid
cache acceptance still requires a separate publication and reconciliation primitive:

1. **Shared logo receipt acceptance:** run the new copy/retry/retained-byte tests
   for all declared scopes and review storage/lifecycle behavior before use.
2. **Trading212 catalog acceptance:** exercise the bounded archived catalog through
   its declared frozen runtime input, failed refresh and current request proof.
3. **Wise history-policy acceptance and continuation:** exercise derived flags,
   cutoffs and atomic statement-success promotion; implement profile-wide fallback
   authorization separately from per-account facts and define explicit reset.
4. **Monobank history-state acceptance:** exercise exact archived boundaries and
   oldest-hold derivation through factory capture, pending policy and replay.
5. **SimpleFIN classifier-hint acceptance:** exercise the retained typed cache
   observation and native construction; reconcile older archives without the
   capture. Never revive expired hints or infer historical absence from eviction.
6. **Plaid deployment-binding acceptance:** exercise the immutable copy-run binding,
   repeated item-copy path, source/application drift and factory/request checks.
   This preserves configuration provenance; it does not establish that the token
   is valid upstream or that cached transactions have been applied.
7. **Plaid cached-change and checkpoint acceptance:** execute the durable journal
   regressions, then resolve every ordered observation through an explicit
   financial-publication/disposition path. Duplicates and excluded pending rows
   now survive in the signed journal; its completion is not financial acceptance.
   Resolve missing item-wide coverage separately before installing a live cursor.
   Legacy caches overwrite older change sets, and the old cursor can advance before
   financial processing succeeds. Neither a successful legacy Sync nor the existing
   read-only plan proves complete acceptance.

Onchain capture/assembly and bounded Twelve Data/Frankfurter/MOEX-history/Yahoo FX
acquisition now have implementation with unrun tests. Yahoo integration includes
durable private authentication references, bounded refresh/inverse branches and
dispatch-time expiry checks. Runtime/performance verification, quota coordination
and financial migration acceptance remain priority-1 blockers. Undated MOEX
current quotes are excluded rather than assigned an inferred date.
Trade Republic's copied topology and quote input now have implementation, but
their runtime acceptance and historical timeline disposition remain unfinished.
Any new handoff must preserve original archives and receipt IDs, reject stale or
foreign context, retain financial UUIDs and user edits, and survive child commit /
parent retry. Regular native cursor progress must not overwrite installation
evidence. A fresh empty cursor or successful current request cannot establish
complete historical coverage.
