# Retained provider logo transfer

Implementation and behavioral tests are written; Rails/PostgreSQL/ActiveStorage
tests remain unrun. No migration, activation, blob replacement or purge was
performed. This is auxiliary preservation, not financial-history acceptance.

`Provider::AccountData::AuxiliaryCopier.for(control:)` selects an explicit reviewed
logo scope for all 20 legacy item models that declare `logo`: Akahu, Binance,
Brex, Coinbase, CoinStats, Enable Banking, IBKR, Indexa Capital, Kraken, Lunch Flow,
Mercury, Monobank, Plaid, Questrade, Redbark, SimpleFIN, SnapTrade, Sophtron,
Trading212 and Up. Onchain wallets, Trade Republic and Wise have no declared logo
scope. An unknown provider or additional attachment/schema column requires review.
Model names come only from the allowlisted migration manifest.

## Formats and compatibility

The 19 non-IBKR providers use stream `legacy_logo_auxiliary`, archive format
`provider-logo-auxiliary/v1`, retained context format
`provider-retained-logo-auxiliary/v1`, and scope `<LegacyItemType>:<UUID>:logo`.
The encrypted manifest pins family, control, connection, original source item,
exact attachment/blob columns and a keyed fingerprint. Retained mode additionally
pins the original verified row-copy context before reading bytes.

The old `Ibkr::AuxiliaryCopier` class remains as a compatibility subclass.
`.for` selects it for IBKR. Its original `legacy_ibkr_auxiliary` stream,
`ibkr-logo-auxiliary/v1` archive, `ibkr-retained-auxiliary/v1` context,
`IbkrItem:<UUID>:logo` scope, `ibkr-auxiliary` idempotency prefix and
`ibkr-auxiliary-manifest-v1` HMAC salt are unchanged. Original checkpoint, chunk,
attachment and copy-run UUIDs are preserved. Neither format is silently
interpreted as the other. The old shadow `run` API continues to work; an unbound
shadow receipt requires explicit reconciliation before retained preparation and
cannot be adopted merely because bytes match.

## Bounded copy and verification

The shared primitive preserves the [IBKR protocol](provider-ibkr-auxiliary-transfer.md):

- `run_retained(family:, expected_context: nil)` returns an immutable receipt with
  original checkpoint/context and monotone copy/verification chunk counts.
- `verify_retained_page(family:, cursor: nil, limit: 4)` rereads current ranges and
  compares original encrypted chunks without changing the completed receipt.
  Continuations pin original source/target/copy and page size.
- `each_archived_chunk` validates the full archive before yielding bytes for a
  separately authorized recovery operation; it never creates a storage object.

Operations enter the actual exclusive item fence outside DB transactions. Short
guarded steps lock and recheck the disabled unused connection, main copy, source
attachment/blob metadata, checkpoint inventory and target binding. Storage reads
happen between those transactions. An absent logo has an explicit zero-chunk
receipt, including on connections with no external accounts. Completion creates
only an attachment to the original blob, bypassing upload, analysis, source-touch
and purge callbacks. A conflicting target is left untouched and rejected.

Limits remain 32 MiB per logo, 256 KiB manifest metadata, 1 MiB checkpoint state,
1 KiB to 1 MiB per chunk and eight remote ranges per call. Stored size checks
precede materialization. The terminal archive checksum pass may read all 32 MiB
of encrypted chunks from the database; the remote page limit does not bound that
DB work. Completion verifies the original ActiveStorage checksum and a SHA-256.
Byte, metadata or target drift stops progress. Separate calls cannot prove that
storage remained unchanged between them.

Lost checkpoints with surviving chunks cannot recreate the child. Mutating main
copy restart and return to legacy also reject auxiliary evidence, including after
checkpoint loss. Read-only retained comparison remains permitted. Evidence is
preserved for explicit recovery, not discarded to make preparation succeed.

## Preparation integration

[MigrationPreparation](provider-migration-preparation.md) captures one logo input
after inventory and before financial identities, then independently reverifies it
after fresh copy/identity sweeps. The parent commits child IDs/context and chunk
progress through its compare-and-swap boundary. A child commit followed by parent
failure resumes the same archive. Final retries and new verification runs reset
only parent page progress.

IBKR retains input kind `ibkr_auxiliary/v1`; the other 19 use `provider_logo/v1`.
Binance has one connection logo scope plus one history disposition per account,
so its expected count is `1 + inventory_count`. Its final sweep verifies the logo
first, then account history. Unlinked/unsupported accounts remain unresolved even
when the logo passes. Other logo providers have one integrated scope. An absent
logo counts as a checked auxiliary disposition, not discovered data.

All 20 contracts remain `partial`; the three providers without integrated handlers
remain `not_integrated`. The exact v2 input contract changed for the 19 newly
included providers. Older progress lacking the logo scope is rejected, including
terminal progress; there is no silent upgrade or reset. Existing IBKR v2 receipts
retain their exact contract. Lost parent progress cannot adopt a standalone child,
including a zero-account or no-logo receipt.

Tests cover the declared-provider inventory, non-IBKR bytes/absence, fresh workers,
storage and parent interruption, final sweeps, foreign family, source/target drift,
missing checkpoints and prior contracts. IBKR tests assert old format/key/signer
compatibility; Binance tests now count both scope kinds. Run these with copier,
identity evidence and preparation suites before deployment. Attachment lifecycle,
deletion/variant behavior, storage-service behavior and cutover remain acceptance
requirements.
