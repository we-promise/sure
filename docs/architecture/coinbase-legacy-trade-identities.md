# Coinbase retained trade identities

The native Coinbase activity writer can reuse an existing `coinbase_buy_*` or
`coinbase_sell_*` financial identity when a `coinbase_txn_*` observation has an
exact retained provider relationship to it. This is implemented in
[LegacyTradeIdentity](../../app/models/provider/account_data/coinbase/legacy_trade_identity.rb)
and consumed by [LedgerWriter](../../app/models/ingestion/ledger_writer.rb).
It does not match trades by amount, date, name or security.

The relationship must come from a completed retained transaction's embedded
buy/sell ID, or a completed retained buy/sell endpoint row together with that
explicit ID in the newly captured transaction. The copied archive, original
account/link binding, current activities policy and captured native batch must
agree. The original active posting must also have permanent signed bootstrap
proof for the exact Entry and Trade identity. Missing, withdrawn, retyped,
unsigned or conflicting postings refuse publication. A retained old trade with
no explicit relationship cannot silently become a second native trade.

Successful publication preserves the original Entry and Trade UUIDs and their
legacy external ID. Ordinary insert-only trade behavior preserves financial and
user edits. The original SourceRecord's immutable input ID also remains the old
ID; the native transaction ID and endpoint relationship remain in the encrypted
captured native page. Subsequent observations must prove the same relationship
from the previous applied capture. The writer refuses two modern transaction
IDs claiming one legacy identity, including claims in separate pages.

An explicit new endpoint ID with no retained old identity follows ordinary
native publication. Observation-only sources do not borrow an authoritative
financial posting. This is a same-provider migration bridge, not cross-provider
deduplication or source switching.

Archive rows, identity inventories and stored proof bytes are bounded. Reads and
proof checks run in the existing admitted publication transaction without HTTP.
Repeated proof validation under the account lock still needs large-page
performance acceptance. Stored-byte checks do not establish a hard bound on
decompression allocations for historical encrypted values.

[Fifteen behavioral tests](../../test/models/provider/account_data/coinbase/legacy_trade_identity_test.rb)
cover buy/sell UUID retention, replay, preserved user edits, ordinary new trades,
missing and conflicting proof, captured-input mismatch, source-policy and
account drift, ambiguous relationships and bounds. They are authored but unrun
because Ruby is unavailable in this environment. No migration or cutover was
executed and no native readiness flag changed. Older archives without required
copy-time baselines, unresolved legacy relationships, cached valuation fallback,
lifecycle and executable parity acceptance remain gates.
